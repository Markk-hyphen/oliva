<?php
declare(strict_types=1);

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit; }

const HUB     = 'http://localhost/.well-known/mercure';
const SECRET  = '!ChangeThisSecret!'; // must match Caddyfile publisher_jwt key
const TOPIC   = 'https://oliva.dev/live';
const CLIENTS = '/tmp/oliva_clients';

function b64url(string $d): string {
    return rtrim(strtr(base64_encode($d), '+/', '-_'), '=');
}
function jwt(): string {
    $h = b64url(json_encode(['alg' => 'HS256', 'typ' => 'JWT']));
    $p = b64url(json_encode(['mercure' => ['publish' => ['*']]]));
    return "$h.$p." . b64url(hash_hmac('sha256', "$h.$p", SECRET, true));
}
function publish(array $data): void {
    $ctx = stream_context_create(['http' => [
        'method'  => 'POST',
        'header'  => "Content-Type: application/x-www-form-urlencoded\r\nAuthorization: Bearer " . jwt(),
        'content' => http_build_query(['topic' => TOPIC, 'data' => json_encode($data)]),
        'timeout' => 3,
        'ignore_errors' => true,
    ]]);
    @file_get_contents(HUB, false, $ctx);
}
function clients(int $delta): int {
    $fp = fopen(CLIENTS, 'c+');
    flock($fp, LOCK_EX);
    $n = max(0, ((int) stream_get_contents($fp)) + $delta);
    ftruncate($fp, 0); rewind($fp); fwrite($fp, (string) $n);
    flock($fp, LOCK_UN); fclose($fp);
    return $n;
}

$body = json_decode(file_get_contents('php://input'), true) ?? [];
$type = $body['type'] ?? '';

header('Content-Type: application/json');

match ($type) {
    'join'     => publish(['type' => 'clients', 'payload' => ['count' => clients(+1), 'joined' => true]]),
    'leave'    => publish(['type' => 'clients', 'payload' => ['count' => clients(-1), 'joined' => false]]),
    'draw', 'reaction', 'clear'
               => publish(['type' => $type, 'payload' => $body['payload'] ?? null]),
    default    => (function () { http_response_code(400); echo json_encode(['error' => 'unknown type']); exit; })(),
};

echo json_encode(['ok' => true]);

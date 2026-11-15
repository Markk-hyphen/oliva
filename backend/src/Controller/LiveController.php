<?php

namespace App\Controller;

use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\Mercure\HubInterface;
use Symfony\Component\Mercure\Update;
use Symfony\Component\Routing\Attribute\Route;

/**
 * The live demo's publish endpoint: relays what a browser does (draw, react,
 * join) to every other browser through the Mercure hub.
 *
 * It is part of the demo, not of the framework: `./oliva init` removes it
 * together with frontend/src/js/live.js. It publishes through the configured
 * hub, so it uses whatever key this machine generated.
 */
class LiveController
{
    private const TOPIC = 'https://oliva.dev/live';
    private const CLIENTS = '/tmp/oliva_clients';

    #[Route('/api/live', methods: ['POST'])]
    public function __invoke(Request $request, HubInterface $hub): JsonResponse
    {
        $body = json_decode($request->getContent(), true) ?? [];
        $type = $body['type'] ?? '';

        $data = match ($type) {
            'join' => ['type' => 'clients', 'payload' => ['count' => $this->clients(+1), 'joined' => true]],
            'leave' => ['type' => 'clients', 'payload' => ['count' => $this->clients(-1), 'joined' => false]],
            'draw', 'reaction', 'clear' => ['type' => $type, 'payload' => $body['payload'] ?? null],
            default => null,
        };
        if (null === $data) {
            return new JsonResponse(['error' => 'unknown type'], 400);
        }

        $hub->publish(new Update(self::TOPIC, json_encode($data)));

        return new JsonResponse(['ok' => true]);
    }

    private function clients(int $delta): int
    {
        $fp = fopen(self::CLIENTS, 'c+');
        flock($fp, LOCK_EX);
        $n = max(0, ((int) stream_get_contents($fp)) + $delta);
        ftruncate($fp, 0);
        rewind($fp);
        fwrite($fp, (string) $n);
        flock($fp, LOCK_UN);
        fclose($fp);

        return $n;
    }
}

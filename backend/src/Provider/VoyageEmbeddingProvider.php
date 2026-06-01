<?php

namespace App\Provider;

use Symfony\Contracts\HttpClient\HttpClientInterface;

class VoyageEmbeddingProvider implements EmbeddingProviderInterface
{
    private const MODEL = 'voyage-3';

    public function __construct(
        private readonly HttpClientInterface $httpClient,
        private readonly string $apiKey,
    ) {}

    public function embed(string $text): ?array
    {
        if ('' === $this->apiKey) {
            return null;
        }

        $response = $this->httpClient->request('POST', 'https://api.voyageai.com/v1/embeddings', [
            'headers' => [
                'Authorization' => 'Bearer ' . $this->apiKey,
                'content-type'  => 'application/json',
            ],
            'json' => [
                'model'      => self::MODEL,
                'input'      => [$text],
                'input_type' => 'document',
            ],
        ]);

        $data = $response->toArray();

        return $data['data'][0]['embedding'] ?? null;
    }
}

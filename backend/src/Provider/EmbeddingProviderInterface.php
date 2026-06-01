<?php

namespace App\Provider;

interface EmbeddingProviderInterface
{
    /**
     * Returns a dense vector for semantic search, or null if the provider is unavailable.
     *
     * @return float[]|null
     */
    public function embed(string $text): ?array;
}

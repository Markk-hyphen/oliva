<?php

namespace App\Provider;

interface EnrichmentProviderInterface
{
    /**
     * @param string $contentHash SHA-256 of the article URL — used as local cache key
     */
    public function enrich(string $contentHash, string $title, ?string $body): EnrichmentResult;
}

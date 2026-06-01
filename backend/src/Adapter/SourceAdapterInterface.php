<?php

namespace App\Adapter;

interface SourceAdapterInterface
{
    public function getId(): string;

    /**
     * Fetch raw items from the source.
     *
     * Each item is an array with keys:
     *   externalId  (string)  — original GUID/ID from the feed
     *   title       (string)
     *   url         (string)
     *   body        (string|null)
     *   publishedAt (\DateTimeImmutable)
     *
     * @return iterable<array<string, mixed>>
     */
    public function fetch(): iterable;
}

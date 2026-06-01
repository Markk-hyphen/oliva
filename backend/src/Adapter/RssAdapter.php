<?php

namespace App\Adapter;

use Symfony\Contracts\HttpClient\HttpClientInterface;

class RssAdapter implements SourceAdapterInterface
{
    public function __construct(
        private readonly HttpClientInterface $httpClient,
        private readonly string $sourceId,
        private readonly string $feedUrl,
    ) {}

    public function getId(): string
    {
        return $this->sourceId;
    }

    public function fetch(): iterable
    {
        $response = $this->httpClient->request('GET', $this->feedUrl, [
            'timeout' => 10,
            'headers' => ['Accept' => 'application/rss+xml, application/xml, text/xml'],
        ]);

        $xml = new \SimpleXMLElement($response->getContent());
        $items = $xml->channel->item ?? [];

        foreach ($items as $item) {
            $guid = (string) ($item->guid ?? $item->link);
            $url  = (string) $item->link;

            if ('' === $url) {
                continue;
            }

            $body = null;
            // Prefer full content when the feed provides it
            $namespaces = $item->getNamespaces(true);
            if (isset($namespaces['content'])) {
                $content = $item->children($namespaces['content']);
                $encoded = (string) ($content->encoded ?? '');
                if ('' !== $encoded) {
                    $body = strip_tags($encoded);
                }
            }
            if (null === $body) {
                $desc = (string) ($item->description ?? '');
                $body = '' !== $desc ? strip_tags($desc) : null;
            }

            $pubDate = (string) ($item->pubDate ?? '');
            try {
                $publishedAt = new \DateTimeImmutable($pubDate !== '' ? $pubDate : 'now');
            } catch (\Exception) {
                $publishedAt = new \DateTimeImmutable();
            }

            yield [
                'externalId'  => $guid !== '' ? $guid : $url,
                'title'       => strip_tags((string) ($item->title ?? '')),
                'url'         => $url,
                'body'        => $body,
                'publishedAt' => $publishedAt,
            ];
        }
    }
}

<?php

namespace App\Entity;

use App\Repository\NewsItemRepository;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity(repositoryClass: NewsItemRepository::class)]
#[ORM\Table(name: 'news_item')]
#[ORM\UniqueConstraint(name: 'uniq_content_hash', columns: ['content_hash'])]
#[ORM\Index(name: 'idx_news_item_status', columns: ['status'])]
#[ORM\Index(name: 'idx_news_item_published_at', columns: ['published_at'])]
class NewsItem
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    private ?int $id = null;

    /** Identifies the origin feed: e.g. 'coindesk-rss', 'cointelegraph-rss' */
    #[ORM\Column(length: 64)]
    private string $source;

    /** Original GUID/ID from the source feed */
    #[ORM\Column(length: 512)]
    private string $externalId;

    #[ORM\Column(length: 512)]
    private string $title;

    #[ORM\Column(length: 2048)]
    private string $url;

    #[ORM\Column(type: 'text', nullable: true)]
    private ?string $body = null;

    #[ORM\Column(type: 'datetime_immutable')]
    private \DateTimeImmutable $publishedAt;

    /** SHA-256 of url — used for deduplication across fetches */
    #[ORM\Column(length: 64)]
    private string $contentHash;

    #[ORM\Column(type: 'string', length: 16, enumType: NewsItemStatus::class)]
    private NewsItemStatus $status = NewsItemStatus::Pending;

    #[ORM\Column(type: 'datetime_immutable')]
    private \DateTimeImmutable $createdAt;

    #[ORM\OneToOne(mappedBy: 'newsItem', cascade: ['persist', 'remove'])]
    private ?Enrichment $enrichment = null;

    public function __construct()
    {
        $this->createdAt = new \DateTimeImmutable();
    }

    public function getId(): ?int { return $this->id; }

    public function getSource(): string { return $this->source; }
    public function setSource(string $source): static { $this->source = $source; return $this; }

    public function getExternalId(): string { return $this->externalId; }
    public function setExternalId(string $externalId): static { $this->externalId = $externalId; return $this; }

    public function getTitle(): string { return $this->title; }
    public function setTitle(string $title): static { $this->title = $title; return $this; }

    public function getUrl(): string { return $this->url; }
    public function setUrl(string $url): static { $this->url = $url; return $this; }

    public function getBody(): ?string { return $this->body; }
    public function setBody(?string $body): static { $this->body = $body; return $this; }

    public function getPublishedAt(): \DateTimeImmutable { return $this->publishedAt; }
    public function setPublishedAt(\DateTimeImmutable $publishedAt): static { $this->publishedAt = $publishedAt; return $this; }

    public function getContentHash(): string { return $this->contentHash; }
    public function setContentHash(string $contentHash): static { $this->contentHash = $contentHash; return $this; }

    public function getStatus(): NewsItemStatus { return $this->status; }
    public function setStatus(NewsItemStatus $status): static { $this->status = $status; return $this; }

    public function getCreatedAt(): \DateTimeImmutable { return $this->createdAt; }

    public function getEnrichment(): ?Enrichment { return $this->enrichment; }
}

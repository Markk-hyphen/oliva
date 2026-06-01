<?php

namespace App\MessageHandler;

use App\Entity\Enrichment;
use App\Entity\NewsItemStatus;
use App\Message\EnrichItemMessage;
use App\Provider\EmbeddingProviderInterface;
use App\Provider\EnrichmentProviderInterface;
use App\Repository\NewsItemRepository;
use Doctrine\ORM\EntityManagerInterface;
use Psr\Log\LoggerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
class EnrichItemHandler
{
    public function __construct(
        private readonly NewsItemRepository $newsItemRepo,
        private readonly EnrichmentProviderInterface $enrichmentProvider,
        private readonly EmbeddingProviderInterface $embeddingProvider,
        private readonly EntityManagerInterface $em,
        private readonly LoggerInterface $logger,
    ) {}

    public function __invoke(EnrichItemMessage $message): void
    {
        $item = $this->newsItemRepo->find($message->newsItemId);

        if (null === $item) {
            $this->logger->warning('EnrichItemHandler: NewsItem not found', ['id' => $message->newsItemId]);
            return;
        }

        if ($item->getStatus() !== NewsItemStatus::Pending) {
            $this->logger->info('EnrichItemHandler: already processed, skipping', [
                'id'     => $message->newsItemId,
                'status' => $item->getStatus()->value,
            ]);
            return;
        }

        $result = $this->enrichmentProvider->enrich(
            $item->getContentHash(),
            $item->getTitle(),
            $item->getBody(),
        );

        $embedding = $this->embeddingProvider->embed(
            $item->getTitle() . "\n" . ($item->getBody() ?? '')
        );

        $enrichment = (new Enrichment())
            ->setNewsItem($item)
            ->setSummary($result->summary)
            ->setSentiment($result->sentiment)
            ->setAssetClass($result->assetClass)
            ->setTickers($result->tickers)
            ->setEntities($result->entities)
            ->setEmbedding($embedding)
            ->setModel($result->model)
            ->setTokens($result->totalTokens)
            ->setCostUsd($result->costUsd);

        $item->setStatus(NewsItemStatus::Enriched);

        $this->em->persist($enrichment);
        $this->em->flush();

        // Step 1.5 will publish the enriched item to Mercure here.

        $this->logger->info('EnrichItemHandler: enriched', [
            'id'       => $item->getId(),
            'model'    => $result->model,
            'tokens'   => $result->totalTokens,
            'cost_usd' => $result->costUsd,
            'embedding' => null !== $embedding ? \count($embedding) . 'd' : 'null',
        ]);
    }
}

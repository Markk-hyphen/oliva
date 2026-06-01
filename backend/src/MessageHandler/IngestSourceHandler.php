<?php

namespace App\MessageHandler;

use App\Adapter\SourceAdapterInterface;
use App\Entity\NewsItem;
use App\Message\EnrichItemMessage;
use App\Message\IngestSourceMessage;
use App\Repository\NewsItemRepository;
use Doctrine\ORM\EntityManagerInterface;
use Psr\Log\LoggerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\MessageBusInterface;

#[AsMessageHandler]
class IngestSourceHandler
{
    /** @param iterable<SourceAdapterInterface> $adapters */
    public function __construct(
        private readonly iterable $adapters,
        private readonly NewsItemRepository $newsItemRepo,
        private readonly EntityManagerInterface $em,
        private readonly MessageBusInterface $bus,
        private readonly LoggerInterface $logger,
    ) {}

    public function __invoke(IngestSourceMessage $message): void
    {
        $adapter = $this->findAdapter($message->sourceId);
        if (null === $adapter) {
            $this->logger->warning('No adapter found for source', ['sourceId' => $message->sourceId]);
            return;
        }

        $persisted = 0;
        $skipped   = 0;

        foreach ($adapter->fetch() as $raw) {
            $hash = hash('sha256', $raw['url']);

            if ($this->newsItemRepo->findOneBy(['contentHash' => $hash])) {
                ++$skipped;
                continue;
            }

            $item = (new NewsItem())
                ->setSource($message->sourceId)
                ->setExternalId($raw['externalId'])
                ->setTitle($raw['title'])
                ->setUrl($raw['url'])
                ->setBody($raw['body'])
                ->setPublishedAt($raw['publishedAt'])
                ->setContentHash($hash);

            $this->em->persist($item);
            $this->em->flush();

            $this->bus->dispatch(new EnrichItemMessage($item->getId()));
            ++$persisted;
        }

        $this->logger->info('Ingest complete', [
            'sourceId'  => $message->sourceId,
            'persisted' => $persisted,
            'skipped'   => $skipped,
        ]);
    }

    private function findAdapter(string $sourceId): ?SourceAdapterInterface
    {
        foreach ($this->adapters as $adapter) {
            if ($adapter->getId() === $sourceId) {
                return $adapter;
            }
        }
        return null;
    }
}

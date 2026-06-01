<?php

namespace App\MessageHandler;

use App\Message\IngestSourceMessage;
use Psr\Log\LoggerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
class IngestSourceHandler
{
    public function __construct(private readonly LoggerInterface $logger) {}

    public function __invoke(IngestSourceMessage $message): void
    {
        // Stub — real ingestion logic arrives in Phase 1
        $this->logger->info('IngestSourceHandler: stub no-op', ['sourceId' => $message->sourceId]);
    }
}

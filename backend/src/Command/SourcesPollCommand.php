<?php

namespace App\Command;

use App\Adapter\SourceAdapterInterface;
use App\Message\IngestSourceMessage;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Messenger\MessageBusInterface;

#[AsCommand(name: 'app:sources:poll', description: 'Poll configured sources and enqueue ingestion jobs')]
class SourcesPollCommand extends Command
{
    /** @param iterable<SourceAdapterInterface> $adapters */
    public function __construct(
        private readonly MessageBusInterface $bus,
        private readonly iterable $adapters,
    ) {
        parent::__construct();
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        foreach ($this->adapters as $adapter) {
            $this->bus->dispatch(new IngestSourceMessage($adapter->getId()));
            $output->writeln(sprintf('[%s] Enqueued: %s', date('Y-m-d H:i:s'), $adapter->getId()));
        }

        return Command::SUCCESS;
    }
}

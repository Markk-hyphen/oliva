<?php

namespace App\Command;

use App\Entity\NewsItemStatus;
use App\Message\EnrichItemMessage;
use App\Repository\NewsItemRepository;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Messenger\MessageBusInterface;

#[AsCommand(
    name: 'app:enrich:requeue-pending',
    description: 'Dispatch EnrichItemMessage for every NewsItem still in pending status',
)]
class EnrichRequeueCommand extends Command
{
    public function __construct(
        private readonly NewsItemRepository $newsItemRepo,
        private readonly MessageBusInterface $bus,
    ) {
        parent::__construct();
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $items = $this->newsItemRepo->findBy(['status' => NewsItemStatus::Pending]);

        foreach ($items as $item) {
            $this->bus->dispatch(new EnrichItemMessage($item->getId()));
        }

        $output->writeln(\sprintf('[%s] Requeued %d pending items.', date('Y-m-d H:i:s'), \count($items)));

        return Command::SUCCESS;
    }
}

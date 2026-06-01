<?php

namespace App\Message;

final class EnrichItemMessage
{
    public function __construct(
        public readonly int $newsItemId,
    ) {}
}

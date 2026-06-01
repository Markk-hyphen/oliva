<?php

namespace App\Tests\Unit\Message;

use App\Message\IngestSourceMessage;
use PHPUnit\Framework\TestCase;

class IngestSourceMessageTest extends TestCase
{
    public function testSourceIdIsPreserved(): void
    {
        $message = new IngestSourceMessage('coindesk-rss');

        $this->assertSame('coindesk-rss', $message->sourceId);
    }

    public function testSourceIdCanBeEmpty(): void
    {
        $message = new IngestSourceMessage('');

        $this->assertSame('', $message->sourceId);
    }
}

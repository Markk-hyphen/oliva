<?php

namespace App\Tests\Controller;

use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;

/**
 * The example to copy for a first integration test: it boots the kernel in the
 * test environment and goes through the router, like a real request.
 */
class HealthControllerTest extends WebTestCase
{
    public function testHealthAnswersOk(): void
    {
        $client = static::createClient();
        $client->request('GET', '/health');

        self::assertResponseIsSuccessful();
        self::assertJsonStringEqualsJsonString('{"status":"ok"}', (string) $client->getResponse()->getContent());
    }
}

<?php

namespace App\Entity;

enum NewsItemStatus: string
{
    case Pending  = 'pending';
    case Enriched = 'enriched';
    case Failed   = 'failed';
}

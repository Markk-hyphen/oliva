#!/bin/sh
# oliva-relay — the command of the `realtime-relay` service (docker-compose.yml, profile
# `realtime`). It is the only publisher to the Mercure hub: the backend dispatches a
# Symfony\Component\Mercure\Update to the `realtime` transport (Doctrine/PostgreSQL) and
# this relay consumes it and POSTs it to the hub. The request path never waits on the hub
# (E-unbundle-roles, decisions phase 2).
#
# --sleep=0.01 AND the transport's get_notify_timeout (messenger.yaml) are BOTH required:
# with either alone the latency is ~1s, because after each message the next poll runs
# without LISTEN and the worker sleeps the full --sleep (measured, runbook G1-G3).
set -e

# The table lives only where this service runs: an app without the `realtime` profile never
# gets it, and its doctrine:schema:validate stays green (a schema_filter hides the table).
# The relay creates it on start; it is idempotent.
php bin/console messenger:setup-transports realtime

exec php bin/console messenger:consume realtime --sleep=0.01 --time-limit=3600 --memory-limit=128M

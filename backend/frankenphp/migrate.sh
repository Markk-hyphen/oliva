#!/bin/bash
# oliva-migrate — the command of the one-shot `migrate` service (docker-compose.yml).
#
# The database lifecycle used to run inside the server's entrypoint, on every start of
# the backend container. A failed migration then put the backend in a restart loop while
# `up -d` reported success (E-backend-slot, finding M1). As its own service, a failed
# migration stops the stack from coming up: `up --wait` fails with this service's exit
# code, and every PHP service waits for it (`service_completed_successfully`).
#
# Contract (backend slot, "Migrate"): idempotent, non-zero on failure, logs to stdout.
# Running two at once is safe without a lock: measured, see the epic (step 2).
set -euo pipefail

# Wait for the database. In standalone, depends_on (database healthy) already orders it;
# in shared infra there is no local database to depend on, so this loop is the order.
echo 'oliva-migrate: waiting for the database...'
attempts=60
until db_error="$(php bin/console dbal:run-sql -q 'SELECT 1' 2>&1)"; do
	rc=$?
	if [ "$rc" -eq 255 ]; then
		# Doctrine exits 255 on an unrecoverable error (bad credentials, unknown host...).
		attempts=0
	fi
	attempts=$((attempts - 1))
	if [ "$attempts" -le 0 ]; then
		echo 'oliva-migrate: the database is not up or not reachable:' >&2
		echo "$db_error" >&2
		exit 1
	fi
	sleep 1
done
echo 'oliva-migrate: the database is reachable'

if [ -z "$(find ./migrations -iname '*.php' -print -quit 2>/dev/null)" ]; then
	echo 'oliva-migrate: no migrations, nothing to do'
	exit 0
fi

exec php bin/console doctrine:migrations:migrate --no-interaction --all-or-nothing

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

# The driver's own message, without Symfony's console box or the command's usage text
# (until 1.12.0 the last line printed was `dbal:run-sql`'s usage, not the error).
db_reason() {
	printf '%s\n' "$1" | grep -E 'SQLSTATE|FATAL|could not|Connection refused|timeout' \
		| sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'NF' | tail -1 || true
}
# `|| true`: under `set -euo pipefail` a message with none of those words would make grep
# fail and kill the script on the assignment below (the class of bug of friction X17).

attempts=60
# COLUMNS: Symfony's console wraps an error box at the terminal width, which cut the driver's
# message in pieces; wide enough, it stays on one line for db_reason.
until db_error="$(COLUMNS=1000 php bin/console dbal:run-sql -q 'SELECT 1' 2>&1)"; do
	rc=$?
	reason="$(db_reason "$db_error")"
	# Errors that waiting cannot fix: give up at once instead of retrying for a minute
	# (measured: a wrong password was retried 60 times, 67 s). A host that does not resolve
	# yet, or refuses connections, is still retried: the database may be starting.
	if [ "$rc" -eq 255 ] || printf '%s' "$db_error" | grep -qiE \
		'password authentication failed|database "[^"]*" does not exist|role "[^"]*" does not exist|no pg_hba\.conf entry'; then
		attempts=0
	fi
	attempts=$((attempts - 1))
	if [ "$attempts" -le 0 ]; then
		echo "$db_error" >&2
		echo "oliva-migrate: cannot reach the database: ${reason:-see the output above}" >&2
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

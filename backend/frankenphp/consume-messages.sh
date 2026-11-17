#!/bin/sh
# oliva-consume — the command of the `worker` service (docker-compose.yml).
#
# WORKER_CONSUME_ARGS (backend environment: .env.backend, tracked, the app's decision)
# replaces every argument after `messenger:consume`. Empty or unset: consume every
# transport except the app's failure transport, and recycle the process by time and
# memory; the service's `restart:` brings it back.
#
# Why a script and not the variable in `command:`: Compose interpolates `command:` only
# from the project's .env, never from an env_file such as .env.backend, so the arguments
# have to be expanded inside the container. And not `sh -c` in the compose file: $1 would
# be `sh` in docker-entrypoint, the trap backend/Dockerfile warns about.
#
# Transport names have no spaces, so the arguments are split on whitespace and quoting
# inside the variable is not supported.
set -e

if [ -n "${WORKER_CONSUME_ARGS:-}" ]; then
	# shellcheck disable=SC2086  # word splitting on purpose: the value is a list of arguments
	exec php bin/console messenger:consume $WORKER_CONSUME_ARGS
fi

# The failure transport is excluded: consuming it in the same loop retries a poison
# message forever, with no delay. Its name is asked to Symfony, not assumed: Symfony
# ignores an --exclude-receivers that names no transport, so a hardcoded `failed` would
# silently stop excluding anything in an app that renamed it. If Symfony can't be asked,
# keep Oliva's name; if the app has no failure transport (`null`), exclude nothing.
if failure="$(php bin/console debug:config framework messenger.failure_transport 2>/dev/null)"; then
	failure="$(printf '%s\n' "$failure" | awk 'NF { v = $1 } END { print v }')"
else
	failure=failed
fi
case "$failure" in
	'' | null | '~') exclude='' ;;
	*) exclude="--exclude-receivers=$failure" ;;
esac

# shellcheck disable=SC2086  # $exclude is empty or a single argument
exec php bin/console messenger:consume --all $exclude --time-limit=3600 --memory-limit=128M

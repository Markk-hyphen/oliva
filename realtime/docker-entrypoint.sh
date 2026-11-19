#!/bin/sh
# The hub verifies publisher and subscriber tokens with MERCURE_PUBLISHER_JWT_KEY. Oliva's
# Caddyfile gives it no default (an empty key must not silently become a working hub), so
# an empty, placeholder or publicly known key stops the hub here — in EVERY environment:
# the hub cannot tell which one it runs in, and `env check` already treats a public secret
# as an error everywhere (E-unbundle-roles, decisions phase 2). Mirrors the backend
# entrypoint's net, with the same known-public list.
set -e

key="${MERCURE_PUBLISHER_JWT_KEY:-}"
problem=""
if [ -z "$key" ]; then
	problem="is empty"
else
	case "$key" in your_*|generate_with_*|changeme*|*_here) problem="is a placeholder" ;; esac
	if [ -z "$problem" ] && grep -q "^$(printf %s "$key" | sha256sum | cut -d' ' -f1) " \
		/usr/local/share/oliva/known-public-secrets.sha256 2>/dev/null; then
		problem="is a publicly known value"
	fi
fi
if [ -n "$problem" ]; then
	echo "!! MERCURE_PUBLISHER_JWT_KEY $problem: refusing to start the Mercure hub." >&2
	echo "!! Fix: ./oliva env init (it generates the missing secrets in .env), then recreate." >&2
	echo "!!      Secrets live in .env, never in .env.backend (it is tracked)." >&2
	exit 1
fi

exec "$@"

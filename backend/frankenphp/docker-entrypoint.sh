#!/bin/bash
set -e
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

# In production, a secret that is empty, a placeholder or publicly known is no secret at
# all, and nothing downstream would notice: Symfony falls back to the placeholders baked
# from .env, the hub accepts any key. So the container refuses to start. This is the net
# under scripts/deploy.sh (which checks before stopping anything): it also covers a plain
# `docker compose up` and every container of this image (scheduler, worker).
# Staging only warns: its data is disposable. The list is Oliva's (known-public-secrets.sha256).
oliva_secret_problem() {
	if [ -z "$1" ]; then echo 'is empty'; return 0; fi
	case "$1" in your_*|generate_with_*|changeme*|*_here) echo 'is a placeholder'; return 0 ;; esac
	if grep -q "^$(printf %s "$1" | sha256sum | cut -d' ' -f1) " /usr/local/share/oliva/known-public-secrets.sha256 2>/dev/null; then
		echo 'is a publicly known value'; return 0
	fi
	return 1
}
if [ "${APP_ENV:-}" = 'prod' ] || [ "${APP_ENV:-}" = 'staging' ]; then
	oliva_bad=0
	for oliva_var in APP_SECRET JWT_PASSPHRASE MERCURE_JWT_SECRET; do
		if oliva_why="$(oliva_secret_problem "${!oliva_var:-}")"; then
			echo "!! $oliva_var $oliva_why" >&2; oliva_bad=1
		fi
	done
	if [ "$oliva_bad" = 1 ] && [ "$APP_ENV" = 'prod' ]; then
		echo '!! Refusing to start in production on these secrets.' >&2
		echo '!! Fix, on the machine that runs this stack: ./oliva env init' >&2
		echo '!!      then recreate the containers (./scripts/deploy.sh, or docker compose up -d).' >&2
		echo '!!      Secrets live in .env, never in a tracked file.' >&2
		exit 1
	elif [ "$oliva_bad" = 1 ]; then
		echo '!! staging: starting anyway. Fix: ./oliva env init' >&2
	fi
fi

# The Mercure hub moved to its own `realtime` service (1.10.0), which owns the empty-key
# refusal now (realtime/docker-entrypoint.sh). The backend no longer serves Mercure; it
# only signs tokens, with MERCURE_JWT_SECRET (checked above in prod/staging).

# A queue consumer never runs the setup below (JWT keys, wait-for-db, migrations, ACLs):
# the backend does it, and the worker starts only once the backend is healthy, that is,
# migrated (depends_on in docker-compose.yml). Until 1.8.0 the dev worker ran `migrate` at
# the same time as the backend. The worker's own command (oliva-consume) never matches the
# list; the messenger:consume check covers an app whose override still runs it directly.
oliva_setup=0
if [ "$1" = 'frankenphp' ] || [ "$1" = 'php' ] || [ "$1" = 'bin/console' ]; then oliva_setup=1; fi
if [ "${2:-}" = 'messenger:consume' ] || [ "${3:-}" = 'messenger:consume' ]; then oliva_setup=0; fi

if [ "$oliva_setup" = 1 ]; then
	# Generate JWT keys if they don't exist (first deploy or fresh environment)
    JWT_DIR="$PROJECT_DIR/config/jwt"

    if [ -n "$JWT_PASSPHRASE" ] && [ ! -f "$JWT_DIR/private.pem" ]; then
    	echo "Generating JWT keys in $JWT_DIR..."
    	mkdir -p "$JWT_DIR"
		openssl genrsa -aes256 -passout pass:"$JWT_PASSPHRASE" -out "$JWT_DIR/private.pem" 2048
        openssl rsa -pubout -in "$JWT_DIR/private.pem" -out "$JWT_DIR/public.pem" --passin pass:"$JWT_PASSPHRASE"
        echo "JWT keys generated."
    fi

	if grep -q ^DATABASE_URL= .env; then
		echo 'Waiting for database to be ready...'
		ATTEMPTS_LEFT_TO_REACH_DATABASE=60
		until [ $ATTEMPTS_LEFT_TO_REACH_DATABASE -eq 0 ] || DATABASE_ERROR=$(php bin/console dbal:run-sql -q "SELECT 1" 2>&1); do
			if [ $? -eq 255 ]; then
				# If the Doctrine command exits with 255, an unrecoverable error occurred
				ATTEMPTS_LEFT_TO_REACH_DATABASE=0
				break
			fi
			sleep 1
			ATTEMPTS_LEFT_TO_REACH_DATABASE=$((ATTEMPTS_LEFT_TO_REACH_DATABASE - 1))
			echo "Still waiting for database to be ready... Or maybe the database is not reachable. $ATTEMPTS_LEFT_TO_REACH_DATABASE attempts left."
		done

		if [ $ATTEMPTS_LEFT_TO_REACH_DATABASE -eq 0 ]; then
			echo 'The database is not up or not reachable:'
			echo "$DATABASE_ERROR"
			exit 1
		else
			echo 'The database is now ready and reachable'
		fi

		if [ "$( find ./migrations -iname '*.php' -print -quit )" ]; then
			php bin/console doctrine:migrations:migrate --no-interaction --all-or-nothing
		fi
	fi

	# `id -u` (UID numérico), NO `whoami`: en dev el container corre como el usuario
	# del host (docker-compose.override.yml), un UID que no tiene entrada en el
	# /etc/passwd de la imagen → `whoami` falla con "no passwd entry" y, con `set -e`,
	# mata el entrypoint. El UID numérico no necesita passwd y el dueño de `var` (host
	# en dev vía bind-mount, root en prod) puede setear su propia ACL. Sirve para ambos.
	setfacl -R -m u:www-data:rwX -m u:"$(id -u)":rwX var
	setfacl -dR -m u:www-data:rwX -m u:"$(id -u)":rwX var

	echo 'PHP app ready!'
fi

exec docker-php-entrypoint "$@"

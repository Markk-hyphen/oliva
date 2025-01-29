#!/bin/bash
set -e
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

MERCURE_KEYS_DIR="$PROJECT_DIR/config/mercure"
MERCURE_JWT_KEY="$MERCURE_KEYS_DIR/mercure.key"



if [ "$1" = 'frankenphp' ] || [ "$1" = 'php' ] || [ "$1" = 'bin/console' ]; then
	# Install the project the first time PHP is started
	# After the installation, the following block can be deleted
    JWT_DIR="$PROJECT_DIR/config/jwt"
    JWT_CONFIG="$PROJECT_DIR/config/packages/lexik_jwt_authentication.yaml"

    if [ -n "$JWT_PASSPHRASE" ] && [ ! -f "$JWT_DIR/private.pem" ]; then
    	echo "Using JWT passphrase: $JWT_PASSPHRASE"
		echo "Generating JWT keys in $JWT_DIR..."
		echo "Creating JWT configuration file at $JWT_CONFIG..."

    	mkdir -p "$JWT_DIR" "$(dirname "$JWT_CONFIG")"
		openssl genrsa -aes256 -passout pass:"$JWT_PASSPHRASE" -out "$JWT_DIR/private.pem" 2048
        openssl rsa -pubout -in "$JWT_DIR/private.pem" -out "$JWT_DIR/public.pem" --passin pass:"$JWT_PASSPHRASE"
        echo "JWT keys generated."

    fi

	if [ ! -f "$MERCURE_JWT_KEY" ] || [ ! -s "$MERCURE_JWT_KEY" ]; then
    	echo "Generating Caddy Mercure JWT key.."
  		mkdir -p "$(dirname "$MERCURE_JWT_KEY")"

    	openssl rand -base64 -out "$MERCURE_JWT_KEY" 2048 || {
        	echo "Error: Failed to generate Caddy Mercure key."
        	exit 1
    	}

    	echo "Mercure key generated successfully."
	else
    	echo "Mercure keys already exists. Skipping generation."
	fi

	if grep -q ^DATABASE_URL= .env; then
    	echo 'To finish the installation please press Ctrl+C to stop Docker Compose and run: docker compose up --build -d --wait'
    	sleep infinity
    fi

	if [ -z "$(ls -A 'vendor/' 2>/dev/null)" ]; then
		composer install --prefer-dist --no-progress --no-interaction
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

	setfacl -R -m u:www-data:rwX -m u:"$(whoami)":rwX var
	setfacl -dR -m u:www-data:rwX -m u:"$(whoami)":rwX var

	echo 'PHP app ready!'
fi

export CADDY_MERCURE_JWT_SECRET=$(cat "$MERCURE_JWT_KEY")

echo "CADDY_MERCURE_JWT_KEY Key: ${CADDY_MERCURE_JWT_SECRET}"

exec docker-php-entrypoint "$@"

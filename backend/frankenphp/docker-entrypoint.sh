#!/bin/bash
set -e
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

if [ "$1" = 'frankenphp' ] || [ "$1" = 'php' ] || [ "$1" = 'bin/console' ]; then
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

	setfacl -R -m u:www-data:rwX -m u:"$(whoami)":rwX var
	setfacl -dR -m u:www-data:rwX -m u:"$(whoami)":rwX var

	echo 'PHP app ready!'
fi

exec docker-php-entrypoint "$@"

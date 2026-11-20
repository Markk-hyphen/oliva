#syntax=docker/dockerfile:1

# Versions
# Pinned to an exact version: the floating "1-php8.3" tag pulled 1.13.1 on a rebuild and
# its Mercure refused the existing hub config. Upgrade on purpose, then re-check Mercure.
#
# 1.13.2-php8.3.36 (2026-10-21) es un bump de SEGURIDAD, no de rutina:
#   - PHP 8.3.36 arregla PHP2Shell (CVE-2026-109618/109619, CVSS 9.2, RCE sin auth). El
#     109619 es estado de request stale que un worker reusa en el request siguiente → pega
#     de lleno en el worker mode de frankenphp_prod, no es un CVE de espectador.
#   - FrankenPHP 1.13.2 arregla además 4 vulns propias, 2 aplican acá: fuga de fragmentos
#     del input del cliente anterior vía error_get_last() en worker mode
#     (GHSA-4gfw-9v29-gp9h) y thread pool ocupable por un cliente sin auth que encola y
#     se desconecta (GHSA-fq24-r53r-xcx3). Sus upgrade notes son todas de static builds
#     (glibc 2.28, assets de macOS) → no nos tocan, usamos la imagen Docker.
# Existe `1.13.1-php8.3.36` (bump mínimo, solo PHP), pero se eligió 1.13.2 por esas 2
# vulns de worker mode. Es un patch dentro del mismo minor: sin riesgo de la regresión de
# Mercure de 1.13.0 (igual el step [mercure] de scripts/oliva/verify.sh la cubre).
# El fix NO toma efecto en procesos vivos: hay que RECREAR los containers, no reiniciar
# el servicio. scripts/deploy.sh ya hace `down` antes del `up`; el step [php-version] de
# verify.sh asserta que lo que corre coincide con este pin.
FROM dunglas/frankenphp:1.13.5-php8.3.36 AS frankenphp_upstream

# The different stages of this Dockerfile are meant to be built into separate images
# https://docs.docker.com/develop/develop-images/multistage-build/#stop-at-a-specific-build-stage
# https://docs.docker.com/compose/compose-file/#target


# Base FrankenPHP image
FROM frankenphp_upstream AS frankenphp_base

WORKDIR /app

ENV PROJECT_DIR=/app
ENV HTTP_PORT=80

# Trust X-Forwarded-* from private networks. Since 1.9.0 the stack's edge is the
# gateway, not the frontend: client IPs reach the backend as a header, not the
# TCP peer address. `PRIVATE_SUBNETS` is Symfony's shortcut for RFC 1918 + IPv6
# ULA, which is exactly the range the gateway (and, in shared infra, the edge
# proxy) will come from. Decision 6 of E-unbundle-roles, option A.
# NEVER set SYMFONY_TRUSTED_HEADERS: unset = `for, port, proto` (what we want);
# empty string = Symfony throws at boot. env-check.sh flags that too.
ENV SYMFONY_TRUSTED_PROXIES=PRIVATE_SUBNETS

VOLUME /app/var/

# persistent / runtime deps
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
	acl \
	curl \
	file \
	gettext \
	git \
	&& rm -rf /var/lib/apt/lists/*

# install-php-extensions (mlocati), pineado fresco (NO el que viene congelado en la base), SOLO
# para lo que NO pasa por pecl.php.net: @composer (de getcomposer.org) y las extensiones bundled
# de PHP (intl/opcache/pdo_pgsql/zip, que se compilan del source de PHP, no se bajan de pecl).
# amqp/apcu/xdebug ya NO van por acá: migraron a PIE (ver RUN siguiente y el stage dev) porque
# pecl.php.net está en phase-out (RFC adopt_pie_deprecate_pecl) y rompía el build con `exit 100`.
COPY --from=mlocati/php-extension-installer:2.12.3 /usr/bin/install-php-extensions /usr/local/bin/install-php-extensions

# pcntl: signals. PHP is PID 1 in the worker and the realtime relay (`exec php …`), and a
# PID 1 with no handler IGNORES SIGTERM: every `docker stop`/deploy waited 10 s and then
# SIGKILLed the consumer, mid-message if one was in flight (measured: exit 137, 10.3 s).
# With pcntl, Messenger stops between messages. Bundled with PHP, no pecl.
# (E-backend-slot, finding M2.)
RUN set -eux; \
	install-php-extensions \
		@composer-2.10.3 \
		intl \
		opcache \
		pcntl \
		pdo_pgsql \
		zip \
	;

# Extra extensions of the APP (backend/php-extensions.txt belongs to the fork; Oliva ships
# it empty). Lets a fork add e.g. bcmath without editing this file, which is Oliva's.
# Dos sintaxis por línea:
#   bcmath                       → bundled de PHP, por install-php-extensions (este RUN)
#   phpredis/phpredis:6.2.0      → paquete PIE (lleva `/`), por el RUN de PIE de abajo
# Una PECL con el formato viejo (`redis-6.2.0`) también funciona acá, pero baja de
# pecl.php.net (en phase-out, la causa del `exit 100` de 1.1.2): preferir el nombre PIE.
# El archivo entra con bind-mount, NO con `COPY --link ... /tmp/`: el `--link` le dejaba
# /tmp en 755 con el driver buildx `docker-container` (el del CI; el driver `docker` local
# no lo reproduce) y el sandbox `_apt` no podía escribir ahí → `exit 100` en todo fork con
# extensiones. Además así el archivo no queda en la imagen.
# hadolint ignore=DL4006,SC2086
RUN --mount=type=bind,source=php-extensions.txt,target=/run/oliva/php-extensions.txt \
	set -eux; \
	exts="$(grep -vE '^[[:space:]]*(#|$)' /run/oliva/php-extensions.txt | grep -v / || true)"; \
	if [ -n "$exts" ]; then install-php-extensions $exts; fi

# amqp + apcu con PIE (php/pie). La imagen oficial de PIE se monta SOLO en build-time
# (--mount=type=bind) → no queda en la imagen final. PIE baja de Packagist/GitHub, nunca de
# pecl.php.net (en phase-out, era la causa del `exit 100`). `pie install` compila Y habilita
# (escribe el .ini). Deps de build: el toolchain ($PHPIZE_DEPS) + unzip (PIE extrae zips) +
# librabbitmq-dev (amqp lo necesita para compilar); se purgan al final. librabbitmq-dev se deja
# a propósito: su runtime (librabbitmq) lo linkea amqp.so y un --auto-remove lo borraría.
# VA ÚLTIMO EN EL STAGE BASE, DESPUÉS del extension point del fork: ese purga el toolchain, y los
# `install-php-extensions` de arriba (incluido el del fork, ej. bcmath) necesitan gcc para
# compilar. Si esta purga corriera antes, el bcmath del fork fallaría con `gcc: not found` (127).
# Versiones pineadas exactas, igual que antes.
# También instala los paquetes PIE del fork (líneas con `/` de php-extensions.txt). PIE no
# instala libs de sistema: una extensión que las necesite va por el formato de
# install-php-extensions (que sí las resuelve) o hay que pedirla en Oliva.
# `-o APT::Sandbox::User=root`: defensa en profundidad — ya nada copia a /tmp, pero si un
# COPY --link futuro volviera a dejarlo en 755, apt seguiría andando.
# hadolint ignore=DL3008,DL4006,SC2086
RUN --mount=type=bind,from=ghcr.io/php/pie:1.5.3-bin,source=/pie,target=/usr/local/bin/pie \
	--mount=type=bind,source=php-extensions.txt,target=/run/oliva/php-extensions.txt \
	set -eux; \
	export DEBIAN_FRONTEND=noninteractive; \
	apt-get -o APT::Sandbox::User=root update; \
	apt-get install -y --no-install-recommends $PHPIZE_DEPS librabbitmq-dev unzip; \
	pie install --no-cache apcu/apcu:5.1.28; \
	pie install --no-cache php-amqp/php-amqp:2.2.0; \
	for p in $(grep -vE '^[[:space:]]*(#|$)' /run/oliva/php-extensions.txt | grep / || true); do \
		pie install --no-cache "$p"; \
	done; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $PHPIZE_DEPS unzip; \
	rm -rf /var/lib/apt/lists/*

# supercronic — used by the scheduler service
ENV SUPERCRONIC_VERSION=v0.2.46
RUN curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
	-o /usr/local/bin/supercronic \
	&& chmod +x /usr/local/bin/supercronic

# https://getcomposer.org/doc/03-cli.md#composer-allow-superuser
ENV COMPOSER_ALLOW_SUPERUSER=1

ENV PHP_INI_SCAN_DIR=":$PHP_INI_DIR/app.conf.d"

###> recipes ###
###< recipes ###

COPY --link frankenphp/conf.d/10-app.ini $PHP_INI_DIR/app.conf.d/
COPY --link --chmod=755 frankenphp/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
# The worker's command (service `worker`): expands WORKER_CONSUME_ARGS inside the container.
COPY --link --chmod=755 frankenphp/consume-messages.sh /usr/local/bin/oliva-consume
COPY --link --chmod=755 frankenphp/realtime-relay.sh /usr/local/bin/oliva-relay
# The `migrate` service's command: wait for the database, then the migrations.
COPY --link --chmod=755 frankenphp/migrate.sh /usr/local/bin/oliva-migrate
COPY --link frankenphp/Caddyfile /etc/caddy/Caddyfile
# Read by docker-entrypoint: values a secret must never have in production.
COPY --link frankenphp/known-public-secrets.sha256 /usr/local/share/oliva/known-public-secrets.sha256
COPY --link scheduler/crontab /etc/supercronic/crontab

# Install dependencies from versioned composer.json
COPY --link composer.json composer.lock symfony.lock ./
RUN composer install --prefer-dist --no-progress --no-interaction --no-scripts --no-autoloader

# Copy application source
COPY --link bin bin/
COPY --link config config/
COPY --link migrations migrations/
COPY --link public public/
COPY --link src src/
COPY --link tests tests/
COPY --link phpunit.dist.xml ./

RUN composer dump-autoload --optimize

ENTRYPOINT ["docker-entrypoint"]

HEALTHCHECK --start-period=60s CMD curl -f http://localhost:2019/metrics || exit 1
# NO envolver en `sh -c`: el entrypoint distingue su bloque de setup (genera JWT,
# espera la DB, migra) con `[ "$1" = 'frankenphp' ]`. Si el CMD es `sh -c "..."`,
# $1 pasa a ser `sh` y TODO ese bloque se saltea silenciosamente en prod.
# La race de DB la cubre el wait-for-db del entrypoint (60 reintentos), no un sleep.
CMD [ "frankenphp", "run", "--config", "/etc/caddy/Caddyfile" ]

# Dev FrankenPHP image
FROM frankenphp_base AS frankenphp_dev

ENV APP_ENV=dev XDEBUG_MODE=off
ENV FRANKENPHP_CONFIG=""

RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

# xdebug con PIE (php-ext-zend, pineado 3.5.3) — mismo motivo que amqp/apcu: fuera de pecl.php.net.
# No necesita libs de sistema extra; solo el toolchain + unzip, que se purgan acá mismo.
# `apt-get -o APT::Sandbox::User=root`: defensa en profundidad, mismo motivo que en el RUN de
# PIE del stage base (un /tmp sin sticky 1777 rompe el sandbox `_apt` → `exit 100`).
# hadolint ignore=DL3008,SC2086
RUN --mount=type=bind,from=ghcr.io/php/pie:1.5.3-bin,source=/pie,target=/usr/local/bin/pie \
	set -eux; \
	export DEBIAN_FRONTEND=noninteractive; \
	apt-get -o APT::Sandbox::User=root update; \
	apt-get install -y --no-install-recommends $PHPIZE_DEPS unzip; \
	pie install --no-cache xdebug/xdebug:3.5.3; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $PHPIZE_DEPS unzip; \
	rm -rf /var/lib/apt/lists/*

COPY --link frankenphp/conf.d/20-app.dev.ini $PHP_INI_DIR/app.conf.d/

# T5 — manifiesto de los inputs de build que se HORNEAN pero NO se bind-mountean en dev:
# editarlos en el host no surte efecto hasta rebuildear, porque cambiarlos pide
# `composer install` / recompilar extensiones, no copiar el archivo (por eso no se
# montan, a diferencia de phpunit.dist.xml). `./oliva doctor` compara estos hashes
# contra los del host y avisa "rebuildeá la imagen" si driftearon. Va al final del
# stage dev (no en base) para no invalidar el layer caro de xdebug al tocarlo.
# hadolint ignore=DL4006
RUN --mount=type=bind,source=php-extensions.txt,target=/run/oliva/php-extensions.txt \
	set -eux; \
	mkdir -p /usr/local/share/oliva; \
	{ sha256sum composer.json composer.lock symfony.lock | awk '{n=$2; sub(/.*\//,"",n); print $1"  "n}'; \
	  sha256sum /run/oliva/php-extensions.txt | awk '{print $1"  php-extensions.txt"}'; \
	} | sort -k2 > /usr/local/share/oliva/build-inputs.sha256

CMD [ "frankenphp", "run", "--config", "/etc/caddy/Caddyfile", "--watch" ]

# Prod FrankenPHP image
FROM frankenphp_base AS frankenphp_prod

ENV APP_ENV=prod
ENV FRANKENPHP_CONFIG="import worker.Caddyfile"

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY --link frankenphp/conf.d/20-app.prod.ini $PHP_INI_DIR/app.conf.d/
COPY --link frankenphp/worker.Caddyfile /etc/caddy/worker.Caddyfile

# prevent the reinstallation of vendors at every changes in the source code
COPY --link composer.* symfony.* ./

RUN set -eux; \
	composer install --no-cache --prefer-dist --no-dev --no-autoloader --no-scripts --no-progress

# copy sources
COPY --link . ./
RUN rm -Rf frankenphp/

RUN set -eux; \
	mkdir -p var/cache var/log; \
	composer dump-autoload --classmap-authoritative --no-dev; \
	composer dump-env prod; \
	composer run-script --no-dev post-install-cmd; \
	chmod +x bin/console; sync;

# Staging FrankenPHP image — inherits from prod, adds seeding tooling (Foundry + fixtures)
# Prod image is --no-dev so this command is unavailable there: structural guard against
# accidentally seeding production.
FROM frankenphp_prod AS frankenphp_staging

ENV APP_ENV=staging

# frankenphp_prod horneó .env.local.php con APP_ENV=prod compilado (composer
# dump-env prod) — heredarlo pisaría el ENV de arriba. Hay que borrarlo antes
# del install para que el entorno de staging se resuelva en runtime.
RUN set -eux; \
	rm -f .env.local.php; \
	composer install --no-cache --prefer-dist --no-autoloader --no-scripts --no-progress; \
	composer dump-autoload --classmap-authoritative; \
	composer run-script post-install-cmd; \
	chmod +x bin/console; sync;

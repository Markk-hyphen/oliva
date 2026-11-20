#!/bin/sh
# oliva-seed — the backend contract's Seed hook (docs/oliva/backend-contract.md).
#
# Present in the `dev` and `staging` images ONLY: the Dockerfile copies it in those two
# stages, never in `base` or `prod`. The production image has neither this file nor the
# fixtures bundle (composer --no-dev): seeding production is impossible by construction,
# not forbidden by a check that a variable could turn off.
#
# It REPLACES the data: Doctrine fixtures purge every managed table, then load. That is the
# contract's declared behaviour; the first line it prints says so.
#
# The fixture group defaults to the environment (dev, staging), the groups the apps' own
# AppFixtures use. OLIVA_SEED_GROUP picks another one.
set -e

group="${OLIVA_SEED_GROUP:-${APP_ENV:-dev}}"
echo "oliva-seed: replacing the database's data with the '$group' fixtures (purge, then load)"
exec php bin/console doctrine:fixtures:load --group="$group" --no-interaction

#!/usr/bin/env bash
#
# Prepares the test database, when the suite needs one. Run from the repo root,
# with the dev stack up. Called by `./oliva verify` and by CI before PHPUnit.
#
#   scripts/lib/test-db.sh
#
# Symfony's test environment uses its own database (`<name>_test`, see `when@test`
# in backend/config/packages/doctrine.yaml). Nothing created it, so the first test
# that touched Doctrine failed with `database "app_test" does not exist`.
#
# Zero cost when it doesn't apply: an app with unit tests only has no test that
# boots the kernel, and this script exits without touching anything.
set -euo pipefail

grep -rqsE 'KernelTestCase|WebTestCase|ApiTestCase' backend/tests || exit 0

console() { docker compose exec -T backend bin/console --env=test --no-interaction "$@"; }

console doctrine:database:create --if-not-exists --quiet
console doctrine:migrations:migrate --allow-no-migration --quiet
echo "test database ready (created if missing, migrations applied)"

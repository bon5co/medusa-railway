#!/bin/sh
# Boot sequence for Medusa 2 on Railway.
#
# This deliberately does NOT use `init-backend` from medusajs-launch-utils, which
# is what the upstream boilerplate runs. Three reasons, each of which is a
# behaviour difference a deployer can observe:
#
#   1. `seedOnce()` decides whether the database needs work by checking whether
#      the "user" table exists, and skips the WHOLE branch when it does -- which
#      includes `medusa db:migrate`. So migrations run exactly once, on the very
#      first boot, and never again. Any later Medusa version bump then starts
#      against a schema that was migrated by the previous version.
#   2. `reportDeploy()` POSTs { projectId, publicUrl, storefrontPublishUrl } to
#      TEMPLATE_REPORTER_URL -- a server belonging to the template author -- on
#      every boot, and the published template ships that URL as a default.
#   3. It creates the admin user only inside the never-seeded branch, so a
#      deployment that reaches the "already seeded" path with no admin (an
#      interrupted first boot) has no way to get one.
#
# Here migrations run on every boot, the demo catalogue is seeded once behind a
# marker, the admin user is ensured on every boot, and nothing is reported
# anywhere.
set -eu

log() { echo "[railway-entrypoint] $*"; }

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${JWT_SECRET:?JWT_SECRET is required}"
: "${COOKIE_SECRET:?COOKIE_SECRET is required}"

# An empty admin password is not a weak instance, it is an unusable one: Medusa
# has no public sign-up, so the dashboard can only ever be reached by an account
# that was seeded here. Fail loudly instead of serving a locked-out store.
if [ -z "${MEDUSA_ADMIN_EMAIL:-}" ] || [ -z "${MEDUSA_ADMIN_PASSWORD:-}" ]; then
    log "FATAL: MEDUSA_ADMIN_EMAIL and MEDUSA_ADMIN_PASSWORD must both be set."
    log "Medusa has no public registration, so without them the admin dashboard"
    log "can never be signed into."
    exit 1
fi

export MEDUSA_WORKER_MODE="${MEDUSA_WORKER_MODE:-shared}"

# Medusa's CLI posts anonymous usage analytics. On a deploy target this is an
# outbound call on the critical path of every boot; a local reproduction of
# `medusa db:migrate` sat at "Running migrations..." with an idle database
# connection and no progress until it was killed, which is what a blocked
# outbound request looks like from the outside. UNVERIFIED as the cause -- kept
# because a deployer's store has no reason to phone anyone at boot either way.
export MEDUSA_DISABLE_TELEMETRY="${MEDUSA_DISABLE_TELEMETRY:-1}"

# medusa build emits a config that requires 'lib/constants' -- a tsconfig path
# alias with no tsconfig in the built output. Node resolves it through NODE_PATH.
export NODE_PATH="${NODE_PATH:-/app/src}"

# medusa-config.js reads these; keep the admin bundle's same-origin build honest
# by never handing it an absolute URL at runtime either.
export BACKEND_PUBLIC_URL="${BACKEND_PUBLIC_URL:-}"

cd /app

MEDUSA="node_modules/.bin/medusa"

# ---------------------------------------------------------------------------
# Wait for Postgres. Railway starts every service in a template at once, so the
# database is routinely still initialising when this container's first query
# lands.
# ---------------------------------------------------------------------------
log "waiting for Postgres..."
i=0
until psql "$DATABASE_URL" -c 'SELECT 1' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 120 ]; then
        log "FATAL: Postgres did not become reachable within 240s"
        exit 1
    fi
    sleep 2
done
log "Postgres reachable after ${i} attempts"

FRESH=0
if ! psql "$DATABASE_URL" -tAc "SELECT to_regclass('public.\"user\"')" 2>/dev/null | grep -q .; then
    FRESH=1
fi
[ "$FRESH" = 1 ] && log "no existing schema detected -- this is a first boot"

# ---------------------------------------------------------------------------
# Migrations, on EVERY boot. This is the one upstream skips after first boot.
# ---------------------------------------------------------------------------
log "running database migrations..."
"$MEDUSA" db:migrate
log "syncing module links..."
"$MEDUSA" db:sync-links

# ---------------------------------------------------------------------------
# Demo catalogue: once, and only when the deployer asked for it.
# ---------------------------------------------------------------------------
SEED_MARKER_SQL="SELECT 1 FROM public.store LIMIT 1"
if [ "${MEDUSA_SEED_DEMO_DATA:-true}" = "true" ]; then
    if psql "$DATABASE_URL" -tAc "$SEED_MARKER_SQL" 2>/dev/null | grep -q 1; then
        log "store already exists -- skipping demo seed"
    else
        log "seeding demo catalogue (regions, sales channel, sample products)..."
        "$MEDUSA" exec ./src/scripts/seed.js || log "WARNING: demo seed failed; continuing"
    fi
else
    log "MEDUSA_SEED_DEMO_DATA is not 'true' -- skipping demo seed"
fi

# ---------------------------------------------------------------------------
# Admin user, on every boot. `medusa user` exits non-zero when the account is
# already there, which is the normal case on a redeploy.
# ---------------------------------------------------------------------------
if "$MEDUSA" user -e "$MEDUSA_ADMIN_EMAIL" -p "$MEDUSA_ADMIN_PASSWORD" 2>&1 | tee /tmp/user.log; then
    log "admin user ensured: $MEDUSA_ADMIN_EMAIL"
else
    log "admin user already present: $MEDUSA_ADMIN_EMAIL"
fi

log "starting Medusa ${MEDUSA_VERSION:-2} on port ${PORT:-9000}"
exec "$MEDUSA" start

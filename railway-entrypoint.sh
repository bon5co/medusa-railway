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

# Medusa's CLI posts anonymous usage analytics on every invocation. A deployer's
# store has no reason to phone anyone at boot.
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

# ---------------------------------------------------------------------------
# Decide how Medusa should negotiate TLS with that Postgres, and say so out loud.
#
# This is the single thing that stops a Medusa 2 deploy on Railway dead, and it
# does so with NO error message at all. `loadDatabaseConfig` builds the driver
# options from the connection string alone
# (@medusajs/utils/dist/modules-sdk/load-module-database-config.js):
#
#     clientUrl.match(/localhost|127\.0\.0\.1|ssl_mode=(disable|false)|sslmode=(disable)/i)
#         ? { connection: { ssl: false } }
#         : { connection: { ssl: { rejectUnauthorized: false } } }
#
# Railway's Postgres is reached over the private network at
# `postgres.railway.internal`, which matches none of those, so Medusa demands
# TLS from a server that may not offer it. The migration runner then opens its
# advisory-lock pool with `propagateCreateError: false`
# (@medusajs/utils/dist/modules-sdk/create-pg-connection.js), which tells tarn to
# swallow connection-creation failures and retry forever instead of rejecting the
# acquire. So `medusa db:migrate` prints "Migrations table created successfully",
# takes no lock, issues no migration SQL, logs nothing further, and reconnects to
# Postgres several times a second until something kills it. Measured against a
# non-TLS Postgres: 358 sockets in TIME_WAIT after five minutes, 0 rows in
# `mikro_orm_migrations`, 0 rows in `pg_locks` for `locktype = 'advisory'`, and
# the real error only visible after patching that flag to `true` --
# `Error: The server does not support SSL connections` x25, one per module.
#
# The obvious lever, `DATABASE_DRIVER_OPTIONS`, does NOT work here and setting it
# is a wasted boot: `loadDatabaseConfig` reads it, and then the very next branch
# (`isModuleServiceInitializeOptions`) overwrites `driverOptions` with
# `options.database.driverOptions ?? getDefaultDriverOptions(clientUrl)` for any
# caller that passes a database config -- which the app loader always does.
# Verified by exporting it and watching the same silent retry loop.
#
# So the only lever that reaches the guess is the connection string the guess is
# made from. `sslmode=disable` is one of the patterns it looks for, it survives
# the loader's parameter stripping (only `ssl_mode=` is removed), and node-pg
# honours it as a real connection parameter, so URL and driver options agree.
# ---------------------------------------------------------------------------
case "$DATABASE_URL" in
    *sslmode=*|*ssl_mode=*)
        log "DATABASE_URL already specifies an sslmode -- leaving it alone" ;;
    *)
        if PGSSLMODE=require psql "$DATABASE_URL" -c 'SELECT 1' >/dev/null 2>&1; then
            log "Postgres accepts TLS -- leaving Medusa's default (ssl, unverified) in place"
        else
            case "$DATABASE_URL" in
                *\?*) DATABASE_URL="${DATABASE_URL}&sslmode=disable" ;;
                *)    DATABASE_URL="${DATABASE_URL}?sslmode=disable" ;;
            esac
            export DATABASE_URL
            log "Postgres does not offer TLS -- appended sslmode=disable"
        fi ;;
esac

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
# Admin account, on every boot -- created on the first, and its password brought
# back in line with the environment on every one after that.
#
# `medusa user` only ever creates: it refuses once the account exists, and there
# is no update or reset command anywhere in the CLI. So without the second branch
# the password a deployer sets in Railway's variable panel applies exactly once,
# and every later edit is silently ignored while the panel shows the new value.
# ---------------------------------------------------------------------------
# The query comes in over stdin rather than -c because psql only interpolates
# :'variables' for scripts, not for -c, and the address must not be pasted into
# the SQL by hand.
if printf 'SELECT 1 FROM public."user" WHERE email = :%s AND deleted_at IS NULL LIMIT 1\n' "'email'" \
        | psql "$DATABASE_URL" -v email="$MEDUSA_ADMIN_EMAIL" -tA -f - 2>/dev/null | grep -q 1; then
    log "admin account exists -- setting its password from the environment"
    "$MEDUSA" exec /usr/local/bin/rotate-admin.js
else
    log "creating admin account: $MEDUSA_ADMIN_EMAIL"
    "$MEDUSA" user -e "$MEDUSA_ADMIN_EMAIL" -p "$MEDUSA_ADMIN_PASSWORD"
fi

log "starting Medusa ${MEDUSA_VERSION:-2} on port ${PORT:-9000}"
exec "$MEDUSA" start

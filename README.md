# medusa-railway

Medusa 2.17.2 commerce API + Admin dashboard, prebuilt for Railway.

Image: `ghcr.io/bon5co/medusa-railway:2.17.2`

## What this is

Every Medusa listing on the Railway marketplace builds the application from a
GitHub repository on the deployer's build minutes. This image builds it once.

That is possible because of one detail: Medusa bakes `admin.backendUrl` into the
admin dashboard bundle at build time, which is the usual reason a per-deploy
build is needed. Building with an **empty** backend URL makes the dashboard issue
same-origin requests instead, which is correct for any deploy where the admin and
the API share a hostname — which is every deploy of this template.

The application source is the upstream boilerplate
[`rpuls/medusajs-2.0-for-railway-boilerplate`](https://github.com/rpuls/medusajs-2.0-for-railway-boilerplate),
pinned to commit `1e41d72`. Only the boot sequence is replaced.

## What the boot sequence changes

The upstream boilerplate boots via `init-backend` from `medusajs-launch-utils`.
This image does not use it:

1. **Migrations run on every boot.** `seedOnce()` in `medusajs-launch-utils`
   decides whether the database needs work by checking whether the `user` table
   exists, and skips the entire branch when it does — including
   `medusa db:migrate`. So migrations run exactly once, on the very first boot,
   and never again; any later Medusa version bump starts against a schema
   migrated by the previous version.
2. **Nothing is reported anywhere.** `reportDeploy()` POSTs
   `{ projectId, publicUrl, storefrontPublishUrl }` to `TEMPLATE_REPORTER_URL` on
   every boot, and the published upstream template ships that URL — a server
   belonging to the template author — as a variable default.
3. **The admin user is ensured on every boot**, not only inside the
   never-seeded branch, and the container refuses to start when
   `MEDUSA_ADMIN_EMAIL` / `MEDUSA_ADMIN_PASSWORD` are empty. Medusa has no public
   sign-up, so a deployment with no seeded admin is not a weak instance, it is an
   unreachable one.
4. **The demo catalogue is seeded behind a marker** and can be turned off with
   `MEDUSA_SEED_DEMO_DATA=false`.

## Two build-output details this image has to repair

Both are consequences of running the built server standalone, which upstream
never does:

- `medusa build` emits a `medusa-config.js` that `require`s `@medusajs/utils`,
  a transitive dependency that pnpm's default symlinked layout does not expose at
  the top level of `.medusa/server`. Upstream runs the built server from inside
  the source tree, so Node's directory walk finds the source install two levels
  up. Here the built server's dependencies are reinstalled with
  `--config.node-linker=hoisted`.
- The same config `require`s `lib/constants`, a `tsconfig` path alias, and no
  `tsconfig.json` is copied into the build output. `NODE_PATH=/app/src` resolves
  it.

## Environment

| Variable | Required | Notes |
|---|---|---|
| `DATABASE_URL` | yes | Postgres connection string |
| `REDIS_URL` | no | enables the Redis event bus and workflow engine |
| `JWT_SECRET` | yes | |
| `COOKIE_SECRET` | yes | |
| `MEDUSA_ADMIN_EMAIL` | yes | container exits without it |
| `MEDUSA_ADMIN_PASSWORD` | yes | container exits without it |
| `MEDUSA_SEED_DEMO_DATA` | no | `true` (default) seeds the sample catalogue once |
| `STORE_CORS` / `ADMIN_CORS` / `AUTH_CORS` | no | |
| `PORT` | no | honoured; Railway injects it |

## Status

**Not yet verified end to end.** A local boot got as far as loading the config
and starting `medusa db:migrate`, then sat at `Running migrations...` with an
idle database connection until it was killed. `MEDUSA_DISABLE_TELEMETRY=1` is set
on the hypothesis that the stall is Medusa's analytics call on a sandboxed
network, but that has **not** been confirmed. Do not publish a template off this
image until a boot reaches a `200` on `/health`.

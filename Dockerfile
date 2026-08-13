# Medusa 2 headless commerce API + Admin dashboard, prebuilt for Railway.
#
# Every Medusa listing on the Railway marketplace builds this application from a
# GitHub repository on the deployer's build minutes. That is not a stylistic
# choice: Medusa bakes `admin.backendUrl` into the admin dashboard bundle at
# build time, so a per-deploy build is the obvious way to get the deployer's own
# domain into it.
#
# It is not the only way. Building with an empty backend URL makes the dashboard
# issue same-origin requests, which is correct for any deploy where the admin and
# the API share a hostname -- which is every deploy of this template. So the
# image can be built once, pinned, and pulled.
ARG MEDUSA_VERSION=2.17.2

FROM node:22-bookworm-slim AS build

# Pinned commit of the upstream boilerplate this image builds. Kept as a build
# arg so a version bump is a one-line change with a reproducible source.
ARG SOURCE_REPO=https://github.com/rpuls/medusajs-2.0-for-railway-boilerplate.git
ARG SOURCE_REF=1e41d723232b369b9a3e26c04d84bc92e37c5788

RUN apt-get update \
 && apt-get install -y --no-install-recommends git python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init -q . \
 && git remote add origin "$SOURCE_REPO" \
 && git fetch -q --depth 1 origin "$SOURCE_REF" \
 && git checkout -q FETCH_HEAD

WORKDIR /src/backend
RUN corepack enable && corepack prepare pnpm@9.15.4 --activate
RUN pnpm install --frozen-lockfile

# `medusa build` loads medusa-config.js, which asserts these three are present.
# They are placeholders that never reach the built artifact -- the real values
# arrive from the environment at boot.
#
# BACKEND_PUBLIC_URL is deliberately EMPTY. medusa-config.js reads
# `process.env.BACKEND_PUBLIC_URL ?? process.env.RAILWAY_PUBLIC_DOMAIN_VALUE ??
# 'http://localhost:9000'`, and `??` treats the empty string as a value, so the
# admin bundle is built with no absolute backend URL and talks to its own origin.
ENV DATABASE_URL=postgres://build:build@127.0.0.1:5432/build \
    JWT_SECRET=build-placeholder \
    COOKIE_SECRET=build-placeholder \
    BACKEND_PUBLIC_URL= \
    NODE_ENV=production
RUN pnpm build

# `medusa build` emits a medusa-config.js that `require`s '@medusajs/utils'
# directly, but that package is a transitive dependency, so pnpm's default
# symlinked layout does not expose it at the top level of .medusa/server. The
# upstream boilerplate never notices, because it runs the built server from
# inside the source tree and Node's directory walk finds the source install two
# levels up. A standalone runtime image has no such tree, so the built server's
# dependencies are reinstalled hoisted.
RUN cd .medusa/server \
 && rm -rf node_modules \
 && pnpm install --prod --frozen-lockfile --config.node-linker=hoisted


FROM node:22-bookworm-slim AS runtime

ARG MEDUSA_VERSION
LABEL org.opencontainers.image.title="Medusa 2 for Railway" \
      org.opencontainers.image.description="Medusa ${MEDUSA_VERSION} commerce API + Admin dashboard, prebuilt" \
      org.opencontainers.image.source="https://github.com/bon5co/medusa-railway"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates postgresql-client tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The built server, its production dependencies, and the source-side toolchain
# the boot sequence needs (`medusa db:migrate`, `medusa exec` for the seed).
COPY --from=build /src/backend/.medusa/server /app
COPY --from=build /src/backend/src /app/src-original

ENV NODE_ENV=production \
    MEDUSA_VERSION=${MEDUSA_VERSION} \
    PORT=9000 \
    NODE_PATH=/app/src \
    MEDUSA_DISABLE_TELEMETRY=1

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY rotate-admin.js /usr/local/bin/rotate-admin.js
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 9000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/railway-entrypoint.sh"]

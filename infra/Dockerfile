# syntax=docker/dockerfile:1
# zifiri — production image. Plan §5.1 (no logs), §10.3 (reproducible
# build), §11.3 (unix socket), §11.4 (disk/memory).
#
# Design rule: the container root filesystem runs READ-ONLY. The only
# writable places: /tmp and /run (tmpfs), /var/lib/zifiri (single volume) and
# /run/zifiri (socket directory). No secret is ever baked into this image.

# ---------------------------------------------------------------------------
# Stage 0 — client (vanilla TS + Vite, §11.1).
# Bundle < 100 KB target is measured at P2. `npm ci` depends on the lock file;
# without SOURCE_DATE_EPOCH the build is not reproducible (§10.3).
# If the client/ directory does not exist yet (P1) this stage and the COPY line below are commented out.
# ---------------------------------------------------------------------------
ARG NODE_IMAGE=node:22-alpine
FROM ${NODE_IMAGE} AS client
ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    NODE_ENV=development
WORKDIR /client
COPY client/package.json client/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY client/ ./
RUN npm run build -- --outDir /client/dist --emptyOutDir

# ---------------------------------------------------------------------------
# Stage 1 — build.
# ELIXIR_IMAGE is pinned by DIGEST in CI (§10.3): elixir@sha256:...
# Using a tag defeats the "same commit → same hash" claim.
# ---------------------------------------------------------------------------
ARG ELIXIR_IMAGE=elixir:1.18-alpine
FROM ${ELIXIR_IMAGE} AS build

ARG SOURCE_DATE_EPOCH=0
ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    HEX_HTTP_CONCURRENCY=1 \
    HEX_HTTP_TIMEOUT=120

# build-base: for NIFs (ecto_sqlite3, blake3). git: hex git dependency.
RUN apk add --no-cache build-base git

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

# Dependency layer kept separate: not re-downloaded when source changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv

# Client is built with Vite (§11.1); Phoenix's esbuild/tailwind pipeline is
# NOT used, hence no `mix assets.deploy`. Vite output lands directly in
# priv/static and is served by Plug.Static under hashed names — the
# `immutable` cache rule on the nginx side relies on those names.
COPY --from=client /client/dist ./priv/static
RUN mix compile

# Release. `--path` puts the output in a single directory.
RUN mix release --path /out --overwrite

# ---------------------------------------------------------------------------
# Stage 2 — runtime.
# ---------------------------------------------------------------------------
ARG RUNTIME_IMAGE=alpine:3.21
FROM ${RUNTIME_IMAGE} AS runtime

# Minimum libraries required for the Erlang BEAM to run.
# ca-certificates: for external TLS when there is no onion; zifiri itself makes no
# outbound calls, but it is there so we don't deal with a silly "no certificate" error.
RUN apk add --no-cache \
        libstdc++ \
        libgcc \
        ncurses-libs \
        openssl \
        ca-certificates \
 && rm -rf /var/cache/apk/*

# Single non-root user. UID 10001 is SHARED with nginx: nginx, when connecting
# to Phoenix's /run/zifiri/app.sock socket, needs write permission on the socket
# file; with separate UIDs this connect() fails with EACCES.
RUN addgroup -g 10001 -S zifiri \
 && adduser  -u 10001 -S -D -H -h /nonexistent -s /sbin/nologin -G zifiri zifiri

# These two directories are copied by Docker with their ownership from the
# image when a named volume is first created. So the `zifiri-data` and
# `zifiri-run` volumes are born with 10001:10001; the root-owned volume trap is closed.
RUN install -d -o 10001 -g 10001 -m 0750 /var/lib/zifiri \
 && install -d -o 10001 -g 10001 -m 0750 /run/zifiri

COPY --from=build --chown=10001:10001 /out /app

# --- §5.1 / §11.4: crash dump and distribution ------------------------------
# ERL_CRASH_DUMP=/dev/null + SECONDS=0: when BEAM crashes no memory dump is
# WRITTEN. These two alone are not enough; the kernel `core_pattern` must
# also be disabled (deploy.md) and the container must have `ulimit core 0`
# (docker-compose.yml: ulimits.core: 0). Together the three protect stage 2.
# RELEASE_DISTRIBUTION=none: no epmd, no daemon port, no .erlang.cookie.
# HOME=/tmp: so Erlang's write attempt does not blow up on the read-only root.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    HOME=/tmp \
    MIX_ENV=prod \
    RELEASE_DISTRIBUTION=none \
    RELEASE_TMP=/tmp \
    ERL_CRASH_DUMP=/dev/null \
    ERL_CRASH_DUMP_SECONDS=0 \
    ERL_CRASH_DUMP_NICE=19 \
    ZIFIRI_SOCKET=/run/zifiri/app.sock \
    ZIFIRI_DB=/var/lib/zifiri/zifiri.db \
    ZIFIRI_ERR_LOG=/var/lib/zifiri/err.log

WORKDIR /app
USER 10001:10001

# No socket exposed externally; no port published. Healthcheck in compose.
STOPSIGNAL SIGTERM

# `start` runs in the foreground (not a daemon). PID 1 = beam.smp; SIGTERM is
# caught by erl_signal_server, init:stop() runs.
CMD ["/app/bin/zifiri", "start"]

# syntax=docker/dockerfile:1
# zifiri — üretim imajı. Plan §5.1 (log yok), §10.3 (yeniden üretilebilir
# build), §11.3 (unix soket), §11.4 (disk/bellek).
#
# Tasarım kuralı: konteyner kök dosya sistemi READ-ONLY çalışır. Yazılabilir
# tek yerler: /tmp ve /run (tmpfs), /var/lib/zifiri (tek volume) ve
# /run/zifiri (soket dizini). Bu image'a hiçbir sır gömülmez.

# ---------------------------------------------------------------------------
# Aşama 0 — istemci (vanilla TS + Vite, §11.1).
# Bundle < 100 KB hedefi P2'de ölçülür. `npm ci` kilit dosyasına bağlıdır;
# SOURCE_DATE_EPOCH verilmezse build yeniden üretilebilir olmaz (§10.3).
# client/ dizini henüz yoksa (P1) bu aşama ve aşağıdaki COPY satırı yorumlanır.
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
# Aşama 1 — derleme.
# ELIXIR_IMAGE CI'da DIGEST ile sabitlenir (§10.3): elixir@sha256:...
# Etiket kullanmak "aynı commit → aynı hash" iddiasını çürütür.
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

# build-base: NIF'ler (ecto_sqlite3, blake3) için. git: hex git bağımlılığı.
RUN apk add --no-cache build-base git

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

# Bağımlılık katmanı ayrı: kaynak değişince yeniden indirilmez.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv

# İstemci Vite ile derlenir (§11.1); Phoenix'in esbuild/tailwind hattı
# KULLANILMAZ, o yüzden `mix assets.deploy` yok. Vite çıktısı doğrudan
# priv/static'e iner ve Plug.Static tarafından hash'li adla servis edilir —
# nginx tarafındaki `immutable` cache kuralı bu adlara dayanır.
COPY --from=client /client/dist ./priv/static
RUN mix compile

# Release. `--path` ile çıktı tek dizine.
RUN mix release --path /out --overwrite

# ---------------------------------------------------------------------------
# Aşama 2 — çalışma zamanı.
# ---------------------------------------------------------------------------
ARG RUNTIME_IMAGE=alpine:3.21
FROM ${RUNTIME_IMAGE} AS runtime

# Erlang BEAM'in çalışması için gereken asgari kütüphaneler.
# ca-certificates: onion yoksa dış TLS için; zifiri kendisi dış çağrı yapmaz,
# yine de aptal bir "sertifika yok" hatasıyla uğraşmamak için var.
RUN apk add --no-cache \
        libstdc++ \
        libgcc \
        ncurses-libs \
        openssl \
        ca-certificates \
 && rm -rf /var/cache/apk/*

# Root olmayan tek kullanıcı. UID 10001 nginx ile ORTAKTIR: nginx, Phoenix'in
# /run/zifiri/app.sock soketine bağlanırken soket dosyasının yazma iznine
# ihtiyaç duyar; ayrı UID'lerde bu connect() EACCES ile düşer.
RUN addgroup -g 10001 -S zifiri \
 && adduser  -u 10001 -S -D -H -h /nonexistent -s /sbin/nologin -G zifiri zifiri

# Bu iki dizin, isimli volume ilk kez oluşturulurken Docker tarafından
# image'daki sahipliğiyle kopyalanır. Yani `zifiri-data` ve `zifiri-run`
# volume'leri 10001:10001 ile doğar; root sahipli volume tuzağı kapanır.
RUN install -d -o 10001 -g 10001 -m 0750 /var/lib/zifiri \
 && install -d -o 10001 -g 10001 -m 0750 /run/zifiri

COPY --from=build --chown=10001:10001 /out /app

# --- §5.1 / §11.4: çökme dökümü ve dağıtım --------------------------------
# ERL_CRASH_DUMP=/dev/null + SECONDS=0: BEAM çöktüğünde bellek dökümü
# YAZILMAZ. Bu ikisi tek başına yetmez; çekirdek `core_pattern`'i de
# kapatılmalı (deploy.md) ve konteynerde `ulimit core 0` olmalı
# (docker-compose.yml: ulimits.core: 0). Üçü birlikte ayak 2'yi korur.
# RELEASE_DISTRIBUTION=none: epmd yok, daemon portu yok, .erlang.cookie yok.
# HOME=/tmp: Erlang'ın yazma denemesi read-only kökte patlamasın.
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

# Soket dışarı açılmaz; port publish edilmez. Healthcheck compose'da.
STOPSIGNAL SIGTERM

# `start` ön planda çalışır (daemon değil). PID 1 = beam.smp; SIGTERM'i
# erl_signal_server yakalar, init:stop() çalışır.
CMD ["/app/bin/zifiri", "start"]

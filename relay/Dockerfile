# zelt relay: a tiny always-on onion relay with a RAM-only mailbox store.
#
#   docker build -t zelt-relay -f relay/Dockerfile .
#   docker run -d --name zelt-relay --network host -v zelt-relay-data:/data \
#     -e ZELT_PUBLIC_IP=203.0.113.7 zelt-relay
#
# Configuration (environment):
#   ZELT_PORT=47017            listen port
#   ZELT_PUBLIC_IP=ip[,ip]     addresses to advertise (required in practice)
#   ZELT_PEERS="zelt-relay:..." other relays to announce ourselves to
#   ZELT_STATS_MINUTES=1       periodic stats line, 0 = off
#
# Only the relay's key (relay-key.json) is stored, in /data. Message blobs never
# touch disk.

FROM dart:3.13.5 AS build
WORKDIR /src
# Resolve dependencies first so this layer is cached between code changes.
COPY packages/zelt_core/pubspec.yaml packages/zelt_core/pubspec.lock ./
RUN dart pub get
COPY packages/zelt_core/ ./
RUN dart pub get --offline \
 && dart compile exe bin/zelt_relay.dart -o /zelt_relay \
 && mkdir -p /data-skel \
 && chown 65532:65532 /data-skel \
 && chmod 700 /data-skel

# Minimal runtime: only the libraries a compiled Dart binary needs.
FROM scratch
ARG ZELT_REVISION=unknown
LABEL org.opencontainers.image.title="zelt relay" \
      org.opencontainers.image.source="https://github.com/gut-engel/zelt" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.revision="${ZELT_REVISION}"
COPY --from=build /runtime/ /
COPY --from=build /zelt_relay /zelt_relay
COPY --from=build --chown=65532:65532 /data-skel /data
USER 65532:65532
ENV ZELT_PORT=47017 \
    ZELT_STATE=/data/relay-key.json \
    ZELT_STATS_MINUTES=1
EXPOSE 47017/tcp
VOLUME ["/data"]
ENTRYPOINT ["/zelt_relay"]

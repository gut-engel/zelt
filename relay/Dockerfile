# zelt relay: a tiny always-on onion relay with a RAM-only mailbox store.
#
#   docker build -t zelt-relay -f relay/Dockerfile .
#   docker run -d --name zelt-relay --network host -v zelt-relay-data:/data \
#     zelt-relay --public-ip 203.0.113.7
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
 && chown 65532:65532 /data-skel

# Minimal runtime: only the libraries a compiled Dart binary needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /zelt_relay /zelt_relay
COPY --from=build --chown=65532:65532 /data-skel /data
USER 65532:65532
EXPOSE 47017/tcp
VOLUME ["/data"]
ENTRYPOINT ["/zelt_relay", "--state", "/data/relay-key.json"]
CMD ["--port", "47017"]

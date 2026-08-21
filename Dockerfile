# syntax=docker/dockerfile:1.7

# Exact patch-level defaults make local and CI builds repeatable. Release
# pipelines should override both arguments with immutable @sha256 references.
ARG ERLANG_BUILD_IMAGE=erlang:27.3.4.14-alpine
ARG ERLANG_RUNTIME_IMAGE=alpine:3.24.1

FROM ${ERLANG_BUILD_IMAGE} AS build

ARG SOURCE_DATE_EPOCH=0
WORKDIR /workspace

COPY rebar3 rebar.config rebar.lock ./
COPY include ./include
COPY priv ./priv
COPY src ./src
COPY rel ./rel
COPY scripts/deployment ./scripts/deployment

# `erlang_adk_build_ca` is an optional BuildKit secret for inspected/corporate
# TLS paths. It is used only by Hex during this layer and never copied into the
# image. Normal public-CA builders omit it.
RUN --mount=type=secret,id=erlang_adk_build_ca,required=false \
    if [ -s /run/secrets/erlang_adk_build_ca ]; then \
      mkdir -p /root/.config/rebar3; \
      printf '%s\n' \
        '{ssl_cacerts_path, "/run/secrets/erlang_adk_build_ca"}.' \
        > /root/.config/rebar3/rebar.config; \
    fi && \
    ./rebar3 as prod compile && \
    ./rebar3 as prod release -c rel/relx.config -o /opt/release && \
    rm -f /root/.config/rebar3/rebar.config && \
    find /opt/release -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +

FROM ${ERLANG_RUNTIME_IMAGE} AS runtime

ARG SOURCE_DATE_EPOCH=0
ARG VCS_REF=unknown
ARG VERSION=0.10.0

# Copy the release's small native dependency closure from the already-pinned
# build image. This keeps the runtime build network-independent and prevents a
# package-index refresh from making an otherwise reproducible build fail. The
# promoted build and runtime bases must use the same Alpine ABI generation.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /usr/lib/libcrypto.so.3 /usr/lib/libssl.so.3 /usr/lib/
COPY --from=build /usr/lib/libgcc_s.so.1 /usr/lib/
COPY --from=build /usr/lib/libstdc++.so.6* /usr/lib/
COPY --from=build /usr/lib/libncursesw.so.6* /usr/lib/

RUN addgroup -S -g 10001 erlang_adk && \
    adduser -S -D -H -u 10001 -G erlang_adk erlang_adk && \
    mkdir -p /opt/erlang_adk /var/lib/erlang_adk/run \
             /var/log/erlang_adk /tmp/erlang_adk && \
    chown -R 10001:10001 /opt/erlang_adk /var/lib/erlang_adk \
                          /var/log/erlang_adk /tmp/erlang_adk

COPY --from=build --chown=10001:10001 /opt/release/erlang_adk /opt/erlang_adk

LABEL org.opencontainers.image.title="Erlang ADK" \
      org.opencontainers.image.description="OTP-native Agent Development Kit release" \
      org.opencontainers.image.source="https://github.com/hsalap7/erlang_adk" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV ERLANG_ADK_RELEASE_ROOT=/opt/erlang_adk \
    ERLANG_ADK_DATA_DIR=/var/lib/erlang_adk \
    ERLANG_ADK_LOG_DIR=/var/log/erlang_adk \
    ERLANG_ADK_TMP_DIR=/tmp/erlang_adk \
    ERLANG_ADK_STARTUP_GRACE_SECONDS=2 \
    ERLANG_ADK_NOFILE_CAP=65536 \
    HOME=/tmp/erlang_adk

VOLUME ["/var/lib/erlang_adk", "/var/log/erlang_adk", "/tmp/erlang_adk"]

USER 10001:10001
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/opt/erlang_adk/bin/deployment-health", "live"]
ENTRYPOINT ["/opt/erlang_adk/bin/container-entrypoint"]
CMD ["foreground"]

# syntax=docker/dockerfile:1
# fushi_server image from a published Linux x64 release bundle (fast, ~1 min).
# Build context: this directory (packages/fushi_server/docker).
#
#   docker build -t fushi-server .                                   # newest release
#   docker build -t fushi-server --build-arg FUSHI_SERVER_TAG=v0.1.0-beta.14880 .
#   cp fushi_server-*-linux-x64.tar.gz dist/ && docker build -t fushi-server .   # local/CI tarball
#
# For unreleased code use Dockerfile.source (see README "Docker").
# The runtime stage (from `FROM debian:trixie-slim AS runtime` on) must stay
# identical in both Dockerfiles apart from the COPY source paths;
# server-docker.yml diffs them. The bundle stage is named `bundle` in both.

FROM debian:trixie-slim AS bundle
ARG FUSHI_SERVER_REPO=hajisensai/fushi-server
ARG FUSHI_SERVER_TAG=
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*
COPY dist/ /dist/
# A tarball dropped into dist/ wins; otherwise download from GitHub Releases and
# check the SHA-256 digest GitHub publishes for the asset (same check as the
# server's own updater).
RUN set -eu; \
    mkdir -p /opt; \
    local_tgz="$(ls /dist/fushi_server-*-linux-x64.tar.gz 2>/dev/null | sort -V | tail -n 1 || true)"; \
    if [ -n "$local_tgz" ]; then \
      echo "using local bundle $local_tgz"; tgz="$local_tgz"; \
    else \
      api="https://api.github.com/repos/$FUSHI_SERVER_REPO/releases"; \
      if [ -n "$FUSHI_SERVER_TAG" ]; then \
        curl -fsSL --proto "=https" --proto-redir "=https" "$api/tags/$FUSHI_SERVER_TAG" > /tmp/release.json; \
      else \
        curl -fsSL --proto "=https" --proto-redir "=https" "$api?per_page=20" \
          | jq '[.[] | select(.draft | not) | select(any(.assets[]; .name | endswith("-linux-x64.tar.gz")))][0]' \
          > /tmp/release.json; \
      fi; \
      jq -e '.assets' /tmp/release.json >/dev/null \
        || { echo "no release with a linux-x64 bundle in $FUSHI_SERVER_REPO" >&2; exit 1; }; \
      asset="$(jq -c '[.assets[] | select(.name | endswith("-linux-x64.tar.gz"))][0]' /tmp/release.json)"; \
      name="$(echo "$asset" | jq -r .name)"; \
      url="$(echo "$asset" | jq -r .browser_download_url)"; \
      digest="$(echo "$asset" | jq -r '.digest // empty')"; \
      case "$digest" in sha256:*) ;; *) echo "release asset $name has no sha256 digest" >&2; exit 1 ;; esac; \
      echo "downloading $(jq -r .tag_name /tmp/release.json): $name"; \
      tgz="/tmp/$name"; \
      curl -fsSL --proto "=https" --proto-redir "=https" --retry 3 -o "$tgz" "$url"; \
      echo "${digest#sha256:}  $tgz" | sha256sum -c -; \
    fi; \
    tar --no-same-owner -xzf "$tgz" -C /opt; \
    test -x /opt/fushi_server/bin/fushi_server

FROM debian:trixie-slim AS runtime
# ffmpeg/ffprobe: video, audiobook cue split, subtitles. 7zip: archive import.
# curl: health check.
RUN apt-get update \
    && apt-get install -y --no-install-recommends 7zip ca-certificates curl ffmpeg tzdata \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bundle /opt/fushi_server /opt/fushi_server
# Fail the build, not the first start, if the bundle needs a newer glibc.
COPY --chmod=755 check_bundle_libs.sh /usr/local/bin/fushi-check-bundle-libs
RUN fushi-check-bundle-libs /opt/fushi_server
COPY --chmod=755 entrypoint.sh /usr/local/bin/fushi-entrypoint
COPY --chmod=755 fushi_server.sh /usr/local/bin/fushi_server
COPY --chmod=755 healthcheck.sh /usr/local/bin/fushi-healthcheck
# FUSHI_CONTAINER=1: the in-app self-update refuses (pull a new image instead).
ENV FUSHI_CONTAINER=1 \
    HOME=/config \
    LANG=C.UTF-8
# Runs as a non-root user. 1000:1000 owns the empty /config (a named volume
# inherits that); compose runs it as PUID:PGID from .env instead, and a bind
# mount must already be writable by that user (the entrypoint says so if not).
RUN install -d -o 1000 -g 1000 /config
USER 1000:1000
WORKDIR /config
VOLUME ["/config"]
# 38765 interconnect (pairing / sync, TLS), 38780 WebUI + admin API, 6881 torrent.
EXPOSE 38765/tcp 38780/tcp 6881/tcp 6881/udp
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD ["fushi-healthcheck"]
ENTRYPOINT ["fushi-entrypoint"]
CMD ["serve"]

#!/usr/bin/env bash
# Build the fushi_server image from this checkout (Dockerfile.source).
#
#   bash packages/fushi_server/docker/build_source_image.sh [image-tag]   # default fushi-server:source
#
# Works from Git Bash on Windows or any Linux/macOS host with Docker. The build
# context is the git-tracked source (git ls-files -co --exclude-standard) piped
# as a tar, never the working tree itself, so build outputs, .dart_tool (host
# paths) and git-ignored secrets stay out of the image.
set -euo pipefail

TAG="${1:-fushi-server:source}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# `pwd -W` gives C:/... on Git Bash: docker.exe cannot read /c/... paths.
ROOT="$(cd "$HERE/../../.." && { pwd -W 2>/dev/null || pwd; })"
TOOLCHAIN="fushi-linux-build:trixie"
export MSYS_NO_PATHCONV=1 DOCKER_BUILDKIT=1

echo "==> toolchain image $TOOLCHAIN (tool/linux/Dockerfile)"
docker build -t "$TOOLCHAIN" -f "$ROOT/tool/linux/Dockerfile" "$ROOT/tool/linux"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
echo "==> $TAG from ${COMMIT:0:10}"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) \
  | docker build -t "$TAG" \
      --build-context toolchain="docker-image://$TOOLCHAIN" \
      --build-arg FUSHI_SOURCE_COMMIT="$COMMIT" \
      -f packages/fushi_server/docker/Dockerfile.source -

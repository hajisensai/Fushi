#!/usr/bin/env bash
# Host wrapper: build the Fushi Linux x64 bundle in Docker (works from Git Bash on
# Windows, or any Linux/macOS host with Docker).
#
#   bash tool/linux/build_in_docker.sh [--skip-native] [--clean] [--shell]
#
# The source tree is copied into a Docker volume (git ls-files -co --exclude-standard,
# so build outputs and secrets that are git-ignored stay out), never bind-mounted:
# a bind mount would let the container rewrite .dart_tool/package_config.json with
# Linux paths (docs/agent/build.md). Caches (pub, cargo, vcpkg, gradle, downloads)
# live in named volumes so rebuilds are incremental. The tarball lands in
# build/linux-dist/ of this checkout.
#
# Resource caps keep the host usable: FUSHI_DOCKER_CPUS (default: half the cores),
# FUSHI_DOCKER_MEMORY (default 12g).
set -euo pipefail

# `pwd -W` gives C:/... on Git Bash: docker.exe cannot read /c/... paths (MSYS_NO_PATHCONV is on).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && { pwd -W 2>/dev/null || pwd; })"
IMAGE="fushi-linux-build:trixie"
SRC_VOL="fushi-linux-src"
CLEAN=0; SHELL_ONLY=0; PASS=()
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --shell) SHELL_ONLY=1 ;;
    --skip-native) PASS+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cores="$(nproc 2>/dev/null || echo 8)"
CPUS="${FUSHI_DOCKER_CPUS:-$(( cores > 2 ? cores / 2 : 1 ))}"
MEMORY="${FUSHI_DOCKER_MEMORY:-12g}"

# Git Bash would rewrite /src-style arguments into Windows paths.
export MSYS_NO_PATHCONV=1

echo "==> image $IMAGE"
docker build -t "$IMAGE" -f "$ROOT/tool/linux/Dockerfile" "$ROOT/tool/linux"

if [[ "$CLEAN" == 1 ]]; then
  echo "==> --clean: dropping $SRC_VOL"
  docker volume rm -f "$SRC_VOL" >/dev/null
fi

echo "==> sync source into volume $SRC_VOL"
# Remove tracked/untracked source files first so deletions propagate; keep build
# outputs (fushi/build, native/*/target, native/*/prebuilt, .dart_tool) for speed.
docker run --rm -v "$SRC_VOL:/src" "$IMAGE" bash -c '
  cd /src 2>/dev/null || exit 0
  find . -mindepth 1 -maxdepth 1 ! -name fushi ! -name native ! -name packages -exec rm -rf {} +
  find fushi -mindepth 1 -maxdepth 1 ! -name build ! -name .dart_tool -exec rm -rf {} + 2>/dev/null || true
  for d in native/*/; do find "$d" -mindepth 1 -maxdepth 1 ! -name target ! -name prebuilt ! -name "build-linux-x64" -exec rm -rf {} +; done 2>/dev/null || true
  find packages -mindepth 1 -maxdepth 2 ! -name .dart_tool -path "packages/*/*" -exec rm -rf {} + 2>/dev/null || true
'
commit="$(git -C "$ROOT" rev-parse HEAD)"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) \
  | docker run --rm -i -v "$SRC_VOL:/src" "$IMAGE" tar -xf - -C /src

mkdir -p "$ROOT/build/linux-dist"
run_args=(
  --rm -i
  --cpus "$CPUS" --memory "$MEMORY"
  -e FUSHI_SOURCE_COMMIT="$commit"
  -v "$SRC_VOL:/src"
  -v fushi-linux-pub:/root/.pub-cache
  -v fushi-linux-cargo-registry:/opt/cargo/registry
  -v fushi-linux-cargo-git:/opt/cargo/git
  -v fushi-linux-cache:/root/.cache
  -v fushi-linux-gradle:/root/.gradle
  -v "$ROOT/build/linux-dist:/out"
)
if [[ "$SHELL_ONLY" == 1 ]]; then
  exec docker run -t "${run_args[@]}" "$IMAGE" bash
fi
echo "==> build (cpus=$CPUS memory=$MEMORY commit=${commit:0:10})"
docker run "${run_args[@]}" "$IMAGE" bash /src/tool/linux/build_bundle.sh ${PASS[@]+"${PASS[@]}"}
ls -lh "$ROOT/build/linux-dist"

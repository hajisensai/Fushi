#!/usr/bin/env bash
# Builds build/linux-dist/fushi-<v>.flatpak from the Linux bundle tarball in a
# privileged Debian container (flatpak-builder needs bubblewrap). Module builds are
# cached in the fushi-flatpak-work volume, so only changed modules rebuild.
#   bash tool/linux/flatpak/build_flatpak.sh [path/to/fushi-<v>-linux-x64.tar.gz]
set -euo pipefail
# `pwd -W` gives C:/... on Git Bash: docker.exe cannot read /c/... paths.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && { pwd -W 2>/dev/null || pwd; })"
export MSYS_NO_PATHCONV=1
TARBALL="${1:-$(ls -t "$ROOT"/build/linux-dist/fushi-*-linux-x64.tar.gz | head -1)}"
VERSION="$(basename "$TARBALL" | sed -E 's/^fushi-(.*)-linux-x64\.tar\.gz$/\1/')"
# WebCore's unified sources need ~4 GB per compiler (the SDK builds with -g): budget
# 4.5 GB per job. 6 jobs stalled in 22 GB; 5 jobs fit in 22 GB, 3 in 15 GB.
JOBS="${FUSHI_FLATPAK_JOBS:-3}"
mkdir -p "$ROOT/build/linux-dist"
docker build -q -t fushi-flatpak-build "$ROOT/tool/linux/flatpak" >/dev/null

# Stage manifest + inputs into the work volume (bind mounts from Windows are slow).
(cd "$ROOT/tool/linux/flatpak" && tar -cf - app.fushi.reader.yml app.fushi.reader.desktop ./*.patch) |
  docker run --rm -i -v fushi-flatpak-work:/work fushi-flatpak-build \
    bash -c 'mkdir -p /work/src && tar -xf - -C /work/src'
docker run --rm -i -v fushi-flatpak-work:/work fushi-flatpak-build \
  bash -c 'cat > /work/src/fushi-linux-x64.tar.gz' < "$TARBALL"

docker run --rm --privileged --cpus="$JOBS" --memory="${FUSHI_DOCKER_MEMORY:-15g}" \
  -v fushi-flatpak-state:/root/.local/share/flatpak \
  -v fushi-flatpak-work:/work \
  -v "$ROOT/build/linux-dist:/out" \
  -e JOBS="$JOBS" -e VERSION="$VERSION" \
  fushi-flatpak-build bash -euo pipefail -c '
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    # ccache defaults to 5 GB; WebKit objects with -g need ~50 GB, or the late WebCore
    # objects get evicted and every resume recompiles them for hours.
    mkdir -p /work/state/ccache && echo "max_size = 80G" > /work/state/ccache/ccache.conf
    cd /work/src
    flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse --ccache \
      --jobs="$JOBS" --state-dir=/work/state --repo=/work/repo --force-clean \
      /work/build-dir app.fushi.reader.yml
    flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
      /work/repo "/out/fushi-$VERSION.flatpak" app.fushi.reader
    ls -lh "/out/fushi-$VERSION.flatpak"'

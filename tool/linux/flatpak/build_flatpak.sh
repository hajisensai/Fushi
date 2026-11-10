#!/usr/bin/env bash
# Local build: build/linux-dist/fushi-<v>-linux-x86_64.flatpak from the Linux bundle
# tarball, in a privileged Debian container (flatpak-builder needs bubblewrap). The
# build itself is flatpak_build.sh, the same script CI runs. The BaseApp (WebKit,
# mpv, ...) is built once per BaseApp key and kept in the fushi-flatpak-work volume,
# so normally only the app layer rebuilds (minutes).
#   bash tool/linux/flatpak/build_flatpak.sh [path/to/fushi-<v>-linux-x64.tar.gz]
# FUSHI_FLATPAK_BRANCH (default master = a local build the in-app updater leaves
# alone; stable / beta / debug make it follow that channel).
set -euo pipefail
# `pwd -W` gives C:/... on Git Bash: docker.exe cannot read /c/... paths.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && { pwd -W 2>/dev/null || pwd; })"
export MSYS_NO_PATHCONV=1
TARBALL="${1:-$(ls -t "$ROOT"/build/linux-dist/fushi-*-linux-x64.tar.gz | head -1)}"
VERSION="$(basename "$TARBALL" | sed -E 's/^fushi-(.*)-linux-x64\.tar\.gz$/\1/')"
BRANCH="${FUSHI_FLATPAK_BRANCH:-master}"
# WebCore's unified sources need ~2 GB per compiler without debug info.
JOBS="${FUSHI_FLATPAK_JOBS:-3}"
mkdir -p "$ROOT/build/linux-dist"
docker build -q -t fushi-flatpak-build "$ROOT/tool/linux/flatpak" >/dev/null

# Stage the flatpak dir + tarball into the work volume (bind mounts from Windows are slow).
(cd "$ROOT/tool/linux/flatpak" && tar -cf - .) |
  docker run --rm -i -v fushi-flatpak-work:/work fushi-flatpak-build \
    bash -euo pipefail -c 'rm -rf /work/src && mkdir -p /work/src && tar -xf - -C /work/src'
docker run --rm -i -v fushi-flatpak-work:/work fushi-flatpak-build \
  bash -c 'cat > /work/fushi-linux-x64.tar.gz' < "$TARBALL"

docker run --rm --privileged --cpus="$JOBS" --memory="${FUSHI_DOCKER_MEMORY:-15g}" \
  -v fushi-flatpak-state:/root/.local/share/flatpak \
  -v fushi-flatpak-work:/work \
  -v "$ROOT/build/linux-dist:/out" \
  -e FLATPAK_BUILDER_JOBS="$JOBS" -e FLATPAK_STATE_DIR=/work/state \
  -e VERSION="$VERSION" -e BRANCH="$BRANCH" \
  fushi-flatpak-build bash -euo pipefail -c '
    mkdir -p /work/state/ccache && echo "max_size = 30G" > /work/state/ccache/ccache.conf
    cd /work
    key="$(bash src/flatpak_build.sh baseapp-key)"
    base="/work/baseapp/app.fushi.reader.BaseApp-$key.flatpak"
    if [[ ! -f "$base" ]]; then
      rm -rf /work/baseapp
      bash src/flatpak_build.sh baseapp /work/baseapp
    fi
    if [[ "$(cat /work/baseapp-installed 2>/dev/null)" != "$key" ]]; then
      flatpak install --user -y --noninteractive --reinstall "$base"
      echo "$key" > /work/baseapp-installed
    fi
    rm -rf /work/app-out
    bash src/flatpak_build.sh app /work/fushi-linux-x64.tar.gz "$BRANCH" "$VERSION" /work/app-out
    cp /work/app-out/fushi-$VERSION-linux-x86_64.flatpak /out/'
ls -lh "$ROOT/build/linux-dist/fushi-$VERSION-linux-x86_64.flatpak"

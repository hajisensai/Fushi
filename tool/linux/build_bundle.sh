#!/usr/bin/env bash
# Builds the full Fushi Linux x64 release bundle inside the tool/linux/Dockerfile
# image (run by tool/linux/build_in_docker.sh; source tree at /src).
#
# Every native library is built and REQUIRED here, including the ones the app's
# CMake treats as copy-if-present (fushi_p2p, fushi_fsrs, fushi_torrent): a
# shipped bundle must never be "light" by accident. Output:
#   /src/fushi/build/linux/x64/release/bundle/
#   /out/fushi-<version>-linux-x64.tar.gz
#
# Usage: build_bundle.sh [--skip-native]   (--skip-native reuses existing prebuilt/)
#
# FUSHI_BUILD_NAME / FUSHI_BUILD_NUMBER: the release channel's version name and
# release sequence (release-desktop.yml passes them, as for Windows / macOS) so the
# app reports e.g. 3.4.0-debug.7001 and the update check compares the right thing.
# Default: the pubspec version.
set -euo pipefail

SKIP_NATIVE=0
for arg in "$@"; do
  case "$arg" in
    --skip-native) SKIP_NATIVE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd /src
step() { echo; echo "==> $*"; }

# bootstrap.sh builds the required Rust libs (compute, fsrs, web_core, rwkv,
# music, corpus); p2p and torrent are copy-if-present for the app CMake, so they
# are built here to make them required for a shipped bundle.
if [[ "$SKIP_NATIVE" == 0 ]]; then
  step "native: fushi_p2p"
  bash native/fushi_p2p/build_linux_so.sh
  step "native: fushi_torrent (vcpkg static)"
  bash native/fushi_torrent/build_linux_so.sh "$VCPKG_ROOT"
else
  export FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1
fi

step "bootstrap (pub get, pub-cache patches, vendored binaries, required Rust libs)"
bash tool/bootstrap.sh

step "flutter build linux --release"
pubspec_version="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' fushi/pubspec.yaml)"
version="${FUSHI_BUILD_NAME:-$pubspec_version}"
build_args=(--build-name "$version" --dart-define="FUSHI_BUILD_VERSION=$version")
[[ -n "${FUSHI_BUILD_NUMBER:-}" ]] && build_args+=(--build-number "$FUSHI_BUILD_NUMBER")
(cd fushi && rm -rf build/linux && flutter build linux --release --no-pub "${build_args[@]}")

BUNDLE=/src/fushi/build/linux/x64/release/bundle

step "fushi-anki-sync (release) into bundle"
FUSHI_SOURCE_COMMIT="${FUSHI_SOURCE_COMMIT:-unknown}" \
  bash native/fushi_anki_sync/build.sh --install-dir "$BUNDLE"

step "mihon_bridge runtime into bundle"
bash tool/mihon/build_desktop_runtime.sh "$BUNDLE/mihon_bridge" /root/.cache/fushi/mihon-downloads

step "fushi_cli into bundle"
# Same as release-desktop.yml for Windows: the desktop CLI ships next to the app
# (ai/mcp/ai_mcp_access.dart looks for it there).
dart compile exe packages/fushi_cli/bin/fushi_cli.dart -o "$BUNDLE/fushi_cli"

step "verify required native libs are in the bundle"
missing=0
for lib in libfushi_compute.so libfushi_rwkv.so libfushi_music.so libfushi_web_core.so \
           libfushi_corpus.so libfushi_fsrs.so libfushi_p2p.so libfushi_torrent_ffi.so libfushidicts_ffi.so \
           libapp.so libflutter_linux_gtk.so; do
  if [[ -f "$BUNDLE/lib/$lib" ]]; then echo "ok   lib/$lib"; else echo "MISS lib/$lib"; missing=1; fi
done
for f in fushi fushi_cli fushi-anki-sync mihon_bridge/runtime/bin/java; do
  if [[ -e "$BUNDLE/$f" ]]; then echo "ok   $f"; else echo "MISS $f"; missing=1; fi
done
if [[ "$missing" != 0 ]]; then
  echo "bundle is missing required pieces (see MISS above)" >&2
  exit 1
fi

step "unresolved shared-library dependencies (should be only distro runtime deps)"
find "$BUNDLE" -maxdepth 2 -type f \( -name 'fushi' -o -name '*.so*' \) -print0 \
  | xargs -0 -I{} sh -c 'LD_LIBRARY_PATH="'"$BUNDLE"'/lib" ldd "{}" 2>/dev/null | grep "not found" | sed "s|^|{}: |"' \
  | sort -u || true
echo "required glibc: $(objdump -T "$BUNDLE/fushi" "$BUNDLE"/lib/*.so 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n1)"

mkdir -p /out
tarball="/out/fushi-${version}-linux-x64.tar.gz"
step "package $tarball"
tar -C "$(dirname "$BUNDLE")" -czf "$tarball" --transform "s|^bundle|fushi-${version}-linux-x64|" bundle
ls -lh "$tarball"

#!/usr/bin/env bash
# The one place that builds and lays out the headless fushi_server Linux x64
# bundle. Two callers, same commands, same layout:
#
#   .github/workflows/release-server.yml (job `linux`): one step per subcommand,
#     so each piece keeps its own cache step and log section. Runs on
#     ubuntu-22.04 (glibc 2.35 baseline, checked by the workflow afterwards).
#   packages/fushi_server/docker/Dockerfile.source: `all` inside the
#     tool/linux/Dockerfile toolchain image (Debian trixie).
#
# Bundle (build/fushi_server_linux/bundle):
#   bin/fushi_server, bin/fushi-anki-sync (+ its AGPL SOURCE.txt)
#   lib/*.so: sqlite3 (dart build native asset), torrent bridge (static
#     libtorrent), fushi_p2p, fushi_fsrs, fushi_compute, fushi_rwkv,
#     fushidicts, onnxruntime
#   share/fushi/transforms (fushidicts deinflection tables)
# No release.json / README: the release "Package" step and the Docker image add
# what they need.
#
# Usage: bash packages/fushi_server/tool/build_linux_bundle.sh <subcommand> [args]
#   prepare               flutter pub get (workspace) + ci/apply-patches.sh
#   torrent <vcpkg-root>  static libtorrent bridge + exported ABI check
#   rust <crate>          fushi_p2p | fushi_fsrs | fushi_compute | fushi_rwkv,
#                         then its ABI check
#   cli                   dart build cli; copy the torrent / Rust libraries;
#                         onnxruntime from NuGet (pinned sha256)
#   fushidicts            dictionary engine (.so + dlopen smoke) and transforms;
#                         C++23, so CC/CXX default to gcc-14 / g++-14
#   anki-sync             fushi-anki-sync into bin/ (with version smoke)
#   verify                every required file is there; `fushi_server --help` runs
#   all <vcpkg-root>      all of the above in order
#
# Order matters: `cli` recreates the bundle, so it runs after the native
# libraries and before fushidicts / anki-sync.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
cd "$ROOT"
OUT=build/fushi_server_linux
BUNDLE="$OUT/bundle"
RUST_CRATES=(fushi_p2p fushi_fsrs fushi_compute fushi_rwkv)
ORT_VERSION="${ORT_VERSION:-1.22.0}"

usage() {
  sed -n '/^# Usage:/,/^# *all /p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

step() { echo; echo "==> $*"; }

cmd_prepare() {
  step "pub get (workspace) + pub-cache patches"
  (cd fushi && flutter pub get)
  # fushi_asr_onnx_ffi pins archive ^4 while the workspace pins ^3.6.1; without
  # the ci/patches/ readBytes->content patch `dart build cli` does not compile.
  bash ci/apply-patches.sh
}

cmd_torrent() {
  local vcpkg_root="${1:?torrent needs <vcpkg-root>}"
  step "native: fushi_torrent (vcpkg, static libtorrent)"
  bash native/fushi_torrent/build_linux_so.sh "$vcpkg_root"
  bash .github/scripts/verify_torrent_abi.sh native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so nm
}

cmd_rust() {
  local crate="${1:?rust needs a crate: ${RUST_CRATES[*]}}"
  case " ${RUST_CRATES[*]} " in
    *" $crate "*) ;;
    *) echo "unknown crate $crate (expected: ${RUST_CRATES[*]})" >&2; exit 2 ;;
  esac
  # Only glibc is linked dynamically (Rust links everything else statically),
  # so the build host's glibc is the bundle's floor.
  step "native: $crate"
  bash "native/$crate/build_linux_so.sh"
  bash "native/$crate/verify_abi.sh" "native/$crate/prebuilt/linux-x64/lib$crate.so" nm
}

cmd_cli() {
  step "dart build cli + native libraries + onnxruntime $ORT_VERSION"
  rm -rf "$OUT"
  dart build cli --target packages/fushi_server/bin/fushi_server.dart --output "$OUT"
  mkdir -p "$BUNDLE/lib"
  cp native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so "$BUNDLE/lib/"
  cp native/fushi_p2p/prebuilt/linux-x64/libfushi_p2p.so "$BUNDLE/lib/"
  cp native/fushi_fsrs/prebuilt/linux-x64/libfushi_fsrs.so "$BUNDLE/lib/"
  cp native/fushi_compute/prebuilt/linux-x64/libfushi_compute.so "$BUNDLE/lib/"
  cp native/fushi_rwkv/prebuilt/linux-x64/libfushi_rwkv.so "$BUNDLE/lib/"
  # github.com/microsoft/onnxruntime release assets 404 since 2026-11-17; the
  # same official build comes from NuGet, pinned by sha256 in the script.
  python3 .github/scripts/fetch_onnxruntime_nuget.py "$ORT_VERSION" linux-x64 "$BUNDLE/lib"
  ls -la "$BUNDLE/bin" "$BUNDLE/lib"
}

cmd_fushidicts() {
  # fushidicts needs C++23 (std::ranges::to, std::expected): GCC 14 at least.
  # libstdc++ / libgcc are linked statically into the .so.
  export CC="${CC:-gcc-14}" CXX="${CXX:-g++-14}"
  step "native: fushidicts ($CXX) + transforms"
  bash native/fushidicts/build_linux_so.sh
  local lib="$BUNDLE/lib/libfushidicts_ffi.so"
  mkdir -p "$(dirname "$lib")"
  cp native/fushidicts/prebuilt/linux-x64/libfushidicts_ffi.so "$lib"
  DICTS_LIB="$lib" python3 - <<'PY'
import ctypes
import os
lib = ctypes.CDLL(os.environ["DICTS_LIB"])
lib.fushidicts_create.restype = ctypes.c_void_p
lib.fushidicts_destroy.argtypes = [ctypes.c_void_p]
handle = lib.fushidicts_create()
if not handle:
    raise SystemExit("fushidicts_create returned null")
lib.fushidicts_destroy(handle)
print("fushidicts .so smoke ok")
PY
  # The server finds the tables at bin/../share/fushi/transforms.
  local share="$BUNDLE/share/fushi"
  mkdir -p "$share"
  rm -rf "$share/transforms"
  cp -a fushi/assets/transforms "$share/transforms"
  test -f "$share/transforms/manifest.json"
}

cmd_anki_sync() {
  # AGPL helper linking Anki's rslib; build.sh writes fushi-anki-sync.SOURCE.txt
  # (commit from git HEAD, or FUSHI_SOURCE_COMMIT without .git) and smoke-runs
  # the installed copy.
  step "native: fushi-anki-sync"
  bash native/fushi_anki_sync/build.sh --install-dir "$BUNDLE/bin"
}

cmd_verify() {
  step "verify bundle"
  local missing=0 f
  for f in bin/fushi_server bin/fushi-anki-sync \
           lib/libfushi_torrent_ffi.so lib/libfushi_p2p.so lib/libfushi_fsrs.so \
           lib/libfushi_compute.so lib/libfushi_rwkv.so lib/libfushidicts_ffi.so \
           lib/libonnxruntime.so share/fushi/transforms/manifest.json; do
    if [[ -e "$BUNDLE/$f" ]]; then echo "ok   $f"; else echo "MISS $f"; missing=1; fi
  done
  [[ "$missing" == 0 ]] || { echo "bundle is missing required pieces" >&2; exit 1; }
  "$BUNDLE/bin/fushi_server" --help >/dev/null
  echo "bundle ready: $ROOT/$BUNDLE"
}

cmd_all() {
  local vcpkg_root="${1:?all needs <vcpkg-root>}"
  local crate
  cmd_prepare
  cmd_torrent "$vcpkg_root"
  for crate in "${RUST_CRATES[@]}"; do cmd_rust "$crate"; done
  cmd_cli
  cmd_fushidicts
  cmd_anki_sync
  cmd_verify
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  prepare) cmd_prepare ;;
  torrent) cmd_torrent "$@" ;;
  rust) cmd_rust "$@" ;;
  cli) cmd_cli ;;
  fushidicts) cmd_fushidicts ;;
  anki-sync) cmd_anki_sync ;;
  verify) cmd_verify ;;
  all) cmd_all "$@" ;;
  *) usage ;;
esac

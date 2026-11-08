#!/usr/bin/env bash
# Build the headless fushi_server Linux x64 bundle from source, inside the
# Dockerfile.source build stage (toolchain = tool/linux/Dockerfile).
#
# Same bundle layout and contents as the Linux job of
# .github/workflows/release-server.yml: bin/fushi_server + bin/fushi-anki-sync,
# lib/*.so (torrent bridge, p2p, fsrs, compute, rwkv, fushidicts, onnxruntime),
# share/fushi/transforms. No release.json: a source build is not a release.
#
#   bash packages/fushi_server/docker/build_server_bundle.sh <out-dir>
set -euo pipefail

OUT="${1:?usage: build_server_bundle.sh <out-dir>}"
ORT_VERSION="${ORT_VERSION:-1.22.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
export CC="${CC:-gcc-14}" CXX="${CXX:-g++-14}"

step() { echo; echo "==> $*"; }

step "pub get (workspace) + pub-cache patches"
(cd fushi && flutter pub get)
bash ci/apply-patches.sh

step "native: fushi_torrent (vcpkg, static)"
bash native/fushi_torrent/build_linux_so.sh "$VCPKG_ROOT"
bash .github/scripts/verify_torrent_abi.sh native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so nm

for crate in fushi_p2p fushi_fsrs fushi_compute fushi_rwkv; do
  step "native: $crate"
  bash "native/$crate/build_linux_so.sh"
  bash "native/$crate/verify_abi.sh" "native/$crate/prebuilt/linux-x64/lib$crate.so" nm
done

step "native: fushidicts"
bash native/fushidicts/build_linux_so.sh

step "dart build cli"
rm -rf build/fushi_server_linux
dart build cli --target packages/fushi_server/bin/fushi_server.dart --output build/fushi_server_linux
BUNDLE=build/fushi_server_linux/bundle
mkdir -p "$BUNDLE/lib" "$BUNDLE/share/fushi"
cp native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so "$BUNDLE/lib/"
for crate in fushi_p2p fushi_fsrs fushi_compute fushi_rwkv; do
  cp "native/$crate/prebuilt/linux-x64/lib$crate.so" "$BUNDLE/lib/"
done
cp native/fushidicts/prebuilt/linux-x64/libfushidicts_ffi.so "$BUNDLE/lib/"
cp -a fushi/assets/transforms "$BUNDLE/share/fushi/transforms"

step "onnxruntime $ORT_VERSION"
ort_tmp="$(mktemp -d)"
curl -fsSL --retry 3 -o "$ort_tmp/ort.tgz" \
  "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-linux-x64-${ORT_VERSION}.tgz"
tar -xzf "$ort_tmp/ort.tgz" -C "$ort_tmp"
cp -a "$ort_tmp/onnxruntime-linux-x64-${ORT_VERSION}/lib/"libonnxruntime.so* "$BUNDLE/lib/"
rm -rf "$ort_tmp"

step "fushi-anki-sync"
bash native/fushi_anki_sync/build.sh --install-dir "$BUNDLE/bin"

step "verify bundle"
missing=0
for f in bin/fushi_server bin/fushi-anki-sync lib/libfushi_torrent_ffi.so lib/libfushi_p2p.so \
         lib/libfushi_fsrs.so lib/libfushi_compute.so lib/libfushi_rwkv.so lib/libfushidicts_ffi.so \
         lib/libonnxruntime.so share/fushi/transforms/manifest.json; do
  if [[ -e "$BUNDLE/$f" ]]; then echo "ok   $f"; else echo "MISS $f"; missing=1; fi
done
[[ "$missing" == 0 ]] || { echo "bundle is missing required pieces" >&2; exit 1; }
"$BUNDLE/bin/fushi_server" --help >/dev/null

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -a "$BUNDLE" "$OUT"
cp packages/fushi_server/README.md "$OUT/README.md"
echo "bundle ready: $OUT"

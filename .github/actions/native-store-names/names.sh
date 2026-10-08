#!/usr/bin/env bash
# Native artifact store names: the ONE place that turns build inputs into the artifact
# name `.github/actions/native-artifact-store` looks up. Producers (release-desktop.yml
# on develop, native-cache-warm.yml) and consumers (build-multiplatform.yml PR gates)
# all call this through `.github/actions/native-store-names`, so a name can never be
# computed two ways (guard: fushi/test/build/native_store_names_single_source_guard_test.dart).
#
#   names.sh <windows|macos|ios|linux>
#
# Prints `key=value` lines and appends them to $GITHUB_OUTPUT when that is set, so a
# local dry run is just `bash .github/actions/native-store-names/names.sh linux`.
#
# A name encodes every input of the build:
#   * source: `git ls-tree -r HEAD` of the input paths (blob ids of COMMITTED content).
#     Not hashFiles(): that hashes whatever is on disk at the time, so it had to run
#     before gitignored build/ prebuilt/ target/ dist/ .anki-src/ appeared, and on
#     Windows it hashes the autocrlf-converted checkout. Blob ids are immune to both
#     and identical on every runner OS. On a pull_request run HEAD is the merge commit,
#     so an input tree the PR does not touch yields exactly the develop-side name.
#   * runner image: ImageOS + ImageVersion (preinstalled compilers, SDKs, Xcode, vcpkg
#     revision) and, where the output is single-arch, the runner arch;
#   * toolchain pins that live outside the hashed tree: the fushi_p2p Rust toolchain
#     (exported as p2p_rust; the dtolnay steps read it from here) and the job's CC/CXX.
#     fushi-anki-sync's Rust channel and protoc pin are inside its hashed paths
#     (native/fushi_anki_sync/rust-toolchain.toml, .github/actions/setup-fushi-anki-sync).
# A build starts reading another directory => add it to the path lists below.
set -euo pipefail

platform="${1:?usage: names.sh <windows|macos|ios|linux|android>}"

# fushi_p2p Rust toolchain. Every `Set up Rust (fushi_p2p...)` step takes
# `toolchain: ${{ steps.native_store.outputs.p2p_rust }}`, so bumping it here both
# changes what is built and invalidates every p2p name at once.
P2P_RUST=1.95.0
# cargo-ndk used to cross-build fushi_p2p for Android (release.yml reads it from here).
CARGO_NDK=4.1.2

cd "$(git rev-parse --show-toplevel)"

sanitize() { printf '%s' "$1" | tr -c '0-9A-Za-z._-' '-'; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

image="$(sanitize "${ImageVersion:-unknown-image}")"
image_os="$(sanitize "${ImageOS:-unknown-os}")"
arch="$(sanitize "$(printf '%s' "${RUNNER_ARCH:-unknown-arch}" | tr 'A-Z' 'a-z')")"
# Compilers a job pins through env (build-multiplatform linux-server job: gcc-14). Folded into
# the hash, so a producer that forgot to set them can never feed a consumer that did.
toolchain_env="CC=${CC:-} CXX=${CXX:-}"

# tree_hash <extra-identity> <path>... : sha256 over the committed tree of <path>s plus
# the extra identity string. Fails when the paths match nothing (a renamed directory
# must not silently turn the name into a constant). Markdown is left out: no build in
# these trees reads a .md, and a README edit used to cold-rebuild every platform.
tree_hash() {
  local extra="$1"
  shift
  local listing
  listing="$(git ls-tree -r --full-tree HEAD -- "$@" | grep -viE '\.md$' || true)"
  if [ -z "$listing" ]; then
    echo "::error title=native-store-names::git ls-tree matched nothing for: $*" >&2
    exit 1
  fi
  { printf '%s\n' "$listing"; printf 'identity: %s\n' "$extra"; } | sha256 | cut -c1-64
}

TORRENT=(native/fushi_torrent)
P2P=(native/fushi_p2p)
MIHON=(third_party/m_extension_server third_party/jogamp tool/mihon)
GALGAME=(native/galgame_hook)
ANKI_SYNC=(native/fushi_anki_sync .github/actions/setup-fushi-anki-sync)

names=()
case "$platform" in
  windows)
    names+=(
      "torrent=win-x64-fushi-torrent-dll-v2-$image-$(tree_hash "$toolchain_env" "${TORRENT[@]}")"
      "p2p=win-x64-fushi-p2p-dll-v2-rust$P2P_RUST-$image-$(tree_hash "$toolchain_env rust=$P2P_RUST" "${P2P[@]}")"
      # Mihon runtime: JDK and server commit are pinned inside tool/mihon; no image input.
      "mihon=win-x64-mihon-runtime-v2-$(tree_hash "" "${MIHON[@]}")"
      "galgame=win-galgame-helper-dist-v2-$image-$(tree_hash "$toolchain_env" "${GALGAME[@]}")"
      "anki_sync_release=win-x64-fushi-anki-sync-release-v2-$image-$(tree_hash "$toolchain_env" "${ANKI_SYNC[@]}")"
      "anki_sync_debug=win-x64-fushi-anki-sync-debug-v2-$image-$(tree_hash "$toolchain_env" "${ANKI_SYNC[@]}")"
    )
    ;;
  macos)
    names+=(
      # macOS ships Apple Silicon (arm64) only; Intel Macs are not supported. Release
      # dylib: the PR gate and the desktop release build the same bytes with the same
      # script, so they share one name.
      "p2p=macos-arm64-fushi-p2p-dylib-v1-rust$P2P_RUST-$image_os-$image-$(tree_hash "$toolchain_env rust=$P2P_RUST" "${P2P[@]}")"
      # arm64 static libtorrent bridge (build_macos_dylib.sh); same sharing rule as p2p.
      # The runner's vcpkg checkout is part of the image identity.
      "torrent=macos-arm64-fushi-torrent-dylib-v1-$image_os-$image-$(tree_hash "$toolchain_env" "${TORRENT[@]}")"
      "anki_sync_release=macos-arm64-fushi-anki-sync-release-v1-$image_os-$image-$(tree_hash "$toolchain_env" "${ANKI_SYNC[@]}")"
      # The PR gate's debug build targets the runner's own arch only.
      "anki_sync_debug=macos-$arch-fushi-anki-sync-debug-v1-$image_os-$image-$(tree_hash "$toolchain_env" "${ANKI_SYNC[@]}")"
    )
    ;;
  ios)
    names+=(
      # Device slice only (build_ios_staticlib.sh device), shared by PR gate and release.
      "p2p=ios-device-fushi-p2p-staticlib-v1-rust$P2P_RUST-$image_os-$image-$(tree_hash "$toolchain_env rust=$P2P_RUST" "${P2P[@]}")"
    )
    ;;
  linux)
    names+=(
      "torrent=linux-x64-fushi-torrent-so-static-v1-$image_os-$image-$(tree_hash "$toolchain_env" "${TORRENT[@]}")"
      "p2p=linux-x64-fushi-p2p-so-v1-rust$P2P_RUST-$image_os-$image-$(tree_hash "$toolchain_env rust=$P2P_RUST" "${P2P[@]}")"
      "anki_sync_debug=linux-x64-fushi-anki-sync-debug-v1-$image_os-$image-$(tree_hash "$toolchain_env" "${ANKI_SYNC[@]}")"
    )
    ;;
  android)
    # release.yml's Android build job (the only producer and consumer). The NDK and
    # the runner's vcpkg checkout are build inputs the tree hash cannot see.
    ndk="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "${ANDROID_NDK_LATEST_HOME:-}/source.properties" 2>/dev/null | head -n 1 || true)"
    [ -n "$ndk" ] || ndk="$(basename "${ANDROID_NDK_LATEST_HOME:-unknown-ndk}")"
    ndk="$(sanitize "$ndk")"
    vcpkg_rev="$(sanitize "$(git -C "${VCPKG_INSTALLATION_ROOT:-/nonexistent}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)")"
    names+=(
      "torrent=android-arm64-fushi-torrent-so-v2-ndk$ndk-vcpkg$vcpkg_rev-$image-$(tree_hash "ndk=$ndk vcpkg=$vcpkg_rev" "${TORRENT[@]}")"
      "p2p=android-fushi-p2p-so-v2-3abi-rust$P2P_RUST-cargondk$CARGO_NDK-ndk$ndk-$image-$(tree_hash "ndk=$ndk rust=$P2P_RUST cargo-ndk=$CARGO_NDK" "${P2P[@]}")"
    )
    ;;
  *)
    echo "::error title=native-store-names::unknown platform '$platform' (windows|macos|ios|linux|android)" >&2
    exit 2
    ;;
esac
names+=("p2p_rust=$P2P_RUST" "cargo_ndk=$CARGO_NDK")

for line in "${names[@]}"; do
  echo "$line"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$line" >> "$GITHUB_OUTPUT"; fi
done

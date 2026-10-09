#!/usr/bin/env bash
# Build the existing Darwin framework pipeline with Fushi's menu-capable mpv.
# No upload, release, or app installation is performed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BASE=865ef1494a89007fcf51a28609847debce85fbda
TARGET=${TARGET:-macos}
WORK=${WORK:-"$ROOT/.tmp/bluray-darwin-build"}
PREPARE_ONLY=${PREPARE_ONLY:-0}
case "$TARGET" in macos|ios) ;; *) echo 'TARGET must be macos or ios' >&2; exit 2 ;; esac

mkdir -p "$WORK"
if [ ! -d "$WORK/source.git" ]; then
  git clone --bare https://github.com/hajisensai/libmpv-darwin-build "$WORK/source.git"
fi
if [ ! -d "$WORK/checkout" ]; then
  git --git-dir="$WORK/source.git" worktree add --detach "$WORK/checkout" "$BASE"
fi
test "$(git -C "$WORK/checkout" rev-parse HEAD)" = "$BASE"
PATCH="$ROOT/tool/bluray/platforms/patches/darwin-build.patch"
if git -C "$WORK/checkout" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo 'Darwin build overlay already applied'
else
  test -z "$(git -C "$WORK/checkout" status --porcelain)"
  git -C "$WORK/checkout" apply --check "$PATCH"
  git -C "$WORK/checkout" apply "$PATCH"
fi
cp "$ROOT/tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch" \
  "$WORK/checkout/patches/mpv-gl-dovi-p5-menu.patch"
cp "$ROOT/third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch" \
  "$WORK/checkout/patches/disc-navigation-state.patch"
# Nix flakes deliberately ignore untracked files. Stage only this overlay in
# the isolated dependency worktree, otherwise Nix cannot see the new recipes.
git -C "$WORK/checkout" add nix/packages/mk-pkg-mpv nix/packages/mk-pkg-libbluray \
  nix/packages/mk-pkg-libplacebo nix/packages/mk-pkg-libpng/default.nix \
  nix/packages/mk-out-libs/default.nix packages.lock.nix \
  patches/libbluray-ios-files.patch patches/libpng-modern-apple-math.patch \
  patches/mpv-audiounit-shared-session-menu.patch \
  patches/mpv-darwin-cross-sdk.patch patches/mpv-gl-dovi-p5-menu.patch \
  patches/disc-navigation-state.patch
if [ "$PREPARE_ONLY" = 1 ]; then
  echo "Prepared dependency checkout: $WORK/checkout"
  exit 0
fi
test "$(uname -s)" = Darwin || { echo 'Building requires macOS and Xcode' >&2; exit 2; }
command -v nix >/dev/null
XCODE_PATH=${XCODE_PATH:-$(xcode-select -p | sed 's,/Contents/Developer$,,')}
test -d "$XCODE_PATH"
make -C "$WORK/checkout" XCODE_PATH="$XCODE_PATH" VERSION=bluray-36abaa32 \
  TARGET="mk-out-archive-xcframeworks-$TARGET-universal-video-full"
mkdir -p "$WORK/output"
find -L "$WORK/checkout/result" -maxdepth 2 -name '*.tar.gz' -type f \
  -exec cp '{}' "$WORK/output/" \;
find "$WORK/output" -name '*.tar.gz' -type f -exec shasum -a 256 '{}' \; \
  > "$WORK/output/SHA256SUMS"
test -s "$WORK/output/SHA256SUMS"
cat "$WORK/output/SHA256SUMS"
echo 'Build only: verify native menu navigation and Dolby Vision rendering before updating production pins.'

#!/usr/bin/env bash
# Xcode 构建阶段「Bundle fushi_music dylib」：音乐胖核心（曲库扫描 / 标签 / CUE）的原生库，
# **硬依赖**（GPL-3.0-only）。与 bundle_fushi_music.sh 同一形态。
#
# native/fushi_music/build_macos_dylib.sh 产出 prebuilt/macos/libfushi_music.dylib，拷进
# Contents/Frameworks（Runner 的 LD_RUNPATH_SEARCH_PATHS 含 @executable_path/../Frameworks，
# Dart 侧 packages/fushi_music 按裸名经这个 rpath 加载）。没有 Dart 回退实现，缺库时本阶段失败、
# 整个构建失败——与 Windows / Linux CMake、Android checkFushiMusicNative 同一语义。
set -euo pipefail

name="libfushi_music.dylib"
source="${PROJECT_DIR}/../../native/fushi_music/prebuilt/macos/${name}"
destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
destination="${destination_dir}/${name}"

if [[ ! -f "$source" ]]; then
  # 上一次构建拷进去的旧库不能留着冒充本次产物。
  rm -f "$destination"
  echo "error: fushi_music is a required native dependency, but ${source} is missing; run native/fushi_music/build_macos_dylib.sh first (needs Rust: rustup target add aarch64-apple-darwin)" >&2
  exit 1
fi

# 库在、但缺本次要出的架构（macOS 版只出 arm64）：带进去也加载失败，比「没带」更难查。
available_archs=" $(lipo -archs "$source") "
for arch in ${ARCHS:-$(uname -m)}; do
  case "$available_archs" in
    *" $arch "*) ;;
    *)
      echo "error: ${source} lacks ${arch} (has:${available_archs}); rebuild with native/fushi_music/build_macos_dylib.sh" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$destination_dir"
cp -f "$source" "$destination"
install_name_tool -id "@rpath/${name}" "$destination"

if [[ "${CODE_SIGNING_ALLOWED:-}" != "NO" ]] && command -v codesign >/dev/null 2>&1; then
  sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="-"
  fi
  codesign --force --sign "$sign_identity" --timestamp=none "$destination"
fi

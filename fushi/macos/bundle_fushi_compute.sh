#!/usr/bin/env bash
# Xcode 构建阶段「Bundle fushi_compute dylib」：计算内核（哈希 / 图像 / 文本）的原生库，**硬依赖**。
#
# native/fushi_compute/build_macos_dylib.sh 产出 prebuilt/macos/libfushi_compute.dylib，拷进
# Contents/Frameworks（Runner 的 LD_RUNPATH_SEARCH_PATHS 含 @executable_path/../Frameworks，
# Dart 侧 packages/fushi_compute 按裸名经这个 rpath 加载）。与 bundle_fushi_fsrs.sh 等
# copy-if-present 不同：没有 Dart 回退实现，缺库时本阶段失败、整个构建失败——与 Windows /
# Linux CMake、Android checkFushiComputeNative 同一语义，Mac 上构建 app 前必须先装 Rust 编它。
# 发布流水线（release-desktop.yml / build-multiplatform.yml）先跑构建脚本，出包后再核对。
set -euo pipefail

name="libfushi_compute.dylib"
source="${PROJECT_DIR}/../../native/fushi_compute/prebuilt/macos/${name}"
destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
destination="${destination_dir}/${name}"

if [[ ! -f "$source" ]]; then
  # 上一次构建拷进去的旧库不能留着冒充本次产物。
  rm -f "$destination"
  echo "error: fushi_compute is a required native dependency, but ${source} is missing; run native/fushi_compute/build_macos_dylib.sh first (needs Rust: rustup target add aarch64-apple-darwin)" >&2
  exit 1
fi

# 库在、但缺本次要出的架构（macOS 版只出 arm64）：带进去也加载失败，比「没带」更难查。
available_archs=" $(lipo -archs "$source") "
for arch in ${ARCHS:-$(uname -m)}; do
  case "$available_archs" in
    *" $arch "*) ;;
    *)
      echo "error: ${source} lacks ${arch} (has:${available_archs}); rebuild with native/fushi_compute/build_macos_dylib.sh" >&2
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

#!/usr/bin/env bash
# Xcode 构建阶段「Bundle fushi_web_core dylib」：网页内容核心（fushi_web_core：广告拦截 + 漫画
# 章末广告页识别，Rust）的原生库。
#
# native/fushi_web_core/build_macos_dylib.sh 产出 prebuilt/macos/libfushi_web_core.dylib，拷进
# Contents/Frameworks（Runner 的 LD_RUNPATH_SEARCH_PATHS 含 @executable_path/../Frameworks，
# Dart 侧 packages/fushi_web_core 按裸名经这个 rpath 加载）。
# **硬依赖**：Dart 侧没有「缺库判不可用」的分支。Release / Profile 构建缺它直接失败；Debug 构建
# 只告警（不挡纯 UI 开发，用到网页浏览 / 网页漫画时如实报错）。发布流水线（release-desktop.yml /
# build-multiplatform.yml）先跑构建脚本，出包后再核对 Frameworks 里确有此库。
set -euo pipefail

name="libfushi_web_core.dylib"
source="${PROJECT_DIR}/../../native/fushi_web_core/prebuilt/macos/${name}"
destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
destination="${destination_dir}/${name}"

if [[ ! -f "$source" ]]; then
  # 上一次构建拷进去的旧库不能留着冒充本次产物。
  rm -f "$destination"
  case "${CONFIGURATION:-}" in
    Release*|Profile*)
      echo "error: ${source} not found; fushi_web_core is a required native library. Run native/fushi_web_core/build_macos_dylib.sh first." >&2
      exit 1
      ;;
  esac
  echo "warning: ${source} not found; fushi_web_core is not bundled in this ${CONFIGURATION:-Debug} build (web ad blocking / web comic ad-page detection will fail at runtime)"
  exit 0
fi

# 库在、但缺本次要出的架构（macOS 版只出 arm64）：带进去也加载失败，比「没带」更难查。
available_archs=" $(lipo -archs "$source") "
for arch in ${ARCHS:-$(uname -m)}; do
  case "$available_archs" in
    *" $arch "*) ;;
    *)
      echo "error: ${source} lacks ${arch} (has:${available_archs}); rebuild with native/fushi_web_core/build_macos_dylib.sh" >&2
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

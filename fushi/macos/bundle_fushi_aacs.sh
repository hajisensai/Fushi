#!/usr/bin/env bash
# Xcode 构建阶段「Bundle fushi_aacs dylib」：蓝光原盘菜单用的 libaacs ABI 模块。
#
# 随包 libmpv 里的 libbluray 打开带 AACS 的盘时按 dlopen("@rpath/libaacs.dylib")
# 等路径找 libaacs（libbluray-1.5.0 src/file/dl_posix.c），读菜单 / IG / 标题码流全
# 靠它解密；找不到就整盘打不开（2026-10-09 用户报的「进入原盘菜单纯黑」）。
# 源码在 native/fushi_aacs（纯 C、无依赖），这里每次从源码编，不依赖预编译产物，
# 编不出来就让构建失败——缺了它加密原盘的菜单必然打不开，不能静默发出缺库的包。
set -euo pipefail

source_dir="${PROJECT_DIR}/../../native/fushi_aacs"
build_dir="${TARGET_TEMP_DIR}/fushi_aacs"
name="libaacs.dylib"

cmake_archs="${ARCHS:-$(uname -m)}"
cmake_archs="${cmake_archs// /;}"

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$cmake_archs" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.4}"
cmake --build "$build_dir" --target fushi_aacs --config Release

built="$(find "$build_dir" -type f -name "$name" | head -n 1)"
if [[ -z "$built" ]]; then
  echo "error: $name was not produced under $build_dir" >&2
  exit 1
fi

destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
destination="${destination_dir}/${name}"
mkdir -p "$destination_dir"
cp -f "$built" "$destination"
install_name_tool -id "@rpath/${name}" "$destination"

if [[ "${CODE_SIGNING_ALLOWED:-}" != "NO" ]] && command -v codesign >/dev/null 2>&1; then
  sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="-"
  fi
  codesign --force --sign "$sign_identity" --timestamp=none "$destination"
fi

#!/usr/bin/env bash
# Xcode 构建阶段「Bundle fushi_torrent dylib」：内置 torrent 引擎（libtorrent bridge）的
# 原生库 copy-if-present。
#
# native/fushi_torrent/build_macos_dylib.sh 产出 prebuilt/macos/libfushi_torrent_ffi.dylib
# 则拷进 Contents/Frameworks（Dart 侧 EmbeddedTorrentEngine 在 macOS 先按
# <exe>/../Frameworks/ 绝对路径加载）；缺失时内置引擎判不可用、回退外接 qBittorrent，
# 其余照常——与 Windows CMake / Android jniLibs / Linux bundle/lib 同一语义，没装 vcpkg
# 的 Mac 也能构建。发布流水线（release-desktop.yml / build-multiplatform.yml）先跑构建
# 脚本，再在出包后核对 Frameworks 里确有此库，所以「CI 忘了编」不会静默发出缺库的包。
set -euo pipefail

name="libfushi_torrent_ffi.dylib"
source="${PROJECT_DIR}/../../native/fushi_torrent/prebuilt/macos/${name}"
destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
destination="${destination_dir}/${name}"

if [[ ! -f "$source" ]]; then
  # 上一次构建拷进去的旧库不能留着冒充本次产物。
  rm -f "$destination"
  echo "note: ${source} not found; fushi_torrent is not bundled (embedded torrent engine unavailable in this build)"
  exit 0
fi

# 库在、但缺本次要出的架构：universal 包在另一种 Mac 上会加载失败，比「没带」更难查。
available_archs=" $(lipo -archs "$source") "
for arch in ${ARCHS:-$(uname -m)}; do
  case "$available_archs" in
    *" $arch "*) ;;
    *)
      echo "error: ${source} lacks ${arch} (has:${available_archs}); rebuild with native/fushi_torrent/build_macos_dylib.sh" >&2
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

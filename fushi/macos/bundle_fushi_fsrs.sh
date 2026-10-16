#!/usr/bin/env bash
# Xcode 构建阶段「Bundle fushi_fsrs dylib」：SRS 排程内核（fsrs-rs）的原生库 copy-if-present。
#
# native/fushi_fsrs/build_macos_dylib.sh 产出 prebuilt/macos/libfushi_fsrs.dylib 则拷进
# Contents/Frameworks（Runner 的 LD_RUNPATH_SEARCH_PATHS 含 @executable_path/../Frameworks，
# Dart 侧 packages/fushi_srs 按裸名经这个 rpath 加载）；缺失时 SRS 原生内核判不可用、其余照常——
# 与 Windows CMake / Android jniLibs 同一语义，没装 Rust 的 Mac 也能构建。
# 发布流水线（release-desktop.yml / build-multiplatform.yml）先跑构建脚本，再在出包后
# 核对 Frameworks 里确有此库，所以「CI 忘了编」不会静默发出缺库的包。
set -euo pipefail

name="libfushi_fsrs.dylib"
source="${PROJECT_DIR}/../../native/fushi_fsrs/prebuilt/macos/${name}"
destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
destination="${destination_dir}/${name}"

if [[ ! -f "$source" ]]; then
  # 上一次构建拷进去的旧库不能留着冒充本次产物。
  rm -f "$destination"
  echo "note: ${source} not found; fushi_fsrs is not bundled (SRS native kernel unavailable in this build)"
  exit 0
fi

# 库在、但缺本次要出的架构（macOS 版只出 arm64）：带进去也加载失败，比「没带」更难查。
available_archs=" $(lipo -archs "$source") "
for arch in ${ARCHS:-$(uname -m)}; do
  case "$available_archs" in
    *" $arch "*) ;;
    *)
      echo "error: ${source} lacks ${arch} (has:${available_archs}); rebuild with native/fushi_fsrs/build_macos_dylib.sh" >&2
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

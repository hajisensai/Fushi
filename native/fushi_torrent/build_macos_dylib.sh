#!/usr/bin/env bash
# macOS 版内置 torrent 引擎 bridge：vcpkg manifest 静态链 libtorrent 2.0.11 + boost +
# openssl 进单个 libfushi_torrent_ffi.dylib（universal：arm64 + x86_64），给 app bundle 的
# Contents/Frameworks 用（fushi/macos/bundle_fushi_torrent.sh 在 Xcode 构建阶段拷进去）。
#
# 在此之前 macOS 从没编过这个库：app 侧早把 macOS 算作支持内置引擎的平台，加载失败后
# 内置引擎判不可用，用户只能退到外接 qBittorrent。
#
# 与 build_linux_so.sh / build_android_so.sh 同一套流程/决策：版本由 vcpkg.json 钉死，
# overlay ports 带 DHT 混合代理等补丁，overlay triplet（arm64-osx-fushi / x64-osx-fushi）
# 保证依赖全静态、部署目标与 Runner 的 MACOSX_DEPLOYMENT_TARGET（13.4）对齐。
#
# 用法: build_macos_dylib.sh <vcpkg-root> [arch ...]
#   arch 取 arm64 / x86_64，缺省两者都编并 lipo（发布包是 universal）
#   产物: prebuilt/macos/libfushi_torrent_ffi.dylib（git 忽略；install name = @rpath/…）
#   环境: VCPKG_DOWNLOADS 可选（CI 用它把 distfile 落到可缓存目录）
set -euo pipefail

VCPKG_ROOT="${1:?usage: build_macos_dylib.sh <vcpkg-root> [arch ...]}"
shift
if [[ $# -gt 0 ]]; then ARCHS=("$@"); else ARCHS=(arm64 x86_64); fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VCPKG_TOOLCHAIN="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
[[ -f "$VCPKG_TOOLCHAIN" ]] || { echo "vcpkg toolchain missing: $VCPKG_TOOLCHAIN" >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.4}"

# vcpkg.json 的 builtin-baseline 只从 vcpkg 仓库本地 .git 读；baseline 必须是本地
# HEAD 的祖先（versions/ 只增不删）。同款检查见 build_linux_so.sh / vcpkg_baseline.ps1。
baseline="$(sed -n 's/.*"builtin-baseline"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$SCRIPT_DIR/vcpkg.json")"
[[ -n "$baseline" ]] || { echo "vcpkg.json 缺少 builtin-baseline" >&2; exit 1; }
if [[ "$(git -C "$VCPKG_ROOT" cat-file -t "$baseline" 2>/dev/null)" != commit ]]; then
  echo "==> fetch vcpkg baseline $baseline"
  git -C "$VCPKG_ROOT" fetch --no-tags --quiet origin "$baseline" \
    || { echo "取不到 vcpkg baseline $baseline（$VCPKG_ROOT 无法 fetch）" >&2; exit 1; }
fi
if ! git -C "$VCPKG_ROOT" merge-base --is-ancestor "$baseline" HEAD; then
  echo "vcpkg 太旧：$VCPKG_ROOT 的 HEAD 不是 baseline $baseline 的后代。" >&2
  echo "修复：git -C \"$VCPKG_ROOT\" pull" >&2
  exit 1
fi

triplet_for_arch() {
  case "$1" in
    arm64) echo arm64-osx-fushi ;;
    x86_64) echo x64-osx-fushi ;;
    *) echo "unsupported macOS arch: $1" >&2; return 1 ;;
  esac
}

slices=()
for arch in "${ARCHS[@]}"; do
  triplet="$(triplet_for_arch "$arch")"
  build_dir="$SCRIPT_DIR/build-macos-$arch"
  echo "==> cmake configure ($triplet, MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
  # VCPKG_OVERLAY_TRIPLETS / VCPKG_OVERLAY_PORTS 必须给 cmake：manifest 模式下装依赖的
  # 是工具链而不是命令行（Android 那条静默退回 API 28 的教训）。
  # VCPKG_INSTALLED_DIR 按架构分开：两片共用一个 vcpkg_installed 时第二次 configure
  # 会把第一片的清单当成「已装」改写，增量重编时互相踩。
  cmake -B "$build_dir" -S "$SCRIPT_DIR" \
    "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_TOOLCHAIN" \
    "-DVCPKG_TARGET_TRIPLET=$triplet" \
    "-DVCPKG_OVERLAY_TRIPLETS=$SCRIPT_DIR/vcpkg-triplets" \
    "-DVCPKG_OVERLAY_PORTS=$SCRIPT_DIR/vcpkg-ports" \
    "-DVCPKG_INSTALLED_DIR=$build_dir/vcpkg_installed" \
    "-DCMAKE_OSX_ARCHITECTURES=$arch" \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" \
    "-DCMAKE_BUILD_TYPE=Release"
  cmake --build "$build_dir" --config Release
  slice="$build_dir/libfushi_torrent_ffi.dylib"
  [[ -f "$slice" ]] || { echo "missing artifact: $slice" >&2; exit 1; }
  slices+=("$slice")
done

out_dir="$SCRIPT_DIR/prebuilt/macos"
mkdir -p "$out_dir"
out="$out_dir/libfushi_torrent_ffi.dylib"
lipo -create "${slices[@]}" -output "$out"
install_name_tool -id "@rpath/libfushi_torrent_ffi.dylib" "$out"
strip -x "$out"

# 自检：静态链的意义就是「不依赖用户机上的 libtorrent/ssl/boost」。otool -L 里除了自身
# install name 只许出现系统库（/usr/lib、/System）；冒出 Homebrew / vcpkg 路径 = triplet
# 没生效（退回动态），当场红，别等用户机器上 dlopen 失败。
# universal 产物按架构各打一段「path (architecture x):」表头，依赖行才以空白开头。
if otool -L "$out" | grep -E '^[[:space:]]' | awk '{ print $1 }' \
    | grep -v -e '^@rpath/libfushi_torrent_ffi\.dylib$' -e '^/usr/lib/' -e '^/System/' | grep -q .; then
  echo "libfushi_torrent_ffi.dylib 仍依赖非系统库（静态链未生效）：" >&2
  otool -L "$out" >&2
  exit 1
fi
lipo -info "$out"
otool -L "$out"
echo "==> Done: $out ($(wc -c < "$out") bytes)"

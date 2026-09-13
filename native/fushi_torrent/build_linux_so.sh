#!/usr/bin/env bash
# Linux x64 版内置 torrent 引擎 bridge：vcpkg manifest 静态链 libtorrent 2.0.11 +
# boost + openssl 进单个 libfushi_torrent_ffi.so（无头服务端 fushi_server 随包）。
#
# 与 build_android_so.sh 同一套流程/决策：版本由 vcpkg.json 钉死，overlay ports 带
# DHT 混合代理补丁，overlay triplet（x64-linux-fpic）保证静态归档全 -fPIC。产物
# **不依赖**目标机的 libtorrent-rasterbar / libssl 运行库——此前动态链发行版包，
# 等于逼用户 `apt install libtorrent-rasterbar2.0` 或退到外接 qBittorrent。
#
# 用法: build_linux_so.sh <vcpkg-root>
#   产物: prebuilt/linux-x64/libfushi_torrent_ffi.so（strip 后）
#   环境: VCPKG_DOWNLOADS 可选（CI 用它把 distfile 落到可缓存目录）
set -euo pipefail

VCPKG_ROOT="${1:?usage: build_linux_so.sh <vcpkg-root>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIPLET=x64-linux-fpic
VCPKG_TOOLCHAIN="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
[[ -f "$VCPKG_TOOLCHAIN" ]] || { echo "vcpkg toolchain missing: $VCPKG_TOOLCHAIN" >&2; exit 1; }

# vcpkg.json 的 builtin-baseline 只从 vcpkg 仓库本地 .git 读；baseline 必须是本地
# HEAD 的祖先（versions/ 只增不删）。同款检查见 build_android_so.sh / vcpkg_baseline.ps1。
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

build_dir="$SCRIPT_DIR/build-linux-x64"
echo "==> cmake configure ($TRIPLET)"
# VCPKG_OVERLAY_TRIPLETS / VCPKG_OVERLAY_PORTS 必须给 cmake：manifest 模式下装依赖的
# 是工具链而不是命令行，只传给 `vcpkg install` 的话 overlay 不参与（Android 那条
# 静默退回 API 28 的教训，这里对应「静默退回非 -fPIC 静态库 → 链接 relocation 错」）。
cmake -G Ninja -B "$build_dir" -S "$SCRIPT_DIR" \
  "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_TOOLCHAIN" \
  "-DVCPKG_TARGET_TRIPLET=$TRIPLET" \
  "-DVCPKG_OVERLAY_TRIPLETS=$SCRIPT_DIR/vcpkg-triplets" \
  "-DVCPKG_OVERLAY_PORTS=$SCRIPT_DIR/vcpkg-ports" \
  "-DCMAKE_BUILD_TYPE=Release"
cmake --build "$build_dir"

so="$build_dir/libfushi_torrent_ffi.so"
[[ -f "$so" ]] || { echo "missing artifact: $so" >&2; exit 1; }

out_dir="$SCRIPT_DIR/prebuilt/linux-x64"
mkdir -p "$out_dir"
cp -f "$so" "$out_dir/libfushi_torrent_ffi.so"
strip --strip-unneeded "$out_dir/libfushi_torrent_ffi.so"

# 自检：静态链的意义就是「不依赖目标机的 libtorrent/ssl 运行库」；ldd 里冒出它们
# 任何一个 = triplet 没生效（退回动态），当场红，别等用户机器上 dlopen 失败。
if ldd "$out_dir/libfushi_torrent_ffi.so" | grep -Eq 'torrent-rasterbar|libssl|libcrypto|libboost'; then
  echo "libfushi_torrent_ffi.so 仍动态依赖 libtorrent/ssl/boost（静态链未生效）：" >&2
  ldd "$out_dir/libfushi_torrent_ffi.so" >&2
  exit 1
fi
ls -lh "$out_dir/libfushi_torrent_ffi.so"
ldd "$out_dir/libfushi_torrent_ffi.so"

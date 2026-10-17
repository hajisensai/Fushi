#!/usr/bin/env bash
# Linux x64 版词典引擎 libfushidicts_ffi.so：无头服务端 fushi_server 随包（bundle/lib/），
# 服务端按 `<exe>/../lib/libfushidicts_ffi.so` 定位（packages/fushi_server/lib/src/
# dictionary_host.dart 的 resolveFushiDictsLibraryPath → native_libs.dart）。
#
# 与 native/fushi_torrent/build_linux_so.sh 同一决策：产物只动态依赖 glibc。
#   * -static-libstdc++ -static-libgcc：fushidicts 要 C++23（std::expected / glaze），
#     构建机的 libstdc++ 往往比目标机（老发行版 / NAS）新，动态链等于把目标机的
#     GLIBCXX 版本要求抬到构建机的水平。
#   * -Wl,--exclude-libs,ALL：静态链进来的 fushidicts / zstd / libdeflate / utf8proc /
#     libstdc++ 符号不导出，只留 fushidicts_ffi.cpp 里 FUSHI_EXPORT 的 C ABI。
# 编译器取环境变量 CC / CXX（CI 用 gcc-14 / g++-14）；CMakeLists 的 configure 期会先
# 探一次 std::expected，工具链不够新时直接报错指向编译器。
#
# 用法: build_linux_so.sh [build-dir]
#   产物: prebuilt/linux-x64/libfushidicts_ffi.so（strip 后）
#   build-dir 默认 $RUNNER_TEMP/fushidicts-linux-x64（CI）或脚本旁 build-linux-x64。
#   要短路径：vendored zstd/glaze 的嵌套 object 目录在深 checkout 路径下会很长。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_build_dir="$SCRIPT_DIR/build-linux-x64"
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  default_build_dir="$RUNNER_TEMP/fushidicts-linux-x64"
fi
build_dir="${1:-$default_build_dir}"

echo "==> compiler: ${CXX:-<cmake default>}"
"${CXX:-c++}" --version | head -n 1

echo "==> cmake configure (Release, static libstdc++)"
cmake -G Ninja -S "$SCRIPT_DIR" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_SHARED_LINKER_FLAGS=-static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL"
cmake --build "$build_dir" --target fushidicts_ffi

so="$build_dir/libfushidicts_ffi.so"
[[ -f "$so" ]] || { echo "missing artifact: $so" >&2; exit 1; }

out_dir="$SCRIPT_DIR/prebuilt/linux-x64"
mkdir -p "$out_dir"
out="$out_dir/libfushidicts_ffi.so"
cp -f "$so" "$out"
strip --strip-unneeded "$out"

# 自检 1：静态链真生效——ldd 里不得出现 libstdc++ / libgcc_s。先落文件再 grep，
# 不走管道（pipefail 下 grep -q 提前退出会让写端吃 SIGPIPE，BUG-2804 同族）。
ldd_out="$(mktemp)"
trap 'rm -f "$ldd_out" "${syms_out:-}"' EXIT
ldd "$out" > "$ldd_out"
if grep -Eq 'libstdc\+\+|libgcc_s' "$ldd_out"; then
  echo "libfushidicts_ffi.so 仍动态依赖 libstdc++/libgcc_s（静态链未生效）：" >&2
  cat "$ldd_out" >&2
  exit 1
fi

# 自检 2：Dart 绑定（packages/fushi_dictionary/lib/src/ffi/fushidicts_ffi_bindings.dart）
# 第一批就要的入口必须导出；--exclude-libs 误伤 FFI 自己的符号时在这里红。
syms_out="$(mktemp)"
nm -D --defined-only "$out" > "$syms_out"
for sym in fushidicts_create fushidicts_destroy; do
  if ! grep -Eq "[[:space:]]T[[:space:]]+${sym}\$" "$syms_out"; then
    echo "libfushidicts_ffi.so 未导出 $sym" >&2
    exit 1
  fi
done
# 不该导出的：静态链进来的 libstdc++ / zstd 符号（导出了说明 --exclude-libs 没生效，
# 会与目标进程里别的 libstdc++ / zstd 抢符号）。
if grep -Eq '[[:space:]]T[[:space:]]+(ZSTD_|_ZNSt)' "$syms_out"; then
  echo "libfushidicts_ffi.so 导出了静态依赖的符号（--exclude-libs 未生效）：" >&2
  grep -E '[[:space:]]T[[:space:]]+(ZSTD_|_ZNSt)' "$syms_out" | head -n 20 >&2
  exit 1
fi

ls -lh "$out"
cat "$ldd_out"
# glibc 下限：产物要求的最高 GLIBC_x.y 符号版本（= 目标机 glibc 的最低要求）。
objdump -T "$out" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n 1 | sed 's/^/required glibc: /'

#!/usr/bin/env bash
# BUG-3284：内置 libtorrent 的 Android .so 必须**自带** C++ 运行时（c++_static），
# 动态依赖只许是系统库（libc / libm / libdl），未定义符号只许由 bionic 提供。
#
# 为什么要单独一道门：APK 里只能有一份 libc++_shared.so，Gradle 按 pickFirst 从各
# 插件 AAR 里随便挑一份（实测是 NDK r27-beta1 的）。本库若按 c++_shared 链接，就要求
# 那份 libc++ 至少和编本库的 NDK 一样新——而 CI 用 runner 的最新 NDK（r30 起
# std::hash 移出头文件，引用 std::__ndk1::__hash_memory）。老 libc++_shared 里没有
# 这个符号 → 设备上 dlopen 失败 → 能力探测判「缺少内置引擎运行库」。.so 明明在包里，
# 现有的「文件在 / ht_* 导出齐」两道校验全绿，只有真机运行时才暴露。
#
# 用法: verify_android_cxx_self_contained.sh <so-path> <llvm-readelf> <llvm-nm>
set -euo pipefail

SO="${1:?usage: verify_android_cxx_self_contained.sh <so-path> <readelf> <nm>}"
READELF="${2:?usage: verify_android_cxx_self_contained.sh <so-path> <readelf> <nm>}"
NM="${3:?usage: verify_android_cxx_self_contained.sh <so-path> <readelf> <nm>}"

[[ -f "$SO" ]] || { echo "::error::artifact not found: $SO" >&2; exit 1; }

needed="$("$READELF" -d "$SO" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' | sort -u)"
echo "NEEDED: $(echo "$needed" | tr '\n' ' ')"
unexpected_needed="$(echo "$needed" | grep -vxE 'libc\.so|libm\.so|libdl\.so' || true)"
if [[ -n "$unexpected_needed" ]]; then
  echo "::error title=torrent .so depends on non-system library::期望只依赖 libc/libm/libdl（C++ 运行时须静态链入，ANDROID_STL=c++_static），实际还依赖：" >&2
  echo "$unexpected_needed" | sed 's/^/  - /' >&2
  exit 1
fi

# 强未定义符号（U）必须全部带 bionic 版本标签（@LIBC / @LIBC_N …）。没有版本标签
# 的强未定义符号要靠别的 .so 提供——那正是 libc++_shared 漂移这类故障的入口。
# 弱未定义（w，例如 getentropy）运行时缺失只是 null，不阻止 dlopen。
unversioned="$("$NM" -D --undefined-only "$SO" | awk '$1 == "U" { print $2 }' | grep -v '@LIBC' || true)"
if [[ -n "$unversioned" ]]; then
  echo "::error title=torrent .so has unresolved non-libc symbols::以下强未定义符号不由 bionic 提供（多半是 libc++ 没有静态链入）：" >&2
  echo "$unversioned" | head -40 | sed 's/^/  - /' >&2
  exit 1
fi
echo "C++ runtime self-contained: OK"

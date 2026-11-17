#!/usr/bin/env bash
# Linux 无头服务端包的 glibc 基线门（BUG-4843）。
#
#   check_glibc_baseline.sh <bundle-dir> [readme]
#
# 对 <bundle-dir> 下每个 ELF（跳过符号链接）跑 `objdump -T`，取它要求的最大 GLIBC_x.y
# 符号版本；任何一个超过 GLIBC_BASELINE 就判红。bundle 里除 glibc 外全是静态链 / 随包的，
# 所以「构建机的 glibc 有多新，产物就要求多新」——ubuntu-latest 换到 26.04（glibc 2.43）
# 后 libfushi_compute.so 要 GLIBC_2.43，Debian 13（2.41）上 serve 直接起不来，而 README
# 写的是 ≥ 2.35。这一步把「README 声明的基线」与「产物实际要求」钉在一起：
#   * GLIBC_BASELINE 是唯一数字；README（默认 packages/fushi_server/README.md）里必须有
#     `glibc ≥ <GLIBC_BASELINE>` 这句，对不上也判红，改基线只能两处一起改。
#   * 守卫 fushi/test/build/linux_server_glibc_baseline_guard_test.dart 静态核对调用方与
#     runner 镜像（runner 的 glibc 不得高于本基线）。
set -euo pipefail

GLIBC_BASELINE=2.35

root="${1:?usage: check_glibc_baseline.sh <bundle-dir> [readme]}"
readme="${2:-packages/fushi_server/README.md}"

if ! grep -qF "glibc ≥ ${GLIBC_BASELINE}" "$readme"; then
  echo "::error title=glibc baseline::$readme 没有写 'glibc ≥ ${GLIBC_BASELINE}'：README 声明与本守卫的基线不一致"
  exit 1
fi

# 版本 a 是否严格大于 b（sort -V 比较）。
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
find "$root" -type f -print0 > "$tmp/files"

checked=0
bad=0
while IFS= read -r -d '' f; do
  magic="$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c46" ] || continue
  checked=$((checked + 1))
  if ! objdump -T "$f" > "$tmp/syms" 2> "$tmp/err"; then
    # 纯静态可执行文件没有动态符号表，不依赖目标机 glibc；其它 objdump 失败一律判红。
    if grep -q 'not a dynamic object' "$tmp/err"; then
      echo "static   ${f#"$root"/}"
      continue
    fi
    echo "::error title=glibc baseline::objdump -T $f 失败"
    cat "$tmp/err"
    exit 1
  fi
  { grep -o 'GLIBC_[0-9][0-9.]*' "$tmp/syms" || true; } | sed 's/^GLIBC_//' | sort -V -u > "$tmp/versions"
  max="$(tail -n 1 "$tmp/versions")"
  if [ -z "$max" ]; then
    echo "none     ${f#"$root"/}"
    continue
  fi
  printf '%-8s %s\n' "$max" "${f#"$root"/}"
  if version_gt "$max" "$GLIBC_BASELINE"; then
    bad=$((bad + 1))
    echo "::error title=glibc baseline::${f#"$root"/} 需要 GLIBC_${max}，超过 README 声明的 glibc ≥ ${GLIBC_BASELINE}；超出基线的符号："
    while IFS= read -r v; do
      if version_gt "$v" "$GLIBC_BASELINE"; then
        grep -F "GLIBC_${v} " "$tmp/syms" || grep -F "GLIBC_${v})" "$tmp/syms" || true
      fi
    done < "$tmp/versions"
  fi
done < "$tmp/files"

if [ "$checked" -eq 0 ]; then
  echo "::error title=glibc baseline::$root 下没有任何 ELF：路径错了就等于没检查"
  exit 1
fi
if [ "$bad" -ne 0 ]; then
  echo "::error title=glibc baseline::$bad 个 ELF 超过 glibc ${GLIBC_BASELINE} 基线（共查 $checked 个）"
  exit 1
fi
echo "glibc baseline ok: $checked 个 ELF 都不超过 GLIBC_${GLIBC_BASELINE}"

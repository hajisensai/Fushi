#!/usr/bin/env bash
# 预编译原生库的源码内容键：native/<crate> 在 HEAD 的 git 树哈希；crate 有
# native/<crate>/external_sources.txt（经 `#[path = ...]` 编入的 crate 外源码）时，
# 把这些文件在 HEAD 的 blob 一起并成一个 git 对象 id（`git hash-object`，仍是 40 位
# 十六进制，worker_cache.sh 的 check_key 照样认）。
#
#   bash tool/native_source_key.sh <crate>     # cwd = 仓库根
#
# 与 tool/native_libs.ps1 的 Get-NativeSourceTree 同一算法（那边手算 git blob 的
# SHA-1），dist worker（fushi/tool/dist_test/worker_prepare.sh、worker_build.sh）
# 调这里。没有这一步时 legacy_text.rs（住在 native/fushi_compute/）改了，
# fushi_music 的库键不变、不会重编（BUG-4906）。
set -euo pipefail

crate="${1:?usage: native_source_key.sh <crate>}"
tree="$(git rev-parse "HEAD:native/$crate")"
list="native/$crate/external_sources.txt"
if ! git cat-file -e "HEAD:$list" 2>/dev/null; then
  printf '%s\n' "$tree"
  exit 0
fi

identity="tree $tree"
while IFS= read -r src; do
  src="$(printf '%s' "$src" | tr -d '\r')"
  case "$src" in '' | '#'*) continue ;; esac
  blob="$(git rev-parse "HEAD:$src")"
  identity="$identity
$src $blob"
done < <(git show "HEAD:$list")
printf '%s\n' "$identity" | git hash-object --stdin

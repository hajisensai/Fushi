#!/usr/bin/env bash
# 产物校验：fushi_fsrs 原生库（或静态链进它的 iOS 伞形库 / Runner 主二进制）里有没有测试专用的原始 SQL 通道
# （cargo feature `raw_sql`，见 Cargo.toml；src/store/mod.rs `exec_raw` / `exec_batch_raw`）。
#
#   absent：发布 / 随包产物——verify_abi.sh 末尾调。原始通道在写连接上执行任意语句，只给测试造场景用；带进发布包
#           等于 app 里留着一条绕过全部内核命令的写库入口。
#   present：测试用的库（CI 包测试、单测分片的库）——不带的话几十个测试文件成片红在「raw SQL channel is not
#           built into this library」，这里先给出明确原因。
#
# 判据是只在 `exec_raw` 里出现的报错文本：不带 feature 的构建里那段代码整个不编，文本随之不在；带的构建里 C 入口
# `ffsrs_store_exec` 调到它，LTO / strip 都去不掉（strip 只去符号，不去只读数据）。
#
# 用法: verify_raw_sql.sh <二进制> absent|present
set -euo pipefail

BIN="${1:?usage: verify_raw_sql.sh <binary> absent|present}"
WANT="${2:?usage: verify_raw_sql.sh <binary> absent|present}"
MARKER='raw exec must not leave a transaction open'

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }

if LC_ALL=C grep -a -q -F "$MARKER" "$BIN"; then have=present; else have=absent; fi

case "$WANT" in
  absent | present) ;;
  *) echo "::error::verify_raw_sql.sh: expected absent|present, got $WANT" >&2; exit 2 ;;
esac

if [[ "$have" != "$WANT" ]]; then
  if [[ "$WANT" == absent ]]; then
    echo "::error title=raw SQL channel in a release artifact::$BIN 带着测试专用的原始 SQL 通道（cargo feature raw_sql）。发布 / 随包构建不能设 FUSHI_FSRS_FEATURES=raw_sql。" >&2
  else
    echo "::error title=raw SQL channel missing from a test library::$BIN 没有原始 SQL 通道：测试用的库要带 cargo feature raw_sql（FUSHI_FSRS_FEATURES=raw_sql）。" >&2
  fi
  exit 1
fi
echo "OK: raw SQL channel $WANT in $BIN"

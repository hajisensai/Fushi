#!/usr/bin/env bash
# 产物校验：fushi_fsrs 原生库（或静态链进它的 iOS 伞形库 / Runner 主二进制）带不带 ID 审计。
#
# ID 审计（cargo feature `id_audit`，src/store/ids.rs `audit`）只给测试与本机调试构建用：每条语句多一次扩展 SQL
# 扫描，每次写入后还扫一遍所有 ID 列。随包发布的库不许带。判据是审计分支的报错前缀 "id audit: "
# （`audit::take`，只在 `id_audit` 构建里编进去）在不在二进制里。
#
# 用法: verify_id_audit.sh <binary> absent|present
#   absent  发布产物：带审计就失败（verify_abi.sh 对每个发布产物调这一条）。
#   present 审计库（prebuilt/<平台>/id_audit/）：不带就失败。
set -euo pipefail

BIN="${1:?usage: verify_id_audit.sh <binary> absent|present}"
WANT="${2:?usage: verify_id_audit.sh <binary> absent|present}"
[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }

if LC_ALL=C grep -q -a -F 'id audit: ' "$BIN"; then have=present; else have=absent; fi
case "$WANT" in
  absent|present) ;;
  *) echo "usage: verify_id_audit.sh <binary> absent|present" >&2; exit 2 ;;
esac
if [[ "$have" != "$WANT" ]]; then
  if [[ "$WANT" == absent ]]; then
    echo "::error title=fushi_fsrs built with id_audit::$BIN 带 ID 审计（cargo feature id_audit）：这是测试 / 本机调试用的构建，不能进发布产物。" >&2
  else
    echo "::error title=fushi_fsrs built without id_audit::$BIN 不带 ID 审计：id_audit 目录里的库必须用 --features id_audit 编。" >&2
  fi
  exit 1
fi
echo "OK: id audit $have in $BIN"

#!/usr/bin/env bash
# PR 巡检：open PR 清单 + 已合并 PR 源分支的「合并后未合 commit」检测。
#
# 纪律（用户 2026-07-11 定）：**只有作者 = 本人（默认 hajisensai）的 PR 走自动
# todo + 门禁合并**；外部作者的 PR 一律不自动处理——本脚本只单列出来供用户知晓，
# 不建 todo、不合并，等用户明示才动。
#
# 用法：bash tool/pr_sweep.sh
# 环境变量：PR_SWEEP_REPO（默认 hajisensai/hibiki）/ PR_SWEEP_BASE（默认 develop）
#           PR_SWEEP_SELF（默认 hajisensai）/ PR_SWEEP_LIMIT（默认 40）
# 输出供值班 PM 与看板对照：「自动处理」区每行都应有对应 todo（按 PR 号/分支名
# grep 看板），没有就建；「外部 PR」区只读不动。
set -uo pipefail
REPO="${PR_SWEEP_REPO:-hajisensai/hibiki}"
BASE="${PR_SWEEP_BASE:-develop}"
SELF="${PR_SWEEP_SELF:-hajisensai}"
LIMIT="${PR_SWEEP_LIMIT:-40}"
# fake-ip DNS 下 gh 直连必超时——与 tool/board 同款默认自动挂本机代理。
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:34151}"
export HTTP_PROXY="${HTTP_PROXY:-${HTTPS_PROXY}}"
export PYTHONUTF8=1   # Windows GBK 控制台下内嵌 python 打中文不乱码

open_json=$(gh pr list --repo "$REPO" --state open \
  --json number,title,headRefName,author,updatedAt 2>/dev/null) || {
  echo "（gh 拉取失败——先核代理/网络，别当成没有 PR）"; exit 3; }

echo "=== OPEN PR·自动处理（作者=$SELF：无对应看板 todo 就建 → 审查→复测→integration owner 合并→关 PR）==="
echo "$open_json" | python -c "
import json,sys
rows=json.load(sys.stdin)
mine=[r for r in rows if r['author']['login']=='$SELF']
ext=[r for r in rows if r['author']['login']!='$SELF']
for r in mine: print(f\"#{r['number']} {r['title']} | head={r['headRefName']} | updated={r['updatedAt']}\")
if not mine: print('（无）')
print()
print('=== OPEN PR·外部作者（不自动处理·不建 todo·不合并——仅列出等用户明示）===')
for r in ext: print(f\"#{r['number']} [{r['author']['login']}] {r['title']} | head={r['headRefName']} | updated={r['updatedAt']}\")
if not ext: print('（无）')
"

echo ""
echo "=== 已合并 PR 的合并后更新（作者=$SELF：源分支有 commit 不在 $BASE → 建「再合并」todo）==="
found=0
while IFS=$'\t' read -r num author owner repo branch oid; do
  [ "$author" = "$SELF" ] || continue                   # 外部作者的合并后更新也不自动处理
  cur=$(gh api "repos/$owner/$repo/branches/$branch" --jq .commit.sha 2>/dev/null) || continue  # 分支已删=无更新
  case "$cur" in *[!0-9a-f]*|"") continue;; esac        # 非 40 位 sha（404 JSON 等）跳过
  [ "$cur" = "$oid" ] && continue                       # 合并后分支没动过
  ahead=$(gh api "repos/$REPO/compare/$BASE...$owner:$branch" --jq .ahead_by 2>/dev/null) || ahead=""
  case "$ahead" in ""|*[!0-9]*) ahead="?";; esac
  [ "$ahead" = "0" ] && continue                        # 新 commit 已在 $BASE（被直接合过）
  echo "#$num $owner:$branch 有 $ahead 个 commit 不在 $BASE（merge 时 ${oid:0:9} → 现 ${cur:0:9}）——核实后再合并或废弃分支"
  found=1
done < <(gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
  --json number,author,headRefName,headRefOid,headRepository,headRepositoryOwner \
  --jq '.[] | [.number, .author.login, .headRepositoryOwner.login, .headRepository.name, .headRefName, .headRefOid] | @tsv')
[ "$found" = "0" ] && echo "（无合并后更新）"
exit 0

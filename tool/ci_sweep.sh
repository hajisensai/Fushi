#!/usr/bin/env bash
# CI 巡检：GitHub Actions 失败 run 检测 + （--file）自动落板成 todo。
#
# 纪律（与 tool/pr_sweep.sh 同款，用户 2026-07-11 定）：**只有触发者 = 本人
# （默认 hajisensai）的失败 run 走自动落板**；外部触发的只单列供用户知晓，
# 不建 todo，等用户明示才动。
#
# 用法：bash tool/ci_sweep.sh          # 只读巡检（人读输出）
#       bash tool/ci_sweep.sh --file   # 巡检 + 把「自动落板」项落 vibe-coxswain 看板
#                                      # （面板任务定时跑，不依赖 LLM 即可发现+落板；
#                                      #   判真红/修复等判断类工作留给值班会话）
# --file 的 DB **锚定脚本所在仓库根**（$0/../.vibe-coxswain/board.db 的绝对路径，
# VIBE_COXSWAIN_DB 显式设置时才让位），并要求 DB 已存在——绝不静默新建空库落板。
# 环境变量：CI_SWEEP_REPO（默认 hajisensai/hibiki）/ CI_SWEEP_SELF（默认 hajisensai）
#           CI_SWEEP_DAYS（默认 3，只看窗口内的失败）/ CI_SWEEP_LIMIT（默认 50）
# 去重键 = 「workflow@branch」（标题前缀 token）：同一 workflow 在同一分支反复红，
# 活跃 todo 在板上就不重复落；修好关单后再红 = 新落一条（回归，应有新单）。
set -uo pipefail

FILE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --file) FILE_MODE=1 ;;
    *) echo "未知参数：$arg（仅支持 --file）" >&2; exit 2 ;;
  esac
done

REPO="${CI_SWEEP_REPO:-hajisensai/hibiki}"
SELF="${CI_SWEEP_SELF:-hajisensai}"
DAYS="${CI_SWEEP_DAYS:-3}"
LIMIT="${CI_SWEEP_LIMIT:-50}"
# fake-ip DNS 下 gh 直连必超时——需要代理。解析顺序见 tool/proxy_env.sh：
# 调用方环境变量 > FUSHI_BOOTSTRAP_PROXY > tool/bootstrap.local.env > 不设（照常跑）。
source "$(dirname "${BASH_SOURCE[0]}")/proxy_env.sh"
export PYTHONUTF8=1   # Windows GBK 控制台下内嵌 python 打中文不乱码

# 自动落板项收集成 TSV（runid\tconclusion\tworkflow\tbranch\tsha9\turl\ttitle）；
# 人读输出照旧打印；--file 模式末尾一次性喂给内嵌 python 去重+落板。
AUTO_TSV="$(mktemp)"
trap 'rm -f "$AUTO_TSV"' EXIT

runs_json=$(gh api "repos/$REPO/actions/runs?status=completed&per_page=$LIMIT" 2>/dev/null) || {
  echo "（gh 拉取失败——先核代理/网络，别当成没有失败 run）"; exit 3; }

echo "$runs_json" | python -c '
import datetime
import json
import sys

self_login, days, tsv_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = json.load(sys.stdin)
cutoff = (datetime.datetime.now(datetime.timezone.utc)
          - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
# 真红口径：failure / timed_out / startup_failure；cancelled/skipped 通常是并发挤占
# 或人为取消，不算。窗口外的老失败不翻旧账（修没修早有定论）。
BAD = {"failure", "timed_out", "startup_failure"}
bad = [r for r in data.get("workflow_runs", [])
       if r.get("conclusion") in BAD and (r.get("created_at") or "") >= cutoff]


def clean(s: object) -> str:
    return " ".join(str(s or "").split())  # 压掉 tab/换行，保 TSV 一行一项


# 事件过滤：只有 push / schedule / workflow_dispatch 的失败单独落板——
# pull_request 分支的红由对应 PR todo 的门禁（CI 绿才能合并）覆盖，单独建号是重复噪音。
FILE_EVENTS = {"push", "schedule", "workflow_dispatch"}
mine: dict = {}   # (workflow, branch) -> 最新 run（列表本身按新→旧，取首个即最新）
pr_reds: list = []
ext: list = []
for r in bad:
    actor = ((r.get("actor") or {}).get("login")) or "?"
    if actor != self_login:
        ext.append(r)
        continue
    if (r.get("event") or "") not in FILE_EVENTS:
        pr_reds.append(r)
        continue
    key = (clean(r.get("name")), clean(r.get("head_branch")))
    if key not in mine:
        mine[key] = r

print("=== CI 失败·自动落板（触发者=%s，事件=push/schedule/dispatch，近 %d 天，同 workflow@branch 取最新）===" % (self_login, days))
with open(tsv_path, "a", encoding="utf-8") as f:
    for (wf, br), r in mine.items():
        line = "#%s %s [%s] %s@%s | %s" % (
            r["id"], r.get("conclusion"), r.get("event"), wf, br,
            clean(r.get("display_title"))[:60])
        print(line)
        f.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
            r["id"], r.get("conclusion"), wf, br,
            str(r.get("head_sha") or "")[:9], r.get("html_url") or "",
            clean(r.get("display_title"))[:60]))
if not mine:
    print("（无）")
print()
print("=== CI 失败·PR 分支（不单独落板——由对应 PR todo 的「CI 绿」门禁覆盖）===")
for r in pr_reds:
    print("#%s %s %s@%s" % (r["id"], r.get("conclusion"), clean(r.get("name")),
                            clean(r.get("head_branch"))))
if not pr_reds:
    print("（无）")
print()
print("=== CI 失败·外部触发（不自动落板——仅列出等用户明示）===")
for r in ext:
    print("#%s %s [%s] %s@%s by %s" % (
        r["id"], r.get("conclusion"), r.get("event"), clean(r.get("name")),
        clean(r.get("head_branch")), ((r.get("actor") or {}).get("login")) or "?"))
if not ext:
    print("（无）")
' "$SELF" "$DAYS" "$AUTO_TSV"

# --file 模式：TSV 落板（与 tool/pr_sweep.sh 同一套已过审管道：绝对 DB / 前缀去重 / 失败上报）。
if [ "$FILE_MODE" = "1" ]; then
  echo ""
  echo "=== --file 落板（vibe-coxswain）==="
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  DB="${VIBE_COXSWAIN_DB:-$ROOT/.vibe-coxswain/board.db}"
  if [ ! -f "$DB" ]; then
    echo "落板中止：看板 DB 不存在：$DB（拒绝静默新建空库）" >&2
    exit 3
  fi
  if command -v vibe-coxswain >/dev/null 2>&1; then CLI_KIND="exe"; else CLI_KIND="module"; fi
  python - "$AUTO_TSV" "$CLI_KIND" "$DB" <<'PYEOF'
import datetime
import re
import subprocess
import sys

tsv_path, cli_kind, db_path = sys.argv[1], sys.argv[2], sys.argv[3]
cli = (["vibe-coxswain"] if cli_kind == "exe"
       else [sys.executable, "-m", "vibe_coxswain"]) + ["--db", db_path]


def run_cli(args: list) -> "subprocess.CompletedProcess":
    return subprocess.run(cli + list(args), capture_output=True,
                          text=True, encoding="utf-8", errors="replace")


rows: list = []
with open(tsv_path, encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 7 and parts[0]:
            rows.append(parts)

if not rows:
    print("已落板 0 条；已存在跳过 0 条（本轮无自动落板项）")
    sys.exit(0)

lp = run_cli(["list"])
if lp.returncode != 0:
    sys.stderr.write("vibe-coxswain list 失败（rc=%s）：%s\n"
                     % (lp.returncode, (lp.stderr or lp.stdout).strip()))
    print("落板中止：看板 CLI 不可用——上面的只读巡检输出仍有效，下轮面板任务重试")
    sys.exit(3)
listing = lp.stdout


def tracked(workflow: str, branch: str) -> bool:
    """该 workflow@branch 是否已有活跃 todo：token 必须出现在标题开头。"""
    return re.search(r"\] TODO-\d+ CI失败 %s@%s"
                     % (re.escape(workflow), re.escape(branch)), listing) is not None


today: str = datetime.date.today().isoformat()
added: list = []
skipped: int = 0
failed: int = 0
for runid, conclusion, workflow, branch, sha9, url, title in rows:
    if tracked(workflow, branch):
        skipped += 1
        continue
    todo_title = "CI失败 %s@%s：%s（%s）" % (workflow, branch, title, conclusion)
    acceptance = ("【验收】gh run view %s --log-failed 定位失败 job/step → 真红则根因修复"
                  "（新 commit 使该 workflow 在 %s 最新 run 转绿）；网络/基础设施抖动则重跑"
                  "确认（查询连不上 GitHub ≠ CI 红）→ 转绿后记 run 链接关单。"
                  "来源：ci_sweep --file 自动落板 %s。" % (runid, branch, today))
    next_val = "%s | head=%s" % (url, sha9)
    ap = run_cli(["add", todo_title, "--status", "todo"])
    m = re.search(r"TODO-(\d+)", ap.stdout or "")
    if ap.returncode != 0 or m is None:
        sys.stderr.write("add 失败 run#%s：%s\n" % (runid, (ap.stderr or ap.stdout).strip()))
        failed += 1
        continue
    todo_num = m.group(1)
    for field, value in (("acceptance", acceptance), ("next", next_val),
                         ("conflict_group", "ci-failures")):
        sp = run_cli(["set", todo_num, field, value])
        if sp.returncode != 0:
            sys.stderr.write("set %s 失败 TODO-%s：%s\n"
                             % (field, todo_num, (sp.stderr or sp.stdout).strip()))
            failed += 1
    added.append("TODO-" + todo_num)
    listing += "\n] TODO-%s CI失败 %s@%s" % (todo_num, workflow, branch)  # 同轮防重

if added:
    print("已落板 %d 条：%s；已存在跳过 %d 条" % (len(added), "、".join(added), skipped))
else:
    print("已落板 0 条；已存在跳过 %d 条" % skipped)
if failed:
    sys.stderr.write("本轮 %d 次落板写入失败——面板任务记 fail，下轮重试\n" % failed)
    sys.exit(3)
PYEOF
  rc=$?
  if [ "$rc" -ne 0 ]; then exit "$rc"; fi   # 落板失败向面板如实上报，别被 exit 0 吞掉
fi
exit 0

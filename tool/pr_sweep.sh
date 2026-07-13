#!/usr/bin/env bash
# PR 巡检：open PR 清单 + 已合并 PR 源分支的「合并后未合 commit」检测。
#
# 纪律（用户 2026-07-11 定）：**只有作者 = 本人（默认 hajisensai）的 PR 走自动
# todo + 门禁合并**；外部作者的 PR 一律不自动处理——本脚本只单列出来供用户知晓，
# 不建 todo、不合并，等用户明示才动。**--file 模式下外部作者项同样绝不落板。**
#
# 用法：bash tool/pr_sweep.sh          # 只读巡检（人读输出，行为不变）
#       bash tool/pr_sweep.sh --file   # 巡检 + 把「自动处理」项落 vibe-coxswain 看板成 todo
#                                      # （面板任务每小时跑，不依赖 LLM 即可发现+落板；
#                                      #   审查/合并等判断类工作仍留给值班会话）
# --file 的 DB **锚定脚本所在仓库根**（$0/../.vibe-coxswain/board.db 的绝对路径，
# VIBE_COXSWAIN_DB 显式设置时才让位），并要求 DB 已存在——绝不静默新建空库落板
# （错 cwd 落错库还报成功是对抗审查抓过的 major）。
# 环境变量：PR_SWEEP_REPO（默认 hajisensai/hibiki）/ PR_SWEEP_BASE（默认 develop）
#           PR_SWEEP_SELF（默认 hajisensai）/ PR_SWEEP_LIMIT（默认 40）
# 输出供值班 PM 与看板对照：「自动处理」区每行都应有对应 todo（按 PR 号/分支名
# grep 看板），没有就建（--file 已自动建）；「外部 PR」区只读不动。
set -uo pipefail

FILE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --file) FILE_MODE=1 ;;
    *) echo "未知参数：$arg（仅支持 --file）" >&2; exit 2 ;;
  esac
done

REPO="${PR_SWEEP_REPO:-hajisensai/hibiki}"
BASE="${PR_SWEEP_BASE:-develop}"
SELF="${PR_SWEEP_SELF:-hajisensai}"
LIMIT="${PR_SWEEP_LIMIT:-40}"
# 合并后分支落后 $BASE ≥ 此值 = 疑似陈旧/被后续工作取代（活的 post-merge 迭代应贴近
# $BASE；落后一大截多半 patch-id 漂移的假阳性）——todo 改指向「核实后删远端分支」而非
# 「再合并」，避免 agent 只关不删导致 sweep 每轮重报（PR#68 死循环教训）。
# 导出（非仅 shell 变量）让内嵌 python 直接读到同一真值，默认只此一处。
export PR_SWEEP_STALE_BEHIND="${PR_SWEEP_STALE_BEHIND:-20}"
# fake-ip DNS 下 gh 直连必超时——与 tool/board 同款默认自动挂本机代理。
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:34151}"
export HTTP_PROXY="${HTTP_PROXY:-${HTTPS_PROXY}}"
export PYTHONUTF8=1   # Windows GBK 控制台下内嵌 python 打中文不乱码

# 检测阶段把「自动处理」项统一收集成 TSV（kind\tnum\ttitle\tbranch\tahead\toldsha\tnewsha\tbehind），
# 人读输出照旧打印；--file 模式末尾一次性喂给内嵌 python 去重+落板。
# ⚠️ 路径归一：mktemp 给 MSYS `/tmp/...`，Git-bash 的 cp/printf 解析对，但 Windows
# 内嵌 python 对 `/tmp/...` 解析不稳定（会读到自己在别处建的空文件→落板 0 条·假成功）。
# 用 cygpath -m 转成 `C:/...` 原生路径，bash 与 Windows python 就指向同一物理文件；
# 非 Windows/无 cygpath 时保持原路径（Linux/Mac 上 mktemp 路径本就通用）。
AUTO_TSV="$(mktemp)"
AUTO_TSV="$(cygpath -m "$AUTO_TSV" 2>/dev/null || echo "$AUTO_TSV")"
trap 'rm -f "$AUTO_TSV"' EXIT

open_json=$(gh pr list --repo "$REPO" --state open \
  --json number,title,headRefName,author,updatedAt 2>/dev/null) || {
  echo "（gh 拉取失败——先核代理/网络，别当成没有 PR）"; exit 3; }

echo "=== OPEN PR·自动处理（作者=$SELF：无对应看板 todo 就建 → 审查→复测→integration owner 合并→关 PR）==="
# 注意：只有 mine（作者=SELF）写进 TSV；ext（外部作者）只打印、绝不进落板管道。
echo "$open_json" | python -c '
import json, sys
self_login, tsv_path = sys.argv[1], sys.argv[2]
rows = json.load(sys.stdin)
mine = [r for r in rows if r["author"]["login"] == self_login]
ext  = [r for r in rows if r["author"]["login"] != self_login]
def clean(s: str) -> str:
    return " ".join(str(s).split())  # 去掉标题里的 tab/换行，保 TSV 一行一项
with open(tsv_path, "a", encoding="utf-8") as f:
    for r in mine:  # 8 列（kind num title branch ahead oldsha newsha behind），open 项后四列空
        f.write("open\t%s\t%s\t%s\t\t\t\t\n"
                % (r["number"], clean(r["title"]), clean(r["headRefName"])))
for r in mine:
    print("#%s %s | head=%s | updated=%s"
          % (r["number"], r["title"], r["headRefName"], r["updatedAt"]))
if not mine:
    print("（无）")
print()
print("=== OPEN PR·外部作者（不自动处理·不建 todo·不合并——仅列出等用户明示）===")
for r in ext:
    print("#%s [%s] %s | head=%s | updated=%s"
          % (r["number"], r["author"]["login"], r["title"], r["headRefName"], r["updatedAt"]))
if not ext:
    print("（无）")
' "$SELF" "$AUTO_TSV"

echo ""
echo "=== 已合并 PR 的合并后更新（作者=$SELF：源分支有 commit 不在 $BASE → 建「再合并」todo）==="
found=0
while IFS=$'\t' read -r num author owner repo branch oid; do
  [ "$author" = "$SELF" ] || continue                   # 外部作者的合并后更新也不自动处理
  cur=$(gh api "repos/$owner/$repo/branches/$branch" --jq .commit.sha 2>/dev/null) || continue  # 分支已删=无更新
  case "$cur" in *[!0-9a-f]*|"") continue;; esac        # 非 40 位 sha（404 JSON 等）跳过
  [ "$cur" = "$oid" ] && continue                       # 合并后分支没动过
  # 一次 compare 拿 ahead+behind（behind=分支落后 $BASE 多少 commit，判陈旧/被取代关键）。
  ab=$(gh api "repos/$REPO/compare/$BASE...$owner:$branch" --jq '[.ahead_by,.behind_by]|@tsv' 2>/dev/null) || ab=""
  ahead="${ab%%$'\t'*}"; behind="${ab#*$'\t'}"
  case "$ahead" in ""|*[!0-9]*) ahead="?";; esac
  case "$behind" in ""|*[!0-9]*) behind="?";; esac
  [ "$ahead" = "0" ] && continue                        # 新 commit 已在 $BASE（被直接合过）
  echo "#$num $owner:$branch ahead $ahead / behind $behind（相对 $BASE·merge 时 ${oid:0:9} → 现 ${cur:0:9}）——核实内容是否已落地：未进则再合并，已进/被取代则删远端分支"
  printf 'merged\t%s\t\t%s\t%s\t%s\t%s\t%s\n' \
    "$num" "$owner:$branch" "$ahead" "${oid:0:9}" "${cur:0:9}" "$behind" >> "$AUTO_TSV"
  found=1
done < <(gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
  --json number,author,headRefName,headRefOid,headRepository,headRepositoryOwner \
  --jq '.[] | [.number, .author.login, .headRepositoryOwner.login, .headRepository.name, .headRefName, .headRefOid] | @tsv')
[ "$found" = "0" ] && echo "（无合并后更新）"

# --file 模式：把 TSV 里的自动处理项落 vibe-coxswain 看板（去重后 add + set 三字段）。
if [ "$FILE_MODE" = "1" ]; then
  echo ""
  echo "=== --file 落板（vibe-coxswain）==="
  # DB 锚定脚本所在仓库根的绝对路径（错 cwd 不落错库）；须已存在，绝不静默新建。
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  DB="${VIBE_COXSWAIN_DB:-$ROOT/.vibe-coxswain/board.db}"
  if [ ! -f "$DB" ]; then
    echo "落板中止：看板 DB 不存在：$DB（拒绝静默新建空库）" >&2
    exit 3
  fi
  # CLI 定位：优先 PATH 上的 vibe-coxswain，否则 python -m vibe_coxswain（editable install）
  if command -v vibe-coxswain >/dev/null 2>&1; then CLI_KIND="exe"; else CLI_KIND="module"; fi
  python - "$AUTO_TSV" "$BASE" "$CLI_KIND" "$DB" <<'PYEOF'
import datetime
import os
import re
import subprocess
import sys

tsv_path, base, cli_kind, db_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# bash 已定位好 CLI 形态；module 分支用 sys.executable 保证和本解释器同环境。
# 一律显式传绝对 --db（用户纪律：看板必用绝对 --db，错 cwd 不许落错库）。
cli = (["vibe-coxswain"] if cli_kind == "exe"
       else [sys.executable, "-m", "vibe_coxswain"]) + ["--db", db_path]


def run_cli(args: list) -> "subprocess.CompletedProcess":
    """调看板 CLI；参数列表传递（不过 shell），避免标题里引号/空格的转义地狱。"""
    return subprocess.run(cli + list(args), capture_output=True,
                          text=True, encoding="utf-8", errors="replace")


rows: list = []
with open(tsv_path, encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 8 and parts[1]:  # kind num title branch ahead oldsha newsha behind
            rows.append(parts)

if not rows:
    print("已落板 0 条；已存在跳过 0 条（本轮无自动处理项）")
    sys.exit(0)

# 去重：一次 list（全部未归档行，含 done 未归档）复用给所有项。
# 判据 = PR 号紧跟「] TODO-N 」出现在标题开头（别的 todo 正文顺带提及 "PR#42"
# 不算已跟踪，对抗审查抓过的误抑制），**且该 todo 未 done**——只被 done 单跟踪的 PR
# 会被重新落板：done 只代表「有人关了这条」，不代表 commit 真进了 develop（PR#41 假
# 完成教训：原始合并落了 v38、合并后新推的 v39 没落却被手动标 done，旧去重把 done 单
# 当已跟踪永久抑制，缺口再没被重捞）。只要检测阶段判定 commit 不在 base，就持续建 todo。
lp = run_cli(["list"])
if lp.returncode != 0:
    sys.stderr.write("vibe-coxswain list 失败（rc=%s）：%s\n"
                     % (lp.returncode, (lp.stderr or lp.stdout).strip()))
    print("落板中止：看板 CLI 不可用——上面的只读巡检输出仍有效，下轮面板任务重试")
    sys.exit(3)  # 非零退出：面板任务徽章如实变 fail，下轮调度天然重试
listing = lp.stdout
# done 号单独取（用机器码 --status done，不解析中文标签，标签改了也不误伤）。
# 取失败不致命：done_nums 为空 = 退回「done 也算跟踪」的旧保守行为，绝不误刷屏。
dlp = run_cli(["list", "--status", "done"])
done_nums = set(re.findall(r"TODO-(\d+)", dlp.stdout)) if dlp.returncode == 0 else set()

# PR#41 不得匹配 PR#410：号后接非数字守卫（空格/全角括号/半角括号/句读都放行）。
_PR_TODO_RE = r"\] TODO-(\d+) PR#%s(?![0-9])"


def tracked(num: str) -> bool:
    """该 PR 号是否已有**未 done**的 todo（done 单不抑制 → 假完成能被重捞）。"""
    for m in re.finditer(_PR_TODO_RE % re.escape(num), listing):
        if m.group(1) not in done_nums:
            return True
    return False


def prior_done(num: str) -> bool:
    """该 PR 曾有 done 单却又被检出未落地 = 那条是假完成（关了但 commit 没进 base）。"""
    return any(m.group(1) in done_nums
               for m in re.finditer(_PR_TODO_RE % re.escape(num), listing))

today: str = datetime.date.today().isoformat()
added: list = []
skipped: int = 0
failed: int = 0
try:
    stale_behind = int(os.environ.get("PR_SWEEP_STALE_BEHIND", "20"))
except ValueError:
    stale_behind = 20  # 环境变量给了非数字：退回默认，绝不因此崩落板
for kind, num, title, branch, ahead, oldsha, newsha, behind in rows:
    if tracked(num):
        skipped += 1
        continue
    if kind == "open":
        todo_title = "PR#%s 审查合并：%s" % (num, title)
        acceptance = ("【验收】审查 diff（范围/越界/回退他人）→ bug 类核复测证据 → "
                      "integration owner 合并 %s → CI 绿 → 关 PR、清远端分支。"
                      "来源：pr_sweep --file 自动落板 %s。" % (base, today))
        next_val = "分支 %s" % branch
    else:  # merged：合并后更新。behind 大 = 分支陈旧/被后续工作取代（PR#68 死循环教训）：
           # 标题与验收指向「删远端分支」而非「再合并」，避免只关不删导致每轮重报。
        stale = behind.isdigit() and int(behind) >= stale_behind
        if stale:
            todo_title = ("PR#%s 疑似陈旧分支：%s ahead %s/behind %s（落后 %s 太多，多半已被取代）"
                          % (num, branch, ahead, behind, base))
            acceptance = ("【验收】分支落后 %s %s 个 commit，多半 ahead 的 %s 个 commit 内容已"
                          "以其它形式进 %s（patch-id 漂移的假阳性）：逐个 commit 核内容是否已进 %s"
                          "——已进/已废弃 → `git push origin --delete %s` 删远端分支并注明（删后本 sweep 项永久消失）；"
                          "仅在确有未落地内容时才走门禁再合并。来源：pr_sweep --file 自动落板 %s。"
                          % (base, behind, ahead, base, base, branch, today))
        else:
            todo_title = ("PR#%s 合并后更新：%s ahead %s/behind %s（不在 %s）"
                          % (num, branch, ahead, behind, base))
            acceptance = ("【验收】逐个 commit 核实内容是否已以其它形式进 %s："
                          "未进 → 走门禁再合并；已进/已废弃 → 删远端分支并注明。"
                          "来源：pr_sweep --file 自动落板 %s。" % (base, today))
        next_val = "%s→%s（behind %s）" % (oldsha, newsha, behind)
    if prior_done(num):  # 曾被标 done 又检出未落地 → 明说是假完成重捞，别让人以为是新单
        acceptance += ("（⚠️重捞：此 PR 之前有 done 单，但 commit 仍不在 %s——"
                       "上次「已完成」是假完成，本轮按当前 head 重新落板。）" % base)
    ap = run_cli(["add", todo_title, "--status", "todo"])
    m = re.search(r"TODO-(\d+)", ap.stdout or "")
    if ap.returncode != 0 or m is None:
        sys.stderr.write("add 失败 PR#%s：%s\n" % (num, (ap.stderr or ap.stdout).strip()))
        failed += 1
        continue
    todo_num = m.group(1)
    for field, value in (("acceptance", acceptance), ("next", next_val),
                         ("conflict_group", "pr-sweep")):
        sp = run_cli(["set", todo_num, field, value])
        if sp.returncode != 0:
            sys.stderr.write("set %s 失败 TODO-%s：%s\n"
                             % (field, todo_num, (sp.stderr or sp.stdout).strip()))
            failed += 1
    added.append("TODO-" + todo_num)
    listing += "\n] TODO-%s PR#%s " % (todo_num, num)  # 同轮防重：同 PR 号只落一条

if added:
    print("已落板 %d 条：%s；已存在跳过 %d 条" % (len(added), "、".join(added), skipped))
else:
    print("已落板 0 条；已存在跳过 %d 条" % skipped)
if failed:
    sys.stderr.write("本轮 %d 次落板写入失败——面板任务记 fail，下轮重试\n" % failed)
    sys.exit(3)  # 非零：失败可见性与 gh 拉取失败(exit 3)对齐，别静默绿
PYEOF
  rc=$?
  if [ "$rc" -ne 0 ]; then exit "$rc"; fi   # 落板失败向面板如实上报，别被 exit 0 吞掉
fi
exit 0

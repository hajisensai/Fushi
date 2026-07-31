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
# open PR 的 todo 标题尾部记录落板时的 head commit（`[head <sha9>]`，机器可反解）；
# 后续巡检发现同一 PR head 变了（推了新 commit）→ 落一条「有新 commit」增量 todo，
# 引用原 TODO 和 old→new sha，让更新不被「已有 todo」去重吞掉。旧格式（无 [head]）
# 的存量 todo 视为已跟踪（不刷屏）。
# **去重按「这个 head 有没有落过板」判，不按 todo 死活判**：已 done 的行同样算落过板。
# 否则「关掉重复/已完成行」这个清理动作本身就是循环的燃料——下轮 sweep 看不到任何行，
# 又建一条一模一样的（2026-07-31 实测 PR#539/#602/#608/#618/#619 全被复制成 2~3 条，
# 已合并的 PR#615 更是关一次涨一次 behind 地重建）。head 真变了仍照建增量单。
#
# **「内容有没有进 $BASE」按内容判，不按 commit SHA 判**：本仓 integration 大量走
# rebase / cherry-pick / 自建 merge commit，PR 分支上的 commit SHA 与真正落进 $BASE
# 的 SHA 系统性对不上。`gh api compare` 的 ahead_by 是按 commit 图算的，对 rebase 后
# 的等价提交照样算 ahead>0，于是「内容没落地」永远为真，配上假完成重捞就每轮重建：
#   · PR#539 head 已是 $BASE 祖先（走 rebase + 自建 merge commit），PR 却仍 open；
#   · PR#514 三个 commit 全部以不同 SHA 落地，compare 仍报 ahead 3。
# 判据换成 `git cherry`（patch-id 等价）：分支相对 merge-base 的每个非 merge commit，
# 在 $BASE 上找得到 patch-id 等价物就算已落地；一个不缺 = 内容已全部落地 -> 不落板，
# 只在「内容已全部落地」区单列（该关 PR / 删远端分支，不是该审查合并）。
# patch-id 覆盖不到的一类：落地时补丁本身被改写（PR#503 落地时 BUG 号 1175~1178 被重编成
# 1180~1183，代码等价但注释/文档字节不同 -> patch-id 必然不等，内容确实已在 $BASE）。这类
# 只能人核，核完在该 PR 的**任一**看板行里写显式标记 `[landed <当时的 head sha>]`，落板阶段
# 见到即跳过（标记锚在不可变的 head sha 上，不随行的死活变化；head 真变了标记自动失效）。
# 🔴 判据不可用一律 fail-open（无 git / fetch 不到 objects / $BASE 解析不出 -> 按未落地走
# 旧行为）。「PR 关了但改动没进 $BASE」必须照旧被重新落板（PR#41 教训），绝不允许为了
# 消噪音把这条护栏一起关掉。
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

# 检测阶段把「自动处理」项统一收集成 TSV（kind\tnum\ttitle\tbranch\tahead\toldsha\tnewsha\tbehind；
# open 项 newsha 列 = 当前 head 短 sha，其余列空），
# 人读输出照旧打印；--file 模式末尾一次性喂给内嵌 python 去重+落板。
# ⚠️ 路径归一：mktemp 给 MSYS `/tmp/...`，Git-bash 的 cp/printf 解析对，但 Windows
# 内嵌 python 对 `/tmp/...` 解析不稳定（会读到自己在别处建的空文件→落板 0 条·假成功）。
# 用 cygpath -m 转成 `C:/...` 原生路径，bash 与 Windows python 就指向同一物理文件；
# 非 Windows/无 cygpath 时保持原路径（Linux/Mac 上 mktemp 路径本就通用）。
AUTO_TSV="$(mktemp)"
AUTO_TSV="$(cygpath -m "$AUTO_TSV" 2>/dev/null || echo "$AUTO_TSV")"
MINE_TSV="$(mktemp)"
MINE_TSV="$(cygpath -m "$MINE_TSV" 2>/dev/null || echo "$MINE_TSV")"
EXT_TXT="$(mktemp)"
EXT_TXT="$(cygpath -m "$EXT_TXT" 2>/dev/null || echo "$EXT_TXT")"
trap 'rm -f "$AUTO_TSV" "$MINE_TSV" "$EXT_TXT"' EXIT

# 内容落地判据：`git cherry <base> <head>` 把 merge-base..head 的每个**非 merge** commit
# 按 patch-id 拿去 base 上找等价物，找不到打 `+`、找到打 `-`；`+` 数 = 真正没落地的 commit
# 数。这是 git 自带的内容判据，天然吃 rebase / cherry-pick / 换 SHA。
# 需要本地有 objects：`git fetch <remote> <ref>` **不带 refspec** 只更新 FETCH_HEAD + 拉
# objects，不动任何本地分支、不碰工作区、不抢 index.lock，在共享 checkout 里跑是安全的。
# 仓库根锚**脚本自身位置**，不吃 cwd：面板任务从任意目录调本脚本，cwd 不在仓库里时
# 裸 `git` 直接失败 -> 判据静默停用 -> 又退回按 SHA 判的老毛病（实测踩到过）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_REMOTE="${PR_SWEEP_REMOTE:-origin}"
BASE_SHA=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$ROOT" fetch --no-tags -q "$GIT_REMOTE" "$BASE" >/dev/null 2>&1; then
  BASE_SHA="$(git -C "$ROOT" rev-parse FETCH_HEAD 2>/dev/null)" || BASE_SHA=""
fi
case "$BASE_SHA" in *[!0-9a-f]*|"") BASE_SHA="";; esac   # 解析不出 -> 判据整体停用
[ -n "$BASE_SHA" ] || echo "（内容落地判据不可用：取不到 $GIT_REMOTE/$BASE——本轮一律按未落地处理）" >&2

# 未落地 commit 数；**判不出来输出 "?"**（调用方按未落地走旧行为，绝不静默吞掉真缺口）
unlanded_count() {
  local head="$1" branch="$2"
  [ -n "$BASE_SHA" ] && [ -n "$head" ] || { echo "?"; return; }
  if ! git -C "$ROOT" cat-file -e "${head}^{commit}" 2>/dev/null; then
    git -C "$ROOT" fetch --no-tags -q "$GIT_REMOTE" "$branch" >/dev/null 2>&1
    git -C "$ROOT" cat-file -e "${head}^{commit}" 2>/dev/null || { echo "?"; return; }  # fork/已删
  fi
  git -C "$ROOT" cherry "$BASE_SHA" "$head" 2>/dev/null | grep -c "^+"
}

# 「内容已全部落地」项：不落板，末尾单列一节（该关 PR / 删远端分支，不是该审查合并）
LANDED_REPORT=""

open_json=$(gh pr list --repo "$REPO" --state open \
  --json number,title,headRefName,headRefOid,author,updatedAt 2>/dev/null) || {
  echo "（gh 拉取失败——先核代理/网络，别当成没有 PR）"; exit 3; }

# python 只做拆分：mine 写 TSV 交给下面的 bash 逐条过内容判据，ext 直接渲染成整行。
# 注意：只有 mine（作者=SELF）会进落板管道；ext（外部作者）只打印、绝不落板。
echo "$open_json" | python -c '
import json, sys
self_login, mine_path, ext_path = sys.argv[1], sys.argv[2], sys.argv[3]
rows = json.load(sys.stdin)
def clean(s: str) -> str:
    return " ".join(str(s).split())  # 去掉标题里的 tab/换行，保 TSV 一行一项
with open(mine_path, "w", encoding="utf-8") as fm, \
     open(ext_path, "w", encoding="utf-8") as fe:
    for r in rows:
        if r["author"]["login"] == self_login:
            fm.write("%s\t%s\t%s\t%s\t%s\n"
                     % (r["number"], clean(r["title"]), clean(r["headRefName"]),
                        str(r.get("headRefOid") or ""), r["updatedAt"]))
        else:
            fe.write("#%s [%s] %s | head=%s | updated=%s\n"
                     % (r["number"], r["author"]["login"], clean(r["title"]),
                        clean(r["headRefName"]), r["updatedAt"]))
' "$SELF" "$MINE_TSV" "$EXT_TXT"

echo "=== OPEN PR·自动处理（作者=$SELF：无对应看板 todo 就建 -> 审查->复测->integration owner 合并->关 PR）==="
mine_found=0
while IFS=$'\t' read -r num title branch oid updated; do
  [ -n "$num" ] || continue
  # 内容已全部落地的 open PR 没有可合并的东西，落「审查合并」todo 是事实错误 -> 不落板。
  unlanded="$(unlanded_count "$oid" "$branch" </dev/null)"
  if [ "$unlanded" = "0" ]; then
    LANDED_REPORT="${LANDED_REPORT}#$num（open·$branch @ ${oid:0:9}）$title
"
    continue
  fi
  echo "#$num $title | head=$branch@${oid:0:9} | 未落地 commit $unlanded | updated=$updated"
  # 8 列（kind num title branch ahead oldsha newsha behind）；
  # open 项 newsha 列 = 当前 head 短 sha（落板记录 + 更新检测判据）
  printf 'open\t%s\t%s\t%s\t\t\t%s\t\n' "$num" "$title" "$branch" "${oid:0:9}" >> "$AUTO_TSV"
  mine_found=1
done < "$MINE_TSV"
[ "$mine_found" = "0" ] && echo "（无）"

echo ""
echo "=== OPEN PR·外部作者（不自动处理·不建 todo·不合并——仅列出等用户明示）==="
if [ -s "$EXT_TXT" ]; then cat "$EXT_TXT"; else echo "（无）"; fi

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
  # ahead>0 只说明 commit **图**上对不上，不代表内容没进 $BASE（rebase/cherry-pick 换了
  # SHA）。内容判据说一个不缺 -> 不落板，末尾单列（该删远端分支）；"?" 判不出来按未落地走。
  unlanded="$(unlanded_count "$cur" "$branch" </dev/null)"
  if [ "$unlanded" = "0" ]; then
    LANDED_REPORT="${LANDED_REPORT}#$num（merged·$owner:$branch @ ${cur:0:9}）ahead 的 $ahead 个 commit 已全部以等价补丁进 $BASE
"
    continue
  fi
  echo "#$num $owner:$branch ahead $ahead（未落地 $unlanded）/ behind $behind（相对 $BASE·merge 时 ${oid:0:9} -> 现 ${cur:0:9}）——核实内容是否已落地：未进则再合并，已进/被取代则删远端分支"
  printf 'merged\t%s\t\t%s\t%s\t%s\t%s\t%s\n' \
    "$num" "$owner:$branch" "$ahead" "${oid:0:9}" "${cur:0:9}" "$behind" >> "$AUTO_TSV"
  found=1
done < <(gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
  --json number,author,headRefName,headRefOid,headRepository,headRepositoryOwner \
  --jq '.[] | [.number, .author.login, .headRepositoryOwner.login, .headRepository.name, .headRefName, .headRefOid] | @tsv')
[ "$found" = "0" ] && echo "（无合并后更新）"

echo ""
echo "=== 内容已全部落地（patch-id 等价·不落板——该关 PR / 删远端分支，不是该审查合并）==="
if [ -n "$LANDED_REPORT" ]; then printf '%s' "$LANDED_REPORT"; else echo "（无）"; fi

# --file 模式：把 TSV 里的自动处理项落 vibe-coxswain 看板（去重后 add + set 三字段）。
if [ "$FILE_MODE" = "1" ]; then
  echo ""
  echo "=== --file 落板（vibe-coxswain）==="
  # DB 锚定脚本所在仓库根的绝对路径（错 cwd 不落错库）；须已存在，绝不静默新建。
  # $ROOT 在上面（内容落地判据）已按 $BASH_SOURCE 算好，这里复用同一份真值。
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
# ⚠️ 只认每行**行首自身**的「[状态] TODO-N」编号：整行 findall 会把标题正文里提到的
# 别人的编号也算成 done。PM 清理重复时正是写「[重复行·主行 TODO-2355] ...」并把这条
# 设 done，于是**活着的主行 2355 被误判成 done** → 去重看不见它 → 每轮重建（2026-07-31
# 实测该行为把 2246/2355/2362/2377/2378 五个未完成主行误标成 done）。
# 取失败不致命：done_nums 为空 = 所有行按未 done 处理，merged 路径退回不重捞的保守行为。
_DONE_LINE_RE = re.compile(r"^\[[^\]]*\] TODO-(\d+)\b")
dlp = run_cli(["list", "--status", "done"])
done_nums = ({m.group(1) for m in map(_DONE_LINE_RE.match, dlp.stdout.splitlines()) if m}
             if dlp.returncode == 0 else set())
# 已归档行 list 默认不返回——不带上它，「归档掉一条 pr-sweep 单」就又成了重建的扳机
# （和「设 done」同一个洞）。归档 = 已处置，一律按 done 计（下面 entries() 直接给
# done=True，不去解析中文状态标签）。取失败 → 空串，退回只看未归档的保守行为。
alp = run_cli(["list", "--archived"])
archived_listing = alp.stdout if alp.returncode == 0 else ""

# PR#41 不得匹配 PR#410：号后接非数字守卫（空格/全角括号/半角括号/句读都放行）。
_PR_TODO_RE = re.compile(r"\] TODO-(\d+) PR#(\d+)(?![0-9])")
# open todo 标题尾部记录的落板 head（`[head <sha>]`）；取行内**最后一个**匹配，
# 防 PR 标题正文恰好包含同格式片段时读错。
_HEAD_RE = re.compile(r"\[head ([0-9a-f]{7,40})\]")


# 人工核实后写在该 PR **任一**看板行里的显式落地标记（`[landed <当时的 head sha>]`）。
# 给内容判据（bash 侧 git cherry / patch-id）判不出来的那一类兜底：落地时补丁本身被改写，
# 内容等价但字节不同（PR#503 落地时 BUG 号 1175~1178 被重编成 1180~1183 就是这种）。
# 标记锚在**不可变的 head sha** 上，不锚在行的死活上：那行 todo/done/归档都算数，
# head 真变了（推了新 commit）标记自动失效、照常重新落板。写标记前必须人工核过内容确已在
# base——它是「我核过了」的断言，不是「这条别烦我」的开关。
_LANDED_RE = re.compile(r"\[landed ([0-9a-f]{7,40})\]")


def entries(num: str) -> list:
    """看板上该 PR 号的所有 todo：[(todo_num, head_sha|None, is_done)]。

    扫未归档 + 已归档两份 listing（每 todo 一行、标题不截断），head_sha 来自标题尾部
    [head ...]；旧格式 todo 没有该标记 → None；已归档行一律 is_done=True。
    每次调用重扫，同轮 add 后追加的行也能读到。
    """
    out: list = []
    for line, archived in ([(x, False) for x in listing.splitlines()]
                           + [(x, True) for x in archived_listing.splitlines()]):
        m = _PR_TODO_RE.search(line)
        if m is None or m.group(2) != num:
            continue
        heads = _HEAD_RE.findall(line)
        out.append((m.group(1), heads[-1] if heads else None,
                    archived or m.group(1) in done_nums))
    return out


def prior_done(num: str) -> bool:
    """该 PR 曾有 done 单却又被检出未落地 = 那条是假完成（关了但 commit 没进 base）。

    只给 merged 路径的「非陈旧分支」用：能走到这里说明**内容判据**（bash 侧 git cherry）
    已经认定确有 commit 的内容不在 base（不是「SHA 对不上」，是 patch-id 也找不到等价物），
    这时还被标 done 就是真假完成，必须重新落板（PR#41 教训）。open 路径和陈旧分支不看
    这个——它们的重复落板本身就是噪音源。
    """
    return any(done for _t, _s, done in entries(num))


def same_head(a: str, b: str) -> bool:
    """短/长 sha 前缀互认（本脚本记 9 位；防历史/手改单长度不一时误判「更新了」）。"""
    return a.startswith(b) or b.startswith(a)


def landed_marked(num: str, cur: str) -> bool:
    """该 PR 的看板行里有没有针对**当前 head** 的人工落地标记 `[landed <sha>]`。"""
    if not cur:
        return False
    for line in listing.splitlines() + archived_listing.splitlines():
        m = _PR_TODO_RE.search(line)
        if m is None or m.group(2) != num:
            continue
        if any(same_head(s, cur) for s in _LANDED_RE.findall(line)):
            return True
    return False

today: str = datetime.date.today().isoformat()
added: list = []
skipped: int = 0
failed: int = 0
try:
    stale_behind = int(os.environ.get("PR_SWEEP_STALE_BEHIND", "20"))
except ValueError:
    stale_behind = 20  # 环境变量给了非数字：退回默认，绝不因此崩落板
for kind, num, title, branch, ahead, oldsha, newsha, behind in rows:
    # 人工已核「内容由等价补丁落地」（bash 侧内容判据判不出来的那类）→ 本 head 不再落板。
    # 放在最前面：它是对事实的断言，比任何 head/done 推断都强。
    if landed_marked(num, newsha):
        skipped += 1
        continue
    tracked = entries(num)                        # 该 PR 的**所有**既有 todo（含 done）
    live = [e for e in tracked if not e[2]]       # 其中未 done 的
    fresh_update = False  # open PR 落板后又推新 commit 的增量单（不加重捞后缀）
    if kind == "open":
        cur = newsha  # 检测阶段写进 newsha 列的当前 head 短 sha
        if tracked:
            # 任一既有 todo（含 done）无 sha 记录（旧格式，无从判断）或记的就是当前 head
            # → 这个 head 已经落过板、已被处理过，再建纯噪音，跳过。
            if not cur or any(sha is None or same_head(sha, cur)
                              for _t, sha, _d in tracked):
                skipped += 1
                continue
            # 全部记录的 head 都不是当前 head = 落板后又推了新 commit → 增量 todo。
            # prev 取**所有行里编号最大的**那条（最近一次落板，不管它 done 没 done）。
            fresh_update = True
            prev_todo, prev_sha, _d = max(tracked, key=lambda e: int(e[0]))
            todo_title = ("PR#%s 有新 commit：%s（head %s→%s）[head %s]"
                          % (num, title, prev_sha, cur, cur))
            acceptance = ("【验收】PR#%s 在 TODO-%s 落板（head %s）后又推了新 commit"
                          "（现 head %s）：增量审查新 commit 的 diff，并与原 todo 的"
                          "审查/合并进度对齐（原 todo 未动 → 合并处理；已审/已合 → 只看增量）。"
                          "来源：pr_sweep --file 自动落板 %s。"
                          % (num, prev_todo, prev_sha, cur, today))
            next_val = ("分支 %s @ %s（原 TODO-%s @ %s）"
                        % (branch, cur, prev_todo, prev_sha))
        else:
            todo_title = "PR#%s 审查合并：%s" % (num, title)
            if cur:  # 标题尾部记录落板时 head，供后续巡检做更新检测
                todo_title += " [head %s]" % cur
            acceptance = ("【验收】审查 diff（范围/越界/回退他人）→ bug 类核复测证据 → "
                          "integration owner 合并 %s → CI 绿 → 关 PR、清远端分支。"
                          "来源：pr_sweep --file 自动落板 %s。" % (base, today))
            next_val = "分支 %s" % branch + (" @ %s" % cur if cur else "")
    else:  # merged：合并后更新。behind 大 = 分支陈旧/被后续工作取代（PR#68 死循环教训）：
           # 标题与验收指向「删远端分支」而非「再合并」，避免只关不删导致每轮重报。
        stale = behind.isdigit() and int(behind) >= stale_behind
        # 去重分两档：
        #  · 有未 done 行 → 跳过（旧行为，任何档都成立）。
        #  · 陈旧分支（behind ≥ 阈值）额外：有**任何**既有行（含 done）就跳过。分支合并后
        #    不再前进而 base 继续前进，behind 只会单调变大，关掉一条下轮必以更大的 behind
        #    重建成「新」单（PR#615：behind 125 关掉 → 重建成 behind 130）。报一次够了；
        #    真要清就删远端分支，那样本项永久消失。
        #  · 非陈旧（behind 小 + ahead>0 = 确有内容不在 base）保留 prior_done 重捞：那才是
        #    真·未落地内容被假完成关掉，必须继续喊（PR#41 教训）。
        if live or (stale and tracked):
            skipped += 1
            continue
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
    # 增量单不算重捞（原 todo 还活着，只是 head 前进了）；其余路径维持旧行为
    if not fresh_update and prior_done(num):  # 曾被标 done 又检出未落地 → 明说是假完成重捞，别让人以为是新单
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
    # 同轮防重：追加完整标题（带 PR 号 + [head sha]），entries() 重扫时能读到
    listing += "\n] TODO-%s %s" % (todo_num, todo_title)

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

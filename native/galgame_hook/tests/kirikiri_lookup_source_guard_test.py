#!/usr/bin/env python3
"""KiriKiri 游戏内查词的源码扫描守卫。

守的是 `hook/adapters/kirikiri_adapter.inc`。这些不是风格偏好，每一条都对应一个
**已经在 prototype 里存在过、且必须结构性消失**的东西：

1. 传给 `TVPExecuteScript` 的结果回执不得由动态字符串拼接构成（只允许整数经
   `std::to_wstring`）。prototype 是 `script += ... + word + ... + definition + ...`
   再 eval —— 那是把「游戏进程里能执行任意 TJS」这个注入面焊进架构，靠 escape 函数
   是补不掉的（escape 写错一次就全线失守）。整数化之后注入面**不存在**，而不是
   「更难利用」。

2. 游戏进程里不得有 HTTP 客户端和认证凭据（`WinHttp*` /
   `FUSHI_KIRIKIRI_LOOKUP_PORT` / `FUSHI_KIRIKIRI_LOOKUP_TOKEN`）。token 放进游戏
   进程环境块，任何拿得到 PROCESS_QUERY_INFORMATION 的进程都能读；而且环境变量在
   进程启动后改不了，做不到运行期开关。v14 用共享内存的 `lookup_enabled` 取代它。

3. 不得往引擎全局类上打 monkey-patch（`global.Layer.drawText` /
   `global.MessageLayer.processCh`）。这两条是已被运行日志证伪的捕获路径（只有
   TextRender 命中），而且挂在**全局** Layer 上意味着游戏所有 UI 绘制都要多绕一层
   ——游戏内渲染下每一毫秒都直接变成掉帧。
   唯一豁免：留在 `if(global.fushiLookupProbeMode)` 这个**默认关闭**的探测分支里，
   供换游戏时判断"文本到底走哪条路"。所以这条规则有配套的第二问——那个开关必须默认
   false，否则豁免立刻退化成"全局补丁常驻"。

4. 字形层与 `kag.primaryLayer` 的坐标不能假定共享父子链。KAG 的 fore/back 页可以是
   同一窗口根下的兄弟子树；必须分别沿父链累加到**同一个根**，再以两个绝对图层坐标相减。
   任一父链成环、断根或根不同都必须失败，Probe 也必须在失败时跳过该记录，不能复用上一次
   的 `fushiLookupOffX/Y`。否则同一套代码在 fore 页看似可用，换到 back 页就恒定点不中。

5. KAG 消息层锚点不能靠尺寸认领。必须先取 drawCh 宿主的 `hostPage`，再把
   `kag.currentNum` 投影到该宿主页的 `messages[currentNum]`。旧/定制 KAG 没有
   `currentNum` 时，只能用 `kag.current` 的对象身份从 fore/back 找到逻辑下标，再投影到
   宿主页同一位置；不能依赖 `current.comp` / `id`，更不能跨页按尺寸取第一个候选。

6. 同一 KAG `(page,index)` 的逻辑台词必须由 slot ledger 管理，但 **slot 只能在完整
   candidate（可见宿主 + 字符原点跨度 + page/index）形成后提交**。无 candidate 的新句只清
   当前 renderer，不能推进 slot 或 dismiss；同句重绘必须保留上一轮完整 binding。提交时原子
   退休同 slot peer、推进 generation 并发布 activeEntry。Probe 只接受当前 generation 的
   activeEntry；严格 current 身份可绕过短命 visibleHost，另一个共存 slot 成为 current 时则回退
   到本 entry 的 visibleHost。退休 entry 的同世代迟到 `done` 必须被 render epoch 门拒绝；同 entry
   同句不能降级 binding strength，另一 renderer 的更强 candidate 则可接管弱 active。Entry/slot
   LRU 都必须优先淘汰 inactive；渲染原函数必须先于 Capture，epoch 账本和查词采集只能作为不抛
   出的 sidecar。三个 TextRender wrapper 必须直接安装并立即回读，固定 stage 记录安装边界；
   mouseMove 只做一次 identity 基线，leftClick 低频复核后续覆写，且 bitmask 仅在状态变化时发布。

7. **「哪个才是游戏主窗口」只能有一套答案。** `ResolveKirikiriEngineMainThreadId` 必须
   复用 `lookup_overlay_window.inc` 的 `FindGameMainWindow()`（可见 + 无 owner + 客户区
   面积最大），不得自带一份「EnumWindows 第一个匹配」。第一个匹配那套是错的：TVP 控制台窗、
   splash、同进程启动器窗，或本模块自己那个 1x1 的 `WS_EX_TOPMOST` `FushiLookupOverlay`
   （EnumWindows 会先枚举到它）都会抢走判定，把别的线程 id 当引擎主线程
   `InterlockedCompareExchange(..., 0)` **一次性**缓存下来，写错永不自愈；此后
   `GetCurrentThreadId() != main_tid` 恒真，传感器静默永不安装，症状与「这个引擎不支持」
   完全同形。配套第二问：共享的那套判据本身必须仍然是面积判据，否则统一了也是统一到错的
   那一套。

变异实测纪律：本文件把每条规则实现成一个独立的 `find_*` 函数，`RealAdapterTest` 用它
扫真文件，`MutationSelfTest` 用它扫**合成的脏输入**并要求非空。两组都在，这守卫才不
可能是「永远绿的空守卫」。
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path
from typing import Iterator

# KAGEX 缺席门：`if(typeof global.TextRender == "Object") { ... } else { ... }`。
# 经典 KAG3 游戏（Fate/stay night[Realta Nua]、PRETTY×CATION2、フタマタ恋愛）整个
# global.TextRender 都不存在，逐字几何只从原生 Layer.drawText 经过——全局补丁在**这个
# else 里**是唯一可行采集面，不是又一条兜底。装了 textrender.dll 的游戏走 if 分支，
# 一行都不多绕，所以"全局补丁让所有 UI 绘制多绕一层"的代价只落在别无来源的游戏上。
KAGEX_GATE_RE = re.compile(
    r'if\s*\(\s*typeof\s+global\.TextRender\s*==\s*"Object"\s*\)'
)


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "hook" / "adapters" / "kirikiri_adapter.inc"

# TJS 侧的全局命名空间前缀。C++ 里出现含这个前缀的宽字符串字面量 = 这条语句在拼 TJS 源码。
TJS_MARKER = "fushiLookup"

_SLOT = "\x01"
_SLOT_RE = re.compile(_SLOT + r"\d+" + _SLOT)

# 进程内网络客户端 / 认证凭据残骸。前三条是硬要求；后两条同属 prototype 的 HTTP 直连
# 链路（plan §6 的整段删除清单），一起守住免得换个写法又长回来。
NETWORK_DEBRIS = (
    "WinHttp",
    "FUSHI_KIRIKIRI_LOOKUP_PORT",
    "FUSHI_KIRIKIRI_LOOKUP_TOKEN",
    "/api/lookup/dictionary",
    "Authorization: Bearer",
)

# 往引擎全局类上打补丁：`global.Layer.xxx =` / `global.MessageLayer.xxx =`（排除 `==`）。
GLOBAL_PATCH_RE = re.compile(r"global\.(?:Layer|MessageLayer)\.\w+\s*=(?!=)")

# 默认关闭的探测分支。全局补丁只允许活在它里面：换游戏、TextRender 一条都不命中时才开，
# 用来判断文本到底走哪条路。
PROBE_GATE_RE = re.compile(r"if\s*\(\s*global\.fushiLookupProbeMode\s*\)")

# 生产 bootstrap 为了规避 MSVC raw-literal 长度/编辑风险，被拆成多个相邻的
# `LR"TJS(...)TJS"`。C++ 的 MaskedSource 会把每一整段 raw literal 隐掉；bootstrap 内守卫
# 若扫 `source.masked` 就永远看不到真正执行的 TJS。因此先按 C++ 拼接顺序取出 payload，
# 再在拼接后的 TJS 上做第二轮注释/字符串掩码和函数级结构分析。
TJS_RAW_RE = re.compile(r'(?:L|u8|u|U)?R"TJS\((.*?)\)TJS"', re.S)


def _iter_find(haystack: str, needle: str) -> Iterator[int]:
    start = 0
    while True:
        index = haystack.find(needle, start)
        if index < 0:
            return
        yield index
        start = index + len(needle)


class MaskedSource:
    """抠掉注释与字符串字面量之后的源码，便于按运算符/括号做结构判断。

    `masked` 与原文**等长、换行数相同**：每个字符串字面量整体被替换成
    `\\x01<序号>\\x01` 再用空格补齐，所以下标可以直接换算回原文行号。
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.literals: list[str] = []
        self.masked = self._mask(text)
        self._blocks: list[tuple[int, int]] | None = None

    # -- 掩码 ---------------------------------------------------------------
    def _mask(self, text: str) -> str:
        out: list[str] = []
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "/" and i + 1 < n and text[i + 1] == "/":
                end = text.find("\n", i)
                end = n if end < 0 else end
                out.append(" " * (end - i))
                i = end
                continue
            if ch == "/" and i + 1 < n and text[i + 1] == "*":
                end = text.find("*/", i + 2)
                end = n if end < 0 else end + 2
                out.append("".join("\n" if c == "\n" else " " for c in text[i:end]))
                i = end
                continue
            raw = re.match(r'(?:L|u8|u|U)?R"([^()\\ ]{0,16})\(', text[i:])
            if raw is not None:
                closer = ")" + raw.group(1) + '"'
                end = text.find(closer, i + raw.end())
                end = n if end < 0 else end + len(closer)
                out.append(self._slot(text[i:end]))
                i = end
                continue
            lit = re.match(r'(?:L|u8|u|U)?"', text[i:])
            if lit is not None:
                j = i + lit.end()
                while j < n:
                    if text[j] == "\\":
                        j += 2
                        continue
                    if text[j] == '"':
                        j += 1
                        break
                    j += 1
                out.append(self._slot(text[i:j]))
                i = j
                continue
            if ch == "'":
                j = i + 1
                while j < n:
                    if text[j] == "\\":
                        j += 2
                        continue
                    if text[j] == "'":
                        j += 1
                        break
                    j += 1
                out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
                i = j
                continue
            out.append(ch)
            i += 1
        return "".join(out)

    def _slot(self, literal: str) -> str:
        span = len(literal)
        newlines = literal.count("\n")
        index = len(self.literals)
        self.literals.append(literal)
        token = f"{_SLOT}{index}{_SLOT}"
        if span - newlines < len(token):
            # 极短字面量放不下槽标记：退化成空白（内容本来也无从判定）。
            return "".join("\n" if c == "\n" else " " for c in literal)
        return token + " " * (span - newlines - len(token)) + "\n" * newlines

    # -- 查询 ---------------------------------------------------------------
    def line_of(self, index: int) -> int:
        return self.text.count("\n", 0, index) + 1

    def literal_at(self, index: int) -> str | None:
        if index < 0 or index >= len(self.masked) or self.masked[index] != _SLOT:
            return None
        end = self.masked.find(_SLOT, index + 1)
        if end < 0:
            return None
        return self.literals[int(self.masked[index + 1 : end])]

    def statements(self) -> Iterator[tuple[int, str]]:
        start = 0
        for match in re.finditer(r";", self.masked):
            yield start, self.masked[start : match.start()]
            start = match.end()
        if start < len(self.masked):
            yield start, self.masked[start:]

    def blocks(self) -> list[tuple[int, int]]:
        if self._blocks is not None:
            return self._blocks
        stack: list[int] = []
        found: list[tuple[int, int]] = []
        for index, ch in enumerate(self.masked):
            if ch == "{":
                stack.append(index)
            elif ch == "}" and stack:
                found.append((stack.pop(), index + 1))
        self._blocks = found
        return found

    def enclosing_function(self, index: int) -> tuple[int, int] | None:
        """包住 [index] 的最内层「看起来是函数体」的大括号块。

        判据只看紧邻 `{` 之前那段声明文本：含成对括号、且不是 namespace/class/struct
        /enum/union 的开头。多行签名也能认出来（往前取一段而不是只取一行）。
        """
        best: tuple[int, int] | None = None
        for start, end in self.blocks():
            if not (start <= index < end):
                continue
            head = self.masked[max(0, start - 400) : start]
            cut = max(head.rfind(";"), head.rfind("}"), head.rfind("{"))
            decl = head[cut + 1 :].strip()
            if "(" not in decl or ")" not in decl:
                continue
            if re.match(r"(namespace|class|struct|enum|union)\b", decl):
                continue
            if best is None or start > best[0]:
                best = (start, end)
        return best


# ── 规则实现（真文件与变异样本共用同一份，谁都不许各写一套）──────────────────


def _is_literal_slot(statement: str, index: int) -> bool:
    return bool(_SLOT_RE.match(statement, index))


def _closes_to_wstring(statement: str, close_index: int) -> bool:
    """`statement[close_index]` 是 `)`，判断它闭合的是不是 `std::to_wstring(`。"""
    depth = 0
    i = close_index
    while i >= 0:
        if statement[i] == ")":
            depth += 1
        elif statement[i] == "(":
            depth -= 1
            if depth == 0:
                head = statement[:i].rstrip()
                return head.endswith("to_wstring")
        i -= 1
    return False


_ID_RE = re.compile(r"[A-Za-z_]\w*")
# 赋值目标：标识符后紧跟 `=` 或 `+=`（排除 `==` / `!=` / `>=` / `<=`）。
_TARGET_RE = re.compile(r"([A-Za-z_]\w*)\s*\+?=(?!=)")
_MOVE_RE = re.compile(r"std::move\s*\(\s*([A-Za-z_]\w*)\s*\)")


def _statement_holds_tjs_literal(source: MaskedSource, offset: int, statement: str) -> bool:
    return any(
        TJS_MARKER in (source.literal_at(offset + match.start()) or "")
        for match in _SLOT_RE.finditer(statement)
    )


def _tjs_script_variables(
    source: MaskedSource, statements: list[tuple[int, str]]
) -> set[str]:
    """哪些变量装着 TJS 源码。

    脚本文本通常先用一条语句起头（`std::wstring script = L"...fushiLookupApply(";`），
    再由后续 `script += ...` 追加——追加那几条语句里一个 TJS 字面量都没有。所以判定
    必须跟着**变量**走，只按单条语句看会漏掉真正危险的那几行。
    """
    tainted: set[str] = set()
    for _ in range(3):  # 变量间传递（script -> pending_script）几轮即到不动点
        for offset, statement in statements:
            target = _TARGET_RE.search(statement)
            if target is None:
                continue
            if _statement_holds_tjs_literal(source, offset, statement):
                tainted.add(target.group(1))
                continue
            # 传播只认**直接转手**（`x = script;` / `x = std::move(script);`）。
            # 不能按"语句里提到了某个受污染变量"来传播：那样 `i`、`value` 这种到处都
            # 有的名字会瞬间污染全文件，守卫立刻变成一改就红的噪音源。
            rhs = _MOVE_RE.sub(r"\1", statement[target.end() :])
            rhs = _SLOT_RE.sub(" ", rhs).strip()
            if rhs in tainted:
                tainted.add(target.group(1))
    return tainted


def find_dynamic_tjs_concatenations(source: MaskedSource) -> list[str]:
    """找出「拼 TJS 源码」的语句。

    只看**装着 TJS 源码的变量**身上的 `+`：其操作数必须是字符串字面量或
    `std::to_wstring(...)`。路径拼接、日志拼接这类与注入面无关的字符串运算因此不会被
    误伤——守卫要抓的是「会被 eval 的那段文本」，不是所有字符串加法。
    """
    violations: list[str] = []
    statements = list(source.statements())
    tainted = _tjs_script_variables(source, statements)
    for offset, statement in statements:
        touches_tjs = _statement_holds_tjs_literal(source, offset, statement)
        if not touches_tjs:
            target = _TARGET_RE.search(statement)
            if target is None or target.group(1) not in tainted:
                continue
        for match in re.finditer(r"\+", statement):
            i = match.start()
            if statement[i : i + 2] == "++" or (i > 0 and statement[i - 1] == "+"):
                continue
            compound = statement[i : i + 2] == "+="
            right = i + (2 if compound else 1)
            while right < len(statement) and statement[right].isspace():
                right += 1
            ok = _is_literal_slot(statement, right) or bool(
                re.match(r"(std::)?to_wstring\s*\(", statement[right:])
            )
            if ok and not compound:
                left = i - 1
                while left >= 0 and statement[left].isspace():
                    left -= 1
                if left < 0:
                    ok = False
                elif statement[left] == _SLOT:
                    ok = True  # 字面量槽以 \x01 收尾
                elif statement[left] == ")":
                    ok = _closes_to_wstring(statement, left)
                else:
                    ok = False
            if ok:
                continue
            snippet = " ".join(statement[max(0, i - 70) : i + 70].split())
            violations.append(
                f"{ADAPTER.name}:{source.line_of(offset + i)} "
                f"把非整数内容拼进 TJS 源码：… {snippet} …"
            )
    return violations


def find_network_debris(source: MaskedSource) -> list[str]:
    hits: list[str] = []
    for needle in NETWORK_DEBRIS:
        for index in _iter_find(source.text, needle):
            hits.append(f"{ADAPTER.name}:{source.line_of(index)} {needle}")
    return hits


def _probe_block_spans(text: str) -> list[tuple[int, int]]:
    """`if(global.fushiLookupProbeMode) { ... }` 的字节区间（TJS 侧大括号配对）。"""
    spans: list[tuple[int, int]] = []
    for gate in PROBE_GATE_RE.finditer(text):
        open_index = text.find("{", gate.end())
        if open_index < 0:
            continue
        depth = 0
        for j in range(open_index, len(text)):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    spans.append((gate.start(), j + 1))
                    break
    return spans


def _brace_span(text: str, open_index: int) -> int:
    """从 `open_index` 处的 `{` 起做大括号配对，返回闭合 `}` 的下一个下标（-1=没配上）。"""
    depth = 0
    for j in range(open_index, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    return -1


def _classic_fallback_spans(text: str) -> list[tuple[int, int]]:
    """KAGEX 缺席门的 `else { ... }` 区间。

    只认真正挂在 `typeof global.TextRender == "Object"` 之后的 else——把补丁从这个
    else 里挪出去（或把门本身删掉）会让区间消失，补丁随即落到 find_global_monkey_patches
    的红区里。
    """
    spans: list[tuple[int, int]] = []
    for gate in KAGEX_GATE_RE.finditer(text):
        open_index = text.find("{", gate.end())
        if open_index < 0:
            continue
        close = _brace_span(text, open_index)
        if close < 0:
            continue
        tail = text[close:]
        stripped = tail.lstrip()
        if not stripped.startswith("else"):
            continue
        else_open = text.find("{", close + (len(tail) - len(stripped)) + len("else"))
        if else_open < 0:
            continue
        else_close = _brace_span(text, else_open)
        if else_close < 0:
            continue
        spans.append((else_open, else_close))
    return spans


def find_global_monkey_patches(source: MaskedSource) -> list[str]:
    """引擎全局类的补丁只允许出现在默认关闭的探测分支里。

    `global.Layer.drawText` 挂上包装之后，游戏**所有** UI 绘制都要多绕一层；游戏内
    渲染下这直接变成掉帧。所以补丁只允许出现在两处**有门的**位置：

    1. 默认关闭的探测分支（换游戏时数次数用）；
    2. KAGEX 缺席门的 else——那类游戏没有 global.TextRender，逐字几何只从原生
       Layer.drawText 经过，不绕就等于游戏内查词整个不存在。

    两处之外的补丁一律红：那是"所有游戏都多绕一层"，代价没有对价。
    """
    spans = _probe_block_spans(source.text) + _classic_fallback_spans(source.text)
    hits: list[str] = []
    for m in GLOBAL_PATCH_RE.finditer(source.text):
        if any(start <= m.start() < end for start, end in spans):
            continue
        hits.append(f"{ADAPTER.name}:{source.line_of(m.start())} {m.group(0)}")
    return hits


def find_default_on_probe_switches(source: MaskedSource) -> list[str]:
    """喂给 `__FUSHI_PROBE_MODE__` 的开关必须默认关。

    探测分支被允许存在的**唯一**前提就是它默认不跑；开关默认 true 时上面那条豁免立刻
    变成"全局补丁常驻"。这里跟着实际替换表达式里的标识符走，改名不会让这条守卫失效。
    """
    for match in re.finditer(
        r'__FUSHI_PROBE_MODE__"\s*,([^;]*);', source.text, re.S
    ):
        expression = match.group(1)
        names = [
            name
            for name in _ID_RE.findall(expression)
            if name not in {"L", "true", "false", "std", "wstring"}
        ]
        if not names:
            continue
        for name in names:
            if re.search(rf"\b{re.escape(name)}\s*=\s*false\s*;", source.text):
                return []
        return [
            f"{ADAPTER.name}:{source.line_of(match.start())} "
            f"探测开关 {names} 没有一个定义为 false"
        ]
    return []


def _placeholder_substitutions(text: str) -> list[tuple[int, str, str]]:
    """`ReplaceLookupPlaceholder(script, L"__FUSHI_X__", <值表达式>);` 的 (位置, 占位符, 值)。"""
    return [
        (m.start(), m.group(1), m.group(2))
        for m in re.finditer(r'(__FUSHI_[A-Z0-9_]*__)"\s*,([^;]*)\)\s*;', text, re.S)
    ]


def find_unvalidated_placeholder_values(source: MaskedSource) -> list[str]:
    """填进 TJS bootstrap 的占位符，其值要么是字面量，要么必须过字符类校验。

    PNG 备路要把 `%TEMP%` 下的卡片路径交给 TJS 的 `loadImages`，所以这一处运行期数据是
    必需的、不禁。但它是整条链上最后一个「内容由运行期数据决定的可执行 TJS」，防线只有
    一道：写进那个变量之前拒掉引号、反斜杠和换行。**绕开那道校验直接给变量赋值**（以后
    有人图省事写 `g_lookup_card_path = temp + name;`）就会把注入面重新打开，而症状在真机
    上完全看不出来——所以这里逐个赋值点核，不只看"校验函数还在不在"。
    """
    violations: list[str] = []
    for position, placeholder, expression in _placeholder_substitutions(source.text):
        if '"' in expression or "'" in expression:
            continue  # 值是字面量（如 `? L"1" : L"0"`），没有运行期数据
        names = [
            name
            for name in _ID_RE.findall(expression)
            if name not in {"L", "true", "false", "std", "wstring", "script"}
        ]
        if not names:
            violations.append(
                f"{ADAPTER.name}:{source.line_of(position)} "
                f"{placeholder} 的替换值既不是字面量也认不出变量"
            )
            continue
        for name in names:
            for assign in re.finditer(
                rf"\b{re.escape(name)}\s*=(?!=)", source.masked
            ):
                scope = source.enclosing_function(assign.start())
                body = source.masked[scope[0] : scope[1]] if scope is not None else ""
                if "find_first_of" in body:
                    continue
                violations.append(
                    f"{ADAPTER.name}:{source.line_of(assign.start())} "
                    f"{name}（{placeholder} 的值）在没有字符类校验的地方被赋值"
                )
    return violations


def find_unguarded_bitmap_copies(source: MaskedSource) -> list[str]:
    """取查词位图缓冲的函数里必须出现 `IsLookupFrameSane`。

    跨进程来的 width/height/pitch 是不可信输入，按它们盲拷就是往游戏进程越界写；
    这个闸门是那条路径上唯一的关卡。
    """
    unguarded: list[str] = []
    for index in _iter_find(source.masked, "LookupBitmapAt("):
        scope = source.enclosing_function(index)
        if scope is None:
            unguarded.append(
                f"{ADAPTER.name}:{source.line_of(index)} 取位图缓冲处不在任何函数体内"
            )
            continue
        if "IsLookupFrameSane" not in source.masked[scope[0] : scope[1]]:
            unguarded.append(
                f"{ADAPTER.name}:{source.line_of(index)} "
                "取位图缓冲的函数里没有 IsLookupFrameSane"
            )
    return unguarded


# MSVC 的字符串字面量上限是 16380 **字节**。bootstrap 是 `LR"TJS(...)TJS"` 宽串，一个
# wchar_t 占两字节，所以真正放得下的是约 8190 个 UTF-16 code unit。
#
# 单位必须是 UTF-16 code unit：一个汉字按 UTF-8 是 3 字节、按 UTF-16 只占 1 个。按字节
# 估会以为还剩一大半余量，实际早就贴着线了。
MSVC_WIDE_LITERAL_UNITS = 8190


def find_oversized_tjs_literals(source: MaskedSource) -> list[str]:
    """每段 `LR"TJS(...)TJS"` 都必须留在 MSVC 的宽串上限内。

    这条规则的价值在于**它替 Windows 构建把话说在前面**：超限报的是 C2026，只有
    windows 那条流水线会红，而 Linux 上的 guards 和全部 Dart 单测照样全绿。少了它，
    往 bootstrap 里多写几行中文注释就够让 PR 在十几分钟后翻车，且报错行号指向被截断
    的位置，与真正改动的地方毫无关系。

    拆段本身是免费的：相邻的 raw literal 由编译器拼接，运行时的 TJS 一模一样。所以
    修法永远是「在顶层语句边界插一行 `)TJS" LR"TJS(`」，而不是删注释。
    """
    offenders: list[str] = []
    for match in TJS_RAW_RE.finditer(source.text):
        units = len(match.group(1).encode("utf-16-le")) // 2
        if units > MSVC_WIDE_LITERAL_UNITS:
            offenders.append(
                f"{ADAPTER.name}:{source.line_of(match.start())} "
                f'LR"TJS(...)TJS" 段有 {units} 个 UTF-16 单元，超过 MSVC 上限 '
                f'{MSVC_WIDE_LITERAL_UNITS}（C2026，只在 Windows 构建报）；'
                '在顶层语句边界插一行 )TJS" LR"TJS( 拆开'
            )
    return offenders


def _joined_tjs_payload(source: MaskedSource) -> MaskedSource:
    """按 C++ 相邻 raw literal 的顺序还原最终交给引擎的 TJS。"""
    return MaskedSource(
        "\n".join(match.group(1) for match in TJS_RAW_RE.finditer(source.text))
    )


def _assigned_tjs_functions(
    source: MaskedSource, name: str
) -> list[tuple[str, str]]:
    """返回 `global.<name> = function(<参数>) { <函数体> }` 的参数与掩码后函数体。"""
    pattern = re.compile(
        rf"\bglobal\.{re.escape(name)}\s*=\s*function\s*\(([^)]*)\)\s*"
    )
    by_open = {start: (start, end) for start, end in source.blocks()}
    found: list[tuple[str, str]] = []
    for match in pattern.finditer(source.masked):
        open_index = source.masked.find("{", match.end())
        if open_index < 0 or source.masked[match.end() : open_index].strip():
            continue
        span = by_open.get(open_index)
        if span is None:
            continue
        found.append((match.group(1), source.masked[open_index + 1 : span[1] - 1]))
    return found


def _compact_tjs(text: str) -> str:
    return re.sub(r"\s+", "", text)


def _restore_tjs_literals(source: MaskedSource, text: str) -> str:
    """Restore string slots in a masked TJS slice without restoring comments."""

    def restore(match: re.Match[str]) -> str:
        token = match.group(0)
        return source.literals[int(token[1:-1])]

    return _SLOT_RE.sub(restore, text)


def _braced_spans_after(text: str, marker: str) -> list[tuple[int, int]]:
    """从已压紧的 TJS 中取每个 `marker { ... }` 的函数体区间，支持块内嵌套。"""
    spans: list[tuple[int, int]] = []
    start = 0
    while True:
        marker_index = text.find(marker, start)
        if marker_index < 0:
            return spans
        open_index = marker_index + len(marker)
        if open_index >= len(text) or text[open_index] != "{":
            start = marker_index + len(marker)
            continue
        depth = 0
        for index in range(open_index, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    spans.append((open_index + 1, index))
                    start = index + 1
                    break
        else:
            return spans


def _braced_bodies_after(text: str, marker: str) -> list[str]:
    return [text[start:end] for start, end in _braced_spans_after(text, marker)]


def _ends_with_top_level_continue(text: str) -> bool:
    """块末必须是无条件的顶层 `continue;`，不能藏进 `if` 或更深的块。"""
    index = text.rfind("continue;")
    if index < 0 or index + len("continue;") != len(text):
        return False
    depth = 0
    for ch in text[:index]:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
    if depth != 0:
        return False
    return index == 0 or text[index - 1] in ";}"


def _brace_depth_at(text: str, index: int) -> int:
    """返回已掩码/压紧 TJS 在 index 前的大括号深度。"""
    depth = 0
    for ch in text[: max(index, 0)]:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
    return depth


def find_invalid_kag_anchor_identity_selection(
    source: MaskedSource,
) -> list[str]:
    """守住 KAG 消息层锚点的**冻结点**与宿主页投影契约。

    锚点必须在 drawCh 真正执行的那一刻冻结（`fushiLookupStampBindGroup`），不能留到
    鼠标事件或 Capture 再按"那时的" `kag.currentNum` 去投影：共存的姓名层（ai=1）与
    正文层（ai=0）会轮流成为 current，晚一步投影就把这条绑定挂到别人的台词上，症状是
    卡片稳定地弹在另一行。

    fore/back 是同一组逻辑消息层的双缓冲页。稳定身份是 `currentNum`；旧 KAG 没有这个
    字段时，才允许以 `current` 的对象身份找逻辑下标（`ResolveCurrentSlot`）。宽高不是
    身份。这里钉住冻结点、hostPage、宿主页数组、currentNum 主路径、对象身份兜底的接管
    条件与发布顺序；把这些片段散落在别处或搬回 Capture 都不能过。
    """
    violations: list[str] = []
    if not TJS_RAW_RE.search(source.text):
        return [f'{ADAPTER.name}: 没有找到 LR"TJS(...)TJS" bootstrap']

    tjs = _joined_tjs_payload(source)
    stamps = _assigned_tjs_functions(tjs, "fushiLookupStampBindGroup")
    if len(stamps) != 1:
        return [
            f"{ADAPTER.name}: fushiLookupStampBindGroup 定义数应为 1，"
            f"实际 {len(stamps)}"
        ]
    _, stamp_body = stamps[0]
    stamp = _compact_tjs(stamp_body)

    captures = _assigned_tjs_functions(tjs, "fushiLookupCapture")
    if len(captures) != 1:
        return [
            f"{ADAPTER.name}: fushiLookupCapture 定义数应为 1，实际 {len(captures)}"
        ]
    capture = _compact_tjs(captures[0][1])

    slot = _SLOT_RE.pattern
    field_read_re = re.compile(
        rf"global\.fushiLookupField\(global\.kag,(?P<field>{slot})\)"
    )

    def field_literal_is(match: re.Match[str], expected: str) -> bool:
        token = match.group("field")
        literal = tjs.literals[int(token[1:-1])]
        return (
            len(literal) >= 2
            and literal[0] == literal[-1]
            and literal[0] in {'"', "'"}
            and literal[1:-1] == expected
        )

    # 冻结点：Capture 不得自己再读一次 currentNum。它拿到的必须是 drawCh 当时冻结在
    # BindGroup 上的 anchorPage/anchorIndex/anchorIdentity。
    if any(
        field_literal_is(m, "currentNum") for m in field_read_re.finditer(capture)
    ):
        violations.append(
            f"{ADAPTER.name}: Capture 不得按当时的 kag.currentNum 重新投影锚点；"
            "锚点只能在 drawCh 执行期冻结"
        )

    # 这是已被真机证伪的旧实现形状。单独点名，避免它只因新结构缺失而间接变红：
    # mutation 必须能证明守卫本身认得出「跨页按尺寸首个命中」。
    legacy_pages = re.compile(
        r"(?:var)?pages=\[(?:global\.kag\.)?fore(?:\.messages)?,"
        r"(?:global\.kag\.)?back(?:\.messages)?\]"
    )
    if legacy_pages.search(stamp):
        violations.append(
            f"{ADAPTER.name}: 禁止旧 pages=[fore,back] 跨页按尺寸首个命中后 break"
        )

    host_page = "group.hostPage=global.fushiLookupPageOf(host);"
    messages_decl = "varmessages=global.fushiLookupMessagesForPage(group.hostPage);"
    for needle, message in (
        (host_page, "hostPage 必须由 drawCh 宿主 host 求得"),
        (messages_decl, "宿主页消息数组必须由 hostPage 唯一选择"),
    ):
        count = stamp.count(needle)
        if count != 1:
            violations.append(f"{ADAPTER.name}: {message}（出现 {count} 次）")

    # 冻结前必须先把上一轮的锚点整组清空。少清一个字段，换句时旧值会与新值混着用，
    # 得到一个"半新半旧"的锚点——那比完全没有锚点更难查。
    reset_patterns = (
        re.escape("group.anchorPage=0;"),
        re.escape("group.anchorIndex=-1;"),
        re.escape("group.anchorIdentity=void;"),
        re.escape("group.currentIdentity=void;"),
        re.escape("group.anchorStrength=0;"),
    )
    if not _matches_once_in_order(stamp, reset_patterns):
        violations.append(
            f"{ADAPTER.name}: 冻结前必须整组复位 anchorPage/Index/Identity/"
            "currentIdentity/Strength"
        )

    current_num_decl_re = re.compile(
        rf"varcurrentNum=global\.fushiLookupField\(global\.kag,(?P<field>{slot})\);"
    )
    current_num_decls = list(current_num_decl_re.finditer(stamp))
    if len(current_num_decls) != 1 or not field_literal_is(
        current_num_decls[0], "currentNum"
    ):
        violations.append(
            f"{ADAPTER.name}: currentNum 主路径必须唯一读取 kag.currentNum"
        )

    current_num_gate_re = re.compile(
        rf"if\(messages!==void&&typeofcurrentNum==(?P<type>{slot})&&"
        r"currentNum>=0&&currentNum<messages\.count\)"
    )
    current_num_gates = list(current_num_gate_re.finditer(stamp))
    current_num_spans: list[tuple[int, int]] = []
    if len(current_num_gates) != 1:
        violations.append(
            f"{ADAPTER.name}: currentNum 主路径必须有唯一的整数/上下界门"
        )
    else:
        type_token = current_num_gates[0].group("type")
        type_literal = tjs.literals[int(type_token[1:-1])]
        if type_literal not in {'"Integer"', "'Integer'"}:
            violations.append(
                f"{ADAPTER.name}: currentNum 主路径必须先确认 Integer"
            )
        current_num_spans = _braced_spans_after(
            stamp, current_num_gates[0].group(0)
        )

    if len(current_num_spans) != 1:
        violations.append(
            f"{ADAPTER.name}: currentNum 整数/上下界门必须包住唯一主路径"
        )
    else:
        primary = stamp[current_num_spans[0][0] : current_num_spans[0][1]]
        indexed_gate = "if(indexed!==void&&indexed!==null&&isvalidindexed)"
        indexed_spans = _braced_spans_after(primary, indexed_gate)
        if primary.count("varindexed=messages[currentNum];") != 1 or len(
            indexed_spans
        ) != 1:
            violations.append(
                f"{ADAPTER.name}: currentNum 必须索引宿主页并校验所得消息层"
            )
        else:
            indexed_body = primary[indexed_spans[0][0] : indexed_spans[0][1]]
            primary_publish = (
                re.escape("group.anchorIdentity=indexed;"),
                re.escape("group.anchorPage=global.fushiLookupPageOf(indexed);"),
                re.escape("group.anchorIndex=currentNum;"),
                re.escape("group.anchorStrength=1;"),
            )
            if not _matches_once_in_order(indexed_body, primary_publish):
                violations.append(
                    f"{ADAPTER.name}: currentNum 主路径必须原子发布宿主页同下标消息层"
                    "并记 strength=1"
                )

    resolved_decl = "varresolved=global.fushiLookupResolveCurrentSlot();"
    if stamp.count(resolved_decl) != 1:
        violations.append(
            f"{ADAPTER.name}: identity 兜底必须唯一经 ResolveCurrentSlot 读 kag.current"
        )
    resolved_gate = (
        "if(resolved!==void&&messages!==void&&resolved.index>=0&&"
        "resolved.index<messages.count)"
    )
    resolved_spans = _braced_spans_after(stamp, resolved_gate)
    if len(resolved_spans) != 1:
        violations.append(
            f"{ADAPTER.name}: identity 兜底必须通过宿主页上界门，且只有一处"
        )
    else:
        fallback_body = stamp[resolved_spans[0][0] : resolved_spans[0][1]]
        # 接管条件是这条兜底最关键的一道门：只有"主路径还没定"或"就是同一个 slot"时
        # 才允许它写。少了它，另一个共存 slot（姓名层）成为 current 就会把正文层的
        # 绑定抢走——真机症状是选正文却高亮到人名。
        takeover_gate = (
            "(group.anchorIdentity===void||(resolved.page==group.anchorPage&&"
            "resolved.index==group.anchorIndex))"
        )
        if fallback_body.count("varprojected=messages[resolved.index];") != 1:
            violations.append(
                f"{ADAPTER.name}: identity 下标必须投影到宿主页"
            )
        if fallback_body.count(takeover_gate) != 1:
            violations.append(
                f"{ADAPTER.name}: identity 兜底只能在主路径未选中或同一 slot 时接管"
            )
        fallback_publish = (
            re.escape("group.anchorIdentity=projected;"),
            re.escape("group.anchorPage=global.fushiLookupPageOf(projected);"),
            re.escape("group.anchorIndex=resolved.index;"),
        )
        if not _matches_once_in_order(fallback_body, fallback_publish):
            violations.append(
                f"{ADAPTER.name}: identity 兜底必须原子发布宿主页同下标消息层"
            )
        # strength=2 是"这条绑定拿到了当前 current 的严格身份"这一事实的唯一记号，
        # 后面 Capture 用它决定弱 candidate 能不能顶掉强 binding。它只能在 page 与
        # 对象身份**同时**相等时置位。
        strong_gate = (
            "if(resolved.page==group.anchorPage&&resolved.identity===projected)"
        )
        strong_spans = _braced_spans_after(fallback_body, strong_gate)
        if len(strong_spans) != 1:
            violations.append(
                f"{ADAPTER.name}: strength=2 必须由 page + 对象身份双相等门守住"
            )
        else:
            strong_body = fallback_body[strong_spans[0][0] : strong_spans[0][1]]
            if not _matches_once_in_order(
                strong_body,
                (
                    re.escape("group.currentIdentity=resolved.identity;"),
                    re.escape("group.anchorStrength=2;"),
                ),
            ):
                violations.append(
                    f"{ADAPTER.name}: 严格身份命中必须同时记 currentIdentity 与 "
                    "strength=2"
                )

    if re.search(
        r"(?:\.width|\.height)(?:==|!=|<=|>=)|"
        r"(?:==|!=|<=|>=)[^;{}]{0,80}(?:\.width|\.height)",
        stamp,
    ):
        violations.append(f"{ADAPTER.name}: 锚点身份门不得比较消息层宽高")

    ordered = (
        stamp.find(host_page),
        stamp.find(messages_decl),
        current_num_decls[0].start() if len(current_num_decls) == 1 else -1,
        current_num_gates[0].start() if len(current_num_gates) == 1 else -1,
        stamp.find(resolved_decl),
        stamp.find(resolved_gate),
    )
    if any(index < 0 for index in ordered) or list(ordered) != sorted(ordered):
        violations.append(
            f"{ADAPTER.name}: 锚点必须按 hostPage→宿主页→currentNum→identity 兜底"
            "的顺序选择"
        )
    elif (
        len(current_num_spans) != 1
        or len(resolved_spans) != 1
        or not (current_num_spans[0][1] < ordered[4] < ordered[5])
        or not (
            _brace_depth_at(stamp, ordered[0])
            == _brace_depth_at(stamp, ordered[2])
            == _brace_depth_at(stamp, ordered[4])
        )
    ):
        violations.append(
            f"{ADAPTER.name}: currentNum 与 identity 兜底必须是同一层里互不嵌套的两级路径"
        )
    return violations


def find_invalid_common_root_coordinate_conversion(
    source: MaskedSource,
) -> list[str]:
    """守住字形层与 primaryLayer 之间的共同根坐标换算。

    fore/back 消息页可以是同一窗口根下的兄弟子树。只沿 `layer` 父链找 primary、或把
    `message.left/top` 直接当 primary 坐标，都会在换页后产生恒定偏移。这里钉的是完整
    数据契约：两条父链分别累加、同根才相减、所有失败都停止消费，以及 Probe 不复用旧的
    OffX/OffY。实现细节可以换行或加注释，但少一节就必须红。
    """
    violations: list[str] = []
    raw_segments = list(TJS_RAW_RE.finditer(source.text))
    if not raw_segments:
        return [f"{ADAPTER.name}: 没有找到 LR\"TJS(...)TJS\" bootstrap"]

    tjs = _joined_tjs_payload(source)
    computes = _assigned_tjs_functions(tjs, "fushiLookupComputeOffset")
    probes = _assigned_tjs_functions(tjs, "fushiLookupProbe")
    if len(computes) != 1:
        violations.append(
            f"{ADAPTER.name}: fushiLookupComputeOffset 定义数应为 1，实际 {len(computes)}"
        )
    if len(probes) != 1:
        violations.append(
            f"{ADAPTER.name}: fushiLookupProbe 定义数应为 1，实际 {len(probes)}"
        )
    if len(computes) != 1 or len(probes) != 1:
        return violations

    parameters, compute_body = computes[0]
    compute = _compact_tjs(compute_body)
    if _compact_tjs(parameters) != "layer":
        violations.append(f"{ADAPTER.name}: ComputeOffset 必须只接收 layer")

    required_once = {
        "varprimary=global.kag.primaryLayer;": "必须从 kag.primaryLayer 取得比较坐标系",
        "varlayerX=0,layerY=0;": "缺少 layer 绝对坐标累加器",
        "varlayerRoot=void;": "缺少 layer 根身份",
        "varcurrent=layer;": "第一条父链必须从 layer 开始",
        "varprimaryX=0,primaryY=0;": "缺少 primary 绝对坐标累加器",
        "varprimaryRoot=void;": "缺少 primary 根身份",
        "current=primary;": "第二条父链必须从 primary 开始",
        "global.fushiLookupOffX=layerX-primaryX;": "X 偏移必须是共同根绝对坐标之差",
        "global.fushiLookupOffY=layerY-primaryY;": "Y 偏移必须是共同根绝对坐标之差",
        "returntrue;": "成功路径必须显式返回 true",
    }
    for needle, message in required_once.items():
        count = compute.count(needle)
        if count != 1:
            violations.append(f"{ADAPTER.name}: {message}（出现 {count} 次）")

    chain_marker = "while(current!==void&&current!==null&&isvalidcurrent)"
    chain_spans = _braced_spans_after(compute, chain_marker)
    chains = [compute[start:end] for start, end in chain_spans]
    if len(chain_spans) != 2:
        violations.append(
            f"{ADAPTER.name}: layer/primary 必须各有一条受界父链，实际 {len(chains)} 条"
        )
    else:
        loop_guard = "if(++guard>32){global.fushiLookupMark(16);returnfalse;}"
        first_required = (
            loop_guard,
            "layerRoot=current;",
            "layerX+=current.left;",
            "layerY+=current.top;",
            "current=current.parent;",
        )
        second_required = (
            loop_guard,
            "primaryRoot=current;",
            "primaryX+=current.left;",
            "primaryY+=current.top;",
            "current=current.parent;",
        )
        for label, body, required in (
            ("layer", chains[0], first_required),
            ("primary", chains[1], second_required),
        ):
            for needle in required:
                if body.count(needle) != 1:
                    violations.append(
                        f"{ADAPTER.name}: {label} 父链缺失或重复 `{needle}`"
                    )

    root_gate = (
        "if(layerRoot===void||primaryRoot===void||layerRoot!==primaryRoot)"
        "{global.fushiLookupMark(16);returnfalse;}"
    )
    if compute.count(root_gate) != 1:
        violations.append(
            f"{ADAPTER.name}: 根缺失或根不同必须标记诊断并返回 false"
        )
    first_chain = compute.find(chain_marker)
    second_chain = compute.find(chain_marker, first_chain + len(chain_marker))
    first_chain_end = chain_spans[0][1] if len(chain_spans) == 2 else -1
    second_chain_end = chain_spans[1][1] if len(chain_spans) == 2 else -1
    layer_start = compute.find("varcurrent=layer;")
    primary_start = compute.find("current=primary;")
    root_gate_start = compute.find(root_gate)
    off_x_start = compute.find("global.fushiLookupOffX=layerX-primaryX;")
    off_y_start = compute.find("global.fushiLookupOffY=layerY-primaryY;")
    success_start = compute.rfind("returntrue;")
    if not (
        0
        <= layer_start
        < first_chain
        < first_chain_end
        < primary_start
        < second_chain
        < second_chain_end
        < root_gate_start
        < off_x_start
        < off_y_start
        < success_start
    ):
        violations.append(
            f"{ADAPTER.name}: 必须依次完成 layer/primary 父链、同根门、X/Y 差值和成功返回"
        )
    if not compute.endswith("returntrue;"):
        violations.append(f"{ADAPTER.name}: ComputeOffset 只能在全部校验和写入后成功返回")
    if compute.count("guard=0;") != 2 or not compute.startswith(
        "guard=0;", primary_start + len("current=primary;")
    ):
        violations.append(
            f"{ADAPTER.name}: primary 父链开始前必须把 32 层环保护计数归零"
        )

    _, probe_body = probes[0]
    probe = _compact_tjs(probe_body)
    checked_condition = "if(!global.fushiLookupComputeOffset(layer))"
    checked_index = probe.find(checked_condition)
    checked_end = checked_index + len(checked_condition)
    checked = False
    if checked_index >= 0 and probe.count(checked_condition) == 1:
        if probe.startswith("continue;", checked_end):
            checked = True
        elif probe.startswith("{", checked_end):
            bodies = _braced_bodies_after(probe, checked_condition)
            checked = (
                len(bodies) == 1
                and bodies[0].count("continue;") == 1
                and _ends_with_top_level_continue(bodies[0])
            )
    if not checked:
        violations.append(
            f"{ADAPTER.name}: Probe 必须检查 ComputeOffset 失败并跳过当前记录"
        )
    all_tjs = _compact_tjs(tjs.masked)
    if all_tjs.count("global.fushiLookupComputeOffset(layer)") != 1:
        violations.append(
            f"{ADAPTER.name}: ComputeOffset 只能由受检的 Probe 调用一次"
        )
    for needle, message in (
        (
            "rx=lx-global.fushiLookupOffX-entry.imgLeft-entry.originX;",
            "rx 必须消费共同根 X 偏移",
        ),
        (
            "ry=ly-global.fushiLookupOffY-entry.imgTop-entry.originY;",
            "ry 必须消费共同根 Y 偏移",
        ),
    ):
        if probe.count(needle) != 1:
            violations.append(f"{ADAPTER.name}: {message}")
    return violations


def _matches_once_in_order(text: str, patterns: tuple[str, ...]) -> bool:
    """每个正则必须唯一出现，且顺序与 patterns 相同。"""
    cursor = 0
    for pattern in patterns:
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1 or matches[0].start() < cursor:
            return False
        cursor = matches[0].end()
    return True


def find_invalid_lookup_entry_visibility_lifecycle(
    source: MaskedSource,
) -> list[str]:
    """守住完整 candidate 才发布的 slot/entry 生命周期与无侵入渲染包装。"""
    if not TJS_RAW_RE.search(source.text):
        return [f'{ADAPTER.name}: 没有找到 LR"TJS(...)TJS" bootstrap']

    violations: list[str] = []
    tjs = _joined_tjs_payload(source)
    required_functions = (
        "fushiLookupBootstrap",
        "fushiLookupAuditWrappers",
        "fushiLookupFindEntry",
        "fushiLookupEntryFor",
        "fushiLookupQueueHighlightErase",
        "fushiLookupFlushPendingHighlightErase",
        "fushiLookupClearEntryBinding",
        "fushiLookupRetireAnchorPeers",
        "fushiLookupFindSlot",
        "fushiLookupResolveCurrentSlot",
        "fushiLookupSlotFor",
        "fushiLookupAdoptSlot",
        "fushiLookupCurrentIdentityState",
        "fushiLookupCaptureTokenCurrent",
        "fushiLookupCapture",
        "fushiLookupFlushVisualWork",
        "fushiLookupBindOrigin",
        "fushiLookupProbe",
        "fushiLookupLeftClickHook",
        "fushiLookupMouseMoveHook",
    )
    functions: dict[str, str] = {}
    parameters: dict[str, str] = {}
    for name in required_functions:
        matches = _assigned_tjs_functions(tjs, name)
        if len(matches) != 1:
            violations.append(
                f"{ADAPTER.name}: {name} 定义数应为 1，实际 {len(matches)}"
            )
        else:
            parameters[name] = _compact_tjs(matches[0][0])
            functions[name] = _compact_tjs(matches[0][1])
    if len(functions) != len(required_functions):
        return violations

    joined = _compact_tjs(tjs.masked)

    def require_once(body: str, needle: str, message: str) -> None:
        count = body.count(needle)
        if count != 1:
            violations.append(
                f"{ADAPTER.name}: {message}（出现 {count} 次）"
            )

    bootstrap = _compact_tjs(
        _restore_tjs_literals(tjs, functions["fushiLookupBootstrap"])
    )
    # 两道门必须分开，且顺序固定：kag 无条件等；TextRender 只有**半就绪**（类在、方法
    # 没挂全）才等。把第二道并回第一道会让「完全没有 TextRender」的经典 KAG3 游戏在
    # bootstrap 开头就 return，KAGEX 缺席门的 else 分支随即变成永远走不到的死代码。
    readiness_gate = (
        'if(typeofglobal.kag!="Object"||global.kag===null||'
        'typeofglobal.kag.addHook!="Object")return;'
        'if(typeofglobal.TextRender=="Object"&&global.TextRender!==null&&'
        '(typeofglobal.TextRender.render!="Object"||'
        'typeofglobal.TextRender.done!="Object"||'
        'typeofglobal.TextRender.drawCh!="Object"))return;'
    )
    if not bootstrap.startswith(readiness_gate):
        violations.append(
            f"{ADAPTER.name}: bootstrap 必须先无条件等 kag，再单独等 TextRender "
            "render/done/drawCh 半就绪（TextRender 完全缺席时不得 return）"
        )

    install_stages = re.findall(r"installStage=(\d+);", bootstrap)
    expected_install_stages = [
        "0",
        "10",
        "11",
        "20",
        "21",
        "30",
        "31",
        # 35/36/37：私有 msgwin 插件出现后才封未来入口（getRender 桥）并扫既有
        # MsgwinRender。它不是通用 KiriKiri readiness，所以有自己的三段阶段号——真机上
        # 「卡在装桥还是卡在扫实例」必须分得开，合成一段就退回到只能靠改一版试一版。
        "35",
        "36",
        "37",
        "40",
        "41",
        "42",
        "43",
        "50",
    ]
    if install_stages != expected_install_stages:
        violations.append(
            f"{ADAPTER.name}: bootstrap installStage 必须固定为 "
            "0→10/11→20/21→30/31→35/36/37→40/41/42/43→50；"
            f"实际 {install_stages}"
        )

    for marker, message in (
        (
            "global.fushiLookupWrapperAuditPending=true;"
            "global.fushiLookupWrapperAuditLastState=-1;",
            "wrapper audit 必须初始化一次 mouseMove 启动基线并把 lastState 置 -1",
        ),
        # 给某个 renderer 实例打完补丁后必须重新置位：实例集合变了，上一次审计的
        # state 就不再代表现状。少了这一处，新实例的包装被游戏脚本覆写掉将永远不发诊断。
        (
            "patch.state=1;global.fushiLookupWrapperAuditPending=true;",
            "实例补丁装成后必须重新置位 audit，令下一次审计覆盖新实例",
        ),
    ):
        require_once(bootstrap, marker, message)

    audit = _compact_tjs(
        _restore_tjs_literals(tjs, functions["fushiLookupAuditWrappers"])
    )
    if parameters["fushiLookupAuditWrappers"] != "force":
        violations.append(
            f"{ADAPTER.name}: AuditWrappers 必须接收 force，区分一次性 hover 基线与点击复核"
        )
    audit_contract = (
        "if(!force&&!global.fushiLookupWrapperAuditPending)return;"
        "global.fushiLookupWrapperAuditPending=false;varstate=0;try{"
        'if(typeofglobal.TextRender!="Object"||global.TextRender===null)'
        "state=state|1;else{"
        'if(typeofglobal.TextRender.render!="Object")state=state|2;'
        "elseif(global.fushiLookupRenderInstallFailed||"
        "global.TextRender.render!==global.fushiLookupInstalledRenderWrapper)"
        "state=state|4;"
        'if(typeofglobal.TextRender.done!="Object")state=state|8;'
        "elseif(global.fushiLookupDoneInstallFailed||"
        "global.TextRender.done!==global.fushiLookupInstalledDoneWrapper)"
        "state=state|16;"
        'if(typeofglobal.TextRender.drawCh!="Object")state=state|32;'
        "elseif(global.fushiLookupDrawChInstallFailed||"
        "global.TextRender.drawCh!==global.fushiLookupInstalledDrawChWrapper)"
        "state=state|64;}"
        # 512/1024：私有 msgwin 插件的 getRender 入口没了，或被别人换掉。与 1..64 分开
        # 编码，因为它们是**两条独立的安装路径**——全局类补丁好着、实例入口坏了，症状同样
        # 是"没有卡片"，合成一位就分不出该去修哪条。
        "varplugin=global.fushiLookupResolveMsgwinPlugin();"
        "if(plugin!==void){"
        'if(typeofplugin.getRender!="Object")state=state|512;'
        "elseif(global.fushiLookupInstanceGetRenderInstallFailed||"
        "plugin!==global.fushiLookupInstanceGetRenderOwner||"
        "plugin.getRender!==global.fushiLookupInstanceGetRenderWrapper)"
        "state=state|1024;}"
        # 2048：已经打过补丁的 renderer 实例被游戏脚本覆写回去了。
        "varpatches=global.fushiLookupInstancePatches;"
        "for(varpi=0;pi<patches.count&&pi<16;pi++){"
        "varpatch=patches[pi];"
        "if(patch.state==1&&(patch.renderer.render!==patch.renderWrapper||"
        "patch.renderer.done!==patch.doneWrapper||"
        "patch.renderer.drawCh!==patch.drawChWrapper)){state=state|2048;break;}}"
        "}catch(e){state=state|128;}"
        "if(state!=global.fushiLookupWrapperAuditLastState){"
        "global.fushiLookupWrapperAuditLastState=state;"
        'global.fushiLookupNoteError("wrapper.identity",'
        '%[message:"state="+state]);}'
    )
    if audit != audit_contract:
        violations.append(
            f"{ADAPTER.name}: wrapper audit 必须保留固定 "
            "1/2/4/8/16/32/64/128/512/1024/2048 bitmask，"
            "且只在 lastState 变化时发布无内容 identity 诊断"
        )

    left_click = _compact_tjs(
        _restore_tjs_literals(tjs, functions["fushiLookupLeftClickHook"])
    )
    mouse_move = _compact_tjs(
        _restore_tjs_literals(tjs, functions["fushiLookupMouseMoveHook"])
    )
    # 人工点击是低频的，所以这里可以做有界的重活：先把 getRender 桥补上（游戏可能在
    # bootstrap 之后才加载 msgwin 插件），再扫一遍既有 renders[]（覆盖游戏直接替换
    # textRender 而没走 getRender 的路径），最后才审计。顺序固定：审计要看的是补完之后
    # 的现状，先审后补等于永远审的是上一帧。
    if not left_click.startswith(
        "try{global.fushiLookupInstallGetRenderBridge();"
        "global.fushiLookupSweepMsgwinRenders();"
        "global.fushiLookupAuditWrappers(true);"
    ) or left_click.count("global.fushiLookupAuditWrappers(true);") != 1:
        violations.append(
            f"{ADAPTER.name}: leftClick 必须每次先补 getRender 桥 + 扫 MsgwinRenders "
            "再 AuditWrappers(true)，低频复核后续脚本覆写"
        )
    if not mouse_move.startswith(
        "try{global.fushiLookupAuditWrappers(false);"
    ) or mouse_move.count("global.fushiLookupAuditWrappers(false);") != 1:
        violations.append(
            f"{ADAPTER.name}: mouseMove 只能先 AuditWrappers(false)，建立一次启动基线"
        )
    if bootstrap.count("global.fushiLookupAuditWrappers(true);") != 1 or bootstrap.count(
        "global.fushiLookupAuditWrappers(false);"
    ) != 1:
        violations.append(
            f"{ADAPTER.name}: wrapper audit 调用面只能是 leftClick(true) 与 mouseMove(false)"
        )

    wrapper_markers = (
        (
            "10",
            "global.fushiLookupOriginalRender=global.TextRender.render;",
            "global.TextRender.render=function(a,b,c,d,e,f)",
            "global.fushiLookupInstalledRenderWrapper=global.TextRender.render;",
            "global.fushiLookupRenderInstallFailed="
            "global.fushiLookupInstalledRenderWrapper==="
            "global.fushiLookupOriginalRender;",
            "11",
        ),
        (
            "20",
            "global.fushiLookupOriginalDone=global.TextRender.done;",
            "global.TextRender.done=function()",
            "global.fushiLookupInstalledDoneWrapper=global.TextRender.done;",
            "global.fushiLookupDoneInstallFailed="
            "global.fushiLookupInstalledDoneWrapper==="
            "global.fushiLookupOriginalDone;",
            "21",
        ),
        (
            "30",
            "global.fushiLookupOriginalDrawCh=global.TextRender.drawCh;",
            "global.TextRender.drawCh=function(layer,ox,oy,ch)",
            "global.fushiLookupInstalledDrawChWrapper=global.TextRender.drawCh;",
            "global.fushiLookupDrawChInstallFailed="
            "global.fushiLookupInstalledDrawChWrapper==="
            "global.fushiLookupOriginalDrawCh;",
            "31",
        ),
    )
    wrapper_ends: list[int] = []
    wrappers_complete = True
    for (
        stage_before,
        original_marker,
        wrapper_marker,
        installed_marker,
        install_failed_marker,
        stage_after,
    ) in wrapper_markers:
        before_positions = list(
            _iter_find(bootstrap, f"installStage={stage_before};")
        )
        original_positions = list(_iter_find(bootstrap, original_marker))
        wrapper_spans = _braced_spans_after(bootstrap, wrapper_marker)
        installed_positions = list(_iter_find(bootstrap, installed_marker))
        install_failed_positions = list(
            _iter_find(bootstrap, install_failed_marker)
        )
        after_positions = list(
            _iter_find(bootstrap, f"installStage={stage_after};")
        )
        if (
            len(before_positions) != 1
            or len(original_positions) != 1
            or len(wrapper_spans) != 1
            or len(installed_positions) != 1
            or len(install_failed_positions) != 1
            or len(after_positions) != 1
            or not (
                before_positions[0]
                < original_positions[0]
                < wrapper_spans[0][0]
                < wrapper_spans[0][1]
                < installed_positions[0]
                < install_failed_positions[0]
                < after_positions[0]
            )
        ):
            wrappers_complete = False
            continue
        wrapper_ends.append(wrapper_spans[0][1])

    staged_hooks = (
        re.escape("installStage=40;"),
        re.escape(
            'global.kag.addHook("leftClick",global.fushiLookupLeftClickHook);'
        ),
        re.escape("installStage=41;"),
        re.escape(
            'global.kag.addHook("mouseMove",global.fushiLookupMouseMoveHook);'
        ),
        re.escape("installStage=42;"),
        re.escape(
            'global.kag.addHook("onMouseWheelHook",'
            "global.fushiLookupMouseWheelHook);"
        ),
        re.escape("installStage=43;"),
        re.escape(
            'global.kag.addHook("keyDown",global.fushiLookupKeyDownHook);'
        ),
        re.escape("installStage=50;"),
    )
    if not _matches_once_in_order(bootstrap, staged_hooks):
        violations.append(
            f"{ADAPTER.name}: installStage 40→50 必须逐个包住 leftClick/mouseMove/"
            "wheel/keyDown hook 安装"
        )

    bootstrap_stage_note = (
        'global.fushiLookupNoteError("bootstrap.stage",'
        '%[message:"stage="+installStage]);'
    )
    require_once(
        bootstrap,
        bootstrap_stage_note,
        "bootstrap 安装失败必须只发布固定 stage，不得泄露异常内容",
    )

    remove_handler = (
        "System.removeContinuousHandler(global.fushiLookupBootstrap);"
    )
    remove_positions = list(_iter_find(bootstrap, remove_handler))
    clear_bootstrap = "global.fushiLookupBootstrap=void;"
    clear_positions = list(_iter_find(bootstrap, clear_bootstrap))
    # 生产函数有两条退休路径：完整安装后的 success path，以及安装中途抛错后的
    # fail-closed catch。后者不能删，否则下一帧在半包装状态重试，OriginalRender 可能
    # 指向上一层 wrapper 并形成递归。两条路径都必须先 remove 再 clear；catch 还必须在
    # 第二次 retirement 之前只发布固定 installStage。
    stage_50 = bootstrap.find("installStage=50;")
    stage_note = bootstrap.find(bootstrap_stage_note)
    if not (
        wrappers_complete
        and len(wrapper_ends) == len(wrapper_markers)
        and len(remove_positions) == 2
        and len(clear_positions) == len(remove_positions)
        and max(wrapper_ends) < stage_50 < remove_positions[0] < clear_positions[0]
        and clear_positions[0] < stage_note < remove_positions[1]
        < clear_positions[1]
        and all(
            remove_positions[index] < clear_positions[index]
            for index in range(len(remove_positions))
        )
    ):
        violations.append(
            f"{ADAPTER.name}: bootstrap success/catch 只能在 wrapper 与 staged hooks 后 "
            "fail-closed 移除 continuous handler"
        )

    if joined.count("global.fushiLookupSlots=[];") != 1:
        violations.append(
            f"{ADAPTER.name}: page/index slot ledger 必须唯一初始化"
        )
    if joined.count("global.fushiLookupRendererLease=0;") != 1:
        violations.append(
            f"{ADAPTER.name}: renderer lease 序列必须唯一初始化"
        )

    find_entry = functions["fushiLookupFindEntry"]
    require_once(
        find_entry,
        "if(registry[i].renderer===renderer&&registry[i].rendererLease>0)"
        "returnregistry[i];",
        "done/Capture 必须可 find-only 查询精确 renderer",
    )
    if "fushiLookupEntryFor" in find_entry or "registry.add" in find_entry:
        violations.append(
            f"{ADAPTER.name}: FindEntry 不得分配或复用 registry entry"
        )

    entry_for = functions["fushiLookupEntryFor"]
    for needle, message in (
        (
            "if(slots[si].activeEntry===candidate)",
            "Entry LRU 必须识别 slot.activeEntry",
        ),
        (
            "varvictim=(nonActiveInvalid>=0)?nonActiveInvalid:"
            "((nonActive>=0)?nonActive:"
            "((activeInvalid>=0)?activeInvalid:activeOldest));",
            "Entry LRU 必须优先淘汰 inactive，全部 active 后才退役 active",
        ),
        (
            "layer:void,visibleHost:void,currentIdentity:void",
            "entry 必须分开保存坐标 layer 与真实 visibleHost",
        ),
        (
            "renderEpoch:0,retiredRenderEpoch:0",
            "entry 必须初始化 render/retired epoch",
        ),
        (
            "rendererLease:++global.fushiLookupRendererLease",
            "fresh entry 必须取得单调 renderer lease",
        ),
    ):
        require_once(entry_for, needle, message)
    reused = entry_for.find("varreused=registry[victim];")
    revoke_reused = entry_for.find("reused.rendererLease=0;")
    clear_glyphs = entry_for.find("reused.glyphs=[];")
    clear_reused = entry_for.find(
        "global.fushiLookupClearEntryBinding(reused);"
    )
    publish_reused = entry_for.find("reused.renderer=renderer;")
    publish_lease = entry_for.find(
        "reused.rendererLease=++global.fushiLookupRendererLease;"
    )
    if not (
        0 <= reused < revoke_reused < clear_glyphs < clear_reused
        < publish_reused < publish_lease
    ):
        violations.append(
            f"{ADAPTER.name}: Entry LRU 必须先撤销 lease/清快照和 binding，再发布新 renderer lease"
        )
    for reset in (
        "reused.renderEpoch=0;",
        "reused.retiredRenderEpoch=0;",
    ):
        require_once(entry_for, reset, "Entry LRU 复用必须重置 render epoch")

    clear = functions["fushiLookupClearEntryBinding"]
    clear_patterns = (
        re.escape("if(global.fushiLookupHitEntry===entry)"),
        re.escape(
            "global.fushiLookupQueueHighlightErase("
            "global.fushiLookupHighlightRect);"
        ),
        re.escape("global.fushiLookupHitEntry=void;"),
        re.escape("entry.layer=void;"),
        re.escape("entry.visibleHost=void;"),
        re.escape("if(slots[si].activeEntry===entry)"),
        re.escape("slots[si].activeEntry=void;"),
    )
    if not _matches_once_in_order(clear, clear_patterns):
        violations.append(
            f"{ADAPTER.name}: ClearEntryBinding 必须擦除旧高亮并摘除 activeEntry"
        )
    if any(
        re.search(rf"entry\.{field}=(?!=)", clear)
        for field in ("logicalLine", "slotPage", "slotIndex", "slotGeneration")
    ):
        violations.append(
            f"{ADAPTER.name}: 清 binding 不得抹掉 entry 的 logical slot 身份"
        )

    retire = functions["fushiLookupRetireAnchorPeers"]
    retire_patterns = (
        re.escape("if(peer===entry)continue;"),
        re.escape(
            "if(peer.slotPage!=anchorPage||peer.slotIndex!=anchorIndex)continue;"
        ),
        re.escape("peer.glyphs=[];"),
        re.escape("global.fushiLookupClearEntryBinding(peer);"),
    )
    if not _matches_once_in_order(retire, retire_patterns):
        violations.append(
            f"{ADAPTER.name}: peer retirement 必须严格按 page/index 清快照"
        )
    require_once(
        retire,
        "peer.retiredRenderEpoch=peer.renderEpoch;",
        "peer retirement 必须封存已见 render epoch，阻止迟到 done 复活",
    )
    if "global.fushiLookupDismiss();" in retire:
        violations.append(
            f"{ADAPTER.name}: peer retirement 自身不得 dismiss"
        )

    find_slot = functions["fushiLookupFindSlot"]
    require_once(
        find_slot,
        "if(slots[i].page==page&&slots[i].index==index)returnslots[i];",
        "slot 必须使用严格 (page,index) 复合键",
    )

    resolve = functions["fushiLookupResolveCurrentSlot"]
    for needle, message in (
        (
            "varpages=[global.kag.fore.messages,global.kag.back.messages];",
            "current slot 必须搜索 fore/back message 数组",
        ),
        (
            "if(messages[i]===current)return%[page:p+1,index:i,identity:current];",
            "current slot 必须由严格对象身份解析",
        ),
    ):
        require_once(resolve, needle, message)
    if "currentNum" in resolve:
        violations.append(
            f"{ADAPTER.name}: ResolveCurrentSlot 不得把双缓冲复用的 currentNum 当身份"
        )

    slot_for = functions["fushiLookupSlotFor"]
    slot_lru_patterns = (
        re.escape("if(slots.count>=8)"),
        re.escape(
            "if(slots[i].activeEntry===void||slots[i].activeEntry===null)"
        ),
        re.escape(
            "varoldest=(oldestInactive>=0)?oldestInactive:oldestActive;"
        ),
        re.escape("retired.retiredRenderEpoch=retired.renderEpoch;"),
        re.escape("global.fushiLookupClearEntryBinding(retired);"),
        re.escape("slots.erase(oldest);"),
    )
    if not _matches_once_in_order(slot_for, slot_lru_patterns):
        violations.append(
            f"{ADAPTER.name}: Slot LRU 必须 inactive-first，且退役 active 时先清 binding"
        )

    adopt = functions["fushiLookupAdoptSlot"]
    if parameters["fushiLookupAdoptSlot"] != (
        "entry,line,page,index,identity,capturePhase"
    ):
        violations.append(
            f"{ADAPTER.name}: AdoptSlot 必须接收 capturePhase 并保持完整 candidate 参数"
        )
    detach_patterns = (
        re.escape("varallSlots=global.fushiLookupSlots;"),
        re.escape("if(other===slot)continue;"),
        re.escape("if(other.activeEntry===entry)"),
        re.escape("other.activeEntry=void;"),
    )
    advance_patterns = (
        re.escape("global.fushiLookupRetireAnchorPeers(entry,page,index);"),
        re.escape("slot.line=line;"),
        re.escape("slot.generation++;"),
        re.escape("slot.activeEntry=void;"),
        re.escape("advanced=true;"),
    )
    changed_bodies = _braced_bodies_after(adopt, "elseif(slot.line!=line)")
    changed_ok = (
        len(changed_bodies) == 1
        and _matches_once_in_order(changed_bodies[0], advance_patterns)
    )
    stale_epoch_gate = (
        "if(entry.slotPage==page&&entry.slotIndex==index&&"
        "entry.slotGeneration<slot.generation&&entry.logicalLine==line&&"
        "entry.renderEpoch<=entry.retiredRenderEpoch)"
        "return%[slot:slot,stale:true,same:false,advanced:false];"
    )
    if len(changed_bodies) != 1 or changed_bodies[0].count(stale_epoch_gate) != 1:
        violations.append(
            f"{ADAPTER.name}: 已退休 entry 只有新 render epoch 才能重取 slot；"
            "同世代迟到 done 必须 stale，fresh renderer 不得被误挡"
        )
    commit_patterns = (
        re.escape("entry.logicalLine=line;"),
        re.escape("entry.slotPage=page;"),
        re.escape("entry.slotIndex=index;"),
        re.escape("entry.slotGeneration=slot.generation;"),
    )
    if not _matches_once_in_order(adopt, detach_patterns):
        violations.append(
            f"{ADAPTER.name}: AdoptSlot 必须先把 entry 从其他 slot 的 active 链摘除"
        )
    if not changed_ok or not _matches_once_in_order(adopt, commit_patterns):
        violations.append(
            f"{ADAPTER.name}: 完整异句 candidate 必须原子退休 peer、推进 generation 后提交身份"
        )
    identity = functions["fushiLookupCurrentIdentityState"]
    identity_patterns = (
        re.escape(
            "varslot=global.fushiLookupFindSlot(entry.slotPage,entry.slotIndex);"
        ),
        re.escape(
            "if(slot===void||slot.generation!=entry.slotGeneration||"
            "slot.line!=entry.logicalLine||slot.activeEntry!==entry)return-1;"
        ),
        re.escape("if(resolved===void)return-1;"),
        re.escape(
            "if(resolved.page==entry.slotPage&&resolved.index==entry.slotIndex)"
        ),
        re.escape("returnresolved.identity===captured?1:-1;"),
    )
    if not (
        _matches_once_in_order(identity, identity_patterns)
        and identity.endswith("return0;")
    ):
        violations.append(
            f"{ADAPTER.name}: identity state 必须先验 active/generation；当前同 slot 严格比身份，"
            "其他共存 slot 回退 visibleHost"
        )

    capture = functions["fushiLookupCapture"]
    # expectedBindRevision 与 lease/epoch 同属"进入这次 Capture 时就冻结"的快照：
    # drawCh 在本次 render 之后还会继续绑新的原点组，用调用时刻的 global 版本号配对
    # 就会把下一句的绑定当成本句的。这个参数必须由调用方传进来，不能在函数里现取。
    if parameters["fushiLookupCapture"] != (
        "renderer,capturePhase,expectedLease,expectedRenderEpoch,expectedBindRevision"
    ):
        violations.append(
            f"{ADAPTER.name}: Capture 必须携 render/done 阶段与不可变 "
            "lease/epoch/bindRevision"
        )
    token = functions["fushiLookupCaptureTokenCurrent"]
    for needle, message in (
        (
            "global.fushiLookupFindEntry(renderer)===entry",
            "Capture token 必须复核 exact resident entry",
        ),
        (
            "entry.rendererLease==expectedLease",
            "Capture token 必须复核 renderer lease",
        ),
        (
            "entry.renderEpoch==expectedRenderEpoch",
            "Capture token 必须复核 render epoch",
        ),
        (
            "expectedRenderEpoch>entry.retiredRenderEpoch",
            "Capture token 必须拒绝退休世代",
        ),
    ):
        require_once(token, needle, message)
    if "fushiLookupEntryFor" in capture:
        violations.append(
            f"{ADAPTER.name}: Capture 不得分配 entry；evicted renderer 必须失败关闭"
        )
    token_gate = (
        "if(!global.fushiLookupCaptureTokenCurrent(entry,renderer,"
        "expectedLease,expectedRenderEpoch))return;"
    )
    token_positions = [m.start() for m in re.finditer(re.escape(token_gate), capture)]
    # getCharacters 可能是带私有 ObjThis 的 closure，再 incontextof 一次会把 this 换掉，
    # 所以取出来直接调用。锚点跟着实现走，别倒回去要求 incontextof。
    getter = capture.find("varcharacters=getCharacters(0,0);")
    adopt_call_position = capture.find(
        "slotAdoption=global.fushiLookupAdoptSlot(entry,line,"
    )
    clear_positions = [
        m.start()
        for m in re.finditer(
            re.escape("global.fushiLookupClearEntryBinding(entry);"), capture
        )
    ]
    fallback_start = capture.find("if(slotAdoption===void)")
    fallback_identity = capture.find("entry.logicalLine=line;", fallback_start)
    precommit = capture.find("entry.used=++global.fushiLookupClock;")
    retire_call_position = capture.find(
        "global.fushiLookupRetireAnchorPeers(entry,logicalSlot.page,logicalSlot.index);"
    )
    candidate_publish = capture.find("entry.glyphs=glyphs;", retire_call_position)
    # 九道门，一道也不能少。每道都紧跟在一次**可能重入渲染**的调用之后：Capture 里
    # 每次把控制权交回游戏代码（getCharacters、ResolveCurrentSlot、AdoptSlot），回来时
    # 这个 entry 都可能已经被另一次 render 复用（ABA），此时再往它身上写就是改错对象。
    # 第 3 道守的是 ResolveCurrentSlot 返回后写 entry.observed* 那一步——它和别的门一样
    # 不可省：observed 快照本身就是后面配对锚点的依据。
    token_order_ok = (
        len(token_positions) == 9
        and len(clear_positions) == 2
        and 0 <= token_positions[0] < getter < token_positions[1]
        < token_positions[2] < token_positions[3] < adopt_call_position
        < fallback_start < token_positions[4]
        < clear_positions[0] < token_positions[5] < fallback_identity
        < token_positions[6] < precommit < retire_call_position
        < token_positions[7] < candidate_publish < clear_positions[1]
        < token_positions[8]
    )
    if not token_order_ok:
        violations.append(
            f"{ADAPTER.name}: Capture 必须按 getter 前后、observed 快照前、Adopt 前、"
            "fallback 清理前后、Retire 前后和最终清理后保留 9 个有序 token 门"
        )

    clear_binding = functions["fushiLookupClearEntryBinding"]
    # `.visible=` 而不是 `.visible`：账本里合法地存着 `entry.visibleHost`，裸子串会把它
    # 当成"改了 Layer 可见性"报出来。禁的是**写**引擎的可见性，不是名字里带 visible。
    for forbidden in ("fillRect", ".visible=", ".update(", "fushiLookupDismiss"):
        if forbidden in clear_binding:
            violations.append(
                f"{ADAPTER.name}: ClearEntryBinding 必须是纯账本操作，禁止 Layer/Dismiss: {forbidden}"
            )
    require_once(
        clear_binding,
        "global.fushiLookupQueueHighlightErase(global.fushiLookupHighlightRect)",
        "ClearEntryBinding 必须把旧高亮排入有界 erase queue",
    )
    for helper_name in (
        "fushiLookupEntryFor",
        "fushiLookupRetireAnchorPeers",
        "fushiLookupSlotFor",
        "fushiLookupAdoptSlot",
    ):
        helper = functions[helper_name]
        for forbidden in ("fillRect", ".update(", "fushiLookupDismiss("):
            if forbidden in helper:
                violations.append(
                    f"{ADAPTER.name}: {helper_name} 事务内禁止视觉 Layer/Dismiss: {forbidden}"
                )

    queue_erase = functions["fushiLookupQueueHighlightErase"]
    for needle, message in (
        ("varpending=global.fushiLookupPendingHighlightEraseRect", "erase queue 必须读取既有矩形"),
        ("varleft=pending.x<rect.x?pending.x:rect.x", "erase queue 必须合并左边界"),
        ("varright=pendingRight>rectRight?pendingRight:rectRight", "erase queue 必须合并右边界"),
        ("varbottom=pendingBottom>rectBottom?pendingBottom:rectBottom", "erase queue 必须合并下边界"),
        ("global.fushiLookupPendingHighlightEraseSeq++", "pending highlight erase 必须用单调 seq 保护重入"),
    ):
        require_once(queue_erase, needle, message)
    flush_erase = functions["fushiLookupFlushPendingHighlightErase"]
    for needle, message in (
        ("if(global.fushiLookupHighlightFlushActive)returnfalse", "erase flush 必须防递归"),
        ("varcompleted=false", "erase flush 必须默认失败保留 pending"),
        ("highlight.fillRect(pending.x,pending.y,pending.w,pending.h,0)", "leaf flush 必须擦 pending union"),
        ("completed=true", "视觉操作完整成功后才可消费 pending"),
        ("if(completed&&global.fushiLookupPendingHighlightEraseSeq==seq)", "只可消费成功且未被重入更新的 pending erase"),
    ):
        require_once(flush_erase, needle, message)
    visual_flush = functions["fushiLookupFlushVisualWork"]
    for needle, message in (
        ("if(global.fushiLookupVisualFlushActive)returnfalse", "visual flush 必须防递归"),
        ("global.fushiLookupPendingVisualDismiss=false", "visual flush 必须先摘 pending dismiss"),
        ("global.fushiLookupFlushPendingHighlightErase()", "visual leaf 必须 drain erase"),
    ):
        require_once(visual_flush, needle, message)
    span_patterns = (
        re.escape("varglyphOriginSpanX=originMaxX-originMinX;"),
        re.escape("varglyphOriginSpanY=originMaxY-originMinY;"),
        re.escape(
            "varspanErrX=Math.abs((g.maxOx-g.minOx)-glyphOriginSpanX);"
        ),
        re.escape(
            "varspanErrY=Math.abs((g.maxOy-g.minOy)-glyphOriginSpanY);"
        ),
        re.escape(
            "if(spanErrX>toleranceX||spanErrY>toleranceY)continue;"
        ),
        # 可见性判据必须走 BindGroupVisible(g)，不能退回裸 `fushiLookupVisible(g.host)`：
        # drawCh 的逐字淡入宿主在角色口型/表情切换时会变 hidden，而 KAG message 仍在屏上。
        # 按短命 host 判，整句会在配音角色一说话就变成不可选。
        re.escape("if(!global.fushiLookupBindGroupVisible(g))continue;"),
    )
    if not _matches_once_in_order(capture, span_patterns):
        violations.append(
            f"{ADAPTER.name}: candidate 必须用字符原点跨度配对并要求真实宿主可见"
        )

    best_bodies = _braced_bodies_after(capture, "if(best!==void)")
    candidate_complete = False
    if len(best_bodies) == 1:
        best = best_bodies[0]
        candidate_complete = _matches_once_in_order(
            best,
            (
                re.escape(
                    "candidateLayer=(anchorMsg!==void&&isvalidanchorMsg)"
                    "?anchorMsg:best.host;"
                ),
                re.escape("candidateVisibleHost=best.host;"),
                re.escape("candidateAnchorPage=anchorPage;"),
                re.escape("candidateAnchorIndex=anchorIndex;"),
                re.escape("candidateReady=true;"),
            ),
        )
    if not candidate_complete:
        violations.append(
            f"{ADAPTER.name}: candidateReady 只能在 layer/visibleHost/page/index 全部形成后发布"
        )

    adopt_call = (
        "slotAdoption=global.fushiLookupAdoptSlot(entry,line,"
        "candidateAnchorPage,candidateAnchorIndex,candidateCurrentIdentity,"
        "capturePhase);"
    )
    candidate_ready = capture.find("candidateReady=true;")
    adoption = capture.find(adopt_call)
    if not (0 <= candidate_ready < adoption):
        violations.append(
            f"{ADAPTER.name}: slot adoption 必须晚于完整 candidate"
        )
    if "fushiLookupAdoptSlot(entry,line,resolvedCurrent." in capture:
        violations.append(
            f"{ADAPTER.name}: resolvedCurrent 只能作身份证据，不能在 candidate 前推进 slot"
        )
    if capture.count("if(slotAdoption.stale)return;") != 1:
        violations.append(
            f"{ADAPTER.name}: Capture 必须丢弃退休同世代的迟到 done"
        )

    fallback_bodies = _braced_bodies_after(capture, "if(slotAdoption===void)")
    fallback_ok = False
    if len(fallback_bodies) == 1:
        fallback = fallback_bodies[0]
        changed_bodies = _braced_bodies_after(fallback, "if(!entrySameLogical)")
        owned_patterns = (
            re.escape("if(entry.slotPage!=0&&entry.slotIndex>=0)"),
            re.escape(
                "varowned=global.fushiLookupFindSlot("
                "entry.slotPage,entry.slotIndex);"
            ),
            re.escape("if(owned!==void&&owned.activeEntry===entry)"),
            re.escape("owned.activeEntry=void;"),
            re.escape("owned.activeStrength=0;"),
            re.escape("global.fushiLookupClearEntryBinding(entry);"),
        )
        fallback_ok = (
            len(changed_bodies) == 1
            and _matches_once_in_order(changed_bodies[0], owned_patterns)
            and "entry.slotGeneration++;" in changed_bodies[0]
            and "global.fushiLookupDismiss();" not in fallback
            and "entry.retiredRenderEpoch=entry.renderEpoch;" not in fallback
        )
    if not fallback_ok or "global.fushiLookupDismiss();" in capture:
        violations.append(
            f"{ADAPTER.name}: 无 candidate 的新句只能清当前 entry，不得推进 slot 或 dismiss"
        )

    strength_map = (
        "candidateStrength=(candidateCurrentIdentity!==void)?2:"
        "((anchorKind!=0&&anchorPage!=0&&anchorIndex>=0)?1:0);"
    )
    same_entry_strength = (
        "if(candidateReady&&entrySameLogical&&entry.hasBase&&"
        "candidateStrength<entry.bindingStrength)candidateReady=false;"
    )
    stronger_renderer_gate = (
        "if(activeUsable&&candidateStrength<=logicalSlot.activeStrength)"
        "candidateReady=false;"
    )
    for needle, message in (
        (strength_map, "candidate strength 必须由 identity/slot/host 证据映射"),
        (
            same_entry_strength,
            "同 entry 同句的瞬时弱 candidate 不得降级既有 binding",
        ),
        (
            stronger_renderer_gate,
            "另一 renderer 的更强 candidate 必须可接管弱 active，"
            "同强/更弱仅在旧 active 不可用时接管",
        ),
    ):
        require_once(capture, needle, message)

    same_bodies = _braced_bodies_after(
        capture, "elseif(entrySameLogical&&entry.hasBase)"
    )
    same_ok = False
    if len(same_bodies) == 1:
        same = same_bodies[0]
        same_ok = (
            same.count("entry.glyphs=glyphs;") == 1
            and same.count("entry.line=line;") == 1
            and "fushiLookupClearEntryBinding" not in same
            and "entry.layer=" not in same
            and "entry.visibleHost=" not in same
            and "entry.currentIdentity=" not in same
        )
    if not same_ok:
        violations.append(
            f"{ADAPTER.name}: 同句无完整 candidate 时必须保留上一轮完整 binding"
        )

    candidate_bodies = _braced_bodies_after(capture, "if(candidateReady)")
    publish_ok = False
    if len(candidate_bodies) == 1:
        publish = candidate_bodies[0]
        publish_ok = _matches_once_in_order(
            publish,
            (
                re.escape(
                    "global.fushiLookupRetireAnchorPeers(entry,"
                    "logicalSlot.page,logicalSlot.index);"
                ),
                re.escape("entry.layer=candidateLayer;"),
                re.escape("entry.visibleHost=candidateVisibleHost;"),
                re.escape("entry.currentIdentity=candidateCurrentIdentity;"),
                re.escape("logicalSlot.activeEntry=entry;"),
            ),
        )
    if not publish_ok:
        violations.append(
            f"{ADAPTER.name}: 完整 candidate 必须原子写入 layer/visibleHost 并发布 activeEntry"
        )

    bind = functions["fushiLookupBindOrigin"]
    bind_patterns = (
        re.escape(
            "if(victimHost===void||victimHost===null||!isvalidvictimHost)"
        ),
        re.escape("if(groups[vi].clock<victimClock)"),
        re.escape("groups.erase(victim);"),
        # drawX/drawY 是**逐字**落点（ch.x/ch.y），不是 drawCh 传进来的共享行原点
        # ox/oy。用行原点判换行会把整行的最后一个字当成行起点，正是第一版包围盒恒不
        # 命中的成因；锚点必须跟着逐字落点走。
        re.escape("varyRewound=drawY<slot.lastOy-2;"),
        re.escape(
            "varreturnedTop=drawY<=slot.minOy+2&&drawX<slot.lastOx-2;"
        ),
        re.escape(
            "varnewRun=slot.count>0&&(yRewound||returnedTop);"
        ),
    )
    if not _matches_once_in_order(bind, bind_patterns):
        violations.append(
            f"{ADAPTER.name}: BindGroups 必须 invalid-first/LRU，且多行向下换行不能误重置跨度"
        )
    if "originY>slot.lastOy" in bind:
        violations.append(
            f"{ADAPTER.name}: 向下换行不得被当成新的绘制序列"
        )

    probe = functions["fushiLookupProbe"]
    if not probe.startswith("global.fushiLookupFlushVisualWork();"):
        violations.append(
            f"{ADAPTER.name}: Probe 必须在命中/绘制前作为事务外叶子 flush visual work"
        )
    probe_patterns = (
        re.escape("varlayer=entry.layer;"),
        re.escape("if(!global.fushiLookupComputeOffset(layer))"),
        re.escape(
            "varcurrentIdentityState="
            "global.fushiLookupCurrentIdentityState(entry);"
        ),
        # 可见性只能经 fushiLookupEntryVisible 这一个入口：它内部是「entry.layer 可见就算
        # 可见，否则回退 visibleHost」的固定顺序。把这两段拆开写在 Probe 里，顺序一错就是
        # 两类真机故障之一——先判短命 host 会让配音角色一说话整句变不可选（BUG-1631），
        # 而完全不看 layer 又会让没有 visibleHost 的经典 KAG3 采集面永远命不中。
        re.escape(
            "if(currentIdentityState<0||(currentIdentityState==0&&"
            "!global.fushiLookupEntryVisible(entry)))"
        ),
    )
    if not _matches_once_in_order(probe, probe_patterns):
        violations.append(
            f"{ADAPTER.name}: Probe 坐标必须走 layer；可见性必须走 "
            "identity/EntryVisible 共存语义"
        )
    for forbidden in (
        "global.fushiLookupVisible(layer)",
        "global.fushiLookupVisible(visibleHost)",
    ):
        if forbidden in probe:
            violations.append(
                f"{ADAPTER.name}: Probe 不得自行拼可见性判据，必须走 "
                f"EntryVisible: {forbidden}"
            )

    render_wrapper = (
        "varcaptureLease=0,captureEpoch=0;"
        "try{varepochEntry=global.fushiLookupEntryFor(this);"
        "epochEntry.renderEpoch++;captureLease=epochEntry.rendererLease;"
        "captureEpoch=epochEntry.renderEpoch;}"
        "catch(e){global.fushiLookupFault();}"
        "varresult=(global.fushiLookupOriginalRenderincontextofthis)(...);"
        "try{global.fushiLookupCapture(this,1,captureLease,captureEpoch);}"
        "catch(e){global.fushiLookupFault();}"
        "try{global.fushiLookupFlushVisualWork();}"
        "catch(e){global.fushiLookupFault();}returnresult;"
    )
    done_wrapper = (
        "vardoneLease=0,doneEpoch=0;"
        "try{vardoneEntry=global.fushiLookupFindEntry(this);"
        "if(doneEntry!==void){doneLease=doneEntry.rendererLease;"
        "doneEpoch=doneEntry.renderEpoch;}}"
        "catch(e){global.fushiLookupFault();}"
        "varresult=(global.fushiLookupOriginalDoneincontextofthis)(...);"
        "try{if(doneLease>0)global.fushiLookupCapture(this,2,doneLease,doneEpoch);}"
        "catch(e){global.fushiLookupFault();}"
        "try{global.fushiLookupFlushVisualWork();}"
        "catch(e){global.fushiLookupFault();}returnresult;"
    )
    require_once(
        joined,
        render_wrapper,
        "TextRender.render 的 epoch 账本必须 catch 隔离；原函数必须先于 Capture(1)",
    )
    require_once(
        joined,
        done_wrapper,
        "TextRender.done 必须 original-first，且仅调用 Capture(2)",
    )
    return violations


def _strip_line_comments(text: str) -> str:
    """去掉 `//` 行注释，长度不变（换成空格）。

    判据必须落在**可执行代码**上：注释里写一句"归属见 fushiLookupCardEntry"不该让守卫
    转绿，否则改坏判据只要留着注释就能蒙混过去。
    """
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def _tjs_function_body(text: str, name: str) -> tuple[int, int] | None:
    """TJS `global.<name> = function(...) { ... }` 的函数体区间（含两端大括号）。"""
    match = re.search(rf"global\.{re.escape(name)}\s*=\s*function", text)
    if match is None:
        return None
    start = text.find("{", match.end())
    if start < 0:
        return None
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return (start, index + 1)
    return None


# 收卡归属：卡片是在 fushiLookupApply 那一刻绑到某条 entry 上的，只有**那条**台词重绘
# 才轮得到收卡。窗口取得比一条 if 语句宽一些（判据可能写成多行），但必须在去注释后的
# 文本上找。
CARD_OWNER_MARKER = "fushiLookupCardEntry"
_CARD_OWNER_WINDOW = 300


def find_ownerless_card_dismissals(source: MaskedSource) -> list[str]:
    """`fushiLookupCapture` 里的收卡必须带归属判据（BUG-1606）。

    捕获回调对**每一个** TextRender renderer 触发：名字层、第二消息层、选项层、历史层
    都会走进来。旧判据是「这个 renderer 上的行文本变了就收卡」，于是同一句里说话人切换
    时另一个文本层逐字重绘，每多一个字就把用户正在读的查词卡片打掉一次（鼠标一动 hover
    又把它拉回来）——表现就是卡片反复闪没。归属判据是这条路径上唯一的关卡：真正的换行
    由 host 侧「会话最新行变了」兜底，与这里是哪个 renderer 无关。
    """
    span = _tjs_function_body(source.text, "fushiLookupCapture")
    if span is None:
        return [f"{ADAPTER.name} 找不到 TJS 的 fushiLookupCapture 函数体"]
    body = _strip_line_comments(source.text[span[0] : span[1]])
    offenders: list[str] = []
    for index in _iter_find(body, "fushiLookupDismiss("):
        window = body[max(0, index - _CARD_OWNER_WINDOW) : index]
        if CARD_OWNER_MARKER in window:
            continue
        offenders.append(
            f"{ADAPTER.name}:{source.line_of(span[0] + index)} "
            f"收卡处附近没有 {CARD_OWNER_MARKER} 归属判据"
        )
    return offenders


# ── BUG-1724：安装路径的线程归属 ────────────────────────────────────────────
#
# KiriKiri 的 TJS 变体字符串池、连续事件回调容器、图层树和绘制设备全部只归引擎主线程，
# 没有任何内部同步，而主线程每一帧都在遍历/分配它们。整个安装动作原本跑在 HookWorker
# 上（HookWorker -> registry.Poll -> ProcessKirikiriVoiceTasks ->
# PollKirikiriLookupInstall），于是 worker 的 TJSAllocVariantString /
# TVPAddContinuousEventHook 与主线程并发。真机表现是随机时刻在引擎内部虚调用一个读成
# NULL 的成员指针（实测落点 tTVPBasicDrawDevice），游戏弹 "Fatal Error / Access
# Violation"；带 hook 9 次复现 1 次，同样的窗口缩放序列不带 hook 5 次 0 崩。
#
# 守两条结构不变式（都是行为，不是写法）：
#   1. worker 侧入口 `void PollKirikiriLookupInstall() ` 的函数体里一个引擎调用都不许有；
#   2. `void RunKirikiriLookupInstallOnMainThread() ` 里，第一个引擎调用必须排在线程身份
#      核对（`GetCurrentThreadId()`）之后——顺序反了等于没守。
WORKER_INSTALL_ENTRY = "void PollKirikiriLookupInstall() "
MAIN_THREAD_INSTALL_ENTRY = "void RunKirikiriLookupInstallOnMainThread() "
MAIN_THREAD_ID_CALL = "GetCurrentThreadId()"
MAIN_THREAD_RESOLVER = "ResolveKirikiriEngineMainThreadId("

# 「调进引擎」的动作。出现在 worker 入口里即红；出现在主线程安装里必须排在身份核对之后。
ENGINE_CALLS = (
    "g_lookup_alloc_string(",
    "g_lookup_add_continuous(",
    "g_lookup_remove_continuous(",
    "g_lookup_execute_script(",
    "g_lookup_execute_expression(",
    "QueryKirikiriNativeLookupFunctions(",
)


def _cpp_function_body(source: MaskedSource, signature: str) -> str | None:
    """取 C++ 函数体（在掩码后的源码上找，注释/字面量已被抠成空白）。"""
    index = source.masked.find(signature)
    if index < 0:
        return None
    open_index = index + len(signature)
    if open_index >= len(source.masked) or source.masked[open_index] != "{":
        return None
    depth = 0
    for cursor in range(open_index, len(source.masked)):
        char = source.masked[cursor]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source.masked[open_index + 1 : cursor]
    return None


def find_engine_calls_on_hook_worker(source: MaskedSource) -> list[str]:
    body = _cpp_function_body(source, WORKER_INSTALL_ENTRY)
    if body is None:
        return [f"找不到 worker 侧入口 {WORKER_INSTALL_ENTRY.strip()}"]
    return [
        f"{WORKER_INSTALL_ENTRY.strip()} 里出现引擎调用 {call}"
        for call in ENGINE_CALLS
        if call in body
    ]


def find_missing_main_thread_identity_check(source: MaskedSource) -> list[str]:
    body = _cpp_function_body(source, MAIN_THREAD_INSTALL_ENTRY)
    if body is None:
        return [f"找不到主线程安装入口 {MAIN_THREAD_INSTALL_ENTRY.strip()}"]
    offenders: list[str] = []
    if MAIN_THREAD_RESOLVER not in body:
        offenders.append(f"主线程安装里没有解析引擎主线程（{MAIN_THREAD_RESOLVER}）")
    guard_at = body.find(MAIN_THREAD_ID_CALL)
    if guard_at < 0:
        offenders.append(f"主线程安装里没有线程身份核对（{MAIN_THREAD_ID_CALL}）")
    call_positions = [body.find(call) for call in ENGINE_CALLS]
    first_call = min((pos for pos in call_positions if pos >= 0), default=-1)
    if guard_at >= 0 and first_call >= 0 and first_call < guard_at:
        offenders.append("引擎调用排在线程身份核对之前")
    return offenders


# 规则 7：「哪个才是游戏主窗口」只能有一套答案。
#
# ResolveKirikiriEngineMainThreadId 曾经自带一份 EnumWindows：取**第一个**可见、无 owner
# 的顶层窗口就收工；而同一编译单元里 lookup_overlay_window.inc 的 FindOverlayOwner 对同
# 一问题取的是**客户区面积最大**的那个（注释写着「启动器/工具窗口都比它小」）。两套判据
# 里第一个匹配那套是错的：进程里只要还有另一个可见无 owner 顶层窗口且属于别的线程（TVP
# 控制台窗、splash、同进程启动器窗，或本模块自己那个 1x1 的 WS_EX_TOPMOST
# FushiLookupOverlay —— EnumWindows 会**先**枚举到它），就会把那个线程 id 当引擎主线程
# 缓存下来。缓存是 InterlockedCompareExchange(..., 0) 的一次性写入，写错**永不自愈**，
# 此后 GetCurrentThreadId() != main_tid 恒真，传感器静默永不安装 —— 症状与「这个引擎不
# 支持」完全同形。
MAIN_THREAD_RESOLVER_ENTRY = "DWORD ResolveKirikiriEngineMainThreadId() "
SHARED_MAIN_WINDOW_FN = "FindGameMainWindow("
OVERLAY_WINDOW_INC = ROOT / "hook" / "lookup_overlay_window.inc"


def find_divergent_main_window_criteria(source: MaskedSource) -> list[str]:
    body = _cpp_function_body(source, MAIN_THREAD_RESOLVER_ENTRY)
    if body is None:
        return [f"找不到 {MAIN_THREAD_RESOLVER_ENTRY.strip()}"]
    offenders: list[str] = []
    if "EnumWindows(" in body:
        offenders.append(
            "ResolveKirikiriEngineMainThreadId 自带一份 EnumWindows 判据："
            "游戏主窗口的判据必须只有一套（FindGameMainWindow）"
        )
    if SHARED_MAIN_WINDOW_FN not in body:
        offenders.append(
            "ResolveKirikiriEngineMainThreadId 没有复用 FindGameMainWindow()："
            "同概念两套答案，其中一套必然与另一套不一致"
        )
    return offenders


def find_unshared_main_window_area_criterion(overlay_source: str) -> list[str]:
    """共享的那套判据本身必须是「面积最大」，否则统一了也是统一到错的那套。"""
    text = _strip_line_comments(overlay_source)
    if "HWND FindGameMainWindow(" not in text:
        return ["lookup_overlay_window.inc 里没有 FindGameMainWindow()"]
    offenders: list[str] = []
    if not re.search(r"\bbest_area\b", text):
        offenders.append(
            "FindOverlayOwner 不再按客户区面积挑选：启动器/工具窗口/1x1 overlay "
            "会被当成游戏主窗口"
        )
    if not re.search(r"IsWindowVisible\s*\(", text):
        offenders.append("FindOverlayOwner 少了可见性判据")
    if not re.search(r"GW_OWNER", text):
        offenders.append("FindOverlayOwner 少了顶层（无 owner）判据")
    return offenders


# ── 扫真文件 ────────────────────────────────────────────────────────────────


class RealAdapterTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = MaskedSource(ADAPTER.read_text(encoding="utf-8"))

    def test_tjs_literals_fit_msvc_wide_string_limit(self) -> None:
        self.assertEqual([], find_oversized_tjs_literals(self.source))

    def test_install_never_calls_engine_from_hook_worker(self) -> None:
        self.assertEqual(
            [],
            find_engine_calls_on_hook_worker(self.source),
            "PollKirikiriLookupInstall 跑在 HookWorker 上，里面不能有任何引擎调用："
            "KiriKiri 的 TJS 堆与连续事件回调容器只归主线程 (BUG-1724)",
        )

    def test_main_thread_install_checks_thread_identity_first(self) -> None:
        self.assertEqual(
            [],
            find_missing_main_thread_identity_check(self.source),
            "RunKirikiriLookupInstallOnMainThread 必须先核对线程身份再碰引擎；"
            "引擎也会在后台线程开流，只靠'在 detour 里'不足以断定主线程 (BUG-1724)",
        )

    def test_main_thread_resolver_reuses_the_shared_main_window_criteria(self) -> None:
        self.assertEqual(
            [],
            find_divergent_main_window_criteria(self.source),
            "ResolveKirikiriEngineMainThreadId 必须复用 FindGameMainWindow()："
            "自带一份「EnumWindows 第一个可见无 owner 顶层窗口」会把 TVP 控制台窗/"
            "splash/1x1 的 FushiLookupOverlay 的线程 id 永久缓存成引擎主线程，"
            "此后传感器静默永不安装",
        )

    def test_shared_main_window_lookup_still_uses_the_area_criterion(self) -> None:
        self.assertEqual(
            [],
            find_unshared_main_window_area_criterion(
                OVERLAY_WINDOW_INC.read_text(encoding="utf-8")
            ),
            "统一到 FindGameMainWindow 之后，它本身的「可见 + 无 owner + 面积最大」"
            "判据就是唯一真相源，不能被悄悄改成第一个匹配",
        )

    def test_never_builds_tjs_source_from_dynamic_strings(self) -> None:
        self.assertEqual(
            [],
            find_dynamic_tjs_concatenations(self.source),
            "传给 TVPExecuteScript 的 TJS 文本只能由字面量 + std::to_wstring(整数) 构成；"
            "任何运行期字符串拼进去都等于在游戏进程里开一个 eval 注入面。",
        )

    def test_has_no_http_client_or_credentials(self) -> None:
        self.assertEqual(
            [],
            find_network_debris(self.source),
            "游戏进程里不得有 HTTP 客户端或认证凭据；开关与 BGRA 数据一律走 v14 共享内存查词区。",
        )

    def test_does_not_monkey_patch_engine_globals_outside_the_probe_branch(
        self,
    ) -> None:
        self.assertEqual(
            [],
            find_global_monkey_patches(self.source),
            "global.Layer.drawText / global.MessageLayer.processCh 的全局补丁已被运行"
            "日志证伪（只有 TextRender 命中）；挂在全局类上会让游戏所有 UI 绘制多绕一层，"
            "游戏内渲染下直接掉帧。只允许留在默认关闭的探测分支里。",
        )

    def test_probe_branch_is_off_by_default(self) -> None:
        self.assertEqual(
            [],
            find_default_on_probe_switches(self.source),
            "探测分支被允许存在的唯一前提是它默认不跑；开关默认打开等于全局补丁常驻。",
        )

    def test_placeholder_values_pass_the_character_class_check(self) -> None:
        self.assertEqual(
            [],
            find_unvalidated_placeholder_values(self.source),
            "填进 TJS bootstrap 的运行期值（PNG 备路的卡片路径）必须先被拒掉引号/反斜杠/"
            "换行；绕开那道校验直接赋值等于把 eval 注入面重新打开。",
        )

    def test_bitmap_copy_sites_are_guarded_by_the_frame_sanity_check(self) -> None:
        self.assertEqual(
            [],
            find_unguarded_bitmap_copies(self.source),
            "读写查词位图缓冲之前必须先过 IsLookupFrameSane —— 它是「按跨进程不可信的 "
            "width/height 盲拷」这条越界写路径上的唯一闸门。",
        )

    def test_glyph_coordinates_use_a_bounded_common_root_conversion(self) -> None:
        self.assertEqual(
            [],
            find_invalid_common_root_coordinate_conversion(self.source),
            "字形层和 primaryLayer 可能位于共同窗口根下的兄弟子树；必须分别累加到同一根"
            "后相减，任一父链失败都要停止命中计算，不能复用旧的 OffX/OffY。",
        )

    def test_kag_anchor_uses_host_page_identity_and_priority(self) -> None:
        self.assertEqual(
            [],
            find_invalid_kag_anchor_identity_selection(self.source),
            "KAG 消息层必须按 hostPage 下的 currentNum→对象 identity 下标兜底选择；"
            "禁止 pages=[fore,back] 跨页按尺寸首个命中。",
        )

    def test_lookup_slot_ledger_publishes_only_complete_candidates(self) -> None:
        self.assertEqual(
            [],
            find_invalid_lookup_entry_visibility_lifecycle(self.source),
            "page/index ledger 只能在完整 candidate 后提交；无 candidate 不推进/不 dismiss，"
            "同句保留 binding，Probe 只接受当前 generation 的 activeEntry。",
        )

    def test_card_dismissal_is_scoped_to_the_owning_line(self) -> None:
        self.assertEqual(
            [],
            find_ownerless_card_dismissals(self.source),
            "fushiLookupCapture 对每个 TextRender renderer 都触发（名字层 / 第二消息层 / "
            "选项层 / 历史层都在内）；收卡必须只认卡片自己依附的那条台词，否则说话人切换"
            "时另一个文本层逐字重绘会把用户正在读的卡片反复打掉（BUG-1606）。",
        )


# ── 变异自测：证明上面每条规则真的会红 ──────────────────────────────────────

CLEAN_SAMPLE = """
// 整数回执：唯一允许的形态。
void QueueLookupApply(uint64_t seq, uint32_t start, uint32_t length) {
  std::wstring script = L"if(typeof global.fushiLookupApply!=\\"undefined\\") "
                        L"global.fushiLookupApply(";
  script += std::to_wstring(seq) + L"," + std::to_wstring(start) + L"," +
            std::to_wstring(length) + L");";
  g_lookup_pending_script = std::move(script);
}

bool CopyLookupFrame(SharedHeader* header, uint32_t index,
                     uint8_t* target) {
  const LookupFrame* frame = LookupFrameAt(header, index);
  if (!IsLookupFrameSane(header, frame)) return false;
  const uint8_t* pixels = LookupBitmapAt(header, index);
  memcpy(target, pixels, frame->byte_len);
  return true;
}

// 与 TJS 无关的字符串拼接不该被误伤。
std::wstring TempPath(const std::wstring& dir, const std::wstring& name) {
  return dir + name + L".png";
}

constexpr bool kProbePaths = false;

std::wstring g_lookup_card_path;

// PNG 备路要把 %TEMP% 下的卡片路径交给 TJS 的 loadImages：唯一一处进 bootstrap 的运行期
// 数据，防线就是这道字符类拒绝。
bool SetLookupCardPath(const std::wstring& path) {
  if (path.find_first_of(kForbiddenPathChars) != std::wstring::npos) return false;
  g_lookup_card_path = path;
  return true;
}

std::wstring BuildBootstrap() {
  std::wstring script = kBootstrap;
  ReplaceLookupPlaceholder(script, L"__FUSHI_PROBE_MODE__",
                           kProbePaths ? L"1" : L"0");
  ReplaceLookupPlaceholder(script, L"__FUSHI_CARD_PATH__", g_lookup_card_path);
  return script;
}

// 默认关闭的探测分支：全局补丁只允许活在这里。
static const wchar_t kBootstrap[] = LR"TJS(
if(global.fushiLookupProbeMode)
{
	global.fushiLookupProbeOriginalDrawText = global.Layer.drawText;
	global.Layer.drawText = function(x, y, text) { return 0; };
}
if(typeof global.TextRender == "Object")
{
	global.TextRender.render = function() { return 0; };
}
else
{
	global.fushiLookupOriginalDrawText = global.Layer.drawText;
	global.Layer.drawText = function(x, y, text) { return 0; };
}
global.fushiLookupCapture = function(renderer)
{
    var entry = global.fushiLookupEntryFor(renderer);
    var changed = entry.line != renderer.line;
    entry.line = renderer.line;
    if(changed)
    {
        if(global.fushiLookupCardEntry === entry) global.fushiLookupDismiss();
        else if(global.fushiLookupHitEntry === entry) global.fushiLookupClearHover();
    }
};
)TJS";
"""

# 干净样本里那条带归属的收卡判据（变异自测的锚点）。
OWNED_DISMISS_SAMPLE = (
    "        if(global.fushiLookupCardEntry === entry) global.fushiLookupDismiss();\n"
    "        else if(global.fushiLookupHitEntry === entry) "
    "global.fushiLookupClearHover();"
)


# 故意拆成两个相邻 raw literal：生产 bootstrap 也是这样拼出来的。共同根守卫若错误地扫
# C++ 的 masked 文本，或只看某一段 raw literal，这个 clean 样本就无法通过。
COORDINATE_CLEAN_SAMPLE = r'''
static const wchar_t kCoordinateBootstrap[] = LR"TJS(
global.fushiLookupComputeOffset = function(layer)
{
  var primary = global.kag.primaryLayer;
  var layerX = 0, layerY = 0;
  var layerRoot = void;
  var current = layer;
  var guard = 0;
  while(current !== void && current !== null && isvalid current)
  {
    if(++guard > 32)
    {
      global.fushiLookupMark(16);
      return false;
    }
    layerRoot = current;
    layerX += current.left;
    layerY += current.top;
    current = current.parent;
  }

  var primaryX = 0, primaryY = 0;
  var primaryRoot = void;
)TJS" LR"TJS(
  current = primary;
  guard = 0;
  while(current !== void && current !== null && isvalid current)
  {
    if(++guard > 32)
    {
      global.fushiLookupMark(16);
      return false;
    }
    primaryRoot = current;
    primaryX += current.left;
    primaryY += current.top;
    current = current.parent;
  }

  if(layerRoot === void || primaryRoot === void ||
    layerRoot !== primaryRoot)
  {
    global.fushiLookupMark(16);
    return false;
  }
  global.fushiLookupOffX = layerX - primaryX;
  global.fushiLookupOffY = layerY - primaryY;
  return true;
};

global.fushiLookupProbe = function(submit)
{
  var lx = global.kag.primaryLayer.cursorX;
  var ly = global.kag.primaryLayer.cursorY;
  var layer = global.fushiLookupHitEntry.layer;
  var entry = global.fushiLookupHitEntry;
  for(var i = 0; i < 1; i++)
  {
    var rx = 0;
    var ry = 0;
    if(!global.fushiLookupComputeOffset(layer))
    {
      global.fushiLookupMark(32);
      continue;
    }
    rx = lx - global.fushiLookupOffX - entry.imgLeft - entry.originX;
    ry = ly - global.fushiLookupOffY - entry.imgTop - entry.originY;
  }
};
)TJS";
'''


# 生产锚点选择位于 fushiLookupCapture 内，且与其它 bootstrap 一样可能被分成
# 相邻 raw literal。clean 样本保留这个形状，防止守卫退回去扫 C++ masked 文本。
ANCHOR_IDENTITY_CLEAN_SAMPLE = r'''
static const wchar_t kAnchorBootstrap[] = LR"TJS(
global.fushiLookupStampBindGroup = function(group, host)
{
  group.hostPage = global.fushiLookupPageOf(host);
  group.anchorPage = 0;
  group.anchorIndex = -1;
  group.anchorIdentity = void;
  group.currentIdentity = void;
  group.anchorStrength = 0;
  var messages = global.fushiLookupMessagesForPage(group.hostPage);
  var currentNum = global.fushiLookupField(global.kag, "currentNum");
  if(messages !== void && typeof currentNum == "Integer" &&
    currentNum >= 0 && currentNum < messages.count)
  {
    try
    {
      var indexed = messages[currentNum];
      if(indexed !== void && indexed !== null && isvalid indexed)
      {
        group.anchorIdentity = indexed;
        group.anchorPage = global.fushiLookupPageOf(indexed);
        group.anchorIndex = currentNum;
        group.anchorStrength = 1;
      }
    }
    catch(e) {}
  }
)TJS" LR"TJS(
  var resolved = global.fushiLookupResolveCurrentSlot();
  if(resolved !== void && messages !== void && resolved.index >= 0 &&
    resolved.index < messages.count)
  {
    try
    {
      var projected = messages[resolved.index];
      if(projected !== void && projected !== null && isvalid projected &&
        (group.anchorIdentity === void ||
         (resolved.page == group.anchorPage &&
          resolved.index == group.anchorIndex)))
      {
        group.anchorIdentity = projected;
        group.anchorPage = global.fushiLookupPageOf(projected);
        group.anchorIndex = resolved.index;
        if(resolved.page == group.anchorPage &&
          resolved.identity === projected)
        {
          group.currentIdentity = resolved.identity;
          group.anchorStrength = 2;
        }
      }
    }
    catch(e) {}
  }
};

global.fushiLookupCapture = function(renderer, capturePhase,
  expectedLease, expectedRenderEpoch, expectedBindRevision)
{
  var entry = global.fushiLookupFindEntry(renderer);
  entry.layer = best.anchorIdentity;
  entry.hostPage = best.hostPage;
};
)TJS";
'''


# page/index slot ledger 的完整 candidate 提交边界、active entry 与可见性生命周期。生产
# bootstrap 里的函数跨越多个 raw literal，clean 样本也保留拼接形状。
ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE = r'''
static const wchar_t kEntryBootstrap[] = LR"TJS(
global.fushiLookupBootstrap = function(tick)
{
  if(typeof global.kag != "Object" || global.kag === null ||
    typeof global.kag.addHook != "Object") return;
  if(typeof global.TextRender == "Object" && global.TextRender !== null &&
    (typeof global.TextRender.render != "Object" ||
    typeof global.TextRender.done != "Object" ||
    typeof global.TextRender.drawCh != "Object")) return;
var installStage = 0;
try
{
global.fushiLookupSlots = [];
global.fushiLookupRendererLease = 0;
global.fushiLookupPendingHighlightEraseRect = void;
global.fushiLookupPendingHighlightEraseSeq = 0;
global.fushiLookupHighlightFlushActive = false;
global.fushiLookupPendingVisualDismiss = false;
global.fushiLookupVisualFlushActive = false;
global.fushiLookupWrapperAuditPending = true;
global.fushiLookupWrapperAuditLastState = -1;

global.fushiLookupAuditWrappers = function(force)
{
  if(!force && !global.fushiLookupWrapperAuditPending) return;
  global.fushiLookupWrapperAuditPending = false;
  var state = 0;
  try
  {
    if(typeof global.TextRender != "Object" || global.TextRender === null)
      state = state | 1;
    else
    {
      if(typeof global.TextRender.render != "Object") state = state | 2;
      else if(global.fushiLookupRenderInstallFailed ||
        global.TextRender.render !== global.fushiLookupInstalledRenderWrapper)
        state = state | 4;
      if(typeof global.TextRender.done != "Object") state = state | 8;
      else if(global.fushiLookupDoneInstallFailed ||
        global.TextRender.done !== global.fushiLookupInstalledDoneWrapper)
        state = state | 16;
      if(typeof global.TextRender.drawCh != "Object") state = state | 32;
      else if(global.fushiLookupDrawChInstallFailed ||
        global.TextRender.drawCh !== global.fushiLookupInstalledDrawChWrapper)
        state = state | 64;
    }
    var plugin = global.fushiLookupResolveMsgwinPlugin();
    if(plugin !== void)
    {
      if(typeof plugin.getRender != "Object") state = state | 512;
      else if(global.fushiLookupInstanceGetRenderInstallFailed ||
        plugin !== global.fushiLookupInstanceGetRenderOwner ||
        plugin.getRender !== global.fushiLookupInstanceGetRenderWrapper)
        state = state | 1024;
    }
    var patches = global.fushiLookupInstancePatches;
    for(var pi = 0; pi < patches.count && pi < 16; pi++)
    {
      var patch = patches[pi];
      if(patch.state == 1 && (patch.renderer.render !== patch.renderWrapper ||
        patch.renderer.done !== patch.doneWrapper ||
        patch.renderer.drawCh !== patch.drawChWrapper))
      {
        state = state | 2048;
        break;
      }
    }
  }
  catch(e) { state = state | 128; }
  if(state != global.fushiLookupWrapperAuditLastState)
  {
    global.fushiLookupWrapperAuditLastState = state;
    global.fushiLookupNoteError("wrapper.identity", %[message: "state=" + state]);
  }
};

global.fushiLookupFindEntry = function(renderer)
{
  var registry = global.fushiLookupRegistry;
  for(var i = 0; i < registry.count; i++)
    if(registry[i].renderer === renderer && registry[i].rendererLease > 0)
      return registry[i];
  return void;
};

global.fushiLookupEntryFor = function(renderer)
{
  var registry = global.fushiLookupRegistry;
  var nonActiveInvalid = -1, nonActive = -1;
  var activeInvalid = -1, activeOldest = -1;
  for(var i = 0; i < registry.count; i++)
  {
    var candidate = registry[i];
    var active = false;
    var slots = global.fushiLookupSlots;
    for(var si = 0; si < slots.count; si++)
      if(slots[si].activeEntry === candidate) active = true;
  }
  if(registry.count < 8)
  {
    var fresh = %[renderer:renderer,
      rendererLease:++global.fushiLookupRendererLease,
      glyphs:[], line:"", used:0,
      layer:void, visibleHost:void, currentIdentity:void,
      logicalLine:"", slotPage:0, slotIndex:-1, slotGeneration:0,
      renderEpoch:0, retiredRenderEpoch:0];
    registry.add(fresh);
    return fresh;
  }
  var victim = (nonActiveInvalid >= 0) ? nonActiveInvalid :
    ((nonActive >= 0) ? nonActive :
    ((activeInvalid >= 0) ? activeInvalid : activeOldest));
  var reused = registry[victim];
  reused.rendererLease = 0;
  reused.glyphs = [];
  reused.line = "";
  reused.used = 0;
  global.fushiLookupClearEntryBinding(reused);
  reused.renderer = renderer;
  reused.renderEpoch = 0;
  reused.retiredRenderEpoch = 0;
  reused.rendererLease = ++global.fushiLookupRendererLease;
  return reused;
};

global.fushiLookupQueueHighlightErase = function(rect)
{
  if(rect === void || rect === null) return;
  var pending = global.fushiLookupPendingHighlightEraseRect;
  if(pending === void || pending === null)
    global.fushiLookupPendingHighlightEraseRect = rect;
  else
  {
    var left = pending.x < rect.x ? pending.x : rect.x;
    var top = pending.y < rect.y ? pending.y : rect.y;
    var pendingRight = pending.x + pending.w;
    var rectRight = rect.x + rect.w;
    var right = pendingRight > rectRight ? pendingRight : rectRight;
    var pendingBottom = pending.y + pending.h;
    var rectBottom = rect.y + rect.h;
    var bottom = pendingBottom > rectBottom ? pendingBottom : rectBottom;
    global.fushiLookupPendingHighlightEraseRect =
      %[x:left, y:top, w:right - left, h:bottom - top];
  }
  global.fushiLookupPendingHighlightEraseSeq++;
};

global.fushiLookupFlushPendingHighlightErase = function()
{
  if(global.fushiLookupHighlightFlushActive) return false;
  var pending = global.fushiLookupPendingHighlightEraseRect;
  if(pending === void || pending === null) return true;
  var seq = global.fushiLookupPendingHighlightEraseSeq;
  global.fushiLookupHighlightFlushActive = true;
  var completed = false;
  try
  {
    var highlight = global.fushiLookupHighlightLayer;
    highlight.fillRect(pending.x, pending.y, pending.w, pending.h, 0);
    highlight.visible = false;
    highlight.update();
    completed = true;
  }
  catch(e) { global.fushiLookupFault(); }
  global.fushiLookupHighlightFlushActive = false;
  if(completed && global.fushiLookupPendingHighlightEraseSeq == seq)
    global.fushiLookupPendingHighlightEraseRect = void;
  return global.fushiLookupPendingHighlightEraseRect === void;
};

global.fushiLookupClearEntryBinding = function(entry)
{
  if(global.fushiLookupHitEntry === entry)
  {
    global.fushiLookupQueueHighlightErase(global.fushiLookupHighlightRect);
    global.fushiLookupHitEntry = void;
  }
  entry.layer = void;
  entry.visibleHost = void;
  entry.currentIdentity = void;
  var slots = global.fushiLookupSlots;
  for(var si = 0; si < slots.count; si++)
  {
    if(slots[si].activeEntry === entry)
    {
      slots[si].activeEntry = void;
      slots[si].activeStrength = 0;
    }
  }
};

global.fushiLookupRetireAnchorPeers = function(entry, anchorPage, anchorIndex)
{
  var registry = global.fushiLookupRegistry;
  for(var i = 0; i < registry.count; i++)
  {
    var peer = registry[i];
    if(peer === entry) continue;
    if(peer.slotPage != anchorPage || peer.slotIndex != anchorIndex) continue;
    peer.glyphs = [];
    peer.retiredRenderEpoch = peer.renderEpoch;
    global.fushiLookupClearEntryBinding(peer);
  }
};

global.fushiLookupFindSlot = function(page, index)
{
  var slots = global.fushiLookupSlots;
  for(var i = 0; i < slots.count; i++)
    if(slots[i].page == page && slots[i].index == index) return slots[i];
  return void;
};

global.fushiLookupResolveCurrentSlot = function()
{
  var current = global.fushiLookupField(global.kag, "current");
  var pages = [global.kag.fore.messages, global.kag.back.messages];
  for(var p = 0; p < pages.count; p++)
  {
    var messages = pages[p];
    for(var i = 0; i < messages.count; i++)
      if(messages[i] === current)
        return %[page:p + 1, index:i, identity:current];
  }
  return void;
};

global.fushiLookupSlotFor = function(page, index, identity)
{
  var slots = global.fushiLookupSlots;
  if(slots.count >= 8)
  {
    var oldestInactive = -1, oldestActive = -1;
    for(var i = 0; i < slots.count; i++)
    {
      if(slots[i].activeEntry === void || slots[i].activeEntry === null)
        oldestInactive = i;
      else
        oldestActive = i;
    }
    var oldest = (oldestInactive >= 0) ? oldestInactive : oldestActive;
    var retired = slots[oldest].activeEntry;
    retired.retiredRenderEpoch = retired.renderEpoch;
    global.fushiLookupClearEntryBinding(retired);
    slots.erase(oldest);
  }
  var fresh = %[page:page, index:index, line:"", generation:0,
    currentIdentity:identity, activeEntry:void, activeStrength:0];
  slots.add(fresh);
  return fresh;
};

global.fushiLookupAdoptSlot = function(entry, line, page, index, identity,
  capturePhase)
{
  var slot = global.fushiLookupSlotFor(page, index, identity);
  var allSlots = global.fushiLookupSlots;
  for(var si = 0; si < allSlots.count; si++)
  {
    var other = allSlots[si];
    if(other === slot) continue;
    if(other.activeEntry === entry)
    {
      other.activeEntry = void;
      other.activeStrength = 0;
    }
  }
  var advanced = false;
  if(slot.line == "")
  {
    slot.line = line;
    slot.generation++;
  }
  else if(slot.line != line)
  {
    if(entry.slotPage == page && entry.slotIndex == index &&
      entry.slotGeneration < slot.generation && entry.logicalLine == line &&
      entry.renderEpoch <= entry.retiredRenderEpoch)
      return %[slot:slot, stale:true, same:false, advanced:false];
    global.fushiLookupRetireAnchorPeers(entry, page, index);
    slot.line = line;
    slot.generation++;
    slot.activeEntry = void;
    advanced = true;
  }
  var same = entry.logicalLine == line;
  entry.logicalLine = line;
  entry.slotPage = page;
  entry.slotIndex = index;
  entry.slotGeneration = slot.generation;
  return %[slot:slot, same:same, advanced:advanced];
};

global.fushiLookupFlushVisualWork = function()
{
  if(global.fushiLookupVisualFlushActive) return false;
  global.fushiLookupVisualFlushActive = true;
  var dismiss = global.fushiLookupPendingVisualDismiss;
  global.fushiLookupPendingVisualDismiss = false;
  if(dismiss) global.fushiLookupDismissNow();
  global.fushiLookupFlushPendingHighlightErase();
  global.fushiLookupVisualFlushActive = false;
  return true;
};

global.fushiLookupCurrentIdentityState = function(entry)
{
  var slot = global.fushiLookupFindSlot(entry.slotPage, entry.slotIndex);
  if(slot === void || slot.generation != entry.slotGeneration ||
    slot.line != entry.logicalLine || slot.activeEntry !== entry) return -1;
  if(entry.anchorKind == 0) return 0;
  var captured = entry.currentIdentity;
  if(captured === void || captured === null) return 0;
  var resolved = global.fushiLookupResolveCurrentSlot();
  if(resolved === void) return -1;
  if(resolved.page == entry.slotPage && resolved.index == entry.slotIndex)
    return resolved.identity === captured ? 1 : -1;
  return 0;
};
)TJS" LR"TJS(
global.fushiLookupCaptureTokenCurrent = function(entry, renderer,
  expectedLease, expectedRenderEpoch)
{
  return entry !== void && expectedLease > 0 &&
    global.fushiLookupFindEntry(renderer) === entry &&
    entry.renderer === renderer && entry.rendererLease == expectedLease &&
    entry.renderEpoch == expectedRenderEpoch &&
    expectedRenderEpoch > entry.retiredRenderEpoch;
};

global.fushiLookupCapture = function(renderer, capturePhase,
  expectedLease, expectedRenderEpoch, expectedBindRevision)
{
  var entry = global.fushiLookupFindEntry(renderer);
  if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
    expectedLease, expectedRenderEpoch)) return;
  var getCharacters = renderer.getCharacters;
  var characters = getCharacters(0, 0);
  if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
    expectedLease, expectedRenderEpoch)) return;
  var resolvedCurrent = global.fushiLookupResolveCurrentSlot();
  if(capturePhase != 3 && resolvedCurrent !== void)
  {
    if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
      expectedLease, expectedRenderEpoch)) return;
    entry.observedPage = resolvedCurrent.page;
    entry.observedIndex = resolvedCurrent.index;
    entry.observedIdentity = resolvedCurrent.identity;
  }
  var slotAdoption = void;
  var logicalSlot = void;
  var entrySameLogical = false;
  var glyphs = [], line = "";
  var candidateReady = false;
  var candidateLayer = void;
  var candidateVisibleHost = void;
  var candidateCurrentIdentity = void;
  var candidateAnchorPage = 0;
  var candidateAnchorIndex = -1;
  var originMinX = 0, originMaxX = 10;
  var originMinY = 0, originMaxY = 0;
  var glyphOriginSpanX = originMaxX - originMinX;
  var glyphOriginSpanY = originMaxY - originMinY;
  var groups = global.fushiLookupBindGroups;
  var best = void;
  for(var gi = 0; gi < groups.count; gi++)
  {
    var g = groups[gi];
    var spanErrX = Math.abs((g.maxOx - g.minOx) - glyphOriginSpanX);
    var spanErrY = Math.abs((g.maxOy - g.minOy) - glyphOriginSpanY);
    var toleranceX = 12, toleranceY = 2;
    if(spanErrX > toleranceX || spanErrY > toleranceY) continue;
    if(!global.fushiLookupBindGroupVisible(g)) continue;
    best = g;
  }
  if(best !== void)
  {
    var anchorMsg = global.kag.current;
    var anchorPage = 1;
    var anchorIndex = 0;
    candidateLayer = (anchorMsg !== void && isvalid anchorMsg)
      ? anchorMsg : best.host;
    candidateVisibleHost = best.host;
    candidateAnchorPage = anchorPage;
    candidateAnchorIndex = anchorIndex;
    candidateReady = true;
  }
  if(slotAdoption === void && candidateAnchorPage != 0 &&
    candidateAnchorIndex >= 0)
  {
    if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
      expectedLease, expectedRenderEpoch)) return;
    slotAdoption = global.fushiLookupAdoptSlot(entry, line,
      candidateAnchorPage, candidateAnchorIndex, candidateCurrentIdentity,
      capturePhase);
    if(slotAdoption.stale) return;
    logicalSlot = slotAdoption.slot;
    entrySameLogical = slotAdoption.same;
  }
  if(slotAdoption === void)
  {
    if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
      expectedLease, expectedRenderEpoch)) return;
    entrySameLogical = entry.logicalLine == line;
    if(!entrySameLogical)
    {
      if(entry.slotPage != 0 && entry.slotIndex >= 0)
      {
        var owned = global.fushiLookupFindSlot(
          entry.slotPage, entry.slotIndex);
        if(owned !== void && owned.activeEntry === entry)
        {
          owned.activeEntry = void;
          owned.activeStrength = 0;
        }
      }
      entry.glyphs = [];
      global.fushiLookupClearEntryBinding(entry);
      if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
        expectedLease, expectedRenderEpoch)) return;
      entry.logicalLine = line;
      entry.slotGeneration++;
    }
  }
  candidateStrength = (candidateCurrentIdentity !== void) ? 2 :
    ((anchorKind != 0 && anchorPage != 0 && anchorIndex >= 0) ? 1 : 0);
  if(candidateReady && entrySameLogical && entry.hasBase &&
    candidateStrength < entry.bindingStrength) candidateReady = false;
  if(activeUsable && candidateStrength <= logicalSlot.activeStrength)
    candidateReady = false;
  if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
    expectedLease, expectedRenderEpoch)) return;
  entry.used = ++global.fushiLookupClock;
  if(candidateReady)
  {
    if(logicalSlot !== void)
      global.fushiLookupRetireAnchorPeers(entry,
        logicalSlot.page, logicalSlot.index);
    if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
      expectedLease, expectedRenderEpoch)) return;
    entry.glyphs = glyphs;
    entry.layer = candidateLayer;
    entry.visibleHost = candidateVisibleHost;
    entry.currentIdentity = candidateCurrentIdentity;
    if(logicalSlot !== void)
      logicalSlot.activeEntry = entry;
    if(slotAdoption !== void && slotAdoption.advanced)
      global.fushiLookupPendingVisualDismiss = true;
  }
  else if(entrySameLogical && entry.hasBase)
  {
    entry.glyphs = glyphs;
    entry.line = line;
  }
  else
  {
    entry.glyphs = [];
    global.fushiLookupClearEntryBinding(entry);
    if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
      expectedLease, expectedRenderEpoch)) return;
  }
};

global.fushiLookupBindOrigin = function(renderer, layer, originX, originY, ch)
{
  var drawX = originX + ch.x;
  var drawY = originY + ch.y;
  var groups = global.fushiLookupBindGroups;
  if(groups.count >= 8)
  {
    var victim = 0;
    var victimClock = groups[0].clock;
    for(var vi = 0; vi < groups.count; vi++)
    {
      var victimHost = groups[vi].host;
      if(victimHost === void || victimHost === null || !isvalid victimHost)
      {
        victim = vi;
        break;
      }
      if(groups[vi].clock < victimClock)
      {
        victim = vi;
        victimClock = groups[vi].clock;
      }
    }
    groups.erase(victim);
  }
  var slot = groups[0];
  var yRewound = drawY < slot.lastOy - 2;
  var returnedTop = drawY <= slot.minOy + 2 &&
    drawX < slot.lastOx - 2;
  var newRun = slot.count > 0 && (yRewound || returnedTop);
  if(newRun) slot.count = 0;
};

global.fushiLookupProbe = function(submit)
{
  global.fushiLookupFlushVisualWork();
  var entry = global.fushiLookupRegistry[0];
  var layer = entry.layer;
  if(!global.fushiLookupComputeOffset(layer)) return false;
  var currentIdentityState =
    global.fushiLookupCurrentIdentityState(entry);
  if(currentIdentityState < 0 ||
    (currentIdentityState == 0 &&
    !global.fushiLookupEntryVisible(entry)))
    return false;
  return true;
};

global.fushiLookupPatchRendererInstance = function(patch)
{
  patch.state = 1;
  global.fushiLookupWrapperAuditPending = true;
  return true;
};

global.fushiLookupLeftClickHook = function()
{
  try
  {
    global.fushiLookupInstallGetRenderBridge();
    global.fushiLookupSweepMsgwinRenders();
    global.fushiLookupAuditWrappers(true);
    return global.fushiLookupProbe(true);
  }
  catch(e) { global.fushiLookupFault(); return false; }
};
global.fushiLookupMouseMoveHook = function(x, y)
{
  try
  {
    global.fushiLookupAuditWrappers(false);
    global.fushiLookupProbe(false);
  }
  catch(e) { global.fushiLookupFault(); }
  return false;
};

installStage = 10;
global.fushiLookupOriginalRender = global.TextRender.render;
global.TextRender.render = function(a, b, c, d, e, f)
{
  var captureLease = 0, captureEpoch = 0;
  try
  {
    var epochEntry = global.fushiLookupEntryFor(this);
    epochEntry.renderEpoch++;
    captureLease = epochEntry.rendererLease;
    captureEpoch = epochEntry.renderEpoch;
  }
  catch(e) { global.fushiLookupFault(); }
  var result = (global.fushiLookupOriginalRender incontextof this)(...);
  try { global.fushiLookupCapture(this, 1, captureLease, captureEpoch); }
  catch(e) { global.fushiLookupFault(); }
  try { global.fushiLookupFlushVisualWork(); }
  catch(e) { global.fushiLookupFault(); }
  return result;
};
global.fushiLookupInstalledRenderWrapper = global.TextRender.render;
global.fushiLookupRenderInstallFailed =
  global.fushiLookupInstalledRenderWrapper === global.fushiLookupOriginalRender;
installStage = 11;
installStage = 20;
global.fushiLookupOriginalDone = global.TextRender.done;
global.TextRender.done = function()
{
  var doneLease = 0, doneEpoch = 0;
  try
  {
    var doneEntry = global.fushiLookupFindEntry(this);
    if(doneEntry !== void)
    {
      doneLease = doneEntry.rendererLease;
      doneEpoch = doneEntry.renderEpoch;
    }
  }
  catch(e) { global.fushiLookupFault(); }
  var result = (global.fushiLookupOriginalDone incontextof this)(...);
  try
  {
    if(doneLease > 0)
      global.fushiLookupCapture(this, 2, doneLease, doneEpoch);
  }
  catch(e) { global.fushiLookupFault(); }
  try { global.fushiLookupFlushVisualWork(); }
  catch(e) { global.fushiLookupFault(); }
  return result;
};
global.fushiLookupInstalledDoneWrapper = global.TextRender.done;
global.fushiLookupDoneInstallFailed =
  global.fushiLookupInstalledDoneWrapper === global.fushiLookupOriginalDone;
installStage = 21;
installStage = 30;
global.fushiLookupOriginalDrawCh = global.TextRender.drawCh;
global.TextRender.drawCh = function(layer, ox, oy, ch)
{
  try { global.fushiLookupBindOrigin(this, layer, ox, oy); }
  catch(e) { global.fushiLookupFault(); }
  return (global.fushiLookupOriginalDrawCh incontextof this)(...);
};
global.fushiLookupInstalledDrawChWrapper = global.TextRender.drawCh;
global.fushiLookupDrawChInstallFailed =
  global.fushiLookupInstalledDrawChWrapper === global.fushiLookupOriginalDrawCh;
installStage = 31;
if(global.fushiLookupResolveMsgwinPlugin() !== void)
{
  installStage = 35;
  global.fushiLookupInstallGetRenderBridge();
  installStage = 36;
  global.fushiLookupSweepMsgwinRenders();
  installStage = 37;
}
installStage = 40;
global.kag.addHook("leftClick", global.fushiLookupLeftClickHook);
installStage = 41;
global.kag.addHook("mouseMove", global.fushiLookupMouseMoveHook);
installStage = 42;
global.kag.addHook("onMouseWheelHook", global.fushiLookupMouseWheelHook);
installStage = 43;
global.kag.addHook("keyDown", global.fushiLookupKeyDownHook);
installStage = 50;
System.removeContinuousHandler(global.fushiLookupBootstrap);
global.fushiLookupBootstrap = void;
}
catch(e)
{
  try
  {
    if(typeof global.fushiLookupNoteError == "Object")
      global.fushiLookupNoteError("bootstrap.stage",
        %[message: "stage=" + installStage]);
  }
  catch(e2) {}
  System.removeContinuousHandler(global.fushiLookupBootstrap);
  global.fushiLookupBootstrap = void;
}
};
)TJS";
'''


# 旧 prototype 的负样本：跨 fore/back 页扫描，只看尺寸，遇到第一个就结束。
# 这是单独的点名变异，不能只靠“新结构不完整”的附带报错证明守卫有效。
LEGACY_CROSS_PAGE_ANCHOR_SAMPLE = r'''
static const wchar_t kAnchorBootstrap[] = LR"TJS(
global.fushiLookupStampBindGroup = function(group, host)
{
  var anchorMsg = void;
  var pages = [global.kag.fore, global.kag.back];
  for(var pgi = 0; pgi < pages.count && anchorMsg === void; pgi++)
  {
    var messages = pages[pgi].messages;
    for(var mj = 0; mj < messages.count; mj++)
    {
      var candidate = messages[mj];
      if(candidate.width == host.width &&
        candidate.height == host.height)
      {
        anchorMsg = candidate;
        break;
      }
    }
  }
  group.anchorIdentity = anchorMsg;
};

global.fushiLookupCapture = function(renderer, capturePhase,
  expectedLease, expectedRenderEpoch, expectedBindRevision)
{
  var entry = global.fushiLookupFindEntry(renderer);
  entry.layer = best.anchorIdentity;
};
)TJS";
'''


DIRTY_OWN_ENUM_WINDOWS = """
DWORD ResolveKirikiriEngineMainThreadId() {
  struct Finder { DWORD pid; DWORD tid; } finder = {GetCurrentProcessId(), 0};
  EnumWindows([](HWND w, LPARAM p) -> BOOL {
    Finder* self = reinterpret_cast<Finder*>(p);
    DWORD pid = 0;
    const DWORD tid = GetWindowThreadProcessId(w, &pid);
    if (pid != self->pid) return TRUE;
    if (GetWindow(w, GW_OWNER) != nullptr) return TRUE;
    if (!IsWindowVisible(w)) return TRUE;
    self->tid = tid;
    return FALSE;
  }, reinterpret_cast<LPARAM>(&finder));
  return finder.tid;
}
"""

CLEAN_SHARED_RESOLVER = """
DWORD ResolveKirikiriEngineMainThreadId() {
  const HWND main_window = FindGameMainWindow();
  if (main_window == nullptr) return 0;
  DWORD pid = 0;
  const DWORD tid = GetWindowThreadProcessId(main_window, &pid);
  if (tid == 0 || pid != GetCurrentProcessId()) return 0;
  return tid;
}
"""

DIRTY_FIRST_MATCH_OWNER = """
BOOL CALLBACK FindOverlayOwner(HWND window, LPARAM param) {
  OwnerSearch* search = reinterpret_cast<OwnerSearch*>(param);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid != search->pid) return TRUE;
  if (!IsWindowVisible(window)) return TRUE;
  if (GetWindow(window, GW_OWNER) != nullptr) return TRUE;
  search->best = window;
  return FALSE;
}

HWND FindGameMainWindow() {
  OwnerSearch search;
  EnumWindows(&FindOverlayOwner, reinterpret_cast<LPARAM>(&search));
  return search.best;
}
"""

CLEAN_AREA_OWNER = """
BOOL CALLBACK FindOverlayOwner(HWND window, LPARAM param) {
  OwnerSearch* search = reinterpret_cast<OwnerSearch*>(param);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid != search->pid) return TRUE;
  if (!IsWindowVisible(window)) return TRUE;
  if (GetWindow(window, GW_OWNER) != nullptr) return TRUE;
  RECT rect = {};
  if (!GetClientRect(window, &rect)) return TRUE;
  const long area = (rect.right - rect.left) * (rect.bottom - rect.top);
  if (area > search->best_area) {
    search->best_area = area;
    search->best = window;
  }
  return TRUE;
}

HWND FindGameMainWindow() {
  OwnerSearch search;
  EnumWindows(&FindOverlayOwner, reinterpret_cast<LPARAM>(&search));
  return search.best;
}
"""


class MutationSelfTest(unittest.TestCase):
    """把每条规则要抓的东西真的塞进合成源码，确认规则会红。"""

    maxDiff = None

    def setUp(self) -> None:
        self.clean = MaskedSource(CLEAN_SAMPLE)
        self.coordinate_clean = MaskedSource(COORDINATE_CLEAN_SAMPLE)
        self.anchor_clean = MaskedSource(ANCHOR_IDENTITY_CLEAN_SAMPLE)
        self.entry_lifecycle_clean = MaskedSource(
            ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE
        )

    def _mutate(self, old: str, new: str) -> MaskedSource:
        self.assertIn(old, CLEAN_SAMPLE, "变异锚点必须真的存在于干净样本里")
        dirty = CLEAN_SAMPLE.replace(old, new, 1)
        self.assertNotEqual(dirty, CLEAN_SAMPLE, "变异样本必须真的与干净样本不同")
        return MaskedSource(dirty)

    def _mutate_coordinate(self, old: str, new: str) -> MaskedSource:
        self.assertIn(
            old,
            COORDINATE_CLEAN_SAMPLE,
            "共同根变异锚点必须真的存在于干净样本里",
        )
        dirty = COORDINATE_CLEAN_SAMPLE.replace(old, new, 1)
        self.assertNotEqual(
            dirty,
            COORDINATE_CLEAN_SAMPLE,
            "共同根变异样本必须真的与干净样本不同",
        )
        return MaskedSource(dirty)

    def _mutate_anchor(self, old: str, new: str) -> MaskedSource:
        self.assertIn(
            old,
            ANCHOR_IDENTITY_CLEAN_SAMPLE,
            "锚点身份变异锚点必须真的存在于干净样本里",
        )
        dirty = ANCHOR_IDENTITY_CLEAN_SAMPLE.replace(old, new, 1)
        self.assertNotEqual(
            dirty,
            ANCHOR_IDENTITY_CLEAN_SAMPLE,
            "锚点身份变异样本必须真的与干净样本不同",
        )
        return MaskedSource(dirty)

    def _mutate_entry_lifecycle(self, old: str, new: str) -> MaskedSource:
        self.assertIn(
            old,
            ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE,
            "entry 生命周期变异锚点必须真的存在于干净样本里",
        )
        dirty = ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE.replace(old, new, 1)
        self.assertNotEqual(
            dirty,
            ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE,
            "entry 生命周期变异样本必须真的与干净样本不同",
        )
        return MaskedSource(dirty)

    def test_own_enum_windows_in_resolver_is_red(self) -> None:
        self.assertNotEqual(
            [], find_divergent_main_window_criteria(MaskedSource(DIRTY_OWN_ENUM_WINDOWS))
        )

    def test_resolver_reusing_shared_helper_stays_green(self) -> None:
        self.assertEqual(
            [], find_divergent_main_window_criteria(MaskedSource(CLEAN_SHARED_RESOLVER))
        )

    def test_first_match_owner_search_is_red(self) -> None:
        self.assertNotEqual(
            [], find_unshared_main_window_area_criterion(DIRTY_FIRST_MATCH_OWNER)
        )

    def test_area_owner_search_stays_green(self) -> None:
        self.assertEqual(
            [], find_unshared_main_window_area_criterion(CLEAN_AREA_OWNER)
        )

    def test_clean_sample_passes_every_rule(self) -> None:
        self.assertEqual([], find_dynamic_tjs_concatenations(self.clean))
        self.assertEqual([], find_network_debris(self.clean))
        self.assertEqual([], find_global_monkey_patches(self.clean))
        self.assertEqual([], find_default_on_probe_switches(self.clean))
        self.assertEqual([], find_unvalidated_placeholder_values(self.clean))
        self.assertEqual([], find_unguarded_bitmap_copies(self.clean))
        self.assertEqual([], find_ownerless_card_dismissals(self.clean))
        # 干净样本里确实有一个 KAGEX 缺席门 else，否则放行 classic 采集面这条分支
        # 在自测里根本没被走到（放行规则会变成永远走不到的死代码而无人察觉）。
        self.assertNotEqual([], _classic_fallback_spans(CLEAN_SAMPLE))
        # 干净样本里确实有一次收卡，否则归属这条规则根本没被走到。
        self.assertIsNotNone(_tjs_function_body(CLEAN_SAMPLE, "fushiLookupCapture"))
        self.assertIn("fushiLookupDismiss(", CLEAN_SAMPLE)
        # 干净样本里确实有一处运行期占位符替换，否则这条规则根本没被走到。
        self.assertTrue(
            any(
                name == "__FUSHI_CARD_PATH__"
                for _, name, _ in _placeholder_substitutions(CLEAN_SAMPLE)
            )
        )
        # 干净样本里确实有一个被豁免的探测分支补丁——否则"豁免"这条根本没被走到。
        self.assertIsNotNone(GLOBAL_PATCH_RE.search(CLEAN_SAMPLE))
        self.assertNotEqual([], _probe_block_spans(CLEAN_SAMPLE))

    def test_split_raw_tjs_common_root_sample_is_green(self) -> None:
        self.assertEqual(
            2,
            len(TJS_RAW_RE.findall(COORDINATE_CLEAN_SAMPLE)),
            "clean 样本必须跨 raw literal，才能覆盖生产 bootstrap 的真实拼接形态",
        )
        self.assertEqual(
            [],
            find_invalid_common_root_coordinate_conversion(self.coordinate_clean),
        )

    def test_split_raw_tjs_anchor_identity_sample_is_green(self) -> None:
        self.assertEqual(
            2,
            len(TJS_RAW_RE.findall(ANCHOR_IDENTITY_CLEAN_SAMPLE)),
            "clean 锚点样本必须跨 raw literal，覆盖生产 bootstrap 的拼接形态",
        )
        self.assertEqual(
            [],
            find_invalid_kag_anchor_identity_selection(self.anchor_clean),
        )

    def test_split_raw_tjs_complete_candidate_sample_is_green(self) -> None:
        self.assertEqual(
            2,
            len(TJS_RAW_RE.findall(ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE)),
            "clean entry 样本必须跨 raw literal，覆盖生产 bootstrap 的拼接形态",
        )
        self.assertEqual(
            [],
            find_invalid_lookup_entry_visibility_lifecycle(
                self.entry_lifecycle_clean
            ),
        )

    def test_bootstrap_waits_for_complete_textrender_surface(self) -> None:
        mutations = (
            (
                'typeof global.kag != "Object"',
                'typeof global.kag == "undefined"',
            ),
            ('typeof global.kag.addHook != "Object"', "false"),
            (
                'typeof global.TextRender != "Object"',
                'typeof global.TextRender == "undefined"',
            ),
            ('typeof global.TextRender.render != "Object"', "false"),
            ('typeof global.TextRender.done != "Object"', "false"),
            ('typeof global.TextRender.drawCh != "Object"', "false"),
        )
        for old, new in mutations:
            with self.subTest(missing=old):
                dirty = self._mutate_entry_lifecycle(old, new)
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_bootstrap_readiness_precedes_lookup_state_initialization(self) -> None:
        readiness = (
            '  if(typeof global.kag != "Object" || global.kag === null ||\n'
            '    typeof global.kag.addHook != "Object") return;\n'
            '  if(typeof global.TextRender == "Object" && '
            'global.TextRender !== null &&\n'
            '    (typeof global.TextRender.render != "Object" ||\n'
            '    typeof global.TextRender.done != "Object" ||\n'
            '    typeof global.TextRender.drawCh != "Object")) return;\n'
        )
        install_start = "var installStage = 0;\ntry\n{\n"
        state = "global.fushiLookupSlots = [];\n"
        dirty = self._mutate_entry_lifecycle(
            readiness + install_start + state,
            state + readiness + install_start,
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_bootstrap_retires_only_after_all_three_wrappers(self) -> None:
        staged_success_retire = (
            "installStage = 50;\n"
            "System.removeContinuousHandler(global.fushiLookupBootstrap);\n"
        )
        retire_before_final_stage = (
            "System.removeContinuousHandler(global.fushiLookupBootstrap);\n"
            "installStage = 50;\n"
        )
        dirty = self._mutate_entry_lifecycle(
            staged_success_retire, retire_before_final_stage
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_wrapper_install_readback_and_failure_markers_are_pinned(self) -> None:
        for marker in (
            "global.fushiLookupInstalledRenderWrapper = global.TextRender.render;\n",
            "global.fushiLookupRenderInstallFailed =\n"
            "  global.fushiLookupInstalledRenderWrapper === "
            "global.fushiLookupOriginalRender;\n",
            "global.fushiLookupInstalledDoneWrapper = global.TextRender.done;\n",
            "global.fushiLookupDoneInstallFailed =\n"
            "  global.fushiLookupInstalledDoneWrapper === "
            "global.fushiLookupOriginalDone;\n",
            "global.fushiLookupInstalledDrawChWrapper = global.TextRender.drawCh;\n",
            "global.fushiLookupDrawChInstallFailed =\n"
            "  global.fushiLookupInstalledDrawChWrapper === "
            "global.fushiLookupOriginalDrawCh;\n",
        ):
            with self.subTest(marker=marker.strip()):
                dirty = self._mutate_entry_lifecycle(marker, "")
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_wrapper_audit_force_bitmask_and_state_change_are_pinned(self) -> None:
        mutations = (
            ("function(force)\n", "function()\n"),
            ("state = state | 64;\n", "state = state | 4;\n"),
            (
                "if(state != global.fushiLookupWrapperAuditLastState)\n",
                "if(true)\n",
            ),
        )
        for old, new in mutations:
            with self.subTest(old=old.strip()):
                dirty = self._mutate_entry_lifecycle(old, new)
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_wrapper_audit_call_sites_are_pinned(self) -> None:
        for old, new in (
            (
                "global.fushiLookupAuditWrappers(true);\n",
                "global.fushiLookupAuditWrappers(false);\n",
            ),
            (
                "global.fushiLookupAuditWrappers(false);\n",
                "global.fushiLookupAuditWrappers(true);\n",
            ),
        ):
            with self.subTest(old=old.strip()):
                dirty = self._mutate_entry_lifecycle(old, new)
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_wrapper_install_stage_sequence_is_pinned(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "installStage = 31;\n", "installStage = 32;\n"
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_slot_key_requires_page_and_index(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    if(slots[i].page == page && slots[i].index == index) "
            "return slots[i];\n",
            "    if(slots[i].index == index) return slots[i];\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_entry_lru_must_protect_active_entries(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "      if(slots[si].activeEntry === candidate) active = true;\n",
            "      active = false;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_clear_binding_queues_hover_erase_and_unlinks_active(self) -> None:
        for removed in (
            "    global.fushiLookupQueueHighlightErase("
            "global.fushiLookupHighlightRect);\n",
            "      slots[si].activeEntry = void;\n",
        ):
            with self.subTest(removed=removed.strip()):
                dirty = self._mutate_entry_lifecycle(removed, "")
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_slot_lru_prefers_inactive_slots(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    var oldest = (oldestInactive >= 0) ? "
            "oldestInactive : oldestActive;\n",
            "    var oldest = oldestActive;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_adoption_detaches_entry_from_other_slots(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "      other.activeEntry = void;\n",
            "",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_complete_different_line_retires_peers_before_advancing(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    global.fushiLookupRetireAnchorPeers(entry, page, index);\n"
            "    slot.line = line;\n",
            "    slot.line = line;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_retired_same_render_done_cannot_revive_slot(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "      entry.renderEpoch <= entry.retiredRenderEpoch)\n"
            "      return %[slot:slot, stale:true, same:false, advanced:false];\n",
            "      false)\n"
            "      return %[slot:slot, stale:true, same:false, advanced:false];\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_candidate_uses_origin_spans_and_visible_host(self) -> None:
        mutations = (
            (
                "    var spanErrX = Math.abs((g.maxOx - g.minOx) - "
                "glyphOriginSpanX);\n",
                "    var spanErrX = Math.abs(g.maxOx - glyphOriginSpanX);\n",
            ),
            (
                "    if(!global.fushiLookupBindGroupVisible(g)) continue;\n",
                "",
            ),
            # 退回裸的短命宿主可见性 = BUG-1631 的原始形状，必须单独变红。
            (
                "    if(!global.fushiLookupBindGroupVisible(g)) continue;\n",
                "    if(!global.fushiLookupVisible(g.host)) continue;\n",
            ),
        )
        for old, new in mutations:
            with self.subTest(replacement=new.strip()):
                dirty = self._mutate_entry_lifecycle(old, new)
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_multiline_downward_wrap_does_not_reset_origin_span(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "  var yRewound = drawY < slot.lastOy - 2;\n",
            "  var yRewound = drawY > slot.lastOy + 2;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_slot_adoption_waits_for_complete_candidate(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    candidateAnchorIndex = anchorIndex;\n"
            "    candidateReady = true;\n",
            "    candidateReady = true;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_no_candidate_new_line_never_dismisses(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "      global.fushiLookupClearEntryBinding(entry);\n"
            "      if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,\n"
            "        expectedLease, expectedRenderEpoch)) return;\n"
            "      entry.logicalLine = line;\n",
            "      global.fushiLookupClearEntryBinding(entry);\n"
            "      global.fushiLookupDismiss();\n"
            "      if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,\n"
            "        expectedLease, expectedRenderEpoch)) return;\n"
            "      entry.logicalLine = line;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_no_candidate_clears_only_owned_active_slot(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "        if(owned !== void && owned.activeEntry === entry)\n",
            "        if(owned !== void)\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_capture_never_allocates_an_evicted_renderer_entry(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "  var entry = global.fushiLookupFindEntry(renderer);\n",
            "  var entry = global.fushiLookupEntryFor(renderer);\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_renderer_lease_is_rechecked_after_game_getters(self) -> None:
        gate = (
            "  if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,\n"
            "    expectedLease, expectedRenderEpoch)) return;\n"
        )
        dirty = self._mutate_entry_lifecycle(gate, "")
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_all_nine_capture_token_boundaries_are_required(self) -> None:
        gate = (
            "  if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,\n"
            "    expectedLease, expectedRenderEpoch)) return;\n"
        )
        # 样本里这九道门分布在不同缩进层级（fallback 分支比外层多两级），所以按
        # 缩进无关的调用形态数，别拿某一种缩进的整块字符串去数。
        self.assertEqual(
            9,
            ENTRY_VISIBILITY_LIFECYCLE_CLEAN_SAMPLE.count(
                "if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,"
            ),
        )
        dirty = self._mutate_entry_lifecycle(gate, "")
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_slot_eviction_retires_the_active_render_epoch(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    retired.retiredRenderEpoch = retired.renderEpoch;\n",
            "",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_done_is_find_only_and_uses_a_pre_original_token(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    var doneEntry = global.fushiLookupFindEntry(this);\n",
            "    var doneEntry = global.fushiLookupEntryFor(this);\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_same_line_without_candidate_preserves_binding(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "  else if(entrySameLogical && entry.hasBase)\n"
            "  {\n"
            "    entry.glyphs = glyphs;\n",
            "  else if(entrySameLogical && entry.hasBase)\n"
            "  {\n"
            "    global.fushiLookupClearEntryBinding(entry);\n"
            "    entry.glyphs = glyphs;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_complete_candidate_publishes_active_entry(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "      logicalSlot.activeEntry = entry;\n",
            "",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_same_entry_strength_does_not_regress(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "  if(candidateReady && entrySameLogical && entry.hasBase &&\n"
            "    candidateStrength < entry.bindingStrength) "
            "candidateReady = false;\n",
            "",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_stronger_new_renderer_can_replace_weak_active(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "  if(activeUsable && candidateStrength <= "
            "logicalSlot.activeStrength)\n",
            "  if(activeUsable)\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_probe_requires_current_generation_and_active_entry(self) -> None:
        gate = (
            "  if(slot === void || slot.generation != entry.slotGeneration ||\n"
            "    slot.line != entry.logicalLine || "
            "slot.activeEntry !== entry) return -1;\n"
        )
        replacements = (
            "  if(slot === void ||\n"
            "    slot.line != entry.logicalLine || "
            "slot.activeEntry !== entry) return -1;\n",
            "  if(slot === void || slot.generation != entry.slotGeneration ||\n"
            "    slot.line != entry.logicalLine) return -1;\n",
        )
        for replacement in replacements:
            with self.subTest(replacement=replacement.strip()):
                dirty = self._mutate_entry_lifecycle(gate, replacement)
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_same_current_slot_requires_exact_object_identity(self) -> None:
        dirty = self._mutate_entry_lifecycle(
            "    return resolved.identity === captured ? 1 : -1;\n",
            "    return 1;\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_other_current_slot_falls_back_to_own_visible_host(self) -> None:
        old = (
            "  if(resolved.page == entry.slotPage && "
            "resolved.index == entry.slotIndex)\n"
            "    return resolved.identity === captured ? 1 : -1;\n"
            "  return 0;\n"
        )
        dirty = self._mutate_entry_lifecycle(
            old,
            old.replace("  return 0;\n", "  return -1;\n"),
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_probe_separates_coordinate_layer_from_visible_host(self) -> None:
        """可见性判据被拆回 Probe 里手写，就不再是 EntryVisible 的固定顺序。"""
        dirty = self._mutate_entry_lifecycle(
            "    !global.fushiLookupEntryVisible(entry)))\n",
            "    !global.fushiLookupVisible(layer)))\n",
        )
        self.assertNotEqual(
            [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
        )

    def test_render_and_done_wrappers_keep_original_before_capture(self) -> None:
        for old, new in (
            (
                "  var result = (global.fushiLookupOriginalRender "
                "incontextof this)(...);\n"
                "  try { global.fushiLookupCapture(this, 1, captureLease, "
                "captureEpoch); }\n",
                "  try { global.fushiLookupCapture(this, 1, captureLease, "
                "captureEpoch); }\n"
                "  var result = (global.fushiLookupOriginalRender "
                "incontextof this)(...);\n",
            ),
            (
                "  var result = (global.fushiLookupOriginalDone "
                "incontextof this)(...);\n"
                "  try\n  {\n    if(doneLease > 0)\n"
                "      global.fushiLookupCapture(this, 2, doneLease, doneEpoch);\n"
                "  }\n",
                "  try\n  {\n    if(doneLease > 0)\n"
                "      global.fushiLookupCapture(this, 2, doneLease, doneEpoch);\n"
                "  }\n"
                "  var result = (global.fushiLookupOriginalDone "
                "incontextof this)(...);\n",
            ),
        ):
            with self.subTest(old=old.strip()):
                dirty = self._mutate_entry_lifecycle(old, new)
                self.assertNotEqual(
                    [], find_invalid_lookup_entry_visibility_lifecycle(dirty)
                )

    def test_string_variable_interpolated_into_tjs_source_is_red(self) -> None:
        dirty = self._mutate(
            'std::to_wstring(start) + L","',
            'word + L","',
        )
        self.assertNotEqual([], find_dynamic_tjs_concatenations(dirty))

    def test_escaping_helper_interpolated_into_tjs_source_is_red(self) -> None:
        dirty = self._mutate(
            'std::to_wstring(length) + L");"',
            'EscapeTjsString(definition) + L");"',
        )
        self.assertNotEqual([], find_dynamic_tjs_concatenations(dirty))

    def test_compound_append_of_a_variable_is_red(self) -> None:
        dirty = self._mutate("script += std::to_wstring(seq)", "script += word")
        self.assertNotEqual([], find_dynamic_tjs_concatenations(dirty))

    def test_global_patch_outside_every_gate_is_red(self) -> None:
        # 补丁挪到无门位置（既不在探测分支、也不在 KAGEX 缺席门里）：所有游戏都要
        # 多绕一层，代价没有对价，必须红。
        dirty = self._mutate(
            "global.fushiLookupCapture = function(renderer)",
            "global.Layer.drawText = function(renderer)",
        )
        self.assertNotEqual([], find_global_monkey_patches(dirty))

    def test_removing_the_kagex_gate_turns_the_classic_patch_red(self) -> None:
        # 门被改成恒真（typeof global.TextRender 判据没了）：else 区间随之消失，
        # 门内补丁立刻落进红区——这正是"别的游戏也跟着多绕一层"那一刻。
        dirty = self._mutate(
            'if(typeof global.TextRender == "Object")',
            "if(global.fushiLookupAlways)",
        )
        self.assertEqual([], _classic_fallback_spans(dirty.text))
        self.assertNotEqual([], find_global_monkey_patches(dirty))

    def test_gate_without_else_does_not_open_a_span(self) -> None:
        # 只有真正的 else 才代表"这台游戏没有 KAGEX"。把 else 换成新的无条件块，
        # 区间必须消失，块里的补丁必须红。
        dirty = self._mutate("else", "if(1)")
        self.assertEqual([], _classic_fallback_spans(dirty.text))
        self.assertNotEqual([], find_global_monkey_patches(dirty))

    def test_unrelated_string_concatenation_stays_green(self) -> None:
        # 反向变异：非 TJS 语句里加更多字符串拼接，守卫必须仍然绿（否则它一改就红）。
        dirty = self._mutate(
            "return dir + name + L\".png\";",
            "return dir + name + suffix + L\".png\";",
        )
        self.assertEqual([], find_dynamic_tjs_concatenations(dirty))

    def test_every_network_debris_literal_is_red_on_its_own(self) -> None:
        for needle in NETWORK_DEBRIS:
            dirty = MaskedSource(
                CLEAN_SAMPLE + f'\nconst wchar_t kDebris[] = L"{needle}";\n'
            )
            found = find_network_debris(dirty)
            self.assertNotEqual([], found, f"{needle} 必须被抓到")
            self.assertTrue(any(needle in item for item in found), needle)

    def test_global_monkey_patch_outside_the_probe_branch_is_red(self) -> None:
        for patch in (
            "global.Layer.drawText = function(x, y) {};",
            "global.MessageLayer.processCh = function(ch) {};",
            "global.Layer.fillRect = function() {};",
        ):
            dirty = MaskedSource(CLEAN_SAMPLE + "\n" + patch + "\n")
            self.assertNotEqual([], find_global_monkey_patches(dirty), patch)
        # 比较不是补丁，不该误伤。
        same = MaskedSource(
            CLEAN_SAMPLE + "\nif(global.Layer.drawText == original) return;\n"
        )
        self.assertEqual([], find_global_monkey_patches(same))

    def test_probe_branch_defaulting_to_on_is_red(self) -> None:
        dirty = self._mutate(
            "constexpr bool kProbePaths = false;",
            "constexpr bool kProbePaths = true;",
        )
        self.assertNotEqual([], find_default_on_probe_switches(dirty))

    def test_patch_escaping_the_probe_branch_is_red(self) -> None:
        # 把补丁从探测分支里挪出来（分支留空）——豁免立刻失效。
        dirty = self._mutate(
            "if(global.fushiLookupProbeMode)\n{\n\t"
            "global.fushiLookupProbeOriginalDrawText = global.Layer.drawText;\n\t"
            "global.Layer.drawText = function(x, y, text) { return 0; };\n}",
            "global.Layer.drawText = function(x, y, text) { return 0; };",
        )
        self.assertNotEqual([], find_global_monkey_patches(dirty))

    def test_dropping_the_card_path_character_check_is_red(self) -> None:
        dirty = self._mutate(
            "  if (path.find_first_of(kForbiddenPathChars) != std::wstring::npos)"
            " return false;\n",
            "",
        )
        self.assertNotEqual([], find_unvalidated_placeholder_values(dirty))

    def test_assigning_the_card_path_elsewhere_is_red(self) -> None:
        # 校验函数还在，但有人在别处绕开它直接拼了一个路径进去。
        dirty = MaskedSource(
            CLEAN_SAMPLE
            + "\nvoid Oops(const std::wstring& dir) {\n"
            "  g_lookup_card_path = dir + L\"card.png\";\n}\n"
        )
        self.assertNotEqual([], find_unvalidated_placeholder_values(dirty))

    def test_unguarded_bitmap_copy_is_red(self) -> None:
        dirty = self._mutate(
            "  if (!IsLookupFrameSane(header, frame)) return false;\n", ""
        )
        self.assertNotEqual([], find_unguarded_bitmap_copies(dirty))

    def test_anchor_host_page_not_derived_from_draw_host_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "  group.hostPage = global.fushiLookupPageOf(host);",
            "  group.hostPage = global.fushiLookupPageOf(global.kag.current);",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_host_messages_hardcoded_to_fore_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "  var messages = global.fushiLookupMessagesForPage(group.hostPage);",
            "  var messages = global.kag.fore.messages;",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_stale_anchor_fields_not_reset_is_red(self) -> None:
        dirty = self._mutate_anchor("  group.currentIdentity = void;\n", "")
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_read_is_red_when_removed(self) -> None:
        dirty = self._mutate_anchor(
            '  var currentNum = global.fushiLookupField(global.kag, "currentNum");\n',
            "",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_without_integer_gate_is_red(self) -> None:
        dirty = self._mutate_anchor(
            '  if(messages !== void && typeof currentNum == "Integer" &&\n',
            "  if(messages !== void &&\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_without_upper_bound_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "    currentNum >= 0 && currentNum < messages.count)\n",
            "    currentNum >= 0)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_indexing_fore_directly_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "      var indexed = messages[currentNum];",
            "      var indexed = global.kag.fore.messages[currentNum];",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_hit_not_recorded_as_weak_strength_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "        group.anchorStrength = 1;\n", ""
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_not_via_resolve_current_slot_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "  var resolved = global.fushiLookupResolveCurrentSlot();\n", ""
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_allowed_to_override_current_num_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "        (group.anchorIdentity === void ||\n"
            "         (resolved.page == group.anchorPage &&\n"
            "          resolved.index == group.anchorIndex)))\n",
            "        true)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_not_projected_to_host_page_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "      var projected = messages[resolved.index];",
            "      var projected = global.kag.back.messages[resolved.index];",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_strong_identity_without_dual_equality_gate_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "        if(resolved.page == group.anchorPage &&\n"
            "          resolved.identity === projected)\n",
            "        if(resolved.identity !== void)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_size_comparison_reintroduced_as_identity_gate_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "      if(projected !== void && projected !== null && isvalid projected &&\n",
            "      if(projected !== void && projected !== null && isvalid projected &&\n"
            "        projected.width == host.width &&\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_capture_reprojecting_current_num_is_red(self) -> None:
        """锚点被搬回 Capture 就是这次修复要根除的形状。

        Capture 跑在鼠标事件/渲染回调里，那时 kag.currentNum 可能已经指向共存的另一个
        消息层；按它重新投影会把这条绑定挂到别人的台词上。冻结点只能是 drawCh 执行期。
        """
        dirty = self._mutate_anchor(
            "  var entry = global.fushiLookupFindEntry(renderer);\n",
            "  var entry = global.fushiLookupFindEntry(renderer);\n"
            '  var late = global.fushiLookupField(global.kag, "currentNum");\n',
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_oversized_tjs_literal_is_red_and_splitting_fixes_it(self) -> None:
        # 一行 60 个汉字注释 = 63 个 UTF-16 单元；200 行远超上限，100 行安全。
        filler = "// " + "あ" * 60 + "\n"
        one = 'static const wchar_t k[] = LR"TJS(\n' + filler * 200 + ')TJS";\n'
        self.assertNotEqual([], find_oversized_tjs_literals(MaskedSource(one)))
        # 同样多的内容拆成两段就该绿——这条规则量的是**单段**长度，不是全文件总量；
        # 否则修法会被误导成"删注释"，而正解一直是拆段。
        half = filler * 100
        two = (
            'static const wchar_t k[] = LR"TJS(\n'
            + half
            + ')TJS" LR"TJS(\n'
            + half
            + ')TJS";\n'
        )
        self.assertEqual([], find_oversized_tjs_literals(MaskedSource(two)))

    def test_legacy_cross_page_first_same_size_anchor_is_explicitly_red(
        self,
    ) -> None:
        found = find_invalid_kag_anchor_identity_selection(
            MaskedSource(LEGACY_CROSS_PAGE_ANCHOR_SAMPLE)
        )
        self.assertTrue(
            any("pages=[fore,back]" in violation for violation in found),
            "旧跨页首个同尺寸 break 必须有自己的定向诊断，不能只靠其它缺项带红",
        )


    def test_primary_chain_starting_from_layer_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "  current = primary;\n  guard = 0;",
            "  current = layer;\n  guard = 0;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_missing_primary_parent_chain_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "  while(current !== void && current !== null && isvalid current)\n"
            "  {\n"
            "    if(++guard > 32)\n"
            "    {\n"
            "      global.fushiLookupMark(16);\n"
            "      return false;\n"
            "    }\n"
            "    primaryRoot = current;\n"
            "    primaryX += current.left;\n"
            "    primaryY += current.top;\n"
            "    current = current.parent;\n"
            "  }\n",
            "",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_primary_chain_start_assignment_moved_after_loop_is_red(self) -> None:
        before = (
            "  current = primary;\n"
            "  guard = 0;\n"
            "  while(current !== void && current !== null && isvalid current)"
        )
        after = (
            "  guard = 0;\n"
            "  while(current !== void && current !== null && isvalid current)"
        )
        self.assertIn(before, COORDINATE_CLEAN_SAMPLE)
        moved = COORDINATE_CLEAN_SAMPLE.replace(before, after, 1)
        move_anchor = (
            "    current = current.parent;\n"
            "  }\n\n"
            "  if(layerRoot === void || primaryRoot === void ||"
        )
        self.assertIn(move_anchor, moved)
        moved = moved.replace(
            move_anchor,
            "    current = current.parent;\n"
            "  }\n"
            "  current = primary;\n\n"
            "  if(layerRoot === void || primaryRoot === void ||",
            1,
        )
        self.assertNotEqual(
            [],
            find_invalid_common_root_coordinate_conversion(MaskedSource(moved)),
        )

    def test_primary_chain_start_assignment_inside_first_loop_is_red(self) -> None:
        assignment = "  current = primary;\n"
        self.assertIn(assignment, COORDINATE_CLEAN_SAMPLE)
        moved = COORDINATE_CLEAN_SAMPLE.replace(assignment, "", 1)
        first_parent_step = "    current = current.parent;\n"
        self.assertIn(first_parent_step, moved)
        moved = moved.replace(
            first_parent_step,
            first_parent_step + "    current = primary;\n",
            1,
        )
        self.assertNotEqual(
            [],
            find_invalid_common_root_coordinate_conversion(MaskedSource(moved)),
        )

    def test_primary_chain_without_guard_reset_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "  current = primary;\n  guard = 0;",
            "  current = primary;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_accepting_different_roots_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "    layerRoot !== primaryRoot)",
            "    layerRoot === primaryRoot)",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_adding_root_x_coordinates_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "  global.fushiLookupOffX = layerX - primaryX;",
            "  global.fushiLookupOffX = layerX + primaryX;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_adding_root_y_coordinates_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "  global.fushiLookupOffY = layerY - primaryY;",
            "  global.fushiLookupOffY = layerY + primaryY;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_publishing_offsets_before_the_common_root_gate_is_red(self) -> None:
        assignments = (
            "  global.fushiLookupOffX = layerX - primaryX;\n"
            "  global.fushiLookupOffY = layerY - primaryY;\n"
        )
        self.assertIn(assignments, COORDINATE_CLEAN_SAMPLE)
        moved = COORDINATE_CLEAN_SAMPLE.replace(assignments, "", 1)
        gate = (
            "  if(layerRoot === void || primaryRoot === void ||\n"
            "    layerRoot !== primaryRoot)"
        )
        self.assertIn(gate, moved)
        moved = moved.replace(gate, assignments + gate, 1)
        self.assertNotEqual(
            [],
            find_invalid_common_root_coordinate_conversion(MaskedSource(moved)),
        )

    def test_dropping_a_parent_chain_cycle_guard_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "    if(++guard > 32)\n"
            "    {\n"
            "      global.fushiLookupMark(16);\n"
            "      return false;\n"
            "    }\n",
            "",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_different_root_failure_returning_true_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "  if(layerRoot === void || primaryRoot === void ||\n"
            "    layerRoot !== primaryRoot)\n"
            "  {\n"
            "    global.fushiLookupMark(16);\n"
            "    return false;\n"
            "  }",
            "  if(layerRoot === void || primaryRoot === void ||\n"
            "    layerRoot !== primaryRoot)\n"
            "  {\n"
            "    global.fushiLookupMark(16);\n"
            "    return true;\n"
            "  }",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_unchecked_common_root_call_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "    if(!global.fushiLookupComputeOffset(layer))\n"
            "    {\n"
            "      global.fushiLookupMark(32);\n"
            "      continue;\n"
            "    }",
            "    global.fushiLookupComputeOffset(layer);",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_conditionally_skipping_after_common_root_failure_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "      global.fushiLookupMark(32);\n"
            "      continue;",
            "      global.fushiLookupMark(32);\n"
            "      if(submit) continue;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_probe_ignoring_common_root_x_offset_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "    rx = lx - global.fushiLookupOffX - entry.imgLeft - entry.originX;",
            "    rx = lx - entry.imgLeft - entry.originX;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_probe_ignoring_common_root_y_offset_is_red(self) -> None:
        dirty = self._mutate_coordinate(
            "    ry = ly - global.fushiLookupOffY - entry.imgTop - entry.originY;",
            "    ry = ly - entry.imgTop - entry.originY;",
        )
        self.assertNotEqual(
            [], find_invalid_common_root_coordinate_conversion(dirty)
        )

    def test_ownerless_card_dismissal_is_red(self) -> None:
        # 退回旧判据：任意 renderer 的行文本变了就收卡。
        dirty = self._mutate(OWNED_DISMISS_SAMPLE, "        global.fushiLookupDismiss();")
        self.assertNotEqual([], find_ownerless_card_dismissals(dirty))

    def test_owner_marker_only_in_a_comment_is_still_red(self) -> None:
        # 判据被改坏、只在注释里留个名字——守卫必须照红（否则它形同虚设）。
        dirty = self._mutate(
            OWNED_DISMISS_SAMPLE,
            "        // 归属见 global.fushiLookupCardEntry\n"
            "        global.fushiLookupDismiss();",
        )
        self.assertNotEqual([], find_ownerless_card_dismissals(dirty))

    def test_equivalent_owner_check_stays_green(self) -> None:
        # 反向变异：判据换个等价写法，守卫不该跟着红（否则它是在守写法不是守行为）。
        dirty = self._mutate(
            OWNED_DISMISS_SAMPLE,
            "        if(entry === global.fushiLookupCardEntry) "
            "global.fushiLookupDismiss();",
        )
        self.assertEqual([], find_ownerless_card_dismissals(dirty))

    def test_missing_capture_function_is_red(self) -> None:
        dirty = MaskedSource(
            CLEAN_SAMPLE.replace("global.fushiLookupCapture = function", "// gone", 1)
        )
        self.assertNotEqual([], find_ownerless_card_dismissals(dirty))

    # ── BUG-1724 的变异实测。断言字面量照抄在此，改坏判据必须真红。 ──────────
    #   干净样本：worker 入口只登记意图；主线程入口先核对线程身份再调引擎。
    THREAD_CLEAN = (
        "void PollKirikiriLookupInstall() {\n"
        "  if (g_stop) return;\n"
        "  InterlockedExchange(&g_lookup_install_requested, 1);\n"
        "}\n"
        "void RunKirikiriLookupInstallOnMainThread() {\n"
        "  const DWORD main_tid = ResolveKirikiriEngineMainThreadId();\n"
        "  if (main_tid == 0 || GetCurrentThreadId() != main_tid) return;\n"
        "  QueryKirikiriNativeLookupFunctions(g_lookup_exporter, names, fns, 5);\n"
        "  g_lookup_alloc_string(bootstrap.c_str());\n"
        "  g_lookup_add_continuous(&g_lookup_pump_callback);\n"
        "}\n"
    )

    def test_thread_guard_is_green_on_clean_sample(self) -> None:
        clean = MaskedSource(self.THREAD_CLEAN)
        self.assertEqual([], find_engine_calls_on_hook_worker(clean))
        self.assertEqual([], find_missing_main_thread_identity_check(clean))

    def test_engine_call_moved_back_onto_hook_worker_is_red(self) -> None:
        dirty = MaskedSource(
            self.THREAD_CLEAN.replace(
                "  InterlockedExchange(&g_lookup_install_requested, 1);",
                "  g_lookup_add_continuous(&g_lookup_pump_callback);",
                1,
            )
        )
        self.assertNotEqual([], find_engine_calls_on_hook_worker(dirty))

    def test_engine_call_before_thread_identity_check_is_red(self) -> None:
        dirty = MaskedSource(
            self.THREAD_CLEAN.replace(
                "  const DWORD main_tid = ResolveKirikiriEngineMainThreadId();",
                "  g_lookup_alloc_string(bootstrap.c_str());\n"
                "  const DWORD main_tid = ResolveKirikiriEngineMainThreadId();",
                1,
            )
        )
        self.assertNotEqual([], find_missing_main_thread_identity_check(dirty))

    def test_dropped_thread_identity_check_is_red(self) -> None:
        dirty = MaskedSource(
            self.THREAD_CLEAN.replace(
                "  if (main_tid == 0 || GetCurrentThreadId() != main_tid) return;",
                "",
                1,
            )
        )
        self.assertNotEqual([], find_missing_main_thread_identity_check(dirty))

    def test_thread_identity_check_only_in_a_comment_is_still_red(self) -> None:
        # 判据被改坏、只在注释里留个名字——守卫必须照红（否则它形同虚设）。
        dirty = MaskedSource(
            self.THREAD_CLEAN.replace(
                "  if (main_tid == 0 || GetCurrentThreadId() != main_tid) return;",
                "  // GetCurrentThreadId() 已在别处核对过",
                1,
            )
        )
        self.assertNotEqual([], find_missing_main_thread_identity_check(dirty))

    def test_equivalent_thread_identity_check_stays_green(self) -> None:
        # 反向变异：等价写法不该跟着红（否则守的是写法不是行为）。
        dirty = MaskedSource(
            self.THREAD_CLEAN.replace(
                "  if (main_tid == 0 || GetCurrentThreadId() != main_tid) return;",
                "  const DWORD self_tid = GetCurrentThreadId();\n"
                "  if (main_tid == 0) return;\n"
                "  if (self_tid != main_tid) return;",
                1,
            )
        )
        self.assertEqual([], find_missing_main_thread_identity_check(dirty))

    def test_masking_keeps_line_numbers_and_hides_literal_content(self) -> None:
        self.assertEqual(len(self.clean.masked), len(CLEAN_SAMPLE))
        self.assertEqual(self.clean.masked.count("\n"), CLEAN_SAMPLE.count("\n"))
        self.assertNotIn("fushiLookupApply", self.clean.masked)
        # 行号映射没漂：干净样本里 memcpy 的行号按原文数得出来。
        index = CLEAN_SAMPLE.index("memcpy(")
        self.assertEqual(
            self.clean.line_of(index), CLEAN_SAMPLE.count("\n", 0, index) + 1
        )


if __name__ == "__main__":
    unittest.main()

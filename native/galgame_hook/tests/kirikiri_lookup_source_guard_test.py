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

变异实测纪律：本文件把每条规则实现成一个独立的 `find_*` 函数，`RealAdapterTest` 用它
扫真文件，`MutationSelfTest` 用它扫**合成的脏输入**并要求非空。两组都在，这守卫才不
可能是「永远绿的空守卫」。
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path
from typing import Iterator


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

# KAGEX 缺席门：`if(typeof global.TextRender == "Object") { ... } else { ... }`。
# 经典 KAG3 游戏（Fate/stay night[Realta Nua]、PRETTY×CATION2、フタマタ恋愛）整个
# global.TextRender 都不存在，逐字几何只从原生 Layer.drawText 经过——全局补丁在**这个
# else 里**是唯一可行采集面，不是又一条兜底。装了 textrender.dll 的游戏走 if 分支，
# 一行都不多绕，所以"全局补丁让所有 UI 绘制多绕一层"的代价只落在别无来源的游戏上。
KAGEX_GATE_RE = re.compile(
    r'if\s*\(\s*typeof\s+global\.TextRender\s*==\s*"Object"\s*\)'
)


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


# ── 扫真文件 ────────────────────────────────────────────────────────────────


class RealAdapterTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = MaskedSource(ADAPTER.read_text(encoding="utf-8"))

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
            "游戏进程里不得有 HTTP 客户端或认证凭据；开关与数据一律走 v14 共享内存查词区。",
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


class MutationSelfTest(unittest.TestCase):
    """把每条规则要抓的东西真的塞进合成源码，确认规则会红。"""

    maxDiff = None

    def setUp(self) -> None:
        self.clean = MaskedSource(CLEAN_SAMPLE)

    def _mutate(self, old: str, new: str) -> MaskedSource:
        self.assertIn(old, CLEAN_SAMPLE, "变异锚点必须真的存在于干净样本里")
        dirty = CLEAN_SAMPLE.replace(old, new, 1)
        self.assertNotEqual(dirty, CLEAN_SAMPLE, "变异样本必须真的与干净样本不同")
        return MaskedSource(dirty)

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

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


def find_global_monkey_patches(source: MaskedSource) -> list[str]:
    """引擎全局类的补丁只允许出现在默认关闭的探测分支里。

    `global.Layer.drawText` 挂上包装之后，游戏**所有** UI 绘制都要多绕一层；游戏内
    渲染下这直接变成掉帧。运行日志已经证伪了这条捕获路径（只有 TextRender 命中），
    所以它只能作为换游戏时的探针存在，且默认关闭。
    """
    spans = _probe_block_spans(source.text)
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
    """守住 KAG 消息层锚点的宿主页投影契约。

    fore/back 是同一组逻辑消息层的双缓冲页。稳定身份是 `currentNum`；旧 KAG 没有这个
    字段时，才允许以 `current` 的对象身份找逻辑下标。宽高不是身份，`current.comp` 和
    `id` 也不是必需契约。这里钉住 hostPage、宿主页数组、currentNum 主路径、对象身份
    兜底及发布顺序；把这些片段散落在函数里不能过。
    """
    violations: list[str] = []
    if not TJS_RAW_RE.search(source.text):
        return [f'{ADAPTER.name}: 没有找到 LR"TJS(...)TJS" bootstrap']

    tjs = _joined_tjs_payload(source)
    captures = _assigned_tjs_functions(tjs, "fushiLookupCapture")
    if len(captures) != 1:
        return [
            f"{ADAPTER.name}: fushiLookupCapture 定义数应为 1，实际 {len(captures)}"
        ]

    _, capture_body = captures[0]
    capture = _compact_tjs(capture_body)

    # 这是已被真机证伪的旧实现形状。单独点名，避免它只因新结构缺失而间接变红：
    # mutation 必须能证明守卫本身认得出「跨页按尺寸首个命中」。
    legacy_pages = re.compile(
        r"(?:var)?pages=\[(?:global\.kag\.)?fore(?:\.messages)?,"
        r"(?:global\.kag\.)?back(?:\.messages)?\]"
    )
    if legacy_pages.search(capture):
        violations.append(
            f"{ADAPTER.name}: 禁止旧 pages=[fore,back] 跨页按尺寸首个命中后 break"
        )

    host_page = "varhostPage=global.fushiLookupPageOf(best.host);"
    host_messages_decl = "varhostMessages=void;"
    host_messages_select = (
        "hostMessages=(hostPage==1)?global.kag.fore.messages:"
        "((hostPage==2)?global.kag.back.messages:void);"
    )
    entry_layer = (
        "entry.layer=(anchorMsg!==void&&isvalidanchorMsg)?anchorMsg:best.host;"
    )
    entry_host_page = "entry.hostPage=hostPage;"
    for needle, message in (
        (host_page, "hostPage 必须由 drawCh 宿主 best.host 求得"),
        (host_messages_decl, "必须先声明宿主页消息数组"),
        (host_messages_select, "宿主页消息数组必须由 hostPage 唯一选择"),
        (entry_layer, "选定的 KAG 消息层必须写入 entry.layer"),
        (entry_host_page, "hostPage 必须随记录写入 entry.hostPage"),
    ):
        count = capture.count(needle)
        if count != 1:
            violations.append(f"{ADAPTER.name}: {message}（出现 {count} 次）")

    slot = _SLOT_RE.pattern
    current_num_decl_re = re.compile(
        rf"varcurrentNum=global\.fushiLookupField\(global\.kag,(?P<field>{slot})\);"
    )
    current_decl_re = re.compile(
        rf"varcurrentMsg=global\.fushiLookupField\(global\.kag,(?P<field>{slot})\);"
    )
    current_num_decls = list(current_num_decl_re.finditer(capture))
    current_decls = list(current_decl_re.finditer(capture))

    def field_literal_is(match: re.Match[str], expected: str) -> bool:
        token = match.group("field")
        literal = tjs.literals[int(token[1:-1])]
        return (
            len(literal) >= 2
            and literal[0] == literal[-1]
            and literal[0] in {'"', "'"}
            and literal[1:-1] == expected
        )

    if len(current_num_decls) != 1 or not field_literal_is(
        current_num_decls[0], "currentNum"
    ):
        violations.append(
            f"{ADAPTER.name}: currentNum 主路径必须唯一读取 kag.currentNum"
        )
    if len(current_decls) != 1 or not field_literal_is(current_decls[0], "current"):
        violations.append(
            f"{ADAPTER.name}: identity 兜底必须唯一读取 kag.current"
        )

    current_num_gate_re = re.compile(
        rf"if\(hostMessages!==void&&typeofcurrentNum==(?P<type>{slot})&&"
        r"currentNum>=0&&currentNum<hostMessages\.count\)"
    )
    current_num_gates = list(current_num_gate_re.finditer(capture))
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
            capture, current_num_gates[0].group(0)
        )

    fallback_gate = (
        "if(anchorMsg===void&&hostMessages!==void&&currentMsg!==void&&"
        "currentMsg!==null&&isvalidcurrentMsg)"
    )
    fallback_spans = _braced_spans_after(capture, fallback_gate)
    if len(current_num_spans) != 1:
        violations.append(
            f"{ADAPTER.name}: currentNum 整数/上下界门必须包住唯一主路径"
        )
    else:
        current_num_body = capture[
            current_num_spans[0][0] : current_num_spans[0][1]
        ]
        indexed_decl = "varindexedMsg=hostMessages[currentNum];"
        indexed_gate = "if(indexedMsg!==void&&indexedMsg!==null&&isvalidindexedMsg)"
        indexed_spans = _braced_spans_after(current_num_body, indexed_gate)
        if current_num_body.count(indexed_decl) != 1 or len(indexed_spans) != 1:
            violations.append(
                f"{ADAPTER.name}: currentNum 必须索引宿主页并校验所得消息层"
            )
        else:
            indexed_body = current_num_body[
                indexed_spans[0][0] : indexed_spans[0][1]
            ]
            if indexed_body.count("anchorMsg=indexedMsg;") != 1:
                violations.append(
                    f"{ADAPTER.name}: currentNum 主路径必须发布宿主页同下标消息层"
                )

    if len(fallback_spans) != 1:
        violations.append(
            f"{ADAPTER.name}: 对象身份兜底只能在 currentNum 主路径未选中时进入"
        )
    else:
        fallback_body = capture[fallback_spans[0][0] : fallback_spans[0][1]]
        identity_pages = (
            "varidentityPages=[global.kag.fore.messages,"
            "global.kag.back.messages];"
        )
        page_loop = "for(varpgi=0;pgi<identityPages.count&&identityIndex<0;pgi++)"
        message_loop = "for(varmj=0;mj<identityMessages.count;mj++)"
        identity_gate = "if(identityMessages[mj]===currentMsg)"
        projection_gate = "if(identityIndex>=0&&identityIndex<hostMessages.count)"
        page_spans = _braced_spans_after(fallback_body, page_loop)
        projection_spans = _braced_spans_after(fallback_body, projection_gate)
        if fallback_body.count("varidentityIndex=-1;") != 1:
            violations.append(
                f"{ADAPTER.name}: 对象身份兜底必须以未命中下标开始"
            )
        if fallback_body.count(identity_pages) != 1:
            violations.append(
                f"{ADAPTER.name}: 对象身份兜底必须覆盖 fore/back 两个消息数组"
            )
        if len(page_spans) != 1:
            violations.append(f"{ADAPTER.name}: 必须只遍历一次 identityPages")
        else:
            page_body = fallback_body[page_spans[0][0] : page_spans[0][1]]
            message_spans = _braced_spans_after(page_body, message_loop)
            if (
                page_body.count("varidentityMessages=identityPages[pgi];") != 1
                or len(message_spans) != 1
            ):
                violations.append(
                    f"{ADAPTER.name}: 每个 identity 页必须只遍历一次消息数组"
                )
            else:
                message_body = page_body[
                    message_spans[0][0] : message_spans[0][1]
                ]
                identity_spans = _braced_spans_after(message_body, identity_gate)
                if len(identity_spans) != 1:
                    violations.append(
                        f"{ADAPTER.name}: current 只能用对象严格身份匹配逻辑下标"
                    )
                else:
                    identity_body = message_body[
                        identity_spans[0][0] : identity_spans[0][1]
                    ]
                    index_pos = identity_body.find("identityIndex=mj;")
                    break_pos = identity_body.find("break;")
                    if not (
                        identity_body.count("identityIndex=mj;") == 1
                        and identity_body.count("break;") == 1
                        and 0 <= index_pos < break_pos
                        and identity_body.endswith("break;")
                    ):
                        violations.append(
                            f"{ADAPTER.name}: 对象身份命中后必须保存下标并结束当前页遍历"
                        )

        if len(projection_spans) != 1:
            violations.append(
                f"{ADAPTER.name}: identity 下标投影必须通过宿主页上界门"
            )
        else:
            projection_body = fallback_body[
                projection_spans[0][0] : projection_spans[0][1]
            ]
            projected_decl = "varidentityMsg=hostMessages[identityIndex];"
            projected_gate = "if(identityMsg!==void&&identityMsg!==null&&isvalididentityMsg)"
            projected_spans = _braced_spans_after(projection_body, projected_gate)
            if (
                projection_body.count(projected_decl) != 1
                or len(projected_spans) != 1
            ):
                violations.append(
                    f"{ADAPTER.name}: identity 下标必须投影到宿主页并校验消息层"
                )
            else:
                projected_body = projection_body[
                    projected_spans[0][0] : projected_spans[0][1]
                ]
                if projected_body.count("anchorMsg=identityMsg;") != 1:
                    violations.append(
                        f"{ADAPTER.name}: identity 兜底必须发布宿主页同下标消息层"
                    )

    selection_start = capture.find(host_page)
    selection_end = capture.find(entry_layer)
    selection = (
        capture[selection_start:selection_end]
        if 0 <= selection_start < selection_end
        else capture
    )
    if re.search(
        r"(?:\.width|\.height)(?:==|!=|<=|>=)|"
        r"(?:==|!=|<=|>=)[^;{}]{0,80}(?:\.width|\.height)",
        selection,
    ):
        violations.append(f"{ADAPTER.name}: 锚点身份门不得比较消息层宽高")

    current_num_decl_pos = (
        current_num_decls[0].start() if len(current_num_decls) == 1 else -1
    )
    current_decl_pos = current_decls[0].start() if len(current_decls) == 1 else -1
    current_num_gate_pos = (
        current_num_gates[0].start() if len(current_num_gates) == 1 else -1
    )
    ordered = (
        capture.find(host_page),
        capture.find(host_messages_decl),
        capture.find(host_messages_select),
        current_num_decl_pos,
        current_num_gate_pos,
        current_decl_pos,
        capture.find(fallback_gate),
        capture.find(entry_layer),
        capture.find(entry_host_page),
    )
    if any(index < 0 for index in ordered) or list(ordered) != sorted(ordered):
        violations.append(
            f"{ADAPTER.name}: 锚点必须按 hostPage→宿主页→currentNum→identity 兜底→entry 的顺序选择"
        )
    elif (
        len(current_num_spans) != 1
        or len(fallback_spans) != 1
        or not (
            current_num_spans[0][1]
            < ordered[5]
            < ordered[6]
            < fallback_spans[0][1]
            < ordered[7]
        )
        or not (
            _brace_depth_at(capture, ordered[0])
            == _brace_depth_at(capture, ordered[7])
            == _brace_depth_at(capture, ordered[8])
        )
    ):
        violations.append(
            f"{ADAPTER.name}: currentNum 与 identity 兜底必须是同一选择块中互不嵌套的两级路径"
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
)TJS";
"""


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
global.fushiLookupCapture = function(renderer)
{
  var anchorMsg = void;
  var hostPage = global.fushiLookupPageOf(best.host);
  var hostMessages = void;
  try
  {
    hostMessages = (hostPage == 1) ? global.kag.fore.messages :
      ((hostPage == 2) ? global.kag.back.messages : void);
  }
  catch(e) { hostMessages = void; }
  var currentNum = global.fushiLookupField(global.kag, "currentNum");
  if(hostMessages !== void && typeof currentNum == "Integer" &&
    currentNum >= 0 && currentNum < hostMessages.count)
  {
    try
    {
      var indexedMsg = hostMessages[currentNum];
      if(indexedMsg !== void && indexedMsg !== null && isvalid indexedMsg)
      {
        anchorMsg = indexedMsg;
      }
    }
    catch(e) {}
  }
)TJS" LR"TJS(
  var currentMsg = global.fushiLookupField(global.kag, "current");
  if(anchorMsg === void && hostMessages !== void && currentMsg !== void &&
    currentMsg !== null && isvalid currentMsg)
  {
    var identityIndex = -1;
    try
    {
      var identityPages = [global.kag.fore.messages,
        global.kag.back.messages];
      for(var pgi = 0; pgi < identityPages.count && identityIndex < 0; pgi++)
      {
        var identityMessages = identityPages[pgi];
        for(var mj = 0; mj < identityMessages.count; mj++)
        {
          if(identityMessages[mj] === currentMsg)
          {
            identityIndex = mj;
            break;
          }
        }
      }
      if(identityIndex >= 0 && identityIndex < hostMessages.count)
      {
        var identityMsg = hostMessages[identityIndex];
        if(identityMsg !== void && identityMsg !== null && isvalid identityMsg)
        {
          anchorMsg = identityMsg;
        }
      }
    }
    catch(e) {}
  }
  entry.layer = (anchorMsg !== void && isvalid anchorMsg)
    ? anchorMsg : best.host;
  entry.hostPage = hostPage;
};
)TJS";
'''


# 旧 prototype 的负样本：跨 fore/back 页扫描，只看尺寸，遇到第一个就结束。
# 这是单独的点名变异，不能只靠“新结构不完整”的附带报错证明守卫有效。
LEGACY_CROSS_PAGE_ANCHOR_SAMPLE = r'''
static const wchar_t kAnchorBootstrap[] = LR"TJS(
global.fushiLookupCapture = function(renderer)
{
  var anchorMsg = void;
  var pages = [global.kag.fore, global.kag.back];
  for(var pgi = 0; pgi < pages.count && anchorMsg === void; pgi++)
  {
    var messages = pages[pgi].messages;
    for(var mj = 0; mj < messages.count; mj++)
    {
      var candidate = messages[mj];
      if(candidate.width == best.host.width &&
        candidate.height == best.host.height)
      {
        anchorMsg = candidate;
        break;
      }
    }
  }
  entry.layer = (anchorMsg !== void && isvalid anchorMsg)
    ? anchorMsg : best.host;
};
)TJS";
'''


class MutationSelfTest(unittest.TestCase):
    """把每条规则要抓的东西真的塞进合成源码，确认规则会红。"""

    maxDiff = None

    def setUp(self) -> None:
        self.clean = MaskedSource(CLEAN_SAMPLE)
        self.coordinate_clean = MaskedSource(COORDINATE_CLEAN_SAMPLE)
        self.anchor_clean = MaskedSource(ANCHOR_IDENTITY_CLEAN_SAMPLE)

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

    def test_clean_sample_passes_every_rule(self) -> None:
        self.assertEqual([], find_dynamic_tjs_concatenations(self.clean))
        self.assertEqual([], find_network_debris(self.clean))
        self.assertEqual([], find_global_monkey_patches(self.clean))
        self.assertEqual([], find_default_on_probe_switches(self.clean))
        self.assertEqual([], find_unvalidated_placeholder_values(self.clean))
        self.assertEqual([], find_unguarded_bitmap_copies(self.clean))
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
            "  var hostPage = global.fushiLookupPageOf(best.host);",
            "  var hostPage = global.fushiLookupPageOf(global.kag.current);",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_host_messages_hardcoded_to_fore_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "    hostMessages = (hostPage == 1) ? global.kag.fore.messages :\n"
            "      ((hostPage == 2) ? global.kag.back.messages : void);",
            "    hostMessages = global.kag.fore.messages;",
        )
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
            '  if(hostMessages !== void && typeof currentNum == "Integer" &&\n',
            "  if(hostMessages !== void &&\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_without_upper_bound_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "    currentNum >= 0 && currentNum < hostMessages.count)\n",
            "    currentNum >= 0)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_num_indexing_fore_directly_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "      var indexedMsg = hostMessages[currentNum];",
            "      var indexedMsg = global.kag.fore.messages[currentNum];",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_allowed_to_override_current_num_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "  if(anchorMsg === void && hostMessages !== void && currentMsg !== void &&\n"
            "    currentMsg !== null && isvalid currentMsg)\n",
            "  if(hostMessages !== void && currentMsg !== void &&\n"
            "    currentMsg !== null && isvalid currentMsg)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_omitting_back_page_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "      var identityPages = [global.kag.fore.messages,\n"
            "        global.kag.back.messages];",
            "      var identityPages = [global.kag.fore.messages];",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_using_id_instead_of_object_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "          if(identityMessages[mj] === currentMsg)\n",
            "          if(identityMessages[mj].id == currentMsg.id)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_identity_fallback_not_projected_to_host_page_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "        var identityMsg = hostMessages[identityIndex];",
            "        var identityMsg = identityMessages[identityIndex];",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_size_comparison_reintroduced_as_identity_gate_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "        if(identityMsg !== void && identityMsg !== null && isvalid identityMsg)\n",
            "        if(identityMsg !== void && identityMsg !== null && "
            "isvalid identityMsg && identityMsg.width == best.host.width)\n",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_current_comp_reintroduced_instead_of_identity_projection_is_red(self) -> None:
        dirty = self._mutate_anchor(
            "        var identityMsg = hostMessages[identityIndex];",
            "        var identityMsg = currentMsg.comp;",
        )
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

    def test_not_persisting_host_page_is_red(self) -> None:
        dirty = self._mutate_anchor("  entry.hostPage = hostPage;\n", "")
        self.assertNotEqual(
            [], find_invalid_kag_anchor_identity_selection(dirty)
        )

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

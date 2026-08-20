#!/usr/bin/env python3
"""Ren'Py 游戏内查词传感器的源码扫描守卫。

守的是 `hook/adapters/renpy_lookup.inc`。每条都对应一个**已经付出过代价**的形态：

1. **后台线程只登记意图，不碰 Python。** `PollRenpyLookupInstall` 里不得出现任何
   `g_py_*` 调用。这是 BUG-1724 的直接教训：KiriKiri 当初就是在 HookWorker 上调了引擎
   API（TJS 字符串池分配 + 连续事件回调容器），真机随机崩在引擎内部，而且命中率低到
   靠跑次数根本定位不了。Ren'Py 这边 Layout / Render / layout_cache 同样全部无锁。

2. **`.inc` 里一行 `#include` 都不能有。** 它被 include 进 renpy_adapter.inc，而后者又在
   dll_main.cpp 的匿名命名空间内部展开；头文件里的 `namespace fushi_voice_hook` 会在匿名
   命名空间里再开一个同名嵌套命名空间，把真正的 `::fushi_voice_hook` 整个遮住 —— 症状是
   **之后每个 adapter 都报错**，一条都不指向肇事文件。（这个坑在通用呈现器上真踩过一次。）

3. **坐标换算不得只认 GLDraw。** 真机实测：软件渲染器 `SWDraw` 上没有 `untranslate_mouse`
   （AttributeError），必须有降级路径。所以 bootstrap 里出现 `untranslate_mouse` 时，
   同一段脚本里必须同时有 `virtual_box` 与 `fushi_client` 两级降级。

4. **提交触发不得用左键。** Ren'Py 的左键属于引擎：点一下就推进剧情并重建 say screen，
   于是「点字查词」与「往下读」是同一个动作。真机实测一次点击把 text_writes 从 27 顶到 31，
   被查的那句已经不在了。触发必须是 Shift。

变异实测纪律：每条规则一个独立 `find_*`；`RealSourceTest` 扫真文件要求为空，
`MutationSelfTest` 扫合成脏输入要求非空。两组都在，守卫才不可能是永远绿的空守卫。
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

HOOK_ROOT = Path(__file__).resolve().parent.parent
RENPY_LOOKUP = HOOK_ROOT / "hook" / "adapters" / "renpy_lookup.inc"
RENPY_ADAPTER = HOOK_ROOT / "hook" / "adapters" / "renpy_adapter.inc"

INCLUDE_RE = re.compile(r"^\s*#\s*include\b.*$", re.MULTILINE)


def strip_comments(text: str) -> str:
    """把 // 与 /* */ 注释换成等长空白，保住行号与偏移。"""
    out = list(text)
    i = 0
    end = len(text)
    while i < end:
        char = text[i]
        if char == '"' or char == "'":
            quote = char
            i += 1
            while i < end:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if char == "/" and i + 1 < end and text[i + 1] == "/":
            while i < end and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if char == "/" and i + 1 < end and text[i + 1] == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i + 1 < end and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i + 1 < end:
                out[i] = out[i + 1] = " "
                i += 2
            continue
        i += 1
    return "".join(out)


def _function_body(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        return ""
    open_at = text.find("{", start)
    if open_at < 0:
        return ""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at : i + 1]
    return ""


def find_python_calls_on_worker(source: str) -> list[str]:
    """规则 1：登记函数里不得有任何 Python C API 调用。"""
    body = _function_body(strip_comments(source), "void PollRenpyLookupInstall()")
    if not body:
        return ["找不到 PollRenpyLookupInstall 的函数体"]
    hits = re.findall(r"\bg_py_[A-Za-z_]+\s*\(", body)
    if hits:
        return [
            "PollRenpyLookupInstall 里出现 Python C API 调用："
            + ", ".join(sorted(set(hits)))
            + "；登记函数只能写自己的原子标志（BUG-1724）"
        ]
    return []


def find_includes_in_inc(source: str) -> list[str]:
    """规则 2：该 .inc 在匿名命名空间内展开，一条 #include 都不能有。"""
    stripped = strip_comments(source)
    faults = []
    for match in INCLUDE_RE.finditer(stripped):
        line = stripped.count("\n", 0, match.start()) + 1
        faults.append(
            f"renpy_lookup.inc:{line} 出现 #include："
            "它在匿名命名空间内展开，会把 ::fushi_voice_hook 整个遮住"
        )
    return faults


def find_gldraw_only_mapping(source: str) -> list[str]:
    """规则 3：坐标换算必须有非 GLDraw 的降级路径。"""
    # 用**词边界**而不是裸子串：把 fushi_client 改名成 fushi_client_disabled 时，
    # 裸 `in` 判据仍然为真、守卫静静放行（变异实测抓到过这一条）。短标识符的子串
    # 假阴性是这类守卫最常见的失效方式。
    def has_token(name: str) -> bool:
        return re.search(r"\b" + re.escape(name) + r"\b", source) is not None

    if not has_token("untranslate_mouse"):
        return []  # 换了别的实现，本规则不适用
    faults = []
    if not has_token("virtual_box"):
        faults.append(
            "用了 untranslate_mouse 却没有 virtual_box 降级："
            "软件渲染器 SWDraw 上没有 untranslate_mouse（真机实测 AttributeError）"
        )
    if not has_token("fushi_client"):
        faults.append(
            "缺少基于客户区尺寸的最后一级降级："
            "SWDraw 的 get_physical_size 实测返回的是虚拟尺寸，不能当物理尺寸用"
        )
    return faults


def find_left_button_submit(source: str) -> list[str]:
    """规则 4：提交触发不得用左键。"""
    stripped = strip_comments(source)
    if "VK_LBUTTON" in stripped:
        return [
            "提交触发用了 VK_LBUTTON：Ren'Py 的左键属于引擎（点一下就推进剧情并重建"
            " say screen），查词必须用 Shift"
        ]
    return []


def find_missing_lookup_include(adapter_source: str) -> list[str]:
    """renpy_adapter.inc 必须引入传感器，否则整份是死代码。"""
    if '#include "adapters/renpy_lookup.inc"' in strip_comments(adapter_source):
        return []
    return ["renpy_adapter.inc 没有 include adapters/renpy_lookup.inc"]


class RealSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.lookup = RENPY_LOOKUP.read_text(encoding="utf-8")
        cls.adapter = RENPY_ADAPTER.read_text(encoding="utf-8")

    def test_worker_only_registers_intent(self) -> None:
        self.assertEqual([], find_python_calls_on_worker(self.lookup))

    def test_inc_has_no_includes(self) -> None:
        self.assertEqual([], find_includes_in_inc(self.lookup))

    def test_mapping_has_non_gl_fallbacks(self) -> None:
        self.assertEqual([], find_gldraw_only_mapping(self.lookup))

    def test_submit_is_not_left_button(self) -> None:
        self.assertEqual([], find_left_button_submit(self.lookup))

    def test_adapter_includes_the_sensor(self) -> None:
        self.assertEqual([], find_missing_lookup_include(self.adapter))


DIRTY_WORKER_CALLS_PYTHON = """
void PollRenpyLookupInstall() {
  if (g_stop) return;
  const int gil = g_py_gil_ensure();
  g_py_run_simple("pass");
  g_py_gil_release(gil);
}
"""

CLEAN_WORKER = """
void PollRenpyLookupInstall() {
  if (g_stop) return;
  InterlockedExchange(&g_renpy_lookup_state, 1);
}
"""

DIRTY_WORKER_CALL_IN_COMMENT = """
void PollRenpyLookupInstall() {
  // 这里不要调 g_py_run_simple(...)，安装在别处做
  InterlockedExchange(&g_renpy_lookup_state, 1);
}
"""

DIRTY_INC_WITH_INCLUDE = """
#include "voice_hook_ipc.h"
void PollRenpyLookupInstall() {}
"""

DIRTY_GL_ONLY = "px, py = draw.untranslate_mouse(vx, vy)"

CLEAN_MAPPING = """
fn = getattr(draw, 'untranslate_mouse', None)
box = getattr(draw, 'virtual_box', None)
cw, ch = _fs_g.get('fushi_client', (0, 0))
"""

DIRTY_LBUTTON = "const bool down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;"

CLEAN_SHIFT = "const bool down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;"


class MutationSelfTest(unittest.TestCase):
    def test_python_call_on_worker_is_red(self) -> None:
        self.assertNotEqual([], find_python_calls_on_worker(DIRTY_WORKER_CALLS_PYTHON))

    def test_clean_worker_stays_green(self) -> None:
        self.assertEqual([], find_python_calls_on_worker(CLEAN_WORKER))

    def test_call_only_in_comment_stays_green(self) -> None:
        # 注释里提到函数名不算调用；规则判的是真调用点。
        self.assertEqual([], find_python_calls_on_worker(DIRTY_WORKER_CALL_IN_COMMENT))

    def test_include_in_inc_is_red(self) -> None:
        self.assertNotEqual([], find_includes_in_inc(DIRTY_INC_WITH_INCLUDE))

    def test_gl_only_mapping_is_red(self) -> None:
        self.assertNotEqual([], find_gldraw_only_mapping(DIRTY_GL_ONLY))

    def test_mapping_with_fallbacks_stays_green(self) -> None:
        self.assertEqual([], find_gldraw_only_mapping(CLEAN_MAPPING))

    def test_renamed_client_fallback_is_red(self) -> None:
        # 子串假阴性回归：改名后裸 `in` 判据仍为真，词边界判据必须红。
        renamed = CLEAN_MAPPING.replace("fushi_client", "fushi_client_disabled")
        self.assertNotEqual([], find_gldraw_only_mapping(renamed))

    def test_left_button_submit_is_red(self) -> None:
        self.assertNotEqual([], find_left_button_submit(DIRTY_LBUTTON))

    def test_shift_submit_stays_green(self) -> None:
        self.assertEqual([], find_left_button_submit(CLEAN_SHIFT))

    def test_missing_adapter_include_is_red(self) -> None:
        self.assertNotEqual([], find_missing_lookup_include("void nothing() {}"))


if __name__ == "__main__":
    unittest.main()

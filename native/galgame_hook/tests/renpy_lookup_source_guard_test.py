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

5. **不得裸赋值 config.periodic_callback。** 它是 Ren'Py **官方文档化**的扩展点（约
   20Hz），游戏与 mod 拿它跑自动存档、计时器、状态机。本 DLL 不卸载、没有还原路径，裸赋值
   就是把游戏自己的周期逻辑**本局永久**顶掉，症状是「游戏某个功能莫名不动了」，跟 Hibiki
   完全对不上号。挂载前必须先取旧值并由 tick 链式调用（或直接 append 进复数列表
   config.periodic_callbacks）。

6. **关查词必须有关闸，且关闸赋值排在 enable 早退之前。** 传感器种下去就没有卸载路径。
   native 侧若在 lookup_enabled == 0 时直接 return、不再写任何 Python 全局，而 Python 侧的
   tick 又没有任何 enable 判据，就会继续每帧跑 _fushi_find_render 全树遍历 + 每字形 2 次
   Python 级 mapper 调用，一直到游戏退出（实测 77 字形约 9k 次调用/秒）。所以
   ProcessRenpyLookupTick 必须**先**把 fushi_lookup_on 写进去再判 enable，Python 侧 tick
   必须据它早退。

7. **PYSRC 是窄字符串字面量，上限 16380 字节。** 不是宽串那个 8190 UTF-16 unit；中文注释
   一字 3 字节，很容易无声顶爆成 MSVC C2026（string too big），而那只在 Windows 构建门上红。
   写满了拆段，不要靠删注释腾地方。

8. **宿主心跳必须能自锁、也必须能解锁。** 规则 6 的开关只覆盖「用户关掉查词」。Fushi
   进程被**直接杀掉**时 native 一轮都不再跑，开关永远停在最后写下的 1，Python 侧照样全速
   扫描到游戏退出——症状是「关了 Fushi 之后游戏还是卡」，跟 Hibiki 完全对不上号。所以
   native 每轮再写一个单调递增的 fushi_host_seq，Python 侧连续 N 轮没见它变就自锁早退；
   心跳恢复递增必须立刻解锁，否则退化成「Fushi 重连后查词永久不工作」。自锁只能挡住我们
   自己的扫描，**绝不能**挡住链式调用游戏原本的 periodic_callback。

除源码扫描外，本文件还**真跑一遍** PYSRC（BootstrapBehaviourTest）：在合成的假
renpy.config 上 exec 整段脚本，断言游戏自己的回调被保留并每轮调到、关闸真能挡住扫描、
重复注入不会把自己链成自嵌套。源码扫描守形态，行为测试守语义。

变异实测纪律：每条规则一个独立 `find_*`；`RealSourceTest` 扫真文件要求为空，
`MutationSelfTest` 扫合成脏输入要求非空。两组都在，守卫才不可能是永远绿的空守卫。
"""

from __future__ import annotations

import re
import sys
import types
import unittest
from pathlib import Path

HOOK_ROOT = Path(__file__).resolve().parent.parent
RENPY_LOOKUP = HOOK_ROOT / "hook" / "adapters" / "renpy_lookup.inc"
RENPY_ADAPTER = HOOK_ROOT / "hook" / "adapters" / "renpy_adapter.inc"

INCLUDE_RE = re.compile(r"^\s*#\s*include\b.*$", re.MULTILINE)

PYSRC_RE = re.compile(r'R"PYSRC\((.*?)\)PYSRC"', re.S)

# MSVC C2026 对**窄**字符串字面量的上限：16380 个单字节字符。宽串那个 8190 是
# UTF-16 unit，别拿来套 const char[]（差一倍，会白拆段）。
MSVC_NARROW_LITERAL_BYTES = 16380

PERIODIC_ASSIGN_RE = re.compile(r"\.periodic_callback\s*=(?!=)")
PERIODIC_READ_RE = re.compile(r"""getattr\(\s*\w+\s*,\s*['"]periodic_callback['"]""")
PREV_SLOT = "fushi_prev_periodic"
ENABLE_FLAG = "fushi_lookup_on"


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


def bootstrap_scripts(source: str) -> list[str]:
    """取出 .inc 里全部 PYSRC 原始字面量的内容。"""
    return [match.group(1) for match in PYSRC_RE.finditer(source)]


def _python_function_body(script: str, name: str) -> str:
    """取顶层 def name(...) 的函数体（按缩进切；不引 ast，脏输入也能扫）。"""
    marker = "\ndef " + name + "("
    start = script.find(marker)
    if start < 0:
        return ""
    cursor = script.find(":\n", start)
    if cursor < 0:
        return ""
    body: list[str] = []
    for line in script[cursor + 2 :].split("\n"):
        if line.strip() and not line.startswith((" ", "\t")):
            break
        body.append(line)
    return "\n".join(body)


def find_unchained_periodic_callback(source: str) -> list[str]:
    """规则 5：不得裸赋值 config.periodic_callback，且 tick 必须真调旧回调。"""
    faults: list[str] = []
    for script in bootstrap_scripts(source):
        has_plural = re.search(r"\bperiodic_callbacks\b", script) is not None
        assigns = list(PERIODIC_ASSIGN_RE.finditer(script))
        if not assigns and not has_plural:
            faults.append(
                "bootstrap 既没赋值 periodic_callback 也没碰 periodic_callbacks："
                "传感器根本没挂上"
            )
        for assign in assigns:
            if not PERIODIC_READ_RE.search(script[: assign.start()]):
                faults.append(
                    "裸赋值 config.periodic_callback（赋值前没有 getattr 取旧值）："
                    "游戏/mod 自己的周期回调会被本局永久顶掉，"
                    "本 DLL 不卸载也没有还原路径"
                )
        if PREV_SLOT not in script:
            faults.append(f"bootstrap 里没有 {PREV_SLOT} 槽：旧回调无处安放，等于没链")
            continue
        tick = _python_function_body(script, "_fushi_lookup_tick")
        if not tick:
            faults.append("找不到 _fushi_lookup_tick 的函数体")
            continue
        # tick 必须把旧回调**调用**掉，不能只是存着好看。
        holder = re.search(
            r"(\w+)\s*=\s*\w+\.get\(\s*['\"]" + PREV_SLOT + r"['\"]", tick
        )
        if holder is None:
            faults.append(f"_fushi_lookup_tick 没有读回 {PREV_SLOT}")
            continue
        called = re.search(r"\b" + re.escape(holder.group(1)) + r"\s*\(\s*\)", tick)
        if called is None:
            faults.append(
                f"_fushi_lookup_tick 读了 {PREV_SLOT} 却没有调用它："
                "游戏自己的周期逻辑仍然是哑的"
            )
    return faults


def find_missing_disable_gate(source: str) -> list[str]:
    """规则 6：关闸必须存在，且 native 侧赋值排在 enable 早退之前。"""
    faults: list[str] = []
    for script in bootstrap_scripts(source):
        tick = _python_function_body(script, "_fushi_lookup_tick")
        if not tick:
            faults.append("找不到 _fushi_lookup_tick 的函数体")
            continue
        gate = re.search(
            r"if\s+not\s+\w+\.get\(\s*['\"]"
            + ENABLE_FLAG
            + r"['\"][^)]*\)\s*:\s*\n\s+return",
            tick,
        )
        if gate is None:
            faults.append(
                f"_fushi_lookup_tick 里没有 {ENABLE_FLAG} 早退："
                "关掉查词后传感器会每帧全树遍历直到游戏退出"
            )

    body = _function_body(strip_comments(source), "void ProcessRenpyLookupTick()")
    if not body:
        faults.append("找不到 ProcessRenpyLookupTick 的函数体")
        return faults
    write_at = body.find(ENABLE_FLAG)
    if write_at < 0:
        faults.append(
            f"ProcessRenpyLookupTick 从不写 {ENABLE_FLAG}：Python 侧的关闸永远收不到 0"
        )
        return faults
    for early in re.finditer(r"lookup_enabled[^;{}]*\breturn\b", body):
        if early.start() < write_at:
            faults.append(
                "ProcessRenpyLookupTick 在写关闸之前就按 lookup_enabled 早退了："
                "顺序反了这条修复等于不存在"
            )
            break
    return faults


def find_oversized_bootstrap_literals(source: str) -> list[str]:
    """规则 7：PYSRC 窄字面量不得超过 MSVC 的 16380 字节。"""
    faults = []
    for index, script in enumerate(bootstrap_scripts(source)):
        size = len(script.encode("utf-8"))
        if size > MSVC_NARROW_LITERAL_BYTES:
            faults.append(
                f"第 {index + 1} 段 PYSRC 字面量 {size} 字节 > "
                f"{MSVC_NARROW_LITERAL_BYTES}：MSVC 报 C2026 并截断；拆段，别删注释"
            )
    return faults


HEARTBEAT_GLOBAL = "fushi_host_seq"
HEARTBEAT_LAST = "fushi_host_last"
HEARTBEAT_STALL = "fushi_host_stall"
NATIVE_HEARTBEAT_COUNTER = "g_renpy_host_seq"


def find_missing_host_heartbeat(source: str) -> list[str]:
    """规则 8：宿主心跳必须存在、能自锁、能解锁，且不得挡住链式回调。

    fushi_lookup_on 只覆盖"用户关掉查词"。Fushi 进程被**直接杀掉**时 native 一轮都不
    再跑，开关永远停在最后写下的 1，Python 侧照样全速扫描到游戏退出——症状是"关了
    Fushi 之后游戏还是卡"，跟 Hibiki 完全对不上号。所以 native 每轮还要写一个单调递增
    的心跳，Python 侧连续 N 轮没见它变就自锁；心跳恢复必须立刻解锁，否则就变成"Fushi
    重连后查词永久不工作"。自锁只能挡住我们自己的扫描，绝不能挡住游戏原本的回调。
    """
    faults: list[str] = []
    for script in bootstrap_scripts(source):
        tick = _python_function_body(script, "_fushi_lookup_tick")
        if not tick:
            faults.append("找不到 _fushi_lookup_tick 的函数体")
            continue
        if HEARTBEAT_GLOBAL not in tick:
            faults.append(
                f"_fushi_lookup_tick 不读宿主心跳 {HEARTBEAT_GLOBAL}："
                "Fushi 被直接杀掉时开关停在 1，没有心跳就区分不出宿主没了"
            )
            continue
        lock = re.search(r"\bstall\w*\s*>=\s*(\d+)\s*:\s*\n\s+return", tick)
        if lock is None:
            faults.append("心跳没有自锁早退（缺 stall 计数 >= 阈值后的 return）")
        unlock = re.search(
            r"\[\s*['\"]" + HEARTBEAT_STALL + r"['\"]\s*\]\s*=\s*0", tick
        )
        if unlock is None:
            faults.append(
                f"心跳没有解锁路径（{HEARTBEAT_STALL} 从不归零）："
                "会变成 Fushi 重连后查词永久不工作"
            )
        if HEARTBEAT_LAST not in tick:
            faults.append(f"心跳缺少上一轮读数 {HEARTBEAT_LAST}，无从判断它变没变")
        # 自锁的 return 必须排在链式调用旧回调**之后**：游戏的周期逻辑一帧都不能少调。
        holder = re.search(
            r"(\w+)\s*=\s*\w+\.get\(\s*['\"]" + PREV_SLOT + r"['\"]", tick
        )
        if holder is not None and lock is not None:
            called = re.search(
                r"\b" + re.escape(holder.group(1)) + r"\s*\(\s*\)", tick
            )
            if called is None or called.start() > lock.start():
                faults.append(
                    "心跳自锁的 return 排在链式调用游戏回调之前："
                    "宿主一没了，游戏自己的周期逻辑也跟着哑了"
                )

    body = _function_body(strip_comments(source), "void ProcessRenpyLookupTick()")
    if not body:
        faults.append("找不到 ProcessRenpyLookupTick 的函数体")
        return faults
    if HEARTBEAT_GLOBAL not in body:
        faults.append(
            f"ProcessRenpyLookupTick 从不写 {HEARTBEAT_GLOBAL}：Python 侧心跳恒不变，"
            "开着查词也会被自己的自锁挡死"
        )
    incremented = re.search(
        r"\+\+\s*" + NATIVE_HEARTBEAT_COUNTER + r"\b", body
    ) or re.search(NATIVE_HEARTBEAT_COUNTER + r"\s*\+=\s*1", body)
    if incremented is None:
        faults.append(
            f"ProcessRenpyLookupTick 里 {NATIVE_HEARTBEAT_COUNTER} 没有递增："
            "心跳不动等于没有心跳"
        )
    return faults


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

    def test_periodic_callback_is_chained_not_overwritten(self) -> None:
        self.assertEqual(
            [],
            find_unchained_periodic_callback(self.lookup),
            "config.periodic_callback 是 Ren'Py 官方扩展点，游戏/mod 拿它跑自动存档与"
            "计时器；裸赋值会把它们本局永久顶掉，而本 DLL 不卸载、没有还原路径",
        )

    def test_disable_gate_is_written_before_the_enable_early_return(self) -> None:
        self.assertEqual(
            [],
            find_missing_disable_gate(self.lookup),
            "传感器种下去就没有卸载路径：关查词时必须先把 fushi_lookup_on 写 0 再早退，"
            "否则 Python 侧每帧继续全树遍历 + 每字形 2 次 mapper 调用直到游戏退出",
        )

    def test_bootstrap_fits_the_msvc_narrow_literal_limit(self) -> None:
        self.assertEqual([], find_oversized_bootstrap_literals(self.lookup))

    def test_host_heartbeat_self_locks_and_can_unlock(self) -> None:
        self.assertEqual(
            [],
            find_missing_host_heartbeat(self.lookup),
            "fushi_lookup_on 只覆盖用户关掉查词；Fushi 进程被直接杀掉时它会停在 1，"
            "只有单调递增的宿主心跳能说明宿主没了。自锁必须能解锁，且绝不能挡住"
            "链式调用游戏自己的 periodic_callback",
        )


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


# -- 规则 5/6/7 的合成脏输入 --------------------------------------------

DIRTY_BARE_PERIODIC = """
const char kRenpyLookupBootstrap[] = R"PYSRC(
_fs_g = {}
_fs_g.setdefault('fushi_lookup_on', 0)


def _fushi_lookup_tick():
    g = _fs_g
    if not g.get('fushi_lookup_on', 0):
        return
    _fushi_lookup_scan()


import renpy.config as _fs_config
_fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

void ProcessRenpyLookupTick() {
  const bool lookup_on = g_header->lookup_enabled != 0;
  Assign("_m.fushi_lookup_on=%d", lookup_on ? 1 : 0);
  if (!lookup_on) return;
}
"""

DIRTY_SAVED_NOT_CALLED = """
const char kRenpyLookupBootstrap[] = R"PYSRC(
_fs_g = {}
_fs_g.setdefault('fushi_lookup_on', 0)


def _fushi_lookup_tick():
    g = _fs_g
    prev = g.get('fushi_prev_periodic')
    if not g.get('fushi_lookup_on', 0):
        return
    _fushi_lookup_scan()


import renpy.config as _fs_config
_fs_prev = getattr(_fs_config, 'periodic_callback', None)
_fs_g['fushi_prev_periodic'] = _fs_prev
_fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

void ProcessRenpyLookupTick() {
  const bool lookup_on = g_header->lookup_enabled != 0;
  Assign("_m.fushi_lookup_on=%d", lookup_on ? 1 : 0);
  if (!lookup_on) return;
}
"""

DIRTY_ENABLE_RETURNS_FIRST = """
const char kRenpyLookupBootstrap[] = R"PYSRC(
_fs_g = {}
_fs_g.setdefault('fushi_lookup_on', 0)


def _fushi_lookup_tick():
    g = _fs_g
    prev = g.get('fushi_prev_periodic')
    if prev is not None:
        prev()
    if not g.get('fushi_lookup_on', 0):
        return
    _fushi_lookup_scan()


import renpy.config as _fs_config
_fs_prev = getattr(_fs_config, 'periodic_callback', None)
_fs_g['fushi_prev_periodic'] = _fs_prev
_fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

void ProcessRenpyLookupTick() {
  if (g_header->lookup_enabled == 0) return;
  Assign("_m.fushi_lookup_on=1");
}
"""

DIRTY_TICK_WITHOUT_GATE = """
const char kRenpyLookupBootstrap[] = R"PYSRC(
_fs_g = {}


def _fushi_lookup_tick():
    g = _fs_g
    prev = g.get('fushi_prev_periodic')
    if prev is not None:
        prev()
    _fushi_lookup_scan()


import renpy.config as _fs_config
_fs_prev = getattr(_fs_config, 'periodic_callback', None)
_fs_g['fushi_prev_periodic'] = _fs_prev
_fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

void ProcessRenpyLookupTick() {
  const bool lookup_on = g_header->lookup_enabled != 0;
  Assign("_m.fushi_lookup_on=%d", lookup_on ? 1 : 0);
  if (!lookup_on) return;
}
"""

CLEAN_CHAINED = """
const char kRenpyLookupBootstrap[] = R"PYSRC(
_fs_g = {}
_fs_g.setdefault('fushi_lookup_on', 0)


def _fushi_lookup_tick():
    g = _fs_g
    prev = g.get('fushi_prev_periodic')
    if prev is not None:
        prev()
    if not g.get('fushi_lookup_on', 0):
        return
    _fushi_lookup_scan()


import renpy.config as _fs_config
_fs_prev_tick = _fs_g.get('_fushi_lookup_tick')
_fs_prev = getattr(_fs_config, 'periodic_callback', None)
if _fs_prev is _fushi_lookup_tick or _fs_prev is _fs_prev_tick:
    _fs_prev = _fs_g.get('fushi_prev_periodic')
_fs_g['fushi_prev_periodic'] = _fs_prev
_fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

void ProcessRenpyLookupTick() {
  const bool lookup_on = g_header->lookup_enabled != 0;
  Assign("_m.fushi_lookup_on=%d", lookup_on ? 1 : 0);
  if (!lookup_on) return;
}
"""


CLEAN_HEARTBEAT = """
const char kRenpyLookupBootstrap[] = R"PYSRC(
_fs_g = {}
_fs_g.setdefault('fushi_lookup_on', 0)
_fs_g.setdefault('fushi_host_seq', 0)
_fs_g.setdefault('fushi_host_last', -1)
_fs_g.setdefault('fushi_host_stall', 0)


def _fushi_lookup_tick():
    g = _fs_g
    prev = g.get('fushi_prev_periodic')
    if prev is not None:
        prev()
    if not g.get('fushi_lookup_on', 0):
        return
    seq = g.get('fushi_host_seq', 0)
    if seq != g.get('fushi_host_last', -1):
        g['fushi_host_last'] = seq
        g['fushi_host_stall'] = 0
    else:
        stall = g.get('fushi_host_stall', 0) + 1
        g['fushi_host_stall'] = stall
        if stall >= 60:
            return
    _fushi_lookup_scan()


import renpy.config as _fs_config
_fs_prev = getattr(_fs_config, 'periodic_callback', None)
_fs_g['fushi_prev_periodic'] = _fs_prev
_fs_config.periodic_callback = _fushi_lookup_tick
)PYSRC";

void ProcessRenpyLookupTick() {
  const bool lookup_on = g_header->lookup_enabled != 0;
  ++g_renpy_host_seq;
  Assign("_m.fushi_lookup_on=%d;_m.fushi_host_seq=%llu", lookup_on ? 1 : 0, seq);
  if (!lookup_on) return;
}
"""

_UNLOCK_LINE = "        g[" + repr("fushi_host_stall") + "] = 0"

DIRTY_HEARTBEAT_NO_UNLOCK = CLEAN_HEARTBEAT.replace(_UNLOCK_LINE, "        pass")

DIRTY_HEARTBEAT_BEFORE_PREV = CLEAN_HEARTBEAT.replace(
    """    prev = g.get('fushi_prev_periodic')
    if prev is not None:
        prev()
    if not g.get('fushi_lookup_on', 0):""",
    """    prev = g.get('fushi_prev_periodic')
    if not g.get('fushi_lookup_on', 0):""",
).replace(
    """            return
    _fushi_lookup_scan()""",
    """            return
    if prev is not None:
        prev()
    _fushi_lookup_scan()""",
)

DIRTY_STATIC_HEARTBEAT = CLEAN_HEARTBEAT.replace("  ++g_renpy_host_seq;", "")


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

    def test_bare_periodic_callback_assignment_is_red(self) -> None:
        self.assertNotEqual([], find_unchained_periodic_callback(DIRTY_BARE_PERIODIC))

    def test_chained_periodic_callback_stays_green(self) -> None:
        self.assertEqual([], find_unchained_periodic_callback(CLEAN_CHAINED))

    def test_saved_but_never_called_prev_is_red(self) -> None:
        # 存了旧回调却不调用 = 游戏的周期逻辑照样是哑的。守卫必须看**调用点**。
        self.assertNotEqual(
            [], find_unchained_periodic_callback(DIRTY_SAVED_NOT_CALLED)
        )

    def test_enable_return_before_gate_write_is_red(self) -> None:
        self.assertNotEqual([], find_missing_disable_gate(DIRTY_ENABLE_RETURNS_FIRST))

    def test_gate_written_before_enable_return_stays_green(self) -> None:
        self.assertEqual([], find_missing_disable_gate(CLEAN_CHAINED))

    def test_python_tick_without_gate_is_red(self) -> None:
        self.assertNotEqual([], find_missing_disable_gate(DIRTY_TICK_WITHOUT_GATE))

    def test_tick_without_heartbeat_is_red(self) -> None:
        self.assertNotEqual([], find_missing_host_heartbeat(CLEAN_CHAINED))

    def test_heartbeat_without_unlock_is_red(self) -> None:
        self.assertNotEqual([], find_missing_host_heartbeat(DIRTY_HEARTBEAT_NO_UNLOCK))

    def test_heartbeat_locking_before_prev_call_is_red(self) -> None:
        self.assertNotEqual(
            [], find_missing_host_heartbeat(DIRTY_HEARTBEAT_BEFORE_PREV)
        )

    def test_native_heartbeat_that_never_increments_is_red(self) -> None:
        self.assertNotEqual([], find_missing_host_heartbeat(DIRTY_STATIC_HEARTBEAT))

    def test_full_heartbeat_stays_green(self) -> None:
        self.assertEqual([], find_missing_host_heartbeat(CLEAN_HEARTBEAT))

    def test_oversized_bootstrap_literal_is_red(self) -> None:
        oversized = 'const char k[] = R"PYSRC(' + "#" * 17000 + ')PYSRC";'
        self.assertNotEqual([], find_oversized_bootstrap_literals(oversized))

    def test_real_sized_bootstrap_literal_stays_green(self) -> None:
        self.assertEqual([], find_oversized_bootstrap_literals(CLEAN_CHAINED))


# -- 真跑一遍 bootstrap ----------------------------------------------------
#
# 源码扫描只能守形态。这一组把整段 PYSRC 在合成的假 renpy.config 上 exec 掉，断言的是
# 语义：游戏自己的回调还在不在、还调不调得到、关闸挡不挡得住扫描、重复注入会不会把自己
# 链成自嵌套（最后这条正是"取旧值"最容易写错的地方——重复注入时旧值是**上一次的** tick，
# 与本次是不同的函数对象，identity 比不出来）。


def _load_bootstrap() -> str:
    scripts = bootstrap_scripts(RENPY_LOOKUP.read_text(encoding="utf-8"))
    assert len(scripts) == 1, "renpy_lookup.inc 的 PYSRC 段数变了，行为测试要跟着改"
    return scripts[0]


class _Recorder:
    def __init__(self) -> None:
        self.calls = 0

    def __call__(self) -> None:
        self.calls += 1


def _run_bootstrap(config, namespace=None):
    """在假的 renpy.config 上 exec 整段 PYSRC，返回被当作 __main__ 的那个 dict。"""
    main_module = types.ModuleType("__main__")
    if namespace is not None:
        main_module.__dict__.update(namespace)
    renpy_module = types.ModuleType("renpy")
    renpy_module.config = config
    keys = ("__main__", "renpy", "renpy.config")
    saved = {key: sys.modules.get(key) for key in keys}
    sys.modules["__main__"] = main_module
    sys.modules["renpy"] = renpy_module
    sys.modules["renpy.config"] = config
    try:
        exec(compile(_load_bootstrap(), "<pysrc>", "exec"), main_module.__dict__)
    finally:
        for key, value in saved.items():
            if value is None:
                sys.modules.pop(key, None)
            else:
                sys.modules[key] = value
    return main_module.__dict__


class BootstrapBehaviourTest(unittest.TestCase):
    def _config(self, **attributes):
        config = types.ModuleType("renpy.config")
        for key, value in attributes.items():
            setattr(config, key, value)
        return config

    def test_singular_slot_keeps_and_calls_the_game_callback(self) -> None:
        game = _Recorder()
        config = self._config(periodic_callback=game)
        namespace = _run_bootstrap(config)

        tick = namespace["_fushi_lookup_tick"]
        self.assertIs(config.periodic_callback, tick)
        self.assertIs(namespace["fushi_prev_periodic"], game)

        scan = _Recorder()
        namespace["_fushi_lookup_scan"] = scan

        # 查词还没开：游戏的回调照跑，扫描一次都不能跑。
        tick()
        self.assertEqual(1, game.calls)
        self.assertEqual(0, scan.calls)
        self.assertEqual(0, namespace["fushi_lookup_ticks"])

        # native 写了开关之后才扫描；游戏的回调仍然每轮都调。
        namespace["fushi_lookup_on"] = 1
        tick()
        self.assertEqual(2, game.calls)
        self.assertEqual(1, scan.calls)

        # 关回去：扫描立刻停，游戏的回调不受影响。
        namespace["fushi_lookup_on"] = 0
        tick()
        self.assertEqual(3, game.calls)
        self.assertEqual(1, scan.calls)

    def test_reinjection_does_not_self_nest(self) -> None:
        game = _Recorder()
        config = self._config(periodic_callback=game)
        first = _run_bootstrap(config)
        second = _run_bootstrap(config, namespace=first)

        self.assertIs(second["fushi_prev_periodic"], game)
        self.assertIsNot(second["_fushi_lookup_tick"], first["_fushi_lookup_tick"])
        self.assertIs(config.periodic_callback, second["_fushi_lookup_tick"])

        second["fushi_lookup_on"] = 1
        scan = _Recorder()
        second["_fushi_lookup_scan"] = scan
        second["_fushi_lookup_tick"]()
        # 自嵌套的话 game 会被调两次（旧 tick 链在新 tick 里）。
        self.assertEqual(1, game.calls)
        self.assertEqual(1, scan.calls)

    def test_host_heartbeat_self_locks_when_native_stops(self) -> None:
        # Fushi 被直接杀掉：开关停在 1，只有心跳不再递增。自锁必须停掉**我们的**扫描，
        # 而游戏自己的 periodic_callback 一帧都不能少调。
        game = _Recorder()
        config = self._config(periodic_callback=game)
        namespace = _run_bootstrap(config)
        tick = namespace["_fushi_lookup_tick"]
        scan = _Recorder()
        namespace["_fushi_lookup_scan"] = scan
        namespace["fushi_lookup_on"] = 1

        # 宿主还活着：每轮心跳 +1，每轮都扫。
        for _ in range(5):
            namespace["fushi_host_seq"] += 1
            tick()
        self.assertEqual(5, scan.calls)

        # 宿主没了：心跳冻住。阈值由脚本自己定，测试不硬编码。
        locked_at = None
        for round_index in range(1, 500):
            before = scan.calls
            tick()
            if scan.calls == before:
                locked_at = round_index
                break
        self.assertIsNotNone(locked_at, "心跳冻住后扫描一直没停：自锁不存在")

        # 锁上之后：扫描一次都不涨，游戏的回调一次都不少。
        frozen_scan = scan.calls
        game_before = game.calls
        for _ in range(50):
            tick()
        self.assertEqual(frozen_scan, scan.calls)
        self.assertEqual(game_before + 50, game.calls)

    def test_host_heartbeat_unlocks_when_native_resumes(self) -> None:
        # Fushi 重连：心跳恢复递增就必须立刻恢复扫描，绝不能永久哑掉。
        game = _Recorder()
        config = self._config(periodic_callback=game)
        namespace = _run_bootstrap(config)
        tick = namespace["_fushi_lookup_tick"]
        scan = _Recorder()
        namespace["_fushi_lookup_scan"] = scan
        namespace["fushi_lookup_on"] = 1

        for _ in range(500):
            tick()
        locked = scan.calls
        tick()
        self.assertEqual(locked, scan.calls, "没锁上，后面的解锁断言就没有意义")

        namespace["fushi_host_seq"] += 1
        tick()
        self.assertEqual(locked + 1, scan.calls)
        # 解锁之后继续正常工作。
        for _ in range(5):
            namespace["fushi_host_seq"] += 1
            tick()
        self.assertEqual(locked + 6, scan.calls)

    def test_plural_list_is_appended_not_replaced(self) -> None:
        game = _Recorder()
        config = self._config(periodic_callbacks=[game])
        first = _run_bootstrap(config)

        self.assertEqual([game, first["_fushi_lookup_tick"]], config.periodic_callbacks)
        self.assertIsNone(first["fushi_prev_periodic"])
        self.assertFalse(hasattr(config, "periodic_callback"))

        second = _run_bootstrap(config, namespace=first)
        self.assertEqual(
            [game, second["_fushi_lookup_tick"]], config.periodic_callbacks
        )

    def test_no_previous_callback_still_installs(self) -> None:
        config = self._config()
        namespace = _run_bootstrap(config)
        self.assertIs(config.periodic_callback, namespace["_fushi_lookup_tick"])
        self.assertIsNone(namespace["fushi_prev_periodic"])
        namespace["fushi_lookup_on"] = 1
        scan = _Recorder()
        namespace["_fushi_lookup_scan"] = scan
        namespace["_fushi_lookup_tick"]()
        self.assertEqual(1, scan.calls)


if __name__ == "__main__":
    unittest.main()

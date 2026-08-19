#!/usr/bin/env python3
"""通用位图呈现器的接线守卫。

守的是「`hook/lookup_overlay_window.inc` 必须真的被编进 DLL 并被调用」。

这条守卫存在的理由不是风格，是一段真实历史：该文件在 `0471eccffa` 落地时提交信息
自己写着「尚未接进构建」，之后**没有任何 `#include`、没有任何调用者、CMake 里也只有
它旁边那个纯几何单测**。结果是 KiriKiri 之外的每个引擎（Siglus / CatSystem2 / Ren'Py /
Unity …）上，hit / input / frame 三通道和整条 Dart 编排层全都是通的，唯独卡片位图没有
承载物——功能看起来"实现了"，实际一个像素都显示不出来，而且**任何测试都不会红**：
几何层有单测且恒绿，因为几何层本来就没死。

所以守卫必须盯的是「接线」这个行为本身，逐条对应一个可以静默复发的形态：

1. `hook/dll_main.cpp` 必须 `#include "lookup_overlay_window.inc"`。
   不 include = 整份呈现器退回死代码，也就是上面那个历史状态。

2. 该 include 必须排在第一条 `adapters/` include **之前**。
   KiriKiri 适配器要调 `ClaimLookupPresenter()` 认领呈现；排在后面就是「未声明的标识符」
   编译错误。这是顺序不变量，不是拼写检查——所以断言的是两个 include 的相对位置。

3. `StartLookupOverlayIfUnclaimed()` 必须在 `lookup_overlay_window.inc` **之外**有调用点。
   只 include 不点火，窗口线程永远不起，症状与完全没接线一模一样。

4. `StopLookupOverlay()` 必须在 `lookup_overlay_window.inc` **之外**有调用点。
   呈现器线程每 16ms 读一次 `g_header`；不停就停在解映射之后读悬垂指针。

5. `hook/adapters/kirikiri_adapter.inc` 必须调 `ClaimLookupPresenter()`。
   不认领 = KiriKiri 上 TJS Layer 与通用分层窗口同时显示卡片，出双份。

6. `hook/lookup_overlay_window.inc` 里**一条 `#include` 都不能有**。
   它被 include 进 dll_main.cpp 的匿名命名空间内部，头文件里的
   `namespace fushi_voice_hook` 会在匿名命名空间里再开一个同名嵌套命名空间，把真正的
   `::fushi_voice_hook` 整个遮住。实测症状极具误导性：报错全在**之后每个 adapter**
   里（「不是 fushi_voice_hook 的成员」「const object must be initialized」），
   一条都不指向真正的肇事文件。

调用点判定一律在**剥掉注释之后**做：只在注释里出现的调用不算调用点（对应的变异测试
在下面，注释掉调用是最容易发生的"半回退"）。

变异实测纪律：每条规则一个独立 `find_*` 函数；`RealSourceTest` 扫真文件要求为空，
`MutationSelfTest` 扫合成脏输入要求非空。两组都在，这守卫才不可能是永远绿的空守卫。
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

HOOK_ROOT = Path(__file__).resolve().parent.parent
DLL_MAIN = HOOK_ROOT / "hook" / "dll_main.cpp"
OVERLAY_INC = HOOK_ROOT / "hook" / "lookup_overlay_window.inc"
KIRIKIRI_INC = HOOK_ROOT / "hook" / "adapters" / "kirikiri_adapter.inc"

OVERLAY_INCLUDE = '#include "lookup_overlay_window.inc"'
ADAPTER_INCLUDE_RE = re.compile(r'^\s*#include\s+"adapters/[^"]+"', re.MULTILINE)
INCLUDE_RE = re.compile(r"^\s*#\s*include\b.*$", re.MULTILINE)

START_CALL = "StartLookupOverlayIfUnclaimed"
STOP_CALL = "StopLookupOverlay"
CLAIM_CALL = "ClaimLookupPresenter"
CLAIM_FLAG = "g_lookup_presenter_claimed"
FRAME_COUNTER = "lookup_frame_count_written"
FRAME_ACCESS = "LookupFrameAt("


def strip_comments(text: str) -> str:
    """把 // 与 /* */ 注释换成等长空白，保住行号与偏移。

    等长替换是刻意的：调用点判定要报行号，注释一删行号就全漂。
    """
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


def find_missing_overlay_include(dll_main_text: str) -> list[str]:
    """规则 1：dll_main.cpp 没 include 呈现器 = 死代码。"""
    if OVERLAY_INCLUDE in strip_comments(dll_main_text):
        return []
    return [f"hook/dll_main.cpp 缺少 {OVERLAY_INCLUDE}"]


def find_overlay_include_after_adapters(dll_main_text: str) -> list[str]:
    """规则 2：呈现器 include 必须早于第一条 adapters/ include。"""
    stripped = strip_comments(dll_main_text)
    overlay_at = stripped.find(OVERLAY_INCLUDE)
    if overlay_at < 0:
        return []  # 规则 1 负责报缺失，这里不重复报
    first_adapter = ADAPTER_INCLUDE_RE.search(stripped)
    if first_adapter is None:
        return []
    if overlay_at < first_adapter.start():
        return []
    return [
        "lookup_overlay_window.inc 的 include 排在 adapters/ 之后："
        "KiriKiri 适配器调 ClaimLookupPresenter() 会拿不到声明"
    ]


def _call_sites_outside(name: str, text: str) -> list[int]:
    """返回 `name(` 在剥注释后文本里的所有偏移。"""
    stripped = strip_comments(text)
    return [m.start() for m in re.finditer(re.escape(name) + r"\s*\(", stripped)]


def find_uncalled_presenter_entrypoint(name: str, caller_text: str) -> list[str]:
    """规则 3/4：呈现器的点火/停机入口必须在 .inc 之外有真调用点。"""
    if _call_sites_outside(name, caller_text):
        return []
    return [f"{name}() 在 lookup_overlay_window.inc 之外没有调用点"]


def find_missing_kirikiri_claim(kirikiri_text: str) -> list[str]:
    """规则 5：KiriKiri 必须认领呈现，否则卡片出双份。"""
    if _call_sites_outside(CLAIM_CALL, kirikiri_text):
        return []
    return ["kirikiri_adapter.inc 没有调用 ClaimLookupPresenter()"]


def _function_body(text: str, signature: str) -> str:
    """取 `signature` 之后第一个花括号块的原文（大括号配对）。找不到返回空串。"""
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


def find_missing_per_frame_claim_check(overlay_text: str) -> list[str]:
    """规则 7：PollOverlayFrame 必须每帧复查认领，且复查要早于读帧。

    只在启动时判一次不够——真机上 host 先把 lookup_enabled 拨到 1、引擎适配器才拿到
    脚本宿主并认领，通用呈现器已经起来了，于是两个呈现器同贴一帧 = 双份卡片。
    """
    body = _function_body(strip_comments(overlay_text), "void PollOverlayFrame()")
    if not body:
        return ["找不到 PollOverlayFrame 的函数体"]
    claim_at = body.find(CLAIM_FLAG)
    if claim_at < 0:
        return ["PollOverlayFrame 没有复查 " + CLAIM_FLAG + "：认领后仍会继续贴帧"]
    # 锚点取「第一次真正去碰帧」的调用，而不是某个计数器名字——计数器可以被换掉
    # （规则 8 就把 lookup_frame_count_written 整个赶出了这个函数），锚在它身上
    # 会让本规则在下一次重构里静静失效。
    frame_at = body.find(FRAME_ACCESS)
    if frame_at >= 0 and claim_at > frame_at:
        return [
            "PollOverlayFrame 的认领复查排在读帧之后：让位之前已经把这帧读走了"
        ]
    return []


def find_slot_index_from_write_counter(overlay_text: str) -> list[str]:
    """规则 8：选帧必须扫全部槽按帧自己的发布序挑，**不得**从写入计数器反推槽下标。

    槽下标是契约的一部分：host 用的是「帧发布序 % lookup_frame_count」
    （voice_hook_reader.cpp 的 WriteLookupFrame，元数据与像素块共用同一个 index）。
    `lookup_frame_count_written` 虽然与发布序同步递增，但 `(written - 1) % frame_count`
    恒比它小 1——host 写槽 seq%2，这里就读槽 (seq-1)%2，双缓冲下**永远读的是另一个槽**，
    第一帧读到全零槽（ready=0）直接 return，卡片一辈子不出现。
    真机实测（Ren'Py / Sakura Swim Club，2026-08-19）：改成扫全槽之后
    lookup_diag 才第一次亮起 frame_presented。
    """
    body = _function_body(strip_comments(overlay_text), "void PollOverlayFrame()")
    if not body:
        return ["找不到 PollOverlayFrame 的函数体"]
    faults = []
    if FRAME_COUNTER in body:
        faults.append(
            f"PollOverlayFrame 里出现 {FRAME_COUNTER}："
            "写入计数器既不是槽下标也不是本呈现器的判新依据，用它必然读错槽"
        )
    if "for (" not in body:
        faults.append(
            "PollOverlayFrame 没有扫描循环：选帧必须遍历 lookup_frame_count 个槽"
        )
    return faults


def find_includes_in_overlay_inc(overlay_text: str) -> list[str]:
    """规则 6：该 .inc 在匿名命名空间内被展开，一条 #include 都不能有。"""
    stripped = strip_comments(overlay_text)
    faults = []
    for match in INCLUDE_RE.finditer(stripped):
        line = stripped.count("\n", 0, match.start()) + 1
        faults.append(
            f"lookup_overlay_window.inc:{line} 出现 #include："
            "它在匿名命名空间内展开，会把 ::fushi_voice_hook 整个遮住"
        )
    return faults


class RealSourceTest(unittest.TestCase):
    """扫真文件，全部必须为空。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.dll_main = DLL_MAIN.read_text(encoding="utf-8")
        cls.overlay = OVERLAY_INC.read_text(encoding="utf-8")
        cls.kirikiri = KIRIKIRI_INC.read_text(encoding="utf-8")

    def test_overlay_is_included(self) -> None:
        self.assertEqual([], find_missing_overlay_include(self.dll_main))

    def test_overlay_include_precedes_adapters(self) -> None:
        self.assertEqual([], find_overlay_include_after_adapters(self.dll_main))

    def test_presenter_is_started(self) -> None:
        self.assertEqual(
            [], find_uncalled_presenter_entrypoint(START_CALL, self.dll_main)
        )

    def test_presenter_is_stopped(self) -> None:
        self.assertEqual(
            [], find_uncalled_presenter_entrypoint(STOP_CALL, self.dll_main)
        )

    def test_kirikiri_claims_presenter(self) -> None:
        self.assertEqual([], find_missing_kirikiri_claim(self.kirikiri))

    def test_overlay_inc_has_no_includes(self) -> None:
        self.assertEqual([], find_includes_in_overlay_inc(self.overlay))

    def test_frame_poll_rechecks_the_claim(self) -> None:
        self.assertEqual([], find_missing_per_frame_claim_check(self.overlay))

    def test_frame_poll_scans_slots_instead_of_deriving_index(self) -> None:
        self.assertEqual([], find_slot_index_from_write_counter(self.overlay))


# 合成脏输入。断言的字面量都在这里，真文件改动不会让下面的变异测试失去意义。
DIRTY_NO_INCLUDE = """
#include "adapter.h"
#include "adapters/kirikiri_adapter.inc"
"""

DIRTY_INCLUDE_AFTER_ADAPTERS = """
#include "adapters/unity_adapter.inc"
#include "adapters/kirikiri_adapter.inc"
#include "lookup_overlay_window.inc"
"""

DIRTY_INCLUDE_ONLY_IN_COMMENT = """
// #include "lookup_overlay_window.inc"
#include "adapters/kirikiri_adapter.inc"
"""

CLEAN_DLL_MAIN = """
#include "lookup_overlay_window.inc"
#include "adapters/kirikiri_adapter.inc"

void Worker() {
  StartLookupOverlayIfUnclaimed();
  StopLookupOverlay();
}
"""

DIRTY_START_COMMENTED_OUT = """
#include "lookup_overlay_window.inc"
#include "adapters/kirikiri_adapter.inc"

void Worker() {
  // StartLookupOverlayIfUnclaimed();
  StopLookupOverlay();
}
"""

DIRTY_STOP_IN_BLOCK_COMMENT = """
#include "lookup_overlay_window.inc"

void Worker() {
  StartLookupOverlayIfUnclaimed();
  /* 早先这里调 StopLookupOverlay(); 后来挪走了 */
}
"""

DIRTY_KIRIKIRI_NO_CLAIM = """
void InstallKirikiriLookupSensor(ITVPFunctionExporter* exporter) {
  if (exporter != nullptr) g_lookup_exporter = exporter;
  PollKirikiriLookupInstall();
}
"""

DIRTY_KIRIKIRI_CLAIM_IN_COMMENT = """
// 认领呈现走 ClaimLookupPresenter()，等 bootstrap 成功再说
void InstallKirikiriLookupSensor(ITVPFunctionExporter* exporter) {
  if (exporter != nullptr) g_lookup_exporter = exporter;
}
"""

CLEAN_KIRIKIRI = """
void InstallKirikiriLookupSensor(ITVPFunctionExporter* exporter) {
  if (exporter != nullptr) {
    g_lookup_exporter = exporter;
    ClaimLookupPresenter();
  }
}
"""

DIRTY_OVERLAY_WITH_INCLUDE = """
#include "lookup_overlay_geometry.h"

void ClaimLookupPresenter() {}
"""

CLEAN_OVERLAY = """
// 这里一条 #include 都不能有；lookup_overlay_geometry.h 由 dll_main.cpp 引入。
void ClaimLookupPresenter() {}
"""


DIRTY_POLL_WITHOUT_CLAIM_CHECK = """
void PollOverlayFrame() {
  if (g_header == nullptr) return;
  const uint64_t written = Read(&g_header->lookup_frame_count_written);
  Present(written);
}
"""

DIRTY_POLL_CLAIM_CHECK_TOO_LATE = """
void PollOverlayFrame() {
  LookupFrameAt(g_header, 0);
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) return;
  Present();
}
"""

DIRTY_POLL_CLAIM_ONLY_IN_COMMENT = """
void PollOverlayFrame() {
  // 认领由 g_lookup_presenter_claimed 决定，启动时已经判过
  const uint64_t written = Read(&g_header->lookup_frame_count_written);
  Present(written);
}
"""

CLEAN_POLL = """
void PollOverlayFrame() {
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) {
    HideOverlay();
    return;
  }
  const uint64_t written = Read(&g_header->lookup_frame_count_written);
  Present(written);
}
"""


DIRTY_POLL_INDEX_FROM_WRITE_COUNTER = """
void PollOverlayFrame() {
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) return;
  const uint64_t written = Read(&g_header->lookup_frame_count_written);
  LookupFrameAt(g_header, (written - 1) % frame_count);
}
"""

DIRTY_POLL_NO_SCAN_LOOP = """
void PollOverlayFrame() {
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) return;
  LookupFrameAt(g_header, 0);
}
"""

CLEAN_POLL_SCAN = """
void PollOverlayFrame() {
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) return;
  for (uint32_t i = 0; i < frame_count; ++i) {
    LookupFrameAt(g_header, i);
  }
}
"""


class MutationSelfTest(unittest.TestCase):
    """扫合成脏输入，全部必须非空——否则守卫是空的。"""

    def test_missing_include_is_red(self) -> None:
        self.assertNotEqual([], find_missing_overlay_include(DIRTY_NO_INCLUDE))

    def test_include_only_in_a_comment_is_still_red(self) -> None:
        self.assertNotEqual(
            [], find_missing_overlay_include(DIRTY_INCLUDE_ONLY_IN_COMMENT)
        )

    def test_include_after_adapters_is_red(self) -> None:
        self.assertNotEqual(
            [], find_overlay_include_after_adapters(DIRTY_INCLUDE_AFTER_ADAPTERS)
        )

    def test_clean_dll_main_stays_green(self) -> None:
        self.assertEqual([], find_missing_overlay_include(CLEAN_DLL_MAIN))
        self.assertEqual([], find_overlay_include_after_adapters(CLEAN_DLL_MAIN))
        self.assertEqual(
            [], find_uncalled_presenter_entrypoint(START_CALL, CLEAN_DLL_MAIN)
        )
        self.assertEqual(
            [], find_uncalled_presenter_entrypoint(STOP_CALL, CLEAN_DLL_MAIN)
        )

    def test_start_commented_out_is_red(self) -> None:
        self.assertNotEqual(
            [], find_uncalled_presenter_entrypoint(START_CALL, DIRTY_START_COMMENTED_OUT)
        )

    def test_stop_in_block_comment_is_red(self) -> None:
        self.assertNotEqual(
            [], find_uncalled_presenter_entrypoint(STOP_CALL, DIRTY_STOP_IN_BLOCK_COMMENT)
        )

    def test_kirikiri_without_claim_is_red(self) -> None:
        self.assertNotEqual([], find_missing_kirikiri_claim(DIRTY_KIRIKIRI_NO_CLAIM))

    def test_kirikiri_claim_only_in_comment_is_red(self) -> None:
        self.assertNotEqual(
            [], find_missing_kirikiri_claim(DIRTY_KIRIKIRI_CLAIM_IN_COMMENT)
        )

    def test_kirikiri_with_claim_stays_green(self) -> None:
        self.assertEqual([], find_missing_kirikiri_claim(CLEAN_KIRIKIRI))

    def test_include_inside_overlay_inc_is_red(self) -> None:
        self.assertNotEqual([], find_includes_in_overlay_inc(DIRTY_OVERLAY_WITH_INCLUDE))

    def test_overlay_inc_without_includes_stays_green(self) -> None:
        self.assertEqual([], find_includes_in_overlay_inc(CLEAN_OVERLAY))

    def test_poll_without_claim_check_is_red(self) -> None:
        self.assertNotEqual(
            [], find_missing_per_frame_claim_check(DIRTY_POLL_WITHOUT_CLAIM_CHECK)
        )

    def test_poll_with_late_claim_check_is_red(self) -> None:
        self.assertNotEqual(
            [], find_missing_per_frame_claim_check(DIRTY_POLL_CLAIM_CHECK_TOO_LATE)
        )

    def test_poll_claim_check_only_in_comment_is_red(self) -> None:
        self.assertNotEqual(
            [], find_missing_per_frame_claim_check(DIRTY_POLL_CLAIM_ONLY_IN_COMMENT)
        )

    def test_clean_poll_stays_green(self) -> None:
        self.assertEqual([], find_missing_per_frame_claim_check(CLEAN_POLL))

    def test_slot_index_from_write_counter_is_red(self) -> None:
        self.assertNotEqual(
            [], find_slot_index_from_write_counter(DIRTY_POLL_INDEX_FROM_WRITE_COUNTER)
        )

    def test_missing_scan_loop_is_red(self) -> None:
        self.assertNotEqual(
            [], find_slot_index_from_write_counter(DIRTY_POLL_NO_SCAN_LOOP)
        )

    def test_scanning_poll_stays_green(self) -> None:
        self.assertEqual([], find_slot_index_from_write_counter(CLEAN_POLL_SCAN))

    def test_brace_matcher_takes_the_whole_body(self) -> None:
        body = _function_body("void PollOverlayFrame() { a(); { b(); } c(); } tail", "void PollOverlayFrame()")
        self.assertTrue(body.startswith("{") and body.endswith("}"))
        self.assertIn("c();", body)
        self.assertNotIn("tail", body)

    def test_comment_stripper_preserves_offsets_and_lines(self) -> None:
        text = 'a();\n// StopLookupOverlay();\n/* x */ b();\n'
        stripped = strip_comments(text)
        self.assertEqual(len(text), len(stripped))
        self.assertEqual(text.count("\n"), stripped.count("\n"))
        self.assertNotIn("StopLookupOverlay", stripped)
        self.assertIn("b()", stripped)

    def test_comment_stripper_keeps_string_literals(self) -> None:
        # 字符串里的 // 不是注释；剥错了会把整行调用一起吞掉。
        text = 'Log("http://x"); StartLookupOverlayIfUnclaimed();\n'
        self.assertNotEqual(
            [], _call_sites_outside(START_CALL, text)
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""overlay 窗口类的 GDI 资源必须一次创建、一次转交（BUG-2090）。

为什么是源码守卫而不是单测：`lookup_overlay_window.inc` 不进任何 CTest 编译单元
（它被 hook DLL 的实现文件 `#include` 进去，测试目标不链接它），而这条 bug 的症状是
「进程常驻期内 GDI 句柄缓慢增长」——单测里既造不出 overlay 线程 Stop→Start 的真实
时序，也没有断言点。能在提交前必红的只有「创建了却没人接管、也没人删」这个静态事实。

原状（BUG-2090）：`ApplyLookupHoverHighlight` 每次(重)建窗口都
`CreateSolidBrush` + `RegisterClassExW`，而 `DestroyLookupHoverHighlight` 只销毁窗口、
**从不 UnregisterClass** ⇒ 类一直在 ⇒ 第二次起注册恒返回 `ERROR_CLASS_ALREADY_EXISTS`，
**新建的那把 brush 没有任何人接管**。overlay 线程每 Stop→Start 一轮漏一个 GDI brush，
而本 DLL 常驻在游戏进程里。

判据：把「建 brush → 交给类」收敛成一次性块，并要求该块内每条不完成转交的出口都
`DeleteObject`。零命中 = 扫描面失效，同样判红（与 BUG-1157「零断言伪装通过」同族）。
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "hook" / "lookup_overlay_window.inc"

# 需要显式释放的 GDI 创建原语（返回的句柄不会被 GC，也不随窗口销毁而自动释放）。
GDI_CREATORS = (
    "CreateSolidBrush(",
    "CreatePatternBrush(",
    "CreateHatchBrush(",
    "CreatePen(",
    "CreateFontW(",
    "CreateFontIndirectW(",
)

ONE_SHOT_FLAG = "s_hover_class_registered"


def _block_after(text: str, header: str) -> str:
    """取 `header` 之后由花括号配平界定的块体（含 header 行）。"""
    at = text.index(header)
    depth = 0
    i = text.index("{", at)
    start = i
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
        i += 1
    raise AssertionError("花括号不配平，判据已失效")


class OverlayGdiOwnershipGuard(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(TARGET.is_file(), f"扫描面失效：找不到 {TARGET}")
        self.src = TARGET.read_text(encoding="utf-8")
        # 扫描规模哨兵：文件塌成空壳时下面的否定断言会恒真地「通过」。
        self.assertGreater(
            len(self.src), 20000, "被扫文件异常小，扫描面可能已失效"
        )

    def test_gdi_objects_are_created_exactly_once_in_a_one_shot_block(self) -> None:
        created = [c for c in GDI_CREATORS if c in self.src]
        self.assertTrue(
            created, "零命中：本文件已无 GDI 创建调用，守卫失去意义——请复核判据"
        )

        self.assertIn(
            ONE_SHOT_FLAG,
            self.src,
            f"窗口类注册必须由一次性标志 {ONE_SHOT_FLAG} 守住；"
            "每次重建窗口都重新注册 = 第二次起 brush 无人接管（BUG-2090）",
        )
        block = _block_after(self.src, f"if (!{ONE_SHOT_FLAG})")
        # 自校验：块没塌成空壳。
        self.assertGreater(len(block), 200, "一次性块窗口异常小，判据已失效")
        self.assertIn("RegisterClassExW(", block, "一次性块里必须是那次类注册")

        for creator in created:
            self.assertEqual(
                self.src.count(creator),
                1,
                f"{creator} 在本文件出现多次：每一处都要各自配对释放，"
                "把它收敛成一次性块里的唯一一处",
            )
            self.assertIn(
                creator,
                block,
                f"{creator} 必须在一次性块内——块外创建意味着每次调用都新建一个，"
                "而类只接管注册成功那一次传进去的那个",
            )

    def test_every_non_transferring_exit_releases_the_object(self) -> None:
        block = _block_after(self.src, f"if (!{ONE_SHOT_FLAG})")
        lines = block.splitlines()

        def first_index(needle: str) -> int:
            for i, ln in enumerate(lines):
                if needle in ln:
                    return i
            return -1

        create_at = -1
        for creator in GDI_CREATORS:
            idx = first_index(creator)
            if idx >= 0:
                create_at = idx
                break
        self.assertGreaterEqual(create_at, 0, "一次性块里找不到 GDI 创建调用")

        delete_at = first_index("DeleteObject(")
        self.assertGreater(
            delete_at,
            create_at,
            "创建之后必须有 DeleteObject：注册没成功时类不接管这把句柄（BUG-2090）",
        )

        returns = [i for i, ln in enumerate(lines) if re.search(r"\breturn\b", ln)]
        for r in returns:
            if r <= create_at:
                continue
            self.assertLess(
                delete_at,
                r,
                f"块内第 {r + 1} 行的 return 在 DeleteObject 之前——"
                "这条出口会漏掉刚创建的 GDI 句柄",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)

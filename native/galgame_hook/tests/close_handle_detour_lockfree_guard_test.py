#!/usr/bin/env python3
"""kernel32!CloseHandle 的 detour 及其可达的每个 Forget* 都不得阻塞（BUG-2046）。

为什么是源码守卫而不是单测：这条 bug 的触发条件是「另一份 MinHook（LunaHook32）在
Freeze 里挂起了本进程其它线程之后调 CloseHandle」，单测里造不出第二份 MinHook 与真实
线程挂起时序；真机复现率 ~1/9。能在提交前必红的只有「detour 可达代码里出现阻塞原语」
这个静态事实，所以直接扫源码。

扫描面：hook/adapters/siglus_adapter.inc 里的 Detour_CloseHandle 函数体 → 收集其中
调用的函数名 → 在 hook/ 全树找到每个函数的定义体 → 断言没有阻塞原语。零命中 =
守卫失效，同样判红（与 BUG-1157「零断言伪装通过」同族）。
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "hook"
DETOUR_FILE = HOOK / "adapters" / "siglus_adapter.inc"

BLOCKING = (
    "EnterCriticalSection(",
    "TryEnterCriticalSection(",
    "AcquireSRWLock",
    "WaitForSingleObject",
    "WaitForMultipleObjects",
    "WaitOnAddress(",
    "Sleep(",
    "SleepEx(",
    "std::mutex",
    "std::lock_guard",
    "std::unique_lock",
    "std::scoped_lock",
    "std::shared_mutex",
)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def function_body(text: str, name: str) -> str | None:
    """返回 `name(` 定义（行首、非 `;` 结尾的声明）的花括号体，找不到返回 None。"""
    for match in re.finditer(
        r"^[A-Za-z_][\w:<>\s*&]*\b" + re.escape(name) + r"\s*\([^;{]*\)\s*\{",
        text,
        flags=re.M,
    ):
        start = match.end() - 1
        depth = 0
        for index in range(start, len(text)):
            char = text[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
    return None


def hook_sources() -> dict[Path, str]:
    return {
        path: strip_comments(path.read_text(encoding="utf-8"))
        for path in sorted(HOOK.rglob("*"))
        if path.suffix in {".inc", ".cpp", ".h"}
    }


class CloseHandleDetourLockFreeGuard(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = hook_sources()
        detour_text = self.sources[DETOUR_FILE]
        self.detour_body = function_body(detour_text, "Detour_CloseHandle")
        self.assertIsNotNone(self.detour_body, "Detour_CloseHandle 定义没找到")

    def callees(self) -> list[str]:
        names = re.findall(r"\b([A-Za-z_]\w*)\s*\(", self.detour_body or "")
        keywords = {"if", "while", "for", "switch", "return", "sizeof"}
        return sorted({n for n in names if n not in keywords})

    def find_definition(self, name: str) -> tuple[Path, str] | None:
        for path, text in self.sources.items():
            body = function_body(text, name)
            if body is not None:
                return path, body
        return None

    def test_detour_body_has_no_blocking_primitive(self) -> None:
        for primitive in BLOCKING:
            self.assertNotIn(
                primitive,
                self.detour_body or "",
                f"Detour_CloseHandle 自身不得出现 {primitive}",
            )

    def test_every_forget_reachable_from_detour_is_lock_free(self) -> None:
        checked: list[str] = []
        for name in self.callees():
            if name.startswith("g_orig_") or name == "InterlockedCompareExchange":
                continue
            found = self.find_definition(name)
            self.assertIsNotNone(found, f"{name} 的定义在 hook/ 里没找到")
            path, body = found  # type: ignore[misc]
            for primitive in BLOCKING:
                self.assertNotIn(
                    primitive,
                    body,
                    f"{path.relative_to(ROOT)} 的 {name} 从 CloseHandle detour 可达，"
                    f"不得使用 {primitive}（BUG-2046：Freeze 线程会在这里等被它挂起的线程）",
                )
            checked.append(name)
        # 零命中 = 守卫空转。Detour_CloseHandle 至少要摘 8 张表。
        self.assertGreaterEqual(
            len(checked), 8, f"只检查到 {checked}，扫描面疑似失效"
        )

    def test_forget_helpers_use_the_shared_lock_free_table_or_interlocked(self) -> None:
        """Forget* 必须走 tracked_handle_table.h 或裸 Interlocked CAS——两者之外的实现
        就算暂时没有锁，也没有任何东西阻止下一次改动把锁加回去。"""
        for name in self.callees():
            if not name.startswith("Forget"):
                continue
            found = self.find_definition(name)
            self.assertIsNotNone(found, name)
            _, body = found  # type: ignore[misc]
            self.assertTrue(
                "ForgetTrackedHandle(" in body
                or "InterlockedCompareExchangePointer(" in body,
                f"{name} 既没走 ForgetTrackedHandle 也没用 InterlockedCompareExchangePointer",
            )


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2))

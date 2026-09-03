#!/usr/bin/env python3
"""kernel32!CloseHandle 的 detour 及其**传递可达**的每个函数都不得阻塞（BUG-2046）。

为什么是源码守卫而不是单测：这条 bug 的触发条件是「另一份 MinHook（LunaHook32）在
Freeze 里挂起了本进程其它线程之后调 CloseHandle」，单测里造不出第二份 MinHook 与真实
线程挂起时序；真机复现率 ~1/9。能在提交前必红的只有「detour 可达代码里出现阻塞原语」
这个静态事实，所以直接扫源码。

扫描面：hook/adapters/siglus_adapter.inc 里的 Detour_CloseHandle 函数体 → 收集其中调用
的函数名 → 在 hook/ 全树找到每个函数的定义体 → 再收集**它们**调用的函数名……直到不动点
（传递闭包）。只扫一层曾被变异实测证伪：往共享的 ForgetTrackedHandle 本体或一个中转
helper 里塞锁，单层守卫照样绿。在 hook/ 里找不到定义的名字（Win32 / CRT / Interlocked*
/ 函数指针 g_orig_*）视为外部调用放行；但第一层（detour 直接调用的）必须能找到定义，
否则就是扫描面失效。零命中 = 守卫失效，同样判红（与 BUG-1157「零断言伪装通过」同族）。
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

KEYWORDS = {"if", "while", "for", "switch", "return", "sizeof", "static_cast",
            "reinterpret_cast", "const_cast", "defined"}


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def function_body(text: str, name: str) -> str | None:
    """返回 `name(` 定义（行首、非 `;` 结尾的声明）的花括号体，找不到返回 None。
    模板成员/内联函数（`inline bool Name(Slot (&slots)[N], ...)`）同样匹配：`^` 落在
    `inline` 行，参数表里的 `(&slots)` 由 `[^;{]*` 吞掉。"""
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


def callees(body: str) -> list[str]:
    names = re.findall(r"\b([A-Za-z_]\w*)\s*\(", body)
    return sorted({n for n in names if n not in KEYWORDS})


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

    def find_definition(self, name: str) -> tuple[Path, str] | None:
        for path, text in self.sources.items():
            body = function_body(text, name)
            if body is not None:
                return path, body
        return None

    def reachable(self) -> dict[str, tuple[Path, str]]:
        """从 Detour_CloseHandle 出发的传递闭包：{函数名: (定义文件, 函数体)}。"""
        direct = [n for n in callees(self.detour_body or "") if not n.startswith("g_orig_")]
        found: dict[str, tuple[Path, str]] = {}
        queue = list(direct)
        seen: set[str] = set()
        while queue:
            name = queue.pop()
            if name in seen:
                continue
            seen.add(name)
            definition = self.find_definition(name)
            if definition is None:
                # 第一层必须能找到：detour 直接调的东西除 Interlocked* 外全在 hook/ 里，
                # 找不到 = 扫描面坏了。
                self.assertFalse(
                    name in direct and not name.startswith("Interlocked"),
                    f"{name} 从 Detour_CloseHandle 直接调用，却在 hook/ 里没找到定义",
                )
                continue  # 更深层找不到的是 Win32 / CRT / Interlocked* 等外部调用，放行
            found[name] = definition
            queue.extend(n for n in callees(definition[1]) if not n.startswith("g_orig_"))
        return found

    def test_detour_body_has_no_blocking_primitive(self) -> None:
        for primitive in BLOCKING:
            self.assertNotIn(
                primitive,
                self.detour_body or "",
                f"Detour_CloseHandle 自身不得出现 {primitive}",
            )

    def test_everything_reachable_from_detour_is_lock_free(self) -> None:
        found = self.reachable()
        for name, (path, body) in found.items():
            for primitive in BLOCKING:
                self.assertNotIn(
                    primitive,
                    body,
                    f"{path.relative_to(ROOT)} 的 {name} 从 CloseHandle detour 可达，"
                    f"不得使用 {primitive}（BUG-2046：Freeze 线程会在这里等被它挂起的线程）",
                )
        # 零命中 = 守卫空转。Detour_CloseHandle 至少要摘 8 张表，闭包里还必须包含
        # 共享的 ForgetTrackedHandle——它是十张表的单点，单层扫描曾漏掉它。
        self.assertGreaterEqual(
            len(found), 8, f"只检查到 {sorted(found)}，扫描面疑似失效"
        )
        self.assertIn(
            "ForgetTrackedHandle",
            found,
            "共享的 ForgetTrackedHandle 必须在传递闭包里，否则单层扫描的漏洞又回来了",
        )

    def test_forget_helpers_use_the_shared_lock_free_table_or_interlocked(self) -> None:
        """Forget* 必须走 tracked_handle_table.h 或裸 Interlocked CAS——两者之外的实现
        就算暂时没有锁，也没有任何东西阻止下一次改动把锁加回去。"""
        checked = 0
        for name in callees(self.detour_body or ""):
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
            checked += 1
        self.assertGreaterEqual(checked, 8, "Forget* 数量异常，扫描面疑似失效")


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2))

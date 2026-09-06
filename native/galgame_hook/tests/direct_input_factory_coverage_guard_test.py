#!/usr/bin/env python3
"""通用遮罩层必须钩住 dinput/dinput8 的**每一个** DirectInput 工厂入口（BUG-2154 附带发现）。

为什么是源码守卫：漏钩一个工厂入口的后果是**静默**的——设备照常建出来，我们一无所知，
左键照样穿到游戏里推进对话，而 required 那两位仍然按"模块已加载"点亮，于是 shield 永远停在
不完整覆盖。没有任何断言会红，只有真机上"点了没反应"。实测 フタマタ恋愛 Ver1.00 加载
dinput.dll 而 ready 的 DirectInput 两位始终不亮；当时 DirectInputCreateEx 全仓没钩，
而 DirectInputCreateA/W 在 dinput.dll 内部只是它的包装——游戏直接
GetProcAddress("DirectInputCreateEx") 就完全绕过。

判据的来源刻意**不是**一份手写名单：那正是"漏一个"的同一个失效模式。在 Windows 上直接读
系统 dinput.dll / dinput8.dll 的导出表，取所有形如 `DirectInput*Create*` 的名字当作必须
覆盖的集合——微软哪天多加一个入口，这条守卫会自己发现。系统 DLL 不可读时（非 Windows、
或 32/64 位 System32 重定向异常）退回文档已知集合，仍然强制，绝不静默跳过。

零命中 = 守卫失效，判红（与 BUG-1157「零断言伪装通过」同族）。
"""

from __future__ import annotations

import re
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHIELD = ROOT / "hook" / "generic_input_shield.inc"

# 系统 DLL 读不到时的兜底集合（DirectX 文档的完整工厂入口集）。它只是 fallback，
# Windows 上以真实导出表为准。
DOCUMENTED_FACTORIES = {
    "DirectInput8Create",
    "DirectInputCreateA",
    "DirectInputCreateW",
    "DirectInputCreateEx",
}

SYSTEM_DLLS = (
    Path(r"C:\Windows\System32\dinput.dll"),
    Path(r"C:\Windows\System32\dinput8.dll"),
    Path(r"C:\Windows\SysWOW64\dinput.dll"),
    Path(r"C:\Windows\SysWOW64\dinput8.dll"),
)

FACTORY_RE = re.compile(r"^DirectInput\w*Create\w*$")


def read_pe_exports(path: Path) -> set[str]:
    """返回 PE 导出表里的名字集合。任何解析失败都返回空集，由调用方决定怎么办。"""
    try:
        blob = path.read_bytes()
    except OSError:
        return set()
    try:
        if blob[:2] != b"MZ":
            return set()
        e_lfanew = struct.unpack_from("<I", blob, 0x3C)[0]
        if blob[e_lfanew : e_lfanew + 4] != b"PE\0\0":
            return set()
        coff = e_lfanew + 4
        section_count = struct.unpack_from("<H", blob, coff + 2)[0]
        opt_size = struct.unpack_from("<H", blob, coff + 16)[0]
        opt = coff + 20
        magic = struct.unpack_from("<H", blob, opt)[0]
        data_dirs = opt + (96 if magic == 0x10B else 112)
        export_rva, _ = struct.unpack_from("<II", blob, data_dirs)
        if export_rva == 0:
            return set()
        sections = []
        table = opt + opt_size
        for i in range(section_count):
            entry = table + i * 40
            vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", blob, entry + 8)
            sections.append((vaddr, max(vsize, rawsize), rawptr))

        def to_offset(rva: int) -> int | None:
            for vaddr, size, rawptr in sections:
                if vaddr <= rva < vaddr + size:
                    return rawptr + (rva - vaddr)
            return None

        directory = to_offset(export_rva)
        if directory is None:
            return set()
        name_count = struct.unpack_from("<I", blob, directory + 24)[0]
        names_rva = struct.unpack_from("<I", blob, directory + 32)[0]
        names_at = to_offset(names_rva)
        if names_at is None:
            return set()
        out: set[str] = set()
        for i in range(name_count):
            name_rva = struct.unpack_from("<I", blob, names_at + i * 4)[0]
            at = to_offset(name_rva)
            if at is None:
                continue
            end = blob.index(b"\0", at)
            out.add(blob[at:end].decode("ascii", "replace"))
        return out
    except (struct.error, ValueError, IndexError):
        return set()


def required_factories() -> tuple[set[str], str]:
    """必须覆盖的工厂入口集合，以及它是怎么来的（用于失败信息）。"""
    derived: set[str] = set()
    seen_any = False
    for dll in SYSTEM_DLLS:
        exports = read_pe_exports(dll)
        if exports:
            seen_any = True
            derived |= {name for name in exports if FACTORY_RE.match(name)}
    if seen_any and derived:
        return derived, "系统 dinput/dinput8 导出表"
    return set(DOCUMENTED_FACTORIES), "文档兜底集合（系统 DLL 不可读）"


class DirectInputFactoryCoverageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = SHIELD.read_text(encoding="utf-8")

    def test_shield_source_is_readable(self) -> None:
        # 扫描面失效必须判红，而不是让下面的断言在空串上恒绿。
        self.assertTrue(SHIELD.is_file(), f"扫描面不存在：{SHIELD}")
        self.assertIn(
            "TryInstallGenericDirectInputFactories",
            self.text,
            "generic_input_shield.inc 里找不到工厂安装函数——守卫的扫描面已失效，"
            "改名了就把这条守卫一起改",
        )

    def test_required_set_is_not_empty(self) -> None:
        names, origin = required_factories()
        self.assertTrue(
            names, f"必须覆盖的工厂集合为空（来源：{origin}）——守卫失效，判红"
        )

    def test_every_factory_export_is_hooked(self) -> None:
        names, origin = required_factories()
        missing = sorted(name for name in names if f'"{name}"' not in self.text)
        self.assertEqual(
            [],
            missing,
            f"generic_input_shield.inc 没有钩这些 DirectInput 工厂入口：{missing}\n"
            f"（必须覆盖的集合来源：{origin}）\n"
            "漏钩是静默的：设备照常建出来，左键照样穿到游戏里推进对话，而 required 仍按"
            "「模块已加载」点亮，shield 永远停在不完整覆盖，没有任何断言会红。",
        )

    def test_each_hooked_factory_has_its_own_detour_and_latch(self) -> None:
        """光有 GetProcAddress 字符串不够：每个入口都要有自己的 detour 和 hooked 闩。

        变异实测：把 Ex 那一段的 detour 换成 Detour_GenericDirectInputCreateW（复用别人的
        detour，original 指针就会串台）时，这条会红。
        """
        names, _ = required_factories()
        problems: list[str] = []
        for name in sorted(names):
            if f'"{name}"' not in self.text:
                continue  # 上一条已经报过
            block = re.search(
                r'GetProcAddress\([^,]+,\s*"' + re.escape(name) + r'"\)\)?,\s*'
                r"reinterpret_cast<void \*>\(&(\w+)\),\s*"
                r"reinterpret_cast<void \*\*>\(&(\w+)\)",
                self.text,
            )
            if block is None:
                problems.append(f"{name}: 没有 detour + original 指针的安装块")
                continue
            detour, original = block.group(1), block.group(2)
            if self.text.count(f"reinterpret_cast<void *>(&{detour})") != 1:
                problems.append(f"{name}: detour {detour} 被多个入口共用，original 会串台")
            if self.text.count(f"reinterpret_cast<void **>(&{original})") != 1:
                problems.append(f"{name}: original 指针 {original} 被多个入口共用")
        self.assertEqual([], problems, "\n".join(problems))


if __name__ == "__main__":
    unittest.main(verbosity=2)

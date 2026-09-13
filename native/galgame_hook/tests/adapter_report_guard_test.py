#!/usr/bin/env python3
"""adapter 运行期读数（v23 / BUG-2149）的源码不变式。

这条面回答的是「这局到底哪个 adapter 认领了、装上没有」。它最危险的失败形状**不是**
编译错误，而是：有人加了一个 adapter 却没让它进读数——读数看着完全正常，只是少一行，
于是关于那个引擎的每一个问题继续答不出来，而且没有任何东西会红。

所以这里守的是「成员集合 ⊆ 上报集合」，以及写点/读点/限速三处都还在。
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REGISTRY = ROOT / "hook" / "adapter_registry.inc"
FIELDS = ROOT / "hook" / "generated" / "adapter_fields.inc"
ADMISSION = ROOT / "hook" / "generated" / "adapter_admission.inc"
IPC = ROOT / "include" / "voice_hook_ipc.h"
RING_PROBE = ROOT / "tools" / "ring_probe.cpp"

SNAPSHOT_FN = "void PublishAdapterReportSnapshot()"

MEMBER_RE = re.compile(r"^\s+[A-Za-z0-9_]+Adapter\s+([a-z0-9_]+_)\s*;", re.M)
CONSIDER_RE = re.compile(r"consider\(([a-z0-9_]+_)\)")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _function_body(source: str, signature: str) -> str | None:
    """取 signature 之后第一对花括号之间的正文（按深度配对，不靠缩进）。"""
    at = source.find(signature)
    if at < 0:
        return None
    open_at = source.find("{", at)
    if open_at < 0:
        return None
    depth = 0
    for i in range(open_at, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[open_at + 1 : i]
    return None


def declared_members(registry: str, fields: str) -> set[str]:
    """registry 里手写的 + generated/adapter_fields.inc 里生成的全部 adapter 成员。"""
    return set(MEMBER_RE.findall(registry)) | set(MEMBER_RE.findall(fields))


def reported_members(registry: str, admission: str) -> set[str]:
    """PublishAdapterReportSnapshot 正文里 consider 到的 + 它 include 的生成清单。"""
    body = _function_body(registry, SNAPSHOT_FN)
    if body is None:
        return set()
    reported = set(CONSIDER_RE.findall(body))
    if "generated/adapter_admission.inc" in body:
        reported |= set(CONSIDER_RE.findall(admission))
    return reported


class AdapterReportGuard(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = _read(REGISTRY)
        self.fields = _read(FIELDS)
        self.admission = _read(ADMISSION)
        self.ipc = _read(IPC)
        self.ring_probe = _read(RING_PROBE)

    def test_anchor_is_alive(self) -> None:
        # 锚点没了就别让这套守卫静默变成空跑。
        self.assertIn(SNAPSHOT_FN, self.registry, "快照函数改名/删除了，本守卫在守空气")
        self.assertGreater(
            len(declared_members(self.registry, self.fields)),
            10,
            "解析不到 adapter 成员：正则与声明写法漂开了，集合比较会假绿",
        )

    def test_every_adapter_member_is_reported(self) -> None:
        declared = declared_members(self.registry, self.fields)
        reported = reported_members(self.registry, self.admission)
        missing = sorted(declared - reported)
        self.assertEqual(
            [],
            missing,
            "这些 adapter 有成员却没进运行期读数：%s —— 症状不是编译错误，"
            "而是读数少一行、关于它们的诊断继续答不出来，且没有任何东西会红" % missing,
        )

    def test_snapshot_is_called_from_poll(self) -> None:
        # 只定义不调用 = 写点不存在，读侧永远读到 seq==0。
        self.assertIn(
            "PublishAdapterReportSnapshot();",
            self.registry,
            "快照函数没有被调用：定义了没人调等于这条面不存在",
        )

    def test_snapshot_is_rate_limited(self) -> None:
        body = _function_body(self.registry, SNAPSHOT_FN)
        self.assertIsNotNone(body)
        assert body is not None
        self.assertIn(
            "adapter_report_tick_",
            body,
            "快照没有限速：diagnostics() 内部会调 probe()，而 CMVS/AOS/Unreal 的 probe "
            "要读盘枚举，Poll 最快 16ms 一轮——诊断面没有低延迟需求，不该为它每秒付几十次目录枚举",
        )
        self.assertRegex(
            body,
            r"now\s*-\s*adapter_report_tick_\s*<",
            "限速要真的比较时间差，光有个时间戳不算",
        )

    def test_publish_clears_trailing_slots(self) -> None:
        body = _function_body(self.ipc, "inline uint32_t PublishAdapterReports(")
        self.assertIsNotNone(body, "找不到发布器")
        assert body is not None
        self.assertRegex(
            body,
            r"for\s*\(size_t\s+i\s*=\s*writable;",
            "尾部残留槽没清：adapter 数变少时（换构建）旧槽会以陈旧读数继续存在，"
            "读者看到的是上一次的 probe/installed",
        )

    def test_read_point_exists(self) -> None:
        # 写点有了、读点一个没有，正是这条面原来的病。
        self.assertIn(
            "ReadAdapterReports(",
            self.ring_probe,
            "ring_probe 没有读点：这条面加了等于没加",
        )

    def test_layout_change_bumped_the_shared_version(self) -> None:
        # 布局变了必须升版：两侧都用 sizeof(SharedHeader) 现算 ring/region 基址，
        # 新旧混装会整体错位，而版本门本会放行。
        self.assertIn("adapter_reports[kAdapterReportSlots]", self.ipc)
        match = re.search(r"constexpr\s+uint32_t\s+kSharedVersion\s*=\s*(\d+);", self.ipc)
        self.assertIsNotNone(match, "找不到 kSharedVersion")
        assert match is not None
        self.assertGreaterEqual(
            int(match.group(1)),
            23,
            "SharedHeader 尾部追加了 adapter_reports 却没升 kSharedVersion",
        )

    def test_slot_carries_its_own_id(self) -> None:
        # 下标制会在有人往 generated 清单中间插一行时整体错位，且不报错。
        self.assertRegex(
            self.ipc,
            r"struct\s+AdapterReportSlot\s*\{\s*\n\s*char\s+id\[kAdapterReportIdChars\]",
            "槽必须自带 id：按注册顺序编号会在清单中间插行时整体错位且不报错",
        )


class AdapterReportGuardMutation(unittest.TestCase):
    """变异自测：把不变式破坏掉，守卫必须红。"""

    def setUp(self) -> None:
        self.registry = _read(REGISTRY)
        self.fields = _read(FIELDS)
        self.admission = _read(ADMISSION)

    def test_dropping_one_adapter_from_the_report_is_red(self) -> None:
        declared = sorted(declared_members(self.registry, self.fields))
        self.assertTrue(declared)
        victim = "loopback_"
        self.assertIn(victim, declared)
        dirty = self.registry.replace("    consider(%s);\n" % victim, "", 1)
        self.assertNotEqual(dirty, self.registry, "变异锚点必须真的存在")
        missing = declared_members(dirty, self.fields) - reported_members(
            dirty, self.admission
        )
        self.assertIn(victim, missing, "删掉一行上报，集合比较必须发现它")

    def test_dropping_the_generated_include_is_red(self) -> None:
        # 去掉生成清单的 include：所有由脚手架登记的引擎一次性全掉出读数。
        dirty = self.registry.replace(
            '#include "generated/adapter_admission.inc"\n'
            "    fushi_voice_hook::PublishAdapterReports",
            "    fushi_voice_hook::PublishAdapterReports",
            1,
        )
        self.assertNotEqual(dirty, self.registry, "变异锚点必须真的存在")
        missing = declared_members(dirty, self.fields) - reported_members(
            dirty, self.admission
        )
        self.assertIn("cmvs_", missing)
        self.assertIn("sgre_", missing)


if __name__ == "__main__":
    unittest.main()

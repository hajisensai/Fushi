#!/usr/bin/env python3
"""Static guard for the P1 adapter boundary."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AdapterStructureTest(unittest.TestCase):
    @staticmethod
    def _strip_comments(source: str) -> str:
        """剥掉 `//` 行注释与 `/* */` 块注释。

        「顺序 / 不存在」类断言必须先剥：注释里出现同一个标识符会先被 index 命中，
        把守卫变成恒真或恒假（本仓反复踩过的坑）。
        """
        out = []
        i = 0
        n = len(source)
        while i < n:
            if source.startswith("//", i):
                j = source.find("\n", i)
                i = n if j < 0 else j
            elif source.startswith("/*", i):
                j = source.find("*/", i + 2)
                i = n if j < 0 else j + 2
            else:
                out.append(source[i])
                i += 1
        return "".join(out)

    @staticmethod
    def _member_body(source: str, signature: str) -> str:
        """按大括号配平取成员函数体（含签名）。

        **不要**改回「从签名往后取固定长度窗口」：这些成员是挨着定义的，窗口一溢出
        就会读到下一个函数，断言恒真。
        """
        at = source.index(signature)
        open_at = source.index("{", at)
        depth = 0
        for i in range(open_at, len(source)):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    return source[at : i + 1]
        raise AssertionError("unbalanced body for " + signature)

    def test_main_worker_only_uses_registry(self) -> None:
        source = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        # 行数预算防的是「引擎逻辑重新爬回 dll_main」——真正的判据是下面那三条
        # （必须经 registry、不得出现 TryHook）。系统头 include 与其解释注释不属于
        # 它要挡的东西，但也算行；上界随之从 700 抬到 720，判据本身不变。
        #
        # 不要改回「数总行数」：系统头 include、空行与解释注释都不是它要挡的东西，
        # 却一样计入总行。上界因此被反复顶破而一路抬（700 -> 720），每次都只是改数字；
        # BUG-2016 那次直接是两行 #include 把 719 推到 721，把 develop 打红。只改数字
        # 等于拆守卫：阈值跟着噪声漂，真正要挡的引擎逻辑反而有了越来越大的余地。
        # 改成只量代码行（剔注释、去空行、去 #include），量的就是判据本身想拦的那东西。
        code_lines = [
            line
            for line in self._strip_comments(source).splitlines()
            if line.strip() and not line.lstrip().startswith("#include")
        ]
        self.assertLess(len(code_lines), 520)
        self.assertIn("AdapterRegistry registry;", source)
        self.assertIn("registry.InstallStartupAdapters();", source)
        self.assertIn("registry.Poll();", source)
        self.assertNotIn("TryHook", source)

    def test_every_adapter_is_an_independent_include(self) -> None:
        source = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        adapters = {
            "unity_adapter.inc": "Unity IL2CPP AudioClip",
            "windows_audio_adapter.inc": "IXAudio2SourceVoice",
            "siglus_adapter.inc": "SiglusEngine OVK",
            "kirikiri_adapter.inc": "KiriKiri",
            "renpy_adapter.inc": "Ren'Py",
            "text_render_adapter.inc": "grab dialogue text",
            "loopback_adapter.inc": "WASAPI loopback",
        }
        for filename, marker in adapters.items():
            path = ROOT / "hook" / "adapters" / filename
            self.assertTrue(path.is_file(), filename)
            self.assertIn(marker, path.read_text(encoding="utf-8"))
            self.assertIn(f'#include "adapters/{filename}"', source)

    def test_v19_geometry_publishers_use_registry_lifecycle(self) -> None:
        adapter_root = ROOT / "hook" / "adapters"
        publishers = []
        for path in sorted(adapter_root.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in {
                ".c",
                ".cc",
                ".cpp",
                ".cxx",
                ".h",
                ".hpp",
                ".inc",
            }:
                continue
            source = path.read_text(encoding="utf-8")
            if "g_geometry_provider_registry.PublishHit" not in source:
                continue
            publishers.append(path.relative_to(adapter_root).as_posix())
            lifecycle_source = source
            if path.name == "hunex_gge_lookup_runtime.inc":
                # 该 runtime 是 HUNEX adapter 的纯 include 单元；provider 的
                # OfferReady/Retire 由包含它的 adapter worker/teardown 持有。
                owner = (adapter_root / "hunex_gge_adapter.inc").read_text(
                    encoding="utf-8"
                )
                self.assertIn('#include "hunex_gge_lookup_runtime.inc"', owner)
                lifecycle_source += owner
            self.assertIn(
                "g_geometry_provider_registry.OfferReady", lifecycle_source
            )
            self.assertIn("g_geometry_provider_registry.Retire", lifecycle_source)

        self.assertEqual(7, len(publishers), publishers)
        self.assertIn("hunex_gge_lookup_runtime.inc", publishers)
        self.assertIn("smash_fzmedia_lookup.inc", publishers)

        leaf = (ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc").read_text(
            encoding="utf-8"
        )
        leaf_publication = self._function_body(leaf, "bool PublishLeafLookupHit(")
        self.assertIn(
            "publication.geometry_generation = payload.geometry_generation;",
            leaf_publication,
        )
        self.assertNotIn(
            "publication.geometry_generation = payload.sentence_epoch;",
            leaf_publication,
        )

    def test_geometry_publishers_declare_an_admitted_coordinate_space(self) -> None:
        """每个几何发布者的坐标域必须是被 host 直连路径认过的两种之一。

        host 的直连覆盖窗（fushi/windows/runner/gal_direct_card_geometry.h）把
        `view` 按等比缩放 + 居中映射到游戏客户区，再以字形矩形贴附卡片。该映射的正确性
        建立在一条**跨仓约定**上：

          * ClientPhysicalPixels 的发布者，view 必须就是客户区 —— 此时 scale 恒为 1、
            信箱边为 0，映射退化成恒等变换，与放开 1:1 闸门之前逐像素相同；
          * PrimaryLayer 的发布者（目前只有 KiriKiri），view 是引擎画布 —— 正是需要
            那次缩放的那一个。

        若将来有适配器发布 LayoutLocal（IPC 枚举允许，见 voice_hook_ipc.h 的
        IsPublicationSane 上界），它的坐标既不是客户区也不是画布，host 仍会照着上面
        两条之一去缩放，症状是「卡片贴在离谱的位置」，而三边都不报错。本守卫让这种
        新增在**编译期之外的最早时刻**变红，逼调用方回来改 host 的映射，而不是等真机。
        """
        adapter_root = ROOT / "hook" / "adapters"
        admitted = {
            "kLookupCoordinateSpaceClientPhysicalPixels",
            "kLookupCoordinateSpacePrimaryLayer",
        }
        seen: dict[str, str] = {}
        for path in sorted(adapter_root.rglob("*.inc")):
            source = self._strip_comments(path.read_text(encoding="utf-8"))
            if "g_geometry_provider_registry.PublishHit" not in source:
                continue
            name = path.relative_to(adapter_root).as_posix()
            marker = "publication.coordinate_space ="
            at = source.find(marker)
            self.assertNotEqual(-1, at, f"{name} 必须显式声明 coordinate_space")
            tail = source[at + len(marker) : at + len(marker) + 200]
            spaces = [c for c in admitted if c in tail]
            self.assertEqual(
                1,
                len(spaces),
                f"{name} 的 coordinate_space 不在 host 直连路径认过的集合里：{tail.strip()[:80]}",
            )
            seen[name] = spaces[0]

        self.assertEqual(7, len(seen), seen)
        # PrimaryLayer 是唯一需要 host 做画布→客户区缩放的域；它多一个成员就意味着
        # 多一个引擎走那条缩放路径，必须连同 host 的映射与其单测一起复核。
        primary = sorted(
            n for n, c in seen.items() if c == "kLookupCoordinateSpacePrimaryLayer"
        )
        self.assertEqual(["kirikiri_adapter.inc"], primary, seen)

    def test_sgre_lookup_uses_game_parsed_draw_state(self) -> None:
        source = (
            ROOT / "hook" / "adapters" / "sgre_lookup.inc"
        ).read_text(encoding="utf-8")
        anchors = (
            ROOT / "hook" / "adapters" / "sgre_anchors.h"
        ).read_text(encoding="utf-8")
        detour = source.split("void __fastcall SgreTextDrawDetour", 1)[1]
        detour = detour.split("bool InstallSgreLookupSensor", 1)[0]
        snapshot = detour.index("CaptureSgreLookupDrawState(text_surface)")
        original = detour.index("g_sgre_text_draw_original(text_surface)")
        self.assertLess(snapshot, original)
        # The measured draw boundary lives in the known-build table; the hook
        # site itself reads the resolved anchor set and never a raw constant.
        self.assertIn("kSgreTextDrawRva", anchors)
        self.assertIn("kSgreScenarioTextVtableRva", anchors)
        self.assertIn("kSgreKnownBuilds", anchors)
        install = source.split("bool InstallSgreLookupSensor", 1)[1]
        install = install.split("bool ReadLatestSgreLookupCapture", 1)[0]
        self.assertNotIn("kSgreTextDrawRva", install)
        self.assertNotIn("kSgreScenarioTextVtableRva", install)
        self.assertIn("g_sgre_anchors.text_draw.rva", install)
        self.assertIn("g_sgre_anchors.scenario_text_vtable.rva", install)
        self.assertLess(
            install.index("!g_sgre_anchors.lookup_sensor_available()"),
            install.index("g_sgre_anchors.text_draw.rva"),
        )
        self.assertIn("kSgreDrawVisibleGlyphsOffset", source)
        self.assertIn("kSgreGlyphCharacterOffset", source)
        self.assertIn("kSgreGlyphDrawXOffset", source)
        self.assertIn("kSgreGlyphDrawYOffset", source)
        self.assertIn("MatchesSgreScenarioDrawMetrics", source)
        self.assertNotIn("g_sgre_text_layout_original", source)
        self.assertNotIn("LunaNormalizeMagesControls", source)
        self.assertNotIn("kLookupDiagLunaKnownHookReady", source)

    def test_sgre_lookup_inc_call_sites_use_the_tested_helpers(self) -> None:
        """`.inc` 里的调用点没有任何 CTest 编译单元覆盖，只能源码守。

        `tests/sgre_adapter_test.cpp` 只 include `sgre_lookup.h`，所以
        `SgreLookupHitTextGeneration` / `SgreScenarioLineHeightForClient` 这两个
        纯函数本身是真跑过的；把它们**接进** `sgre_lookup.inc` 的那两行却在任何
        翻译单元之外——BUG-2085 / BUG-2083 的整条修复回退掉，ctest 照样全绿。
        """
        source = (
            ROOT / "hook" / "adapters" / "sgre_lookup.inc"
        ).read_text(encoding="utf-8")

        # BUG-2085 — 点击载荷的 text_generation 必须是「精确文本那一行的行序号」，
        # 不是查词捕获计数器；退回 capture_generation 就等于制卡永远配不上句子。
        publish = self._function_body(
            source, "bool PublishSgreLookupHit(uint64_t capture_generation"
        )
        self.assertIn(
            "publication.text_generation = fushi_voice_hook::"
            "SgreLookupHitTextGeneration(",
            publish,
        )
        self.assertNotIn(
            "publication.text_generation = capture_generation", publish
        )

        # BUG-2083 — 台词面判据的期望行高必须按实时客户区算（设计 40 x 渲染缩放）；
        # 钉成 0 会让门退回自洽带，1080p 窗口下的误判正是这条 bug 的原样。
        copy_draw = self._function_body(
            source, "SgreLookupCaptureResult CopySgreLookupDrawState("
        )
        self.assertIn(
            "expected_line_height = fushi_voice_hook::"
            "SgreScenarioLineHeightForClient(",
            copy_draw,
        )
        self.assertIn("MatchesSgreScenarioDrawMetrics", copy_draw)

        # BUG-2087 审查缺陷 D — 两个高亮窗都是 WS_EX_TOPMOST。悬浮分支靠 game_point
        # 自带前台判据，词高亮分支必须显式带上同一个 game_foreground，否则卡片弹出后
        # Alt+Tab 走开，高亮窗会一直盖在别的应用上。
        tick = self._function_body(source, "void ProcessSgreLookupTick()")
        self.assertIn("const bool game_foreground = GetForegroundWindow() == game;", tick)
        self.assertIn("game_foreground && point_window != nullptr", tick)
        self.assertIn("if (game_foreground && popup_visible &&", tick)

    def test_exact_lookup_clicks_revalidate_logical_generation(self) -> None:
        sgre = (
            ROOT / "hook" / "adapters" / "sgre_lookup.inc"
        ).read_text(encoding="utf-8")
        siglus = (
            ROOT / "hook" / "adapters" / "siglus_lookup.inc"
        ).read_text(encoding="utf-8")

        sgre_up = self._function_body(sgre, "SgreGetDeviceStateDetour(")
        self.assertIn("SgreLookupPayloadMatchesPublishedTarget", sgre_up)
        sgre_worker = self._function_body(sgre, "void ProcessSgreLookupTick()")
        self.assertLess(
            sgre_worker.index("ReadLatestSgreLookupCapture"),
            sgre_worker.index("ReadLatestSgreLookupClickSubmit"),
        )
        self.assertLess(
            sgre_worker.index("g_geometry_provider_registry.OfferReady"),
            sgre_worker.index("ReadLatestSgreLookupClickSubmit"),
        )
        self.assertLess(
            sgre_worker.index("ReadLatestSgreLookupClickSubmit"),
            sgre_worker.index("PublishSgreLookupClickPayload(click_event.payload)"),
        )
        sgre_publish = self._function_body(
            sgre, "bool PublishSgreLookupClickPayload("
        )
        self.assertIn("IsSgreLookupPayloadCurrent(payload)", sgre_publish)
        self.assertIn("payload.logical_generation", sgre_publish)
        self.assertNotIn("payload.capture_seq", sgre_publish)

        siglus_up = self._function_body(siglus, "Detour_SiglusGetKeyState(")
        self.assertIn("SiglusLookupPayloadMatchesPublishedTarget", siglus_up)
        siglus_publish = self._function_body(
            siglus, "bool PublishSiglusLookupPayload("
        )
        self.assertIn("IsSiglusLookupPayloadCurrent(payload)", siglus_publish)
        siglus_capture = self._function_body(
            siglus, "void ConsumeSiglusLookupCaptures()"
        )
        self.assertIn("SameSiglusLookupGeometry", siglus_capture)
        self.assertIn("NextSiglusLookupLogicalGeneration", siglus_capture)
        self.assertIn(
            "matched_end == g_siglus_lookup_glyph_captures.count",
            siglus_capture,
        )

    def test_exact_engine_signatures_are_portable_unique_and_fail_closed(
        self,
    ) -> None:
        adapter_root = ROOT / "hook" / "adapters"
        common = (adapter_root / "exact_lookup_signature.h").read_text(
            encoding="utf-8"
        )
        sgre = (adapter_root / "sgre_lookup.inc").read_text(encoding="utf-8")
        sgre_anchors = (adapter_root / "sgre_anchors.h").read_text(
            encoding="utf-8"
        )
        sgre_profile = (adapter_root / "sgre_profile.h").read_text(
            encoding="utf-8"
        )
        leaf = (adapter_root / "leaf_aquaplus_adapter.inc").read_text(
            encoding="utf-8"
        )
        leaf_profile = (adapter_root / "leaf_aquaplus_profile.h").read_text(
            encoding="utf-8"
        )
        siglus = (adapter_root / "siglus_lookup.inc").read_text(
            encoding="utf-8"
        )
        siglus_header = (adapter_root / "siglus_lookup.h").read_text(
            encoding="utf-8"
        )

        self.assertIn("FindUniquePatternInExecutableSections", common)
        self.assertIn("FindUniqueRipRelativePatternInExecutableSections", common)
        self.assertIn("FindUniqueAbsolute32PatternInExecutableSections", common)
        self.assertIn("return {nullptr, 2u};", common)

        sgre_gate = self._function_body(
            sgre, "bool IsSgreResolvedStructureMatched("
        )
        for required in (
            "ResolveSgreAnchorsGuarded",
            "ValidateSgreLookupAnchorStructure",
            "ValidateSgreDirectInputAnchorStructure",
        ):
            self.assertIn(required, sgre_gate)
        for required in (
            "kSgreScenarioTextVtableSignature",
            "kSgreScenarioTextVtableCorroborationSignature",
            "kSgreDirectInputMouseDeviceSignature",
            "kSgreDirectInputMouseDeviceCorroborationSignature",
            "FindSgreContainingFunctionBegin",
        ):
            self.assertIn(required, sgre_anchors)
        # Uniqueness must cover the complete PE section table. A fixed-capacity
        # view may reject an oversized image, but it must never silently omit
        # later executable sections from ambiguity detection.
        self.assertIn("count > kSgreImageMaxSections", sgre_profile)
        self.assertNotIn(
            "view->section_count < kSgreImageMaxSections", sgre_profile
        )

        leaf_gate = self._function_body(
            leaf, "bool IsLeafAquaplusProfileMatched()"
        )
        for required in (
            "FindUniqueAbsolute32PatternInExecutableSections",
            "FindUniquePatternInExecutableSections",
            "MatchesRel32CallEndingAt",
            "MatchesAbsoluteIndirectCallEndingAt",
            "kEmbedHookOffsetFromAnchor",
        ):
            self.assertIn(required, leaf_gate)
        self.assertIn("kTextTraversalEntryMask", leaf_profile)
        self.assertIn("kTextTraversalCookieOperandOffset", leaf_profile)
        self.assertNotIn("0x30, 0x16, 0x4d, 0x00", leaf_profile.lower())

        siglus_gate = self._function_body(
            siglus, "bool IsSiglusExactBinaryStructureMatched("
        )
        for required in (
            "FindUniquePatternInExecutableSections",
            "MatchesRel32CallEndingAt",
            "MatchesExecutableCallEndingAt",
            "glyph.count == 1u",
            "input.count == 1u",
        ):
            self.assertIn(required, siglus_gate)
        self.assertIn("kGlyphLayoutEntryPattern", siglus_header)
        self.assertIn("kAnemoiInputMessageEntryPattern", siglus_header)
        self.assertIn("kSprbInputMessageEntryPattern", siglus_header)

        for source in (
            common,
            sgre,
            sgre_anchors,
            leaf,
            leaf_profile,
            siglus,
            siglus_header,
        ):
            self.assertNotIn("D:\\", source)
            self.assertNotIn("C:\\", source)

    def test_hunex_lookup_exact_provider_stays_fail_closed_and_registry_owned(
        self,
    ) -> None:
        source = (
            ROOT / "hook" / "adapters" / "hunex_gge_adapter.inc"
        ).read_text(encoding="utf-8")
        runtime = (
            ROOT / "hook" / "adapters" / "hunex_gge_lookup_runtime.inc"
        ).read_text(encoding="utf-8")
        scanner = self._function_body(source, "bool ScanHunexGgeRuntimeAnchors()")
        for required in (
            "IMAGE_SCN_MEM_EXECUTE",
            "draw_count != 1u",
            "glyph_count != 1u",
            "key_poller_count != 1u",
            "input_pump_count != 1u",
            "raw_glyph_calls == 2u",
            "raw_poller_calls == 1u",
            "imported_async_key_state != exported_async_key_state",
        ):
            self.assertIn(required, scanner)
        self.assertIn('#include "hunex_gge_lookup_runtime.inc"', source)
        self.assertIn("g_geometry_provider_registry.OfferReady", source)
        self.assertIn("g_geometry_provider_registry.Retire", source)
        self.assertIn("g_geometry_provider_registry.PublishHit", runtime)
        self.assertIn("kLookupGeometryProviderIdHunexGge", source)
        self.assertIn("kLookupGeometryProviderIdHunexGge", runtime)
        capabilities = self._function_body(
            source,
            "fushi_voice_hook::AdapterCapability capabilities() const override",
        )
        self.assertIn("AdapterCapability::kText", capabilities)
        self.assertIn("AdapterCapability::kResourceAudio", capabilities)

    def test_native_loopback_is_policy_gated_and_generation_owned(self) -> None:
        registry = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )
        worker = (
            ROOT / "hook" / "adapters" / "loopback_adapter.inc"
        ).read_text(encoding="utf-8")
        ipc = (ROOT / "include" / "voice_hook_ipc.h").read_text(
            encoding="utf-8"
        )

        loopback_class = registry.split("class LoopbackAdapter", 1)[1]
        loopback_class = loopback_class.split("class AdapterRegistry", 1)[0]
        install = loopback_class.split("bool install() override", 1)[1]
        install = install.split("AdapterCapability capabilities", 1)[0]
        self.assertIn("PollPolicy();", install)
        self.assertNotIn("CreateThread", install)
        self.assertEqual(loopback_class.count("CreateThread("), 1)
        self.assertIn("NativeLoopbackRequestMatches", loopback_class)
        self.assertIn("control_.request_seq", loopback_class)
        self.assertIn("NativeLoopbackWorkerFailureApplies", loopback_class)
        self.assertIn(
            "WaitForSingleObject(thread_, 0) == WAIT_OBJECT_0",
            loopback_class,
        )
        self.assertIn("WaitForSingleObject(thread_, INFINITE)", loopback_class)

        # The worker independently gates every COM startup stage and binds to
        # the request generation, so rapid allow->deny->allow cannot reuse it.
        self.assertIn("NativeLoopbackWorkerMayCapture", worker)
        self.assertIn("!LbShouldStop(control)", worker)
        initialize = worker.index("client->Initialize(")
        self.assertLess(
            worker.rindex("kLoopbackDiagInitializeAttempted", 0, initialize),
            initialize,
        )
        self.assertIn("client->Stop();", worker)
        self.assertLess(worker.index("client->Stop();"), worker.index("client->Release();"))

        for field in (
            "native_loopback_requested",
            "native_loopback_request_seq",
            "native_loopback_state",
            "native_loopback_applied_seq",
        ):
            self.assertIn(field, ipc)

        injector = (ROOT / "injector" / "injector_main.cpp").read_text(
            encoding="utf-8"
        )
        run_injection = injector.split("int RunInjection(", 1)[1]
        run_injection = run_injection.split("bool IsSiglusExecutable", 1)[0]
        after_policy_publish = run_injection.split(
            "const uint32_t native_loopback_request_seq", 1
        )[1]
        # Every error exit after allow authority can exist must revoke it before
        # releasing the mapping. The first path is publication failure itself
        # and calls the non-lambda helper directly.
        cursor = 0
        while True:
            failure = after_policy_publish.find("return FailWith", cursor)
            if failure < 0:
                break
            prefix = after_policy_publish[max(0, failure - 900) : failure]
            self.assertTrue(
                "revoke_loopback_before_failure();" in prefix
                or "RevokeNativeLoopbackForFailure(" in prefix,
                prefix,
            )
            cursor = failure + 1
        self.assertIn(
            "if (!loopback_stopped_on_failure)", injector
        )
        self.assertIn(
            "LaunchedProcessDisposition::kTerminate", injector
        )

    def test_xaudio_preload_capture_keeps_lifecycle_and_capacity_guards(
        self,
    ) -> None:
        adapter = (
            ROOT / "hook" / "adapters" / "windows_audio_adapter.inc"
        ).read_text(encoding="utf-8")
        main = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")

        # The SGRE regression was a four-slot ADPCM queue plus a wall-clock
        # expiry. Bursty preloads must use the byte-bounded arena, and pending
        # ownership is invalidated by the XAudio2 lifecycle instead of time.
        self.assertNotIn("kXAudioAdpcmJobCount = 4", adapter)
        self.assertNotIn("kPendingXAudioClipMaxAgeMs", adapter)
        for marker in (
            "kXAudioCaptureJobCount = 1024",
            "kXAudioCaptureArenaBytes = 32u * 1024u * 1024u",
            "kXAudioCapturePageBytes = 16u * 1024u",
            "ReserveXAudioCapturePages",
            "ReleaseXAudioCapturePages",
        ):
            self.assertIn(marker, adapter)

        submit = adapter.split("Detour_SubmitSourceBuffer", 1)[1]
        submit = submit.split("Detour_CreateSourceVoice", 1)[0]
        self.assertLess(
            submit.index("PrepareXAudioCaptureJob("),
            submit.index("OriginalHookForVtableSlot<SubmitSourceBuffer_t>"),
        )
        self.assertLess(
            submit.index("OriginalHookForVtableSlot<SubmitSourceBuffer_t>"),
            submit.index("PublishXAudioCaptureJob("),
        )
        self.assertNotIn("g_orig_SubmitSourceBuffer", main)
        self.assertNotIn("g_orig_FlushSourceBuffers", main)
        self.assertIn("g_submit_source_buffer_originals", main)
        self.assertIn("g_flush_source_buffers_originals", main)
        self.assertIn("originals.Lookup(VtableSlot(com_obj, idx))", main)
        # 先发布 trampoline 再启用 hook：反过来的话 detour 已经在跑、original 还没
        # 登记，正是这次要根治的崩溃形态。范围必须收在 codec 专用的那个安装函数体内
        # ——dll_main.cpp 里还有一条普通 HookFn 路径（它用 g_hooked_fns 去重、根本
        # 不碰 registry），全文件 index() 会先撞上那条路径的 MH_EnableHook(target)，
        # 让这条断言在实现完全正确时也失败。
        registry_installer = main.split(
            "bool HookFnWithOriginalRegistry(", 1
        )[1].split("\n}\n", 1)[0]
        self.assertIn("originals->Publish(target, trampoline)", registry_installer)
        self.assertLess(
            registry_installer.index("originals->Publish(target, trampoline)"),
            registry_installer.index("MH_EnableHook(target)"),
        )
        # 发布成功但启用失败时必须把已登记的 trampoline 撤掉，否则 registry 会留下
        # 一条指向已移除 hook 的 original。
        self.assertIn("originals->Erase(target, trampoline)", registry_installer)
        failed = submit.split("if (FAILED(hr))", 1)[1]
        failed = failed.split("return hr;", 1)[0]
        self.assertIn("ReleaseXAudioCaptureJob(staged)", failed)

        for index, detour in (
            ("kIdxFlushSourceBuffers", "Detour_FlushSourceBuffers"),
            ("kIdxDestroyVoice", "Detour_DestroyVoice"),
        ):
            self.assertIn(index, main)
            self.assertIn(detour, adapter)
            self.assertIn(f"VtableSlot(*ppSourceVoice, {index})", adapter)
        self.assertIn("kIdxCommitChanges", main)
        self.assertIn("Detour_CommitChanges", adapter)
        self.assertIn("VtableSlot(x, kIdxCommitChanges)", adapter)

        for diagnostic in (
            "kXAudioDiagDescriptorExhausted",
            "kXAudioDiagArenaExhausted",
            "kXAudioDiagStaleInvalidated",
            "kXAudioDiagCommitObserved",
        ):
            self.assertIn(diagnostic, adapter)

    def test_xaudio_trace_is_fixed_exported_and_remotely_read(self) -> None:
        trace = (ROOT / "include" / "xaudio_trace.h").read_text(
            encoding="utf-8"
        )
        adapter = (
            ROOT / "hook" / "adapters" / "windows_audio_adapter.inc"
        ).read_text(encoding="utf-8")
        main = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        probe = (ROOT / "tools" / "ring_probe.cpp").read_text(encoding="utf-8")

        self.assertIn("FushiXAudioTraceV1", main)
        self.assertIn("__declspec(dllexport)", main)
        for marker in (
            "sizeof(XAudioTraceFormat) == 244",
            "sizeof(XAudioTraceEvent) == 376",
            "sizeof(XAudioTraceSlot) == 384",
            "offsetof(XAudioTraceBuffer, slots) == 40",
            "kXAudioTraceCapacity = 2048",
            "InterlockedCompareExchange(&slot->writing, 1, 0)",
            "InterlockedIncrement64(&trace->dropped_busy)",
        ):
            self.assertIn(marker, trace)
        wma_capture = trace.split("inline void CaptureXAudioTraceWma", 1)[1]
        wma_capture = wma_capture.split(
            "inline void CaptureXAudioTraceFormat", 1
        )[0]
        self.assertIn(
            "source->pDecodedPacketCumulativeBytes == nullptr",
            wma_capture,
        )
        self.assertIn("source->PacketCount == 0", wma_capture)
        self.assertIn("source->pDecodedPacketCumulativeBytes[0]", wma_capture)
        self.assertIn(
            "source->pDecodedPacketCumulativeBytes[source->PacketCount - 1u]",
            wma_capture,
        )
        for forbidden in (
            "CreateFile",
            "ReadFile",
            "WriteFile",
            "Sleep(",
            "WaitForSingleObject",
            "std::mutex",
            "EnterCriticalSection",
            "malloc(",
            "new ",
            "printf(",
            "fprintf(",
            "OutputDebugString",
            "HookLog",
        ):
            self.assertNotIn(forbidden, wma_capture)
        publisher = trace.split("inline uint64_t PublishXAudioTraceEvent", 1)[1]
        publisher = publisher.split("}  // namespace", 1)[0]
        self.assertLess(publisher.index("std::memcpy"), publisher.rindex(
            "InterlockedExchange64"
        ))
        for forbidden in (
            "CreateFile",
            "ReadFile",
            "WriteFile",
            "Sleep(",
            "WaitForSingleObject",
            "std::mutex",
            "EnterCriticalSection",
            "malloc(",
            "new ",
            "printf(",
            "fprintf(",
            "fopen(",
            "OutputDebugString",
            "HookLog",
        ):
            self.assertNotIn(forbidden, publisher)

        for kind in (
            "kCreate",
            "kSubmit",
            "kStart",
            "kStop",
            "kFlush",
            "kDestroy",
            "kCommit",
            "kWorkerWait",
            "kWorkerPublish",
            "kWorkerInvalidate",
        ):
            self.assertIn(f"XAudioTraceEventKind::{kind}", adapter)

        for marker in (
            "--dump-xaudio-trace",
            "TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32",
            "IMAGE_OPTIONAL_HEADER32",
            "IMAGE_OPTIONAL_HEADER64",
            "ResolveRemotePeExportRva",
            "ReadProcessMemory",
            "sequence_before == expected",
            "sequence_after == expected",
        ):
            self.assertIn(marker, probe)
        main_body = probe.split("int main(int argc, char** argv)", 1)[1]
        self.assertLess(main_body.index("--dump-xaudio-trace"),
                        main_body.index("OpenFileMappingW"))

    def test_leaf_d3d_trace_is_numeric_exported_and_remotely_read(self) -> None:
        trace = (ROOT / "include" / "leaf_d3d_trace.h").read_text(
            encoding="utf-8"
        )
        main = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        adapter = (
            ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc"
        ).read_text(encoding="utf-8")
        probe = (ROOT / "tools" / "ring_probe.cpp").read_text(encoding="utf-8")

        self.assertIn(
            'extern "C" __declspec(dllexport) alignas(8)\n'
            "    fushi_voice_hook::LeafD3DTraceBuffer "
            "FushiLeafD3DTraceV1 = {};",
            main,
        )
        for marker in (
            "sizeof(LeafD3DTraceEvent) == 96",
            "sizeof(LeafD3DTraceSlot) == 104",
            "offsetof(LeafD3DTraceBuffer, slots) == 168",
            "kLeafD3DTraceCapacity = 2048",
            "input_poller_owner_tid",
            "input_poller_conflicts",
            "input_poller_last_conflict_tid",
            "primary_quad_candidates",
            "alternate_quad_candidates",
        ):
            self.assertIn(marker, trace)

        event = trace.split("struct alignas(8) LeafD3DTraceEvent", 1)[1]
        event = event.split("};", 1)[0]
        for forbidden in (
            "char ",
            "wchar_t",
            "void*",
            "std::",
            "payload",
        ):
            self.assertNotIn(forbidden, event)
        self.assertNotIn("code_unit", event)
        self.assertNotIn("packed_cp932", trace)
        self.assertIn("uint32_t match_reserved = 0;", event)
        declarations = [
            line.strip() for line in event.splitlines() if " = " in line
        ]
        self.assertTrue(declarations)
        self.assertTrue(
            all(
                declaration.startswith(("uint64_t ", "uint32_t ", "float "))
                for declaration in declarations
            )
        )

        for marker in (
            "--dump-leaf-d3d-trace",
            "FindRemoteLeafD3DTrace",
            "kLeafD3DTraceExportName",
            "LeafD3DTraceHeaderSnapshot",
            "ReadRemoteExact",
            "ReadProcessMemory",
            "writing_before == 0",
            "sequence_before == expected",
            "sequence_after == expected",
            "Leaf D3D trace export exceeds remote module bounds",
        ):
            self.assertIn(marker, probe)
        main_body = probe.split("int main(int argc, char** argv)", 1)[1]
        self.assertLess(
            main_body.index("--dump-leaf-d3d-trace"),
            main_body.index("OpenFileMappingW"),
        )
        for marker in (
            "ClaimLeafInputPollerThread",
            "ReleaseDeadLeafInputPollerOwner",
            "LeafAquaplusConflictingPollerMustConsume",
            "LeafAquaplusTailRequestIsOrphaned",
        ):
            self.assertIn(marker, adapter)
        # 🔴 争用是当前状态，不是一次性闩。admitted poller 区间是 374 字节的 RVA
        # 区间，任意二级线程碰一次就置位；只要没有清除边，整个进程剩余生命周期查词
        # 全废、用户只看到「点了没反应」。所以判据必须每 tick 用单调冲突计数的增量
        # 重算，且 owner 死了要能回收，否则「去掉闩」等于没去。
        tick = adapter.split("void ProcessLeafAquaplusLookupTick()", 1)[1].split(
            "\n}\n", 1
        )[0]
        self.assertIn("poller_conflicts != g_leaf_lookup_seen_poller_conflicts", tick)
        self.assertIn("g_leaf_lookup_seen_poller_conflicts = poller_conflicts;", tick)
        self.assertIn("ReleaseDeadLeafInputPollerOwner();", tick)
        self.assertIn("input_poller_contended", tick)
        self.assertNotIn(
            "g_leaf_input_poller_conflicted",
            adapter,
            "争用不得再退回没有清除边的一次性闩",
        )
        shutdown = adapter.split("void shutdown() override {", 1)[1].split(
            "\n  }\n", 1
        )[0]
        for marker in (
            "g_leaf_input_poller_owner_tid.store(0",
            "input_poller_contended",
            "g_leaf_lookup_seen_poller_conflicts =",
        ):
            self.assertIn(marker, shutdown, "shutdown 必须把争用账本清干净")
        detour = adapter.split(
            "SHORT WINAPI Detour_LeafGetAsyncKeyState", 1
        )[1].split("HRESULT STDMETHODCALLTYPE Detour_LeafSetTexture", 1)[0]
        self.assertLess(
            detour.index("if (admitted_poller && !poller_owner)"),
            detour.index("AdvanceLeafAquaplusSampledInputTail"),
        )
        self.assertIn(
            "poller=owner:%u,conflicts:%u,last_conflict:%u,contended:%u",
            probe,
        )
        self.assertNotIn("code_unit=", probe)
        for marker in (
            "Detour_LeafTextTraversal",
            "Detour_LeafRasterDraw",
            "profile->text_traversal_rva",
            "profile->raster_draw_rva",
            "profile->raster_glyph_return_rva",
            "profile->raster_packed_cp932_stack_offset",
            "PublishLeafPrivateTraversal",
            "CutLeafPrivateTraversalCommittedSequence",
            "NormalizeLeafAquaplusLookupText",
        ):
            self.assertIn(marker, adapter)
        for forbidden in (
            "DescribeLeafGlyph",
            "Detour_LeafGlyphDraw",
            "glyph_code_unit_offset",
            "glyph_record_stride",
        ):
            self.assertNotIn(forbidden, adapter)
        stage = adapter.split(
            "bool StageLeafLookupPrivateTraversal", 1
        )[1].split("bool BuildLeafLookupGeometryFromCandidate", 1)[0]
        for marker in (
            "AreLeafAquaplusMatchedGlyphDrawsPrimary",
            "captured.draw_format",
            "captured.caller_rva",
            "captured.vertex_stride",
            "captured.fvf",
            "profile->quad_draw_return_rva",
            "profile->quad_vertex_stride",
            "profile->quad_fvf",
        ):
            self.assertIn(marker, stage)
        self.assertNotIn("alternate_quad_draw_return_rva", stage)
        self.assertNotIn("alternate_quad_vertex_stride", stage)
        self.assertNotIn("alternate_quad_fvf", stage)
        self.assertLess(
            stage.index("AreLeafAquaplusMatchedGlyphDrawsPrimary"),
            stage.index("wchar_t decoded"),
        )
        selected_consumer = adapter.split(
            "void ConsumeLeafLookupSelectedText", 1
        )[1].split("void ConsumeLeafLookupPrivateTraversals", 1)[0]
        for marker in (
            "newest_selected_event_seq",
            "ClassifyLeafAquaplusSelectedLineEvent",
            "selected_exact_line",
            "payload_shape_valid",
            "g_leaf_text_processed_seq = newest_selected_event_seq",
            "normalized_units == 0",
        ):
            self.assertIn(marker, selected_consumer)
        self.assertGreaterEqual(
            selected_consumer.count(
                "InvalidateLeafLookupSentence(g_leaf_active_line_units != 0)"
            ),
            2,
        )
        invalid_payload_branch = selected_consumer.split(
            "if (newest_disposition !=", 1
        )[1].split("wchar_t normalized", 1)[0]
        self.assertLess(
            invalid_payload_branch.index("InvalidateLeafLookupSentence"),
            invalid_payload_branch.index("return;"),
        )
        normalization_failure_branch = selected_consumer.split(
            "if (!fushi_voice_hook::NormalizeLeafAquaplusLookupText", 1
        )[1].split("const uint32_t normalized_count", 1)[0]
        self.assertLess(
            normalization_failure_branch.index("InvalidateLeafLookupSentence"),
            normalization_failure_branch.index("return;"),
        )

        private_publisher = adapter.split(
            "bool PublishLeafPrivateTraversal", 1
        )[1].split("void PublishLeafD3DTraceTraversal", 1)[0]
        committed_cut = adapter.split(
            "uint64_t CutLeafPrivateTraversalCommittedSequence", 1
        )[1].split("void InvalidateLeafLookupSentence", 1)[0]
        for body in (private_publisher, committed_cut):
            self.assertIn(
                "InterlockedCompareExchange(&g_leaf_private_traversal_writer, 1, 0)",
                body,
            )
            self.assertIn(
                "InterlockedExchange(&g_leaf_private_traversal_writer, 0)", body
            )

        invalidate = adapter.split("void InvalidateLeafLookupSentence", 1)[
            1
        ].split("void ConsumeLeafLookupSelectedText", 1)[0]
        committed_cut_index = invalidate.index(
            "CutLeafPrivateTraversalCommittedSequence()"
        )
        self.assertLess(
            committed_cut_index,
            invalidate.index("memset(g_leaf_active_line"),
        )
        self.assertLess(committed_cut_index, invalidate.index("if (advance_epoch)"))

    def test_registry_exposes_module_notification_seam(self) -> None:
        source = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )
        for engine_id in (
            "xaudio2_directsound",
            "siglus",
            "unity_il2cpp",
            "kirikiri_z",
            "renpy_ffmpeg",
        ):
            self.assertIn(f'return "{engine_id}";', source)
        self.assertIn("DispatchNewModules();", source)
        self.assertIn("onModuleLoaded(entry.szModule);", source)

    def test_lookup_admission_converges_on_a_settled_module_table(self) -> None:
        """收敛闸必须是「模块表稳定了」，不能是「扫过一次」。

        `modules_seeded_` 在注入完成的第 1 拍就成立，而 KiriKiri / Ren'Py / Unity
        的 probe 全是迟到信号（KiriKiri 要等第一句有声台词把 wuvorbis.dll 拉进来）。
        拿它当收敛闸 = 对着唯一已发布查词的引擎自信地说「本引擎没做查词」。
        """
        source = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )
        publish = self._member_body(source, "void PublishLookupAdmissionSummary()")
        # 先剥注释：下面那条 assertNotIn 查的是标识符，而这段代码的解释性注释里
        # 就写着 modules_seeded_ —— 不剥的话守卫恒红（本仓「顺序守卫必剥注释」）。
        publish_code = self._strip_comments(publish)
        self.assertIn("module_settle_.settled(", publish_code)
        self.assertNotIn("modules_seeded_", publish_code)

        dispatch = self._member_body(source, "void DispatchNewModules()")
        dispatch_code = self._strip_comments(dispatch)
        self.assertIn("module_settle_.OnScanCompleted(", dispatch_code)
        # 快照失败的早返回必须排在 OnScanCompleted 之前：那是「没观测到」，不是
        # 「观测到没变」，混同会让连续失败的进程假装自己稳定了。
        self.assertLess(
            dispatch_code.index("if (snapshot == INVALID_HANDLE_VALUE) return;"),
            dispatch_code.index("module_settle_.OnScanCompleted("),
        )

    def test_engine_unsupported_carries_the_host_executable_digest(self) -> None:
        """判成「不支持或未识别」时必须附上 exe 摘要，否则那句承诺是空的。

        这一档的定义就是**没有任何 adapter 认领**，各家私有摘要缓冲（Leaf/Siglus）
        在那一刻全部够不着——所以只能读共享槽。少了这一步，用户报上来的只有
        「用不了」，我们这边一点可查的东西都没有。
        """
        source = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )
        publish = self._strip_comments(
            self._member_body(source, "void PublishLookupAdmissionSummary()")
        )
        gate = publish.index("kLookupAdmissionEngineUnsupported")
        # 摘要必须写在收敛那一支里面，而不是函数别处顺手填一下。
        self.assertIn("HostExecutableSha256Hex()", publish[gate:])

        # 共享槽必须真有人填：Leaf 的 profile 解析对任何 x86 游戏都会跑到，是这个槽
        # 在「谁都没认领」场合仍然满着的唯一来源。它要是改回只写自己的私有缓冲，
        # 上面那句就恒发空串——而空串是合法值，测不出来。
        leaf = (
            ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc"
        ).read_text(encoding="utf-8")
        self.assertIn("PublishHostExecutableSha256(", self._strip_comments(leaf))

    def test_leaf_admission_does_not_claim_identity_rejected(self) -> None:
        """Leaf 报不出 IdentityRejected —— 它的 probe() 本身就是 hash 门。

        registry 只对 `probe()` 成立的 adapter 问话，而 Leaf 的
        `probe() == IsLeafAquaplusProfileMatched()`：身份不符时它根本不会被问到，
        写在那里的分支永远走不到，却会让人以为「白2 换个发行版会显示身份被拒」。
        真实去向是「没人认领 → 模块表稳定后收敛成 EngineUnsupported」。
        对照 Siglus：probe() 是 IsSiglusEngine()，与 hash 门是两回事，它那条是活的。
        """
        leaf = (
            ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc"
        ).read_text(encoding="utf-8")
        admission = self._strip_comments(
            self._member_body(
                leaf,
                "fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override",
            )
        )
        self.assertNotIn("kLookupAdmissionIdentityRejected", admission)

        siglus = (
            ROOT / "hook" / "adapters" / "siglus_lookup.inc"
        ).read_text(encoding="utf-8")
        siglus_admission = self._strip_comments(
            self._member_body(
                siglus,
                "fushi_voice_hook::LookupAdmissionReport SiglusLookupAdmission()",
            )
        )
        self.assertIn("kLookupAdmissionIdentityRejected", siglus_admission)

    def test_sgre_admission_reports_identity_rejected_with_digest(self) -> None:
        """SGRE 与 Leaf 相反：IdentityRejected 是活路径，且必须带 exe 摘要。

        Leaf 的 `probe()` 就是它的 hash 门，身份不符时 registry 根本不问它，
        所以那条分支写了也走不到（见上一条）。SGRE 改成家族探测之后
        （`MatchesSgreFamily`：exe 旁边有没有 voice_body.bin），精确 hash 只用来
        挑量好的锚点——「是这个游戏、但这个 build 的查词锚点连签名扫描都没解出来」
        因此成了可达且**终局**的状态：传感器永远装不上。

        协议规定这一档「lookup_executable_sha256 必须已填」，所以摘要格式化也一并钉住：
        报成 IdentityAccepted 会让用户一直等一个不会到来的门，摘要留空则让他连版本
        都报不出来。
        """
        adapter = (
            ROOT / "hook" / "adapters" / "sgre_adapter.inc"
        ).read_text(encoding="utf-8")
        admission = self._strip_comments(
            self._member_body(
                adapter,
                "fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override",
            )
        )
        self.assertIn("kLookupAdmissionIdentityRejected", admission)
        self.assertIn("FormatSha256Hex", admission)
        self.assertIn("g_sgre_executable_sha256", admission)
        # 终局判据必须是「锚点已解析且传感器锚点没解出来」，不能退化成
        # 「传感器还没装上」——后者在 install() 之前恒真，会把等门期误报成拒绝。
        self.assertIn("g_sgre_anchors_resolved", admission)
        self.assertIn("lookup_sensor_available()", admission)

    def test_unity_text_adapter_supports_legacy_ui_text(self) -> None:
        source = (
            ROOT / "hook" / "adapters" / "unity_adapter.inc"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'class_from_name(image, "UnityEngine.UI", "Text")', source
        )
        self.assertIn(
            'FindIl2CppMethod(ui_text_class, "set_text", text_params, 1)',
            source,
        )
        self.assertIn("Detour_UnityUiTextSetText", source)
        self.assertIn('L"UnityEngine.UI.Text.set_text"', source)
        self.assertIn(
            "tmp_text_ready || ui_text_ready || text_mesh_ready ||",
            source,
        )
        self.assertLess(
            source.index("const bool text_hooks_ready"),
            source.index("bool any = audio_ready"),
        )
        for diagnostic in (
            "kDiagUnityTextScanReady",
            "kDiagUnityUiTextClassFound",
            "kDiagUnityUiTextMethodFound",
            "kDiagUnityUiTextHookReady",
            "kDiagUnityTextMeshClassFound",
            "kDiagUnityTextMeshMethodFound",
            "kDiagUnityTextMeshHookReady",
        ):
            self.assertIn(diagnostic, source)
        self.assertIn(
            'class_from_name(image, "UnityEngine", "TextMesh")', source
        )
        self.assertIn('L"UnityEngine.TextMesh.set_text(glyphs)"', source)
        self.assertIn("void FlushUnityTextMeshLine()", source)
        self.assertIn("UsesSasasaLegacyTextMeshTerminator", source)
        self.assertIn("g_unity_text_mesh_reassembler.ShouldTerminate(c, true)", source)
        # v13: text capture is no longer gated on the selected thread. Each
        # component writes its own lane, so a chatty one cannot squeeze the
        # others out; dropping a non-selected component's line here would mean
        # the user can never recover it after switching components.
        self.assertNotIn("IsExactTextThreadSelected", source)
        self.assertIn("kNativeThreadPreviewStart", source)
        # The selected thread is still read for preview-slot recycling: the
        # selected component must never be the one evicted from the preview
        # table.
        self.assertIn("candidate->thread_id == selected", source)
        text_mesh = source.split("void RecordUnityTextMesh", 1)[1]
        text_mesh = text_mesh.split("void RecordUnityVoiceResourceEvent", 1)[0]
        self.assertNotIn("GetTickCount64", text_mesh)
        self.assertNotIn("c == L'\\r'", text_mesh)
        self.assertNotIn("c == L'\\n'", text_mesh)
        self.assertIn('"Unity TextMesh line"', source)
        dll = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        shutdown = dll.split(
            "// 收尾在工作线程里做（不在 loader lock 中）", 1
        )[1]
        self.assertLess(
            shutdown.index("FlushUnityTextMeshLine();"),
            shutdown.index("g_capture_enabled = false;"),
        )

    def test_unity_resource_observation_is_not_gated_by_pcm_helpers(self) -> None:
        source = (
            ROOT / "hook" / "adapters" / "unity_adapter.inc"
        ).read_text(encoding="utf-8")
        capture = source.split("void CaptureUnityAudioClip", 1)[1]
        capture = capture.split("void ProcessUnityAudioEvent", 1)[0]
        self.assertIn("EnqueueUnityAudioClip(source, clip);", capture)
        self.assertNotIn("RecordUnityVoiceResourceEvent", capture)
        self.assertNotIn("g_il2cpp_runtime_invoke", capture)
        process = source.split("void ProcessUnityAudioEvent", 1)[1]
        process = process.split("void ProcessPendingUnityAudioEvents()", 1)[0]
        self.assertLess(
            process.index("RecordUnityVoiceResourceEvent(event.clip, event.timestamp_ms);"),
            process.index("const bool pcm_helpers_ready"),
        )
        registry = (
            ROOT / "hook" / "adapter_registry.inc"
        ).read_text(encoding="utf-8")
        self.assertIn("unity_.ProcessPendingEvents();", registry)
        install = source.split("bool TryHookUnityIl2CppAudio()", 1)[1]
        # 守的是「先解析 resource 方法（get_clip），再解析 PCM 方法（GetData）」这个顺序，
        # 不是解析用的辅助函数叫什么名字。锚点只取 (类, "方法名", 参数个数) 这段实参：
        # 解析器曾从 class_get_method 换成 FindIl2CppMethodByParamCount，顺序不变量原封
        # 不动，守卫却因为把旧辅助函数名写死进字面量而红了，且红在与本不变量无关的地方。
        self.assertLess(
            install.index('(source_class, "get_clip", 0)'),
            install.index('(clip_class, "GetData", 2)'),
        )
        self.assertLess(
            install.index("pcm_helpers_ready ="),
            install.index("kDiagUnityIl2CppHooksReady"),
        )
        self.assertLess(
            install.index("kDiagUnityHooksDeferredUntilWindow"),
            install.index('GetProcAddress(game, "il2cpp_domain_get")'),
        )
        self.assertLess(
            install.index("kDiagUnityHooksDeferredUntilWindow"),
            install.index("kDiagUnityIl2CppHooksReady"),
        )
        self.assertLess(
            install.index("kDiagUnityHooksDeferredUntilWindow"),
            install.index("bool tmp_text_ready"),
        )
        self.assertIn("HasCurrentProcessTopLevelWindow()", source)
        for diagnostic in (
            "kDiagUnityAudioClassFound",
            "kDiagUnityAudioResourceMethodsFound",
            "kDiagUnityAudioPcmMethodsFound",
            "kDiagUnityAudioPlaybackMethodFound",
            "kDiagUnityAudioPlaybackHookReady",
            "kDiagUnityHooksDeferredUntilWindow",
        ):
            self.assertIn(diagnostic, source)

    def test_unity_extracted_wav_is_committed_to_the_primary_audio_ring(self) -> None:
        injector = (ROOT / "injector" / "injector_main.cpp").read_text(
            encoding="utf-8"
        )
        parser = injector.split("bool ReadUnityWavePcm", 1)[1]
        parser = parser.split("uint64_t UnityClipSourceId", 1)[0]
        self.assertIn('memcmp(riff, "RIFF", 4)', parser)
        self.assertIn('memcmp(riff + 8, "WAVE", 4)', parser)
        self.assertIn("(std::min)(data_size, max_bytes)", parser)
        self.assertIn("retained -= retained % result->block_align", parser)
        commit = injector.split("bool CommitUnityWavePcm", 1)[1]
        commit = commit.split("bool ExtractUnityVoice", 1)[0]
        self.assertIn("InterlockedExchangeAdd64", commit)
        self.assertIn("header->total_written", commit)
        self.assertIn("header->clip_write_count", commit)
        self.assertIn("header->clip_region_offset", commit)
        self.assertIn("clip->timestamp_ms = event.timestamp_ms", commit)
        self.assertIn("clip->seq = index + 1", commit)
        self.assertLess(
            commit.index("MemoryBarrier();"),
            commit.index("clip->seq = index + 1"),
        )
        extraction = injector.split("bool ExtractUnityVoice", 1)[1]
        extraction = extraction.split("void ProcessUnityVoiceEvents", 1)[0]
        self.assertIn(
            "extracted && CommitUnityWavePcm(header, event, output)",
            extraction,
        )

    def test_generated_adapters_have_compile_and_lifecycle_registration_seams(self) -> None:
        main = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        registry = (ROOT / "hook" / "adapter_registry.inc").read_text(encoding="utf-8")
        self.assertIn('#include "generated/profile_includes.inc"', main)
        self.assertIn('#include "generated/adapter_includes.inc"', main)
        for name in ("startup", "module", "shutdown", "fields"):
            path = ROOT / "hook" / "generated" / f"adapter_{name}.inc"
            self.assertTrue(path.is_file())
            self.assertIn(f'#include "generated/adapter_{name}.inc"', registry)

    def test_renpy_decode_callback_only_queues_bounded_copies(self) -> None:
        source = (ROOT / "hook" / "adapters" / "renpy_adapter.inc").read_text(
            encoding="utf-8"
        )
        callback = source.split("int __cdecl Detour_avcodec_decode_audio4", 1)[1]
        callback = callback.split("// -- detour: avformat_close_input", 1)[0]
        self.assertIn("EnqueueRenpyFrame(avctx, frame);", callback)
        for forbidden in (
            "EnterCriticalSection",
            "CreateFile",
            "WriteFile",
            "malloc",
            "Sleep",
            "WaitForSingleObject",
        ):
            self.assertNotIn(forbidden, callback)
        enqueue = source.split("void EnqueueRenpyFrame", 1)[1]
        enqueue = enqueue.split("void ProcessRenpyPcmEvent", 1)[0]
        self.assertIn("TryEnterCriticalSection", enqueue)
        self.assertIn("InterlockedCompareExchange", enqueue)
        self.assertIn("memcpy", enqueue)
        self.assertIn("kRenpyPcmEventBytes", enqueue)

    def test_renpy_runtime_is_versioned_and_follows_game_children(self) -> None:
        adapter = (ROOT / "hook" / "adapters" / "renpy_adapter.inc").read_text(
            encoding="utf-8"
        )
        registry = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )
        injector = (ROOT / "injector" / "injector_main.cpp").read_text(
            encoding="utf-8"
        )
        self.assertIn("ParseFfmpegModuleName", registry)
        self.assertNotIn('GetModuleHandleW(L"avformat-54.dll")', adapter)
        self.assertIn("g_renpy_avformat_major == 54", adapter)
        self.assertIn("LooksLikeRenpyRuntime", injector)
        self.assertIn("WaitForGameChildProcess", injector)
        self.assertIn('a == L"--follow-child-processes"', injector)

    def test_reallive_shared_ovk_path_does_not_claim_engine_identity(self) -> None:
        adapter = (ROOT / "hook" / "adapters" / "reallive_adapter.inc").read_text(
            encoding="utf-8"
        )
        siglus = (ROOT / "hook" / "adapters" / "siglus_adapter.inc").read_text(
            encoding="utf-8"
        )
        self.assertIn("MatchesRealliveProfile", adapter)
        self.assertNotIn("VisualArtsOvkObserved", adapter)
        install = siglus.split("bool TryHookSiglusOvk()", 1)[1]
        self.assertNotIn("kDiagVisualArtsOvkHooksReady", install)
        remember = siglus.split("void RememberSiglusOvk", 1)[1]
        remember = remember.split("void ForgetSiglusOvk", 1)[0]
        self.assertIn("kDiagVisualArtsOvkHooksReady", remember)

    def test_qlie_float_callback_is_bounded_and_does_not_copy_pack_streams(
        self,
    ) -> None:
        qlie = (ROOT / "hook" / "adapters" / "qlie_adapter.inc").read_text(
            encoding="utf-8"
        )
        kirikiri = (
            ROOT / "hook" / "adapters" / "kirikiri_adapter.inc"
        ).read_text(encoding="utf-8")
        callback = kirikiri.split(
            "long __cdecl Detour_wu_ov_read_float", 1
        )[1]
        callback = callback.split("// -- detour: wu_ov_clear", 1)[0]
        self.assertIn("thread_local int16_t converted", callback)
        self.assertIn("first_frame < returned_frames", callback)
        self.assertIn("first_frame += frame_count", callback)
        self.assertIn("RingAppendVoice", callback)
        self.assertIn("RecordVoiceClipFmt", callback)
        for forbidden in (
            "CreateFile",
            "ReadFile",
            "WriteFile",
            "malloc",
            "Sleep",
            "WaitForSingleObject",
        ):
            self.assertNotIn(forbidden, callback)
        datasource_dump = kirikiri.split(
            "void DumpVorbisDatasourceGuarded", 1
        )[1]
        datasource_dump = datasource_dump.split(
            "int __cdecl Detour_wu_ov_open_callbacks", 1
        )[0]
        self.assertIn("g_qlie_profile_active", datasource_dump)
        self.assertIn("MatchesQlieProfile", qlie)
        self.assertIn('return "qlie_filepack";', qlie)

    def test_steam_games_launch_through_client_before_exact_path_injection(
        self,
    ) -> None:
        injector = (ROOT / "injector" / "injector_main.cpp").read_text(
            encoding="utf-8"
        )
        run_launch = injector.split("int RunLaunch(", 1)[1]
        run_launch = run_launch.split("}  // namespace", 1)[0]
        self.assertIn("RunSteamLaunch(exe, steam_app_id", run_launch)
        self.assertLess(
            run_launch.index("RunSteamLaunch(exe, steam_app_id"),
            run_launch.index("CreateProcessW("),
        )
        self.assertIn("const HINSTANCE launched = ShellExecuteW(", injector)
        self.assertIn("nullptr, L\"open\", uri.c_str()", injector)
        self.assertIn("WaitForSteamGameProcess", injector)
        self.assertIn(
            "_wcsicmp(image.c_str(), expected_exe.c_str()) == 0", injector
        )
        before_explicit_direct_launch = run_launch.split(
            "if (force_direct_launch && !steam_app_id.empty())", 1
        )[0]
        self.assertNotIn(
            'SetEnvironmentVariableW(L"SteamAppId"',
            before_explicit_direct_launch,
        )
        self.assertEqual(
            1,
            run_launch.count('SetEnvironmentVariableW(L"SteamAppId"'),
            "Only the explicit force-direct launch may set SteamAppId.",
        )

    def test_sgre_resource_logic_is_profile_scoped(self) -> None:
        shared_paths = (
            ROOT / "hook" / "dll_main.cpp",
            ROOT / "hook" / "adapters" / "windows_audio_adapter.inc",
            ROOT / "hook" / "xwma_resource.h",
        )
        for path in shared_paths:
            source = path.read_text(encoding="utf-8").lower()
            self.assertNotIn("sgre", source, path.name)
            self.assertNotIn("voice_body.bin", source, path.name)

        adapter = (
            ROOT / "hook" / "adapters" / "sgre_adapter.inc"
        ).read_text(encoding="utf-8")
        profile = (
            ROOT / "hook" / "adapters" / "sgre_profile.h"
        ).read_text(encoding="utf-8")
        generic = (
            ROOT / "hook" / "adapters" / "windows_audio_adapter.inc"
        ).read_text(encoding="utf-8")
        # Family membership (voice_body.bin next to the executable) is the
        # probe; the executable hash only selects measured anchors.
        self.assertIn("MatchesSgreFamily", adapter)
        self.assertNotIn("MatchesSgreProfile", adapter)
        self.assertIn("RegisterXAudioCompressedResourceHandler", adapter)
        self.assertIn("FindSgreVoiceArchiveResourceParts", adapter)
        self.assertIn("FindSgreKnownBuild", profile)
        self.assertIn("ResolveSgreRuntimeAnchors", profile)
        anchors = (ROOT / "hook" / "adapters" / "sgre_anchors.h").read_text(
            encoding="utf-8"
        )
        self.assertIn("kSgreExecutableSha256", anchors)
        self.assertIn("HasXAudioCompressedResourceHandler", generic)
        self.assertFalse((ROOT / "hook" / "xaudio_pcm_capture_xapo.h").exists())
        self.assertNotIn("700", generic)

    def test_hook_worker_rejects_unknown_ipc_before_adapter_poll(self) -> None:
        source = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        rejection = source.index(
            "g_header == nullptr || g_header->magic != kSharedMagic"
        )
        polling = source.index("while (!g_stop)")
        self.assertLess(rejection, polling)
        self.assertIn("return 1;", source[rejection:polling])


    def test_sgre_archive_stays_out_of_shared_middleware(self) -> None:
        adapter = (
            ROOT / "hook" / "adapters" / "windows_audio_adapter.inc"
        ).read_text(encoding="utf-8")
        profile = (ROOT / "hook" / "adapters" / "sgre_profile.h").read_text(
            encoding="utf-8"
        )
        sgre = (ROOT / "hook" / "adapters" / "sgre_adapter.inc").read_text(
            encoding="utf-8"
        )
        # The generic XAudio middleware must hold no engine-specific knowledge:
        # it only offers submissions through the registration seam.
        for forbidden in ("Sgre", "sgre", "voice_body"):
            self.assertNotIn(forbidden, adapter, forbidden)
        self.assertIn("RegisterXAudioCompressedResourceHandler", sgre)
        # Family identity is the wind3d11 voice archive next to the executable
        # -- the very data contract the audio proof checks membership against.
        # Build-specific addresses come from the measured hash table or a
        # unique signature hit, never from an executable *file name*: that is
        # a distribution property, not an engine identity, and CLAUDE.md
        # forbids enabling shared middleware on that kind of match.
        self.assertIn("voice_body.bin", profile)
        self.assertNotIn("sgre_steam.exe", profile)
        self.assertNotIn("sgre_steam.exe", adapter)
        anchors = (ROOT / "hook" / "adapters" / "sgre_anchors.h").read_text(
            encoding="utf-8"
        )
        self.assertIn("kSgreExecutableSha256", anchors)
        self.assertIn("kSgreKnownBuilds", anchors)
        self.assertNotIn("sgre_steam.exe", anchors)
        self.assertNotIn("executable_names", anchors)

    def test_unclaimed_xwma_submissions_are_published_not_dropped(self) -> None:
        adapter = (
            ROOT / "hook" / "adapters" / "windows_audio_adapter.inc"
        ).read_text(encoding="utf-8")
        branch = adapter.split("XAudioSourceEncoding::kWmaudio2) {", 1)[1]
        branch = branch.split("const bool is_adpcm", 1)[0]
        # xWMA is the only voice outlet for these engines and this process has
        # no WMA decoder, so a submission no engine profile claims must still
        # be published as a compressed resource rebuilt from its own runtime
        # fmt + dpds. Dropping it removes that engine's voice from the card
        # pipeline entirely.
        # An engine profile that claims the seam owns the verdict entirely;
        # the generic rebuild only applies when nothing claims it, so an
        # archive miss still means "not voice" for that engine.
        self.assertIn("if (g_xaudio_compressed_resource_dispatch.available())",
                      branch)
        self.assertIn("BuildXwmaResource(", branch)
        self.assertIn("kXAudioDiagRuntimeXwmaPublished", branch)
        # Without an archive to compare against, the duration prefilter is the
        # only thing separating a whole line from a chunk of streaming BGM.
        self.assertIn("IsLikelyVoiceWmaSubmission", branch)
        # Byte-exact and runtime-rebuilt resources must not share one
        # diagnostic bit: only the archive path may claim payload hash
        # identity with a source entry.
        self.assertNotIn("kXAudioDiagGameResourcePublished", branch)

    def test_hook_worker_contract_gate_covers_the_poll_pump(self) -> None:
        main = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        worker = main.split("DWORD WINAPI HookWorker", 1)[1]
        # Whitespace-normalised so the assertion pins the control flow, not the
        # formatter. A bare "there is a return somewhere between gate and pump"
        # check is vacuous: SignalReady's own early return already satisfies it.
        compact = " ".join(worker.split())
        gate = compact.index("g_header->version != kSharedVersion")
        self.assertLess(gate, compact.index("registry.Poll();"))
        # Take the gate's own block by brace matching. A bare "there is a
        # return somewhere between gate and pump" check is vacuous: SignalReady's
        # own early return already satisfies it. What must hold is that the
        # mismatch branch itself cannot fall through to the pump.
        open_at = compact.index("{", gate)
        depth = 0
        close_at = -1
        for i in range(open_at, len(compact)):
            if compact[i] == "{":
                depth += 1
            elif compact[i] == "}":
                depth -= 1
                if depth == 0:
                    close_at = i
                    break
        self.assertGreater(close_at, open_at, "contract gate has no block")
        self.assertIn("return 1;", compact[open_at:close_at])
        registry = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )
        poll = registry.split("void Poll() {", 1)[1]
        self.assertIn("loopback_.PollPolicy();", poll)

    @staticmethod
    def _function_body(source: str, signature: str) -> str:
        """取 C++ 自由函数体（从签名后的第一个 `{` 起做大括号配对）。"""
        at = source.index(signature)
        open_at = source.index("{", at)
        depth = 0
        for i in range(open_at, len(source)):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    return source[open_at : i + 1]
        raise AssertionError(f"unbalanced braces after {signature}")

    @staticmethod
    def _call_arguments(source: str, callee: str) -> list[str]:
        """取 `callee(` 每个调用点的实参表，空白已归一。

        逐字面量锚点（`assertNotIn("Foo(module,")`）对 clang-format 敏感：把实参折成
        两行，守卫就完全看不见回改。这里按括号配对取整个实参表再压空白，换行/缩进
        怎么变都命中同一串。
        """
        out: list[str] = []
        at = 0
        while True:
            at = source.find(callee + "(", at)
            if at < 0:
                return out
            open_at = at + len(callee)
            depth = 0
            for i in range(open_at, len(source)):
                if source[i] == "(":
                    depth += 1
                elif source[i] == ")":
                    depth -= 1
                    if depth == 0:
                        out.append(" ".join(source[open_at + 1 : i].split()))
                        at = i + 1
                        break
            else:
                raise AssertionError(f"unbalanced parens after {callee}")

    def test_hunex_hfa_reuses_shared_file_broker_and_parses_only_on_worker(
        self,
    ) -> None:
        broker = (
            ROOT / "hook" / "adapters" / "siglus_adapter.inc"
        ).read_text(encoding="utf-8")
        adapter = (
            ROOT / "hook" / "adapters" / "hunex_gge_adapter.inc"
        ).read_text(encoding="utf-8")
        # The x64 exact-layout/input trace above the resource section is an
        # observation-only renderer probe and legitimately owns its own exact
        # hooks.  This guard is about the HFA file broker: that lower section
        # must continue reusing Siglus' CreateFile/ReadFile detours.
        resource_adapter = adapter[adapter.index("struct HunexVoiceFileIdentity") :]
        registry = (ROOT / "hook" / "adapter_registry.inc").read_text(
            encoding="utf-8"
        )

        for callback in (
            "RememberHunexVoiceHfa(result, file_name)",
            "RememberHunexVoiceHfa(result, wide)",
            "ObserveHunexVoiceHfaRead(file, buffer, done, overlapped)",
            "ForgetHunexVoiceHfa(handle)",
        ):
            self.assertIn(callback, broker)
        close = self._function_body(broker, "BOOL WINAPI Detour_CloseHandle(")
        self.assertLess(
            close.index("ForgetHunexVoiceHfa(handle)"),
            close.index("g_orig_CloseHandle(handle)"),
        )
        for engine_detail in ("HUNEXGGEFA10", '"hw  "', "ParseHunex", "data04000"):
            self.assertNotIn(engine_detail, broker)
        for forbidden in (
            "Detour_CreateFileW",
            "Detour_CreateFileA",
            "Detour_ReadFile",
            "Detour_CloseHandle",
            "HookFn(",
        ):
            self.assertNotIn(forbidden, resource_adapter)

        observer = self._function_body(
            adapter, "void ObserveHunexVoiceHfaRead("
        )
        self.assertIn("QueueHunexVoice(archive_index, start, done, prefix,", observer)
        for forbidden in (
            "ParseHunexHfaIndex",
            "ParseHunexHwOgg",
            "g_hunex_voice_archive.ranges",
            "malloc",
            "WriteVoiceOggAt",
            "CreateFile",
            "ReadFile",
            "WaitForSingleObject",
            "Sleep(",
        ):
            self.assertNotIn(forbidden, observer)

        loader = self._function_body(adapter, "bool LoadHunexVoiceArchive(")
        worker = self._function_body(adapter, "void ProcessHunexVoiceTask(")
        self.assertIn("ParseHunexHfaIndex", loader)
        self.assertIn("ParseHunexHwOgg", worker)
        self.assertIn("WriteVoiceOggAt", worker)
        self.assertLess(
            worker.index("WriteVoiceOggAt"),
            worker.index("kXAudioDiagGameResourcePublished"),
        )
        self.assertIn("g_orig_CreateFileW", loader)
        self.assertIn("g_orig_ReadFile", adapter)
        self.assertIn("g_orig_CloseHandle", loader)

        stop = self._function_body(adapter, "void StopHunexGgeResourceAudio(")
        self.assertLess(
            stop.index("InterlockedExchange(&g_hunex_voice_archive_count, 0)"),
            stop.index("free(ranges)"),
        )
        self.assertLess(
            registry.index("hunex_gge_.install();"),
            registry.index(
                "g_header->hook_diagnostics |= kDiagStartupAudioHooksReady"
            ),
        )
        self.assertIn("hunex_gge_.ProcessPendingEvents();", registry)
        for seam in ("includes", "startup", "module", "shutdown", "fields"):
            generated = (
                ROOT / "hook" / "generated" / f"adapter_{seam}.inc"
            ).read_text(encoding="utf-8")
            self.assertIn("hunex_gge", generated)

    def test_leaf_voice_archive_ranges_are_owned_by_the_worker(self) -> None:
        """游戏线程绝不解引用 ranges，Stop 必须先撤发布再释放。

        ranges 是 HookWorker 上 malloc / free 的堆表，而
        ObserveLeafAquaplusVoicePakRead 跑在游戏线程的 ReadFile detour 里，且
        MH_DisableHook(MH_ALL_HOOKS) 排在 registry.Shutdown() 之后——shutdown 期间
        detour 仍然活着。只要游戏线程还在 ranges 上做二分，命中已归还的页就是玩家的
        游戏进程当场崩溃。修法不是加判空（那只收窄窗口），而是把索引解析整段推给
        worker，让所有权和访问落在同一条线程上。
        """
        source = (
            ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc"
        ).read_text(encoding="utf-8")

        observer = self._function_body(
            source, "void ObserveLeafAquaplusVoicePakRead("
        )
        self.assertNotIn(
            "g_leaf_voice_archives",
            observer,
            "游戏线程的 VOICE.PAK 观察者不得触碰 worker 拥有的档案表",
        )
        self.assertNotIn(
            ".ranges",
            observer,
            "游戏线程的 VOICE.PAK 观察者不得解引用 ranges",
        )
        self.assertIn(
            "QueueLeafVoice(archive_index, start, done,",
            observer,
            "观察者只能把 (槽位, 文件内偏移, 读长度) 这些定值抄进任务",
        )

        resolver = self._function_body(source, "bool FindLeafVoiceRangeIndex(")
        self.assertIn("archive.ranges == nullptr", resolver)

        worker = self._function_body(source, "void ProcessLeafVoiceTask(")
        self.assertIn("FindLeafVoiceRangeIndex(archive, task->offset,", worker)
        self.assertIn("task->read_bytes > range.size", worker)

        stop = self._function_body(source, "void StopLeafAquaplusResourceAudio(")
        unpublish = stop.index("InterlockedExchange(&g_leaf_voice_archive_count, 0)")
        self.assertIn("free(ranges);", stop)
        self.assertLess(
            unpublish,
            stop.index("free("),
            "必须先把 archive_count 撤成 0 再 free，顺序颠倒等于 free 一张仍在发布的表",
        )
        self.assertLess(
            stop.index("g_leaf_voice_archives[index] = {};"),
            stop.index("free(ranges);"),
            "必须先摘掉指针再 free",
        )

    def test_leaf_identity_does_not_latch_an_unmeasured_executable(self) -> None:
        """身份缓存只能记录**测量成功**的结论。

        `g_leaf_aquaplus_profile_state` 是永久缓存（0/±1，命中即直接返回）。若把
        「读不到 exe / 算不出摘要」也写成 -1，一次瞬时失败就让本会话的 Leaf adapter
        永久出局：没有 adapter 认领 → 准入收敛成 EngineUnsupported、LAC 原声 hook
        一次都不装，用户看到整场音频降级到系统 Loopback。首次 probe 可能落在注入
        窗口内（摘要走 BCrypt + 文件映射），所以这是个真实会命中的时序。
        """
        source = self._strip_comments(
            (ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc").read_text(
                encoding="utf-8"
            )
        )
        body = self._function_body(source, "bool IsLeafAquaplusProfileMatched(")

        guard = body.index("if (!executable_read)")
        latch = body.rindex("InterlockedExchange(&g_leaf_aquaplus_profile_state")
        self.assertLess(
            guard,
            latch,
            "测量失败必须在写入永久缓存之前就返回，否则一次瞬时失败被钉成永久拒绝",
        )
        self.assertLess(
            guard,
            body.index("MatchesLeafAquaplusProfile("),
            "测量失败必须早于 profile 选择返回",
        )

        # 重试有界，且**量纲是时间不是调用次数**：本函数每轮 Poll 被打 5~7 次
        # （PollDelayMs 自己也调 leaf_aquaplus_.probe()），DispatchNewModules 每拍
        # 还对每个新模块再打 3 次；按 32 次调用限界只有 0.2~1.2 秒，启动期模块风暴下
        # 单个 200ms 拍就能烧光，而要覆盖的注入窗口以秒计。
        self.assertIn("LeafIdentityRetryWindowExhausted()", body)
        self.assertIn("kXAudioDiag2LeafExecutableUnmeasurable", body)
        whole = (ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc").read_text(
            encoding="utf-8"
        )
        gate = self._strip_comments(whole)
        self.assertIn("kLeafIdentityRetryWindowMs", gate)
        self.assertIn("kLeafIdentityRetryIntervalMs", gate)
        self.assertNotIn(
            "g_leaf_identity_measure_attempts",
            gate,
            "调用次数预算量的是「被问了多少次」，要限的是「等了多久」——不得回退",
        )
        # 计次仍要挡 CPU：高频 Poll 不能把 SHA-256 + 映像展开摊进每一次调用。
        self.assertIn("LeafIdentityMeasurementThrottled()", body)

    def test_leaf_structure_gate_retries_a_transient_pristine_image_failure(
        self,
    ) -> None:
        """原始映像映不上是瞬时条件，不得一次失败就永久钉死身份。

        LoadLeafPristineImage 走 CreateFileW + CreateFileMappingW + VirtualAlloc：
        杀软扫描期占住 exe、共享冲突、32 位地址空间碎片都能让它临时失败。往下走的
        结局是 opened=false → 三组全 false → g_leaf_exact_binary_structure_state 被
        写成 -1 → profile 置空 → g_leaf_aquaplus_profile_state 永久 -1，症状与
        「exe 摘要量不到」完全一样：LAC 原声 hook 一次都不装、整场降级 Loopback。

        结构门在改成读磁盘原始映像之前只读进程内存、没有任何文件 IO——这条失败面是
        那次修法自己引进来的，必须共用同一个有界重试窗口。
        """
        source = self._strip_comments(
            (ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc").read_text(
                encoding="utf-8"
            )
        )
        body = self._function_body(source, "bool IsLeafAquaplusProfileMatched(")

        guard = body.index("if (!pristine_ready)")
        self.assertLess(
            guard,
            body.index("LeafIdentityRetryWindowExhausted()", guard),
            "映像映不上必须走与摘要量不到同一个有界重试窗口",
        )
        self.assertLess(
            guard,
            body.index("InterlockedExchange(&g_leaf_exact_binary_structure_state"),
            "重试窗口未耗尽时必须在写结构门永久缓存之前返回",
        )
        self.assertLess(
            guard,
            body.rindex("InterlockedExchange(&g_leaf_aquaplus_profile_state"),
            "重试窗口未耗尽时也不得写 profile 的永久缓存",
        )

    def test_generic_shield_reservation_is_not_a_one_shot_static(self) -> None:
        """通用护盾对共享 USER32 导出的预留判断不得只求值一次。

        TryInstallGenericKeyAndRawInputShield() 的第一次调用就在 dll_main 里
        MH_Initialize() 成功的那一刻——注入窗口最深处，正是 exact 身份最可能还没量出来
        的时候。判断写成函数内 `static const bool` 就整个进程只求值那一次：那次返回
        false，通用护盾把 GetAsyncKeyState 抢走，之后 exact 侧再来装拿不到 trampoline
        （HookFn 已被占），身份重试成功也救不回来——BUG-2074 场景下「点击穿透」这一半
        根本没修好。

        并且「身份未定」必须按**预留**处置：抢占是不可逆的，不预留最多只是晚一拍装上
        通用护盾（本函数每个 Poll 拍都会重来）。代价不对称时站在可逆的那一边。
        """
        source = self._strip_comments(
            (ROOT / "hook" / "generic_input_shield.inc").read_text(encoding="utf-8")
        )
        body = self._function_body(
            source, "void TryInstallGenericKeyAndRawInputShield("
        )
        for line in body.splitlines():
            stripped = line.strip()
            if "reserve_" in stripped and "=" in stripped:
                self.assertFalse(
                    stripped.startswith("static "),
                    f"预留判断不得是函数内 static（只求值一次）：{stripped!r}",
                )
        self.assertIn("IsLeafAquaplusIdentityUndecided()", body)
        self.assertIn("IsSiglusLookupIdentityUndecided()", body)

        # 三态查询读的必须是身份状态本身，不能是把三态压成 bool 的那个函数。
        for adapter, state in (
            ("leaf_aquaplus_adapter.inc", "g_leaf_aquaplus_profile_state"),
            ("siglus_lookup.inc", "g_siglus_lookup_profile_state"),
        ):
            adapter_source = self._strip_comments(
                (ROOT / "hook" / "adapters" / adapter).read_text(encoding="utf-8")
            )
            name = (
                "bool IsLeafAquaplusIdentityUndecided("
                if "leaf" in adapter
                else "bool IsSiglusLookupIdentityUndecided("
            )
            undecided = self._function_body(adapter_source, name)
            self.assertIn(state, undecided)
            self.assertIn("== 0", undecided)

    def test_leaf_structure_gate_reads_the_pristine_file_not_process_memory(
        self,
    ) -> None:
        """身份的结构校验只能读磁盘上的原始映像。

        这五处掩码模式扫的地址都会被 hook 改写，其中 embed_leaf_hook_rva 正是 profile
        指定给 LunaHook 的 HSX0:0 文本 hook 点：Luna 的 detour 一落下，唯一命中数就变 0,
        结构门判否 → adapter 不认领 → 几何 provider、输入护盾、LAC 原声 hook 全不装,
        表现为「点击穿透到下一句」+「语音整场降级」。text_traversal / raster_draw 更是
        我们自己在 InstallLeafAquaplusD3DTrace 里要 hook 的地址。

        身份是「这个 exe 是不是那份被测量过的构建」——文件的属性，不是当前进程内存的属性。
        """
        source = self._strip_comments(
            (ROOT / "hook" / "adapters" / "leaf_aquaplus_adapter.inc").read_text(
                encoding="utf-8"
            )
        )
        body = self._function_body(source, "bool IsLeafAquaplusProfileMatched(")

        self.assertIn("LoadLeafPristineImage(executable, &pristine)", body)
        self.assertIn("image.absolute_base = preferred_base;", body)
        # 语义锚点：不逐字面量比 "OpenLoadedPeImage(module," ——那对 clang-format
        # 敏感，参数一旦折行守卫就看不见回改（实测能存活变异）。改成取实参表本身。
        calls = self._call_arguments(body, "OpenLoadedPeImage")
        self.assertTrue(calls, "结构校验必须真的打开一份 PE 映像")
        for arguments in calls:
            subject = arguments.split(",")[0]
            self.assertIn(
                "pristine",
                subject,
                "结构校验只能打开 LoadLeafPristineImage 展开的私有副本，"
                f"实参却是 {subject!r}",
            )
            self.assertNotIn(
                "module",
                subject,
                "结构校验不得读进程内已加载的模块："
                "那段内存会被 LunaHook 与我们自己的 hook 改写",
            )
            self.assertNotIn("GetModuleHandle", subject)
        self.assertLess(
            body.index("LoadLeafPristineImage(executable, &pristine)"),
            body.index("FindUniqueAbsolute32PatternInExecutableSections("),
            "原始映像必须在任何模式扫描之前就绪",
        )

        # 加载器认路径：对**本进程自己的主映像**调 LoadLibraryEx(AS_IMAGE_RESOURCE)
        # 会把已加载的那一份别名返回（实测 masked handle == GetModuleHandleW(nullptr)），
        # 于是"原始映像"仍是被改写过的内存。这个坑踩过一次，必须钉住。
        loader = self._function_body(source, "bool LoadLeafPristineImage(")
        self.assertNotIn(
            "LoadLibraryEx",
            loader,
            "不得用加载器取原始映像：自身主映像会被别名回已加载的那一份",
        )
        self.assertNotIn("SEC_IMAGE", loader, "SEC_IMAGE 映射到非首选基址会施加重定位")
        self.assertIn("PAGE_READONLY", loader)
        self.assertIn("IMAGE_FIRST_SECTION", loader)
        # 私有副本每次 ~1.2MB，且 IsLeafAquaplusProfileMatched 在身份未定期间会被
        # 反复调用。释放必须断言在**析构体**上：整份 1500 行源文件里 VirtualFree
        # 到处都有，删掉析构里那一句仍然全绿（实测存活的变异）。
        destructor = self._function_body(source, "~LeafPristineImage()")
        self.assertIn("VirtualFree", destructor)
        self.assertIn("MEM_RELEASE", destructor)

        # absolute_base 只能作用于绝对操作数解码：rel32/寄存器间接算出的是映射内地址。
        shared = self._strip_comments(
            (ROOT / "hook" / "adapters" / "exact_lookup_signature.h").read_text(
                encoding="utf-8"
            )
        )
        decode = self._function_body(shared, "inline bool DecodeAbsolute32ImageAddress(")
        self.assertIn("image.absolute_base", decode)
        to_rva = self._function_body(shared, "inline bool AddressToRva(")
        self.assertNotIn(
            "absolute_base",
            to_rva,
            "AddressToRva 必须继续用 image.base，否则未重定位映像上 rel32 各路整片假失败",
        )


if __name__ == "__main__":
    unittest.main()

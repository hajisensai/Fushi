#!/usr/bin/env python3
"""Static guard for the P1 adapter boundary."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AdapterStructureTest(unittest.TestCase):
    def test_main_worker_only_uses_registry(self) -> None:
        source = (ROOT / "hook" / "dll_main.cpp").read_text(encoding="utf-8")
        self.assertLess(source.count("\n"), 700)
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


if __name__ == "__main__":
    unittest.main()

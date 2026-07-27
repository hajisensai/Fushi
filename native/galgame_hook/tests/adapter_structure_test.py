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

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
        self.assertLess(
            main.index("originals->Publish(target, trampoline)"),
            main.index("MH_EnableHook(target)"),
        )
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
        self.assertIn("MatchesSgreProfile", adapter)
        self.assertIn("RegisterXAudioCompressedResourceHandler", adapter)
        self.assertIn("FindSgreVoiceArchiveResourceParts", adapter)
        self.assertIn("kSgreExecutableSha256", profile)
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


if __name__ == "__main__":
    unittest.main()

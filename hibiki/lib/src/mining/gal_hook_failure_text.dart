import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

/// 结构化 injector 失败原因 → 用户可执行的处置文案。
///
/// 分层理由：`GalHookInjectorFailure` 是纯模型（不依赖 i18n），会话事件里保留它的
/// 机器可读 `name` 供诊断；UI 只在这里把它翻成人话。旧实现把内部代码
/// （`engine_attach_failed`）直接显示给用户，既看不懂也不知道该做什么。
///
/// 返回 null 表示没有比内部代码更有用的信息可说（[GalHookInjectorFailure.none] /
/// [GalHookInjectorFailure.unknown]）——此时调用方应回退显示原始代码，绝不编造原因。
String? galHookFailureLabel(GalHookInjectorFailure failure) =>
    switch (failure) {
      GalHookInjectorFailure.none => null,
      GalHookInjectorFailure.unknown => null,
      GalHookInjectorFailure.helperMissing => t.game_hook_reason_helper_missing,
      GalHookInjectorFailure.targetMissing => t.game_hook_reason_target_missing,
      GalHookInjectorFailure.spawnFailed => t.game_hook_reason_spawn_failed,
      GalHookInjectorFailure.bitnessMismatch =>
        t.game_hook_reason_bitness_mismatch,
      GalHookInjectorFailure.accessDenied => t.game_hook_reason_access_denied,
      GalHookInjectorFailure.elevationRequired =>
        t.game_hook_reason_elevation_required,
      GalHookInjectorFailure.createProcessFailed =>
        t.game_hook_reason_create_process_failed,
      GalHookInjectorFailure.hookDllMissing =>
        t.game_hook_reason_hook_dll_missing,
      GalHookInjectorFailure.gameExeMissing =>
        t.game_hook_reason_game_exe_missing,
      GalHookInjectorFailure.staleSession => t.game_hook_reason_stale_session,
      GalHookInjectorFailure.readyTimeout => t.game_hook_reason_ready_timeout,
      GalHookInjectorFailure.injectionFailed =>
        t.game_hook_reason_injection_failed,
      GalHookInjectorFailure.guardedHookFailed =>
        t.game_hook_reason_guarded_hook_failed,
      GalHookInjectorFailure.resumeFailed => t.game_hook_reason_resume_failed,
      GalHookInjectorFailure.steamTimeout => t.game_hook_reason_steam_timeout,
      GalHookInjectorFailure.sharedMemoryUnavailable =>
        t.game_hook_reason_shared_memory_unavailable,
      GalHookInjectorFailure.handshakeTimeout =>
        t.game_hook_reason_handshake_timeout,
    };

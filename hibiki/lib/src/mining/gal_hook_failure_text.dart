import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
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

/// 一次「启动游戏」结束后要 toast 给用户的话（BUG-1089）。
///
/// 唯一的启动结果播报口：游戏库页和 texthooker 页都走这里，不再各写一套、也不再出现
/// 「游戏库页一个字都不提示」。四种 [GalHookLaunchOutcome] 都有话说——**成功也说**，
/// 因为「点了按钮什么都没发生」本身就是这个 bug 的用户表征。
///
/// [failure] 非 [GalHookInjectorFailure.none] 时把可执行处置作为后缀带上：知道「窗口
/// 没出现」不够，还得知道是缺组件、要管理员，还是握手超时。
String galHookLaunchOutcomeMessage({
  required GalHookLaunchOutcome outcome,
  required GalHookInjectorFailure failure,
  String? lastError,
}) {
  final String? reason = galHookFailureLabel(failure);
  return switch (outcome) {
    // 彻底失败：处置优先，内部英文消息只作最后兜底，绝不编造原因。
    GalHookLaunchOutcome.failed =>
      reason ?? lastError ?? t.game_capture_launch_failed,
    GalHookLaunchOutcome.windowMissing =>
      _withReason(t.game_capture_window_missing, reason),
    GalHookLaunchOutcome.degradedLoopback =>
      _withReason(t.game_capture_degraded_loopback, reason),
    GalHookLaunchOutcome.running => t.game_capture_running,
  };
}

String _withReason(String message, String? reason) =>
    reason == null ? message : '$message（$reason）';

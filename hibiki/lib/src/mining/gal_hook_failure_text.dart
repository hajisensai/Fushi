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
      GalHookInjectorFailure.protocolMismatch =>
        t.game_hook_reason_protocol_mismatch,
      GalHookInjectorFailure.handshakeTimeout =>
        t.game_hook_reason_handshake_timeout,
    };

/// 一次「启动游戏」结束后要 toast 给用户的话（BUG-1089 / BUG-1142）。
///
/// 唯一的启动结果播报口：游戏库页和 texthooker 页都走这里，不再各写一套、也不再出现
/// 「游戏库页一个字都不提示」。**成功也说**，因为「点了按钮什么都没发生」本身就是
/// BUG-1089 的用户表征。
///
/// 返回 `null` 表示**本次结果不该播报**（[GalHookLaunchOutcome.superseded]）：这次操作
/// 已被更新的操作取代，取代它的那次会播报自己的结果。旧实现让作废的那次也弹一句
/// 「游戏启动或捕获失败」，反而把真实结局盖掉。
///
/// [failure] 非 [GalHookInjectorFailure.none] 时把可执行处置作为后缀带上：知道「窗口
/// 没出现」不够，还得知道是缺组件、要管理员，还是握手超时。
/// [injectorDetail] 是会话状态里留存的读侧一手证据（`GalHookSessionState.injectorDetail`）：
/// 降级路径的 [result] 是「已启动」，诊断不在它身上，只能从状态取。
String? galHookLaunchOutcomeMessage({
  required GalHookLaunchOutcome outcome,
  required GalHookLaunchResult result,
  required GalHookInjectorFailure failure,
  String? lastError,
  String injectorDetail = '',
}) {
  final String? reason = galHookFailureLabel(failure);
  // 本次启动结果自带的诊断优先；没有（降级路径 result 是 launched）才用会话状态里的。
  final String resultDetail = galHookDiagnosticsDetail(result.diagnostics);
  final String detail =
      resultDetail.isNotEmpty ? resultDetail : injectorDetail.trim();
  return switch (outcome) {
    GalHookLaunchOutcome.superseded => null,
    GalHookLaunchOutcome.failed =>
      _failedMessage(result, reason, lastError, detail),
    GalHookLaunchOutcome.windowMissing =>
      _annotate(t.game_capture_window_missing, reason, detail),
    GalHookLaunchOutcome.degradedLoopback =>
      _annotate(t.game_capture_degraded_loopback, reason, detail),
    GalHookLaunchOutcome.running => t.game_capture_running,
  };
}

/// 「启动彻底失败」要说的话（BUG-1142）。
///
/// 结论按三级取，**每一级都来自真实事实，绝不编造**：
/// 1. [GalHookLaunchResult.reason]——它是编译期强制填写的，不会缺；
/// 2. injector 的结构化处置（缺组件 / 要管理员 / 位数不符…）；
/// 3. 都归类不出来时退到 `lastError` / 通用兜底文案。
///
/// native 一手诊断（退出码 + 诊断末行）**无条件**附在结论后面（BUG-1216）：BUG-1142 时
/// 只在第 3 级才附，于是归类越准、用户拿到的事实越少——「捕获通道无法打开」这句话在
/// 「游戏跑在管理员权限下」和「helper 版本不符」两种完全不同的现场长得一模一样。
String _failedMessage(
  GalHookLaunchResult result,
  String? injectorReason,
  String? lastError,
  String detail,
) {
  final String? reasonLabel = switch (result.reason) {
    GalHookLaunchFailureReason.unsupportedPlatform => t.game_launch_unsupported,
    GalHookLaunchFailureReason.helperMissing =>
      t.game_hook_reason_helper_missing,
    // injectionFailed 的可执行处置在 injector 诊断里，由 [injectorReason] 提供。
    GalHookLaunchFailureReason.injectionFailed => injectorReason,
    // superseded 已在 [classifyGalHookLaunchOutcome] 早退，走不到 failed 分级；列出只为穷举。
    GalHookLaunchFailureReason.superseded => null,
    // reason == null 即「启动成功」，同样到不了 failed 分级。真到了也**只**落到下面的
    // 兜底事实（lastError / native 诊断），绝不会因此编造一句原因（BUG-1169）。
    null => null,
  };
  final String base = reasonLabel ?? lastError ?? t.game_capture_launch_failed;
  return _annotate(base, null, detail);
}

/// 给一句结论补上「原因 · 一手证据」的括号后缀。空的部分不占位。
///
/// **有原因时也要给证据**（BUG-1216）：知道「捕获通道打不开」不等于知道是拒绝访问、
/// 版本不符还是映射根本不存在。旧实现只在归类不出来时才附诊断，于是归类得越准、
/// 用户和排障者拿到的事实反而越少——一台跑得通、一台跑不通时完全无从对比。
String _annotate(String base, String? reason, String detail) {
  final List<String> parts = <String>[
    if (reason != null && reason.isNotEmpty) reason,
    if (detail.isNotEmpty) detail,
  ];
  return parts.isEmpty ? base : '$base（${parts.join(' · ')}）';
}

/// 会话降级原因（`GalHookSessionState.fallbackReason` 的内部代码）→ 人话文案。
///
/// BUG-1100：`_activateTextWithLoopback` 这条路径显式把 `injectorFailure` 置成
/// [GalHookInjectorFailure.none]（注入链本来就是通的），于是 [galHookFailureLabel]
/// 返回 null，UI 只能把内部代码 `engine_pcm_unavailable` 原样甩给用户看——用户既看不懂，
/// 也不知道这只是「还没播过语音」的临时状态。降级原因和注入失败原因是**两套**独立的
/// 事实，各自要有自己的翻译表，不能指望前者搭后者的便车。
///
/// 未知代码返回 null（调用方回退显示原始代码，绝不编造原因）。
String? galHookFallbackLabel(String fallbackReason) => switch (fallbackReason) {
      'engine_pcm_unavailable' => t.game_hook_fallback_engine_pcm_unavailable,
      'all_audio_sources_failed' =>
        t.game_hook_fallback_all_audio_sources_failed,
      'window_not_found' => t.game_hook_fallback_window_not_found,
      'engine_attach_failed' => t.game_hook_fallback_engine_attach_failed,
      'launch_injection_failed' => t.game_hook_fallback_launch_injection_failed,
      'helper_missing' => t.game_hook_reason_helper_missing,
      'target_missing' => t.game_hook_reason_target_missing,
      _ => null,
    };

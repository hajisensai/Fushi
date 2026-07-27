import 'package:flutter/foundation.dart';
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
String? galHookLaunchOutcomeMessage({
  required GalHookLaunchOutcome outcome,
  required GalHookLaunchResult result,
  required GalHookInjectorFailure failure,
  String? lastError,
}) {
  final String? reason = galHookFailureLabel(failure);
  return switch (outcome) {
    GalHookLaunchOutcome.superseded => null,
    GalHookLaunchOutcome.failed => _failedMessage(result, reason, lastError),
    GalHookLaunchOutcome.windowMissing =>
      _withReason(t.game_capture_window_missing, reason),
    GalHookLaunchOutcome.degradedLoopback =>
      _withReason(t.game_capture_degraded_loopback, reason),
    GalHookLaunchOutcome.running => t.game_capture_running,
  };
}

/// 「启动彻底失败」要说的话（BUG-1142）。
///
/// 分三级取信息，**每一级都来自真实事实，绝不编造**：
/// 1. [GalHookLaunchResult.reason]——它是编译期强制填写的，不会缺；
/// 2. injector 的结构化处置（缺组件 / 要管理员 / 位数不符…）；
/// 3. 都归类不出来时，附上 native 一手诊断（退出码 + stderr 尾行）。
///
/// 第 3 级正是本 bug 的修复点：旧实现在这里只剩一句「游戏启动或捕获失败」，而
/// `diagnostics.stderrTail` 明明有内容，却停在 controller 内部从不进入 UI——用户既
/// 无法自愈，报障时也提供不出任何可用线索。
String _failedMessage(
  GalHookLaunchResult result,
  String? injectorReason,
  String? lastError,
) {
  final String? reasonLabel = switch (result.reason) {
    GalHookLaunchFailureReason.unsupportedPlatform => t.game_launch_unsupported,
    GalHookLaunchFailureReason.helperMissing =>
      t.game_hook_reason_helper_missing,
    // injectionFailed 的可执行处置在 injector 诊断里，由 [injectorReason] 提供。
    GalHookLaunchFailureReason.injectionFailed => injectorReason,
    // 这两个不会走到 failed 分支（superseded 已早退，none 不是失败），列出只为穷举。
    GalHookLaunchFailureReason.superseded => null,
    GalHookLaunchFailureReason.none => null,
  };
  if (reasonLabel != null) return reasonLabel;
  final String base = lastError ?? t.game_capture_launch_failed;
  final String detail = galHookDiagnosticsDetail(result.diagnostics);
  return detail.isEmpty ? base : '$base（$detail）';
}

/// native 诊断压成一行可展示的证据：`exit=<码> <stderr 最后一行非空内容>`。
///
/// 取**最后一行**：injector 失败即退，最后写出的那行就是它停下的地方；早期的
/// `[luna] ... 已注入` 之类是进度而非结论。长诊断从尾部截断（保留结论侧）。
@visibleForTesting
String galHookDiagnosticsDetail(GalHookInjectorDiagnostics diagnostics) {
  const int maxLength = 160;
  final List<String> parts = <String>[];
  if (diagnostics.exitCode != null) {
    parts.add('exit=${diagnostics.exitCode}');
  }
  final List<String> lines = diagnostics.stderrTail
      .split(RegExp(r'[\r\n]+'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();
  if (lines.isNotEmpty) {
    final String last = lines.last;
    parts.add(
      last.length <= maxLength
          ? last
          : '…${last.substring(last.length - maxLength)}',
    );
  }
  return parts.join(' ');
}

String _withReason(String message, String? reason) =>
    reason == null ? message : '$message（$reason）';

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

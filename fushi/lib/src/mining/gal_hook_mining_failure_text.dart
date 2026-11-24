/// gal 场景卡没走到制卡结局（[GalHookMiningResult.aborted]）时给用户看的那句话。
///
/// 查词浮窗制卡（`GalHookTextOverlayController`）与 texthooker 页制卡共用这一处分流：
/// 按 [GalHookMiningResult.failureStage] 说清停在哪一步，写卡阶段被引擎中止、台词已失效
/// 都不再一律报成「窗口截图失败」（#4362 审查遗留）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';

/// [result] 必须是 aborted（`outcome == null`）的结果；有结局的失败走
/// `describeMineOutcome`。
String galHookMiningAbortMessage(GalHookMiningResult result) {
  assert(result.aborted, 'only aborted results have a stage message');
  final String? reason = result.failureReason;
  return switch (result.failureStage ?? GalHookMiningFailureStage.internal) {
    GalHookMiningFailureStage.lineUnavailable => t.game_card_line_unavailable,
    GalHookMiningFailureStage.windowUnbound => t.game_card_window_unbound,
    GalHookMiningFailureStage.capture =>
      reason != null
          ? '${t.external_window_capture_failed}：$reason'
          : t.external_window_capture_failed,
    GalHookMiningFailureStage.audioGate =>
      t.game_audio_fallback_disabled_missing,
    GalHookMiningFailureStage.write => t.game_card_write_aborted(
      reason: reason ?? 'scene card mining aborted',
    ),
    GalHookMiningFailureStage.internal => t.game_card_mining_failed(
      reason: reason ?? 'unknown error',
    ),
  };
}

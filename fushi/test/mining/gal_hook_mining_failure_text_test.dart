import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_mining_failure_text.dart';

/// #4362 审查遗留：gal 场景卡没走到结局时，提示按停在哪一步分流——写卡阶段被引擎
/// 中止、台词已失效都不能再报成「窗口截图失败」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  String messageAt(GalHookMiningFailureStage stage, {String? reason}) =>
      galHookMiningAbortMessage(
        GalHookMiningResult(failureStage: stage, failureReason: reason),
      );

  test('写卡阶段被引擎中止：说写卡被中止并带原因，不提截图', () {
    final String msg = messageAt(
      GalHookMiningFailureStage.write,
      reason: 'required audio missing',
    );
    expect(msg, t.game_card_write_aborted(reason: 'required audio missing'));
    expect(msg, isNot(contains(t.external_window_capture_failed)));
  });

  test('截图失败仍是截图失败文案（带原因）', () {
    expect(
      messageAt(GalHookMiningFailureStage.capture, reason: 'window gone'),
      '${t.external_window_capture_failed}：window gone',
    );
    expect(
      messageAt(GalHookMiningFailureStage.capture),
      t.external_window_capture_failed,
    );
  });

  test('其余阶段各有各的文案，都不是截图失败', () {
    final Map<GalHookMiningFailureStage, String> expected =
        <GalHookMiningFailureStage, String>{
          GalHookMiningFailureStage.lineUnavailable:
              t.game_card_line_unavailable,
          GalHookMiningFailureStage.windowUnbound: t.game_card_window_unbound,
          GalHookMiningFailureStage.audioGate:
              t.game_audio_fallback_disabled_missing,
          GalHookMiningFailureStage.internal: t.game_card_mining_failed(
            reason: 'boom',
          ),
        };
    for (final MapEntry<GalHookMiningFailureStage, String> e
        in expected.entries) {
      final String msg = messageAt(e.key, reason: 'boom');
      expect(msg, e.value, reason: e.key.name);
      expect(
        msg,
        isNot(contains(t.external_window_capture_failed)),
        reason: e.key.name,
      );
    }
  });
}

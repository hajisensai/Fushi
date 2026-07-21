import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-678 / BUG-390：阅读器**查词路径** evaluateJavascript 的异步守卫回归测试
/// （源码扫描，沿用 `reader_live_settings_guard_test.dart` 的静态断言模式：
/// `readReaderPageSource()` + `contains`）。
///
/// 守护 BUG-005 漏网的查词高亮 callsite。半销毁 WebView（页面 teardown / 设置 reload
/// 重建瞬态）上其 per-instance method channel 的 `setMethodCallHandler(null)` 已摘除，
/// `evaluateJavascript` 抛 `MissingPluginException`；`_controller != null` 守卫只防 null，
/// 防不了通道已摘。查词链路里这些 eval 点若回退裸调，异常会逃当前 zone（fire-and-forget
/// 的 onTap / onShiftHover / onDismissBarrierHover / onAllPopupsDismissed），或打断查词
/// 弹窗显示（`_highlightAndShowPopup` 的 finally 之前）。每个守卫都靠一个 ErrorLogService
/// tag 标识，守卫被移除即 tag 消失，本测试红。
///
/// 为什么用源码扫描而非行为测试：reader 页含真实 `InAppWebView` 平台视图，无法在 widget
/// 测试挂载；「controller 非 null 但底层 channel 已废」是运行时销毁竞态，难确定性复现。
/// 故以结构守卫替代手动设备复测（照 BUG-005 / BUG-024 成例）。
void main() {
  final String src = readReaderPageSource();

  test('lookup-path evaluateJavascript sites stay try/catch-guarded', () {
    // 每个 tag 只出现在对应查词 eval 点的 try/catch / catchError 守卫块内。
    const List<String> guardTags = <String>[
      // _highlightAndShowPopup：选区高亮 eval（BUG-005 漏网主点，原只有 finally 无 catch）
      'ReaderHibiki.highlightAndShowPopup.eval',
      // _selectTextAt：onTap / onShiftHover / onDismissBarrierHover fire-and-forget 调
      'ReaderHibiki.selectTextAt.eval',
      // _clearLookupState → _clearSelectionJs：onAllPopupsDismissed fire-and-forget 调
      'ReaderHibiki.clearLookupState.eval',
      // _handleTextSelected 歌词分支：cue context eval（已纳入既有 try 块）
      'ReaderHibiki.lyricsCueContext',
    ];
    for (final String tag in guardTags) {
      expect(
        src,
        contains("'$tag'"),
        reason: '$tag 守卫缺失：半销毁 WebView 上查词 evaluateJavascript 抛 '
            'MissingPluginException 会逃 zone / 打断查词弹窗（TODO-678，BUG-005 '
            '同根因漏网 callsite）。勿退回裸 eval。',
      );
    }
  });

  test(
      '_highlightAndShowPopup shows popup up-front, decoupled from highlight eval',
      () {
    // BUG-717 (2): the popup show is decoupled from the reader-WebView highlight
    // eval. The old impl put showDeferredPopup inside the highlight eval's finally
    // (await eval, then show), so the popup was serialized behind the busy large
    // reader WebView -- the main multiplier making in-app lookup several times
    // slower than the out-of-app overlay. Now the popup is shown UP FRONT with
    // fallbackRect; the highlight eval only reanchors afterwards. Under this
    // structure a failing/half-torn WebView eval (MissingPluginException) still
    // cannot block OR delay the popup -- a stronger guarantee than the old
    // finally. If anyone recouples the show back onto the eval (moving it into a
    // try/finally, or showing only after awaiting the eval), this test goes red.
    final int showIdx =
        src.indexOf('showDeferredPopup(selectionRect: fallbackRect);');
    final int evalIdx =
        src.indexOf("'ReaderHibiki.highlightAndShowPopup.eval'");
    expect(
      showIdx,
      greaterThanOrEqualTo(0),
      reason: '_highlightAndShowPopup must show the popup up front with '
          'fallbackRect (decoupled from the highlight eval); do not recouple it '
          "onto the eval's finally/continuation.",
    );
    expect(
      evalIdx,
      greaterThanOrEqualTo(0),
      reason: 'ReaderHibiki.highlightAndShowPopup.eval guard tag missing.',
    );
    expect(
      showIdx,
      lessThan(evalIdx),
      reason: 'The popup show (showDeferredPopup(fallbackRect)) must appear '
          'before the highlight eval: show and eval are decoupled so an eval '
          'failure or slowdown neither blocks nor delays the popup (BUG-717 2).',
    );
  });

  test('_highlightAndShowPopup reanchors via reanchorTopPopup after eval', () {
    // After decoupling, the highlight eval's only job is to fetch the refined
    // word bbox and reanchor via reanchorTopPopup(rect, generation) (the
    // generation guard prevents a late callback from mis-anchoring a newer
    // lookup's popup; BUG-767: popup must not cover the looked-up word). If
    // anyone drops the reanchor and leaves the popup stuck at the selection
    // fallbackRect, this test goes red.
    expect(
      src,
      contains('reanchorTopPopup(rect, generation)'),
      reason: 'The highlight eval result must reanchor via '
          'reanchorTopPopup(rect, generation) to the refined word bbox '
          '(generation-guarded); do not remove the reanchor.',
    );
  });

  test('_clearLookupState dispatches selection-clear eval via unawaited', () {
    // _clearLookupState 被 onAllPopupsDismissed fire-and-forget 调用，清选区 eval
    // 必须经 unawaited(_clearSelectionJs())（helper 内 try/catch），不能裸 fire-and-forget
    // 让 await 边界后的异常无主逃 zone。
    expect(
      src,
      contains('unawaited(_clearSelectionJs())'),
      reason: '_clearLookupState 必须经 unawaited(_clearSelectionJs()) 派发清选区 '
          'eval（helper 内 try/catch），勿退回裸 _controller?.evaluateJavascript。',
    );
  });
}

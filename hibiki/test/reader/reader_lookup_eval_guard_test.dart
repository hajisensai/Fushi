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

  test('_highlightAndShowPopup keeps showing popup even when highlight eval fails',
      () {
    // catch 记日志后，finally 的 showDeferredPopup 必须照常执行：高亮失败退回
    // fallbackRect，查词弹窗仍显示不中断（TODO-678 核心语义）。谁把 finally 去掉、
    // 让异常吞掉后弹窗也不显示，本断言红。
    expect(
      src,
      contains('} finally {\n      showDeferredPopup(selectionRect: finalRect);'),
      reason: '_highlightAndShowPopup 的 showDeferredPopup 必须留在 finally：高亮 '
          'eval 在半销毁 WebView 上抛 MissingPluginException 时，查词弹窗仍要照常 '
          '显示（退回 fallbackRect）。勿移出 finally。',
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

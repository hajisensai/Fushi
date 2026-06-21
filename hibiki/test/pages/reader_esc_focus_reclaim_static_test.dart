import 'package:flutter_test/flutter_test.dart';
import 'reader_hibiki_page_source_corpus.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

/// BUG-136 — 翻页（手势/滚轮）后 ESC 不退出书籍。
///
/// 退出书籍依赖 Flutter 阅读器 `_focusNode`（挂 `Focus.onKeyEvent:
/// _handleKeyEvent`）持有键盘焦点：ESC → readerDismissDict → Navigator.maybePop()
/// → onWillPop()（恒 true）→ 退出。进书时 `autofocus: true` 给了焦点，所以一开始
/// ESC 能退。但用**指针手势翻页**（滑动 / 鼠标滚轮 / 边界翻章），手势先落在原生
/// WebView 上，WebView 抢走 OS 键盘焦点，没有任何代码把焦点还给 `_focusNode`
/// （不像 popup 路径的 `onAllPopupsDismissed` 会 `_focusNode.requestFocus()`）。
/// 此后 ESC 进了 WebView 被吞，到不了 `_handleKeyEvent` → 翻页后退不出书。
/// 键盘/手柄翻页不经这些 JS 手势回调、不丢焦点，所以 bug 只在触摸/鼠标翻页后出现。
///
/// 决策逻辑抽成纯谓词 [shouldReclaimReaderFocusAfterGesture] 可脱离 WebView 单测；
/// 「真实焦点树 / 原生 WebView 抢焦点」只能在设备复测，故用源码守卫锁住接线
/// （最强可落地层 — 见 docs/BUGS.md，与 reader_webview_com_focus_guard 同范式）。
void main() {
  group('BUG-136 · 纯谓词：何时该夺回阅读器焦点', () {
    test('正常翻页（无弹窗、底栏未持焦点）→ 夺回焦点', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: false,
          chromeHasFocus: false,
        ),
        isTrue,
      );
    });

    test('词典弹窗可见 → 不夺（弹窗合法持有焦点）', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: true,
          chromeHasFocus: false,
        ),
        isFalse,
      );
    });

    test('底栏持有焦点 → 不夺（避免把焦点从底栏抢走，不破坏手柄/键盘导航）', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: false,
          chromeHasFocus: true,
        ),
        isFalse,
      );
    });

    test('两者都成立 → 不夺', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: true,
          chromeHasFocus: true,
        ),
        isFalse,
      );
    });
  });

  group('BUG-136 · 源码守卫：每个指针手势回调都夺回焦点', () {
    // TODO-589 batch8: 指针手势 handler(onSwipe/onBoundarySwipe/onTap/onTapEmpty)
    // 已搬到 reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    final String code = _stripDartLineComments(readReaderPageSource());

    test('阅读器页面合并语料含 WebView 注入', () {
      // 合并语料(主壳 + part)必须真正含 reader WebView 构建点，否则下面的
      // handler 守卫会静默空跑（reader_hibiki_page.dart 已拆主壳 + part）。
      expect(code.contains('InAppWebView('), isTrue);
    });

    // 每个纯指针手势 JS 回调（用户触摸 WebView 触发 → WebView 抢焦点）都必须在
    // 回调体内夺回阅读器焦点，否则该手势之后 ESC / 快捷键失效（BUG-136）。
    for (final String handler in <String>[
      'onSwipe', // 滑动 + 鼠标滚轮翻页（JS wheel 也 callHandler('onSwipe')）
      'onBoundarySwipe', // 边界手势 → 翻章
      'onTapEmpty', // 点空白切底栏
    ]) {
      test("'$handler' 回调体内调用 _reclaimReaderFocusAfterGesture()", () {
        final String body = _handlerCallbackBody(code, handler);
        expect(
          body.contains('_reclaimReaderFocusAfterGesture()'),
          isTrue,
          reason: "'$handler' 回调丢了夺回焦点的调用 —— 该手势翻页/切栏后 ESC "
              '将无法退出书籍（BUG-136）。',
        );
      });
    }

    test("'onTap' 回调（切栏/无选区分支）夺回焦点", () {
      final String body = _handlerCallbackBody(code, 'onTap');
      expect(
        body.contains('_reclaimReaderFocusAfterGesture()'),
        isTrue,
        reason: 'onTap 点击切底栏后 ESC 必须仍能退出书籍（BUG-136）。',
      );
    });

    test('夺回焦点的 helper 经纯谓词把关（弹窗/底栏持焦点时不夺）', () {
      // helper 必须把决策委托给可单测的纯谓词，而不是无条件 requestFocus。
      expect(
        code.contains('shouldReclaimReaderFocusAfterGesture('),
        isTrue,
        reason: '_reclaimReaderFocusAfterGesture 应调用纯谓词 '
            'shouldReclaimReaderFocusAfterGesture 决定是否夺回焦点。',
      );
    });
  });
}

/// 取某个 `handlerName: '<name>'` 之后、到下一个 `handlerName:`（或文件末尾）之前的
/// 源码片段，作为该回调体的近似范围，用于断言夺回焦点的调用确实接在该回调里。
String _handlerCallbackBody(String code, String handlerName) {
  final int start = code.indexOf("handlerName: '$handlerName'");
  expect(start, isNonNegative,
      reason: "找不到 handlerName: '$handlerName' —— 回调被改名/移除，更新此守卫");
  final int next = code.indexOf('handlerName:', start + 1);
  return next < 0 ? code.substring(start) : code.substring(start, next);
}

/// 去掉 `//` 行注释，使断言匹配真实代码而非记录守卫的散文（散文里也会提到这些调用）。
String _stripDartLineComments(String source) => source
    .split('\n')
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');

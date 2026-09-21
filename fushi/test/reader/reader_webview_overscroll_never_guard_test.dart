import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 阅读器 WebView 的原生过滚回弹必须关闭，包括 BUG-2578 的 Android
/// EdgeEffect 和 iOS WKWebView 的 UIScrollView.bounces。
///
/// 阅读器自己拥有两条轴的滚动语义（分页 `touch-action: none` 不走原生滚动；连续
/// 模式只沿书写轴原生滚动、章边界由 onBoundarySwipe 跨章），平台层的 EdgeEffect
/// 辉光 / Android 12+ 拉伸在任一轴上都不对应阅读动作。默认 `IF_CONTENT_SCROLLS`
/// 只看「文档比视口高不高」，不看 CSS 有没有锁轴——竖排连续下 html 已
/// `overflow-y: hidden`，章内任一元素纵向溢出就让上下滑动整页回弹（用户录屏）。
/// 这是平台原生渲染行为，Dart widget / Chromium 无法模拟 iOS 橡皮筋效果；
/// 此处守生产构建点，设备上另验竖屏上下拖动以及连续模式正常阅读滚动。
String _readerInitialSettings() {
  final String src = File(
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
  ).readAsStringSync();
  // 锚在阅读器那份 initialSettings 上：它是 reader_fushi/ 下唯一的
  // InAppWebViewSettings，滚动条关闭那两行是其身份特征。
  final int settingsStart = src.indexOf(
    'initialSettings: InAppWebViewSettings(',
  );
  expect(
    settingsStart,
    greaterThan(0),
    reason: 'reader must build its WebView with initialSettings',
  );
  final int settingsEnd = src.indexOf('onWebViewCreated:', settingsStart);
  expect(settingsEnd, greaterThan(settingsStart));
  final String settings = src
      .substring(settingsStart, settingsEnd)
      .replaceAll(RegExp(r'//[^\r\n]*'), '');
  expect(
    settings,
    contains('verticalScrollBarEnabled: false'),
    reason: 'anchor drifted: not the reader settings block',
  );
  return settings;
}

void main() {
  test('reader InAppWebViewSettings pins overScrollMode to NEVER', () {
    final String settings = _readerInitialSettings();
    expect(
      settings,
      contains('overScrollMode: OverScrollMode.NEVER'),
      reason:
          'BUG-2578: Android overscroll glow/stretch must stay off on the '
          'reader WebView; the reader owns both scroll axes itself',
    );
    expect(settings, isNot(contains('OverScrollMode.IF_CONTENT_SCROLLS')));
    expect(settings, isNot(contains('OverScrollMode.ALWAYS')));
  });

  test('reader disables iOS native rubber banding at WebView creation', () {
    final String settings = _readerInitialSettings();
    expect(
      settings,
      contains('disallowOverScroll: true'),
      reason:
          'Android overScrollMode does not disable WKWebView bouncing; '
          'iOS must set UIScrollView.bounces to false via disallowOverScroll',
    );
  });

  test('disabling overscroll preserves native continuous reading scroll', () {
    final String settings = _readerInitialSettings();
    // 两个书写方向共用同一 WebView，不能通过锁死任何一条原生轴来消回弹。
    for (final String property in <String>[
      'disableVerticalScroll',
      'disableHorizontalScroll',
    ]) {
      final RegExpMatch? setting = RegExp(
        '$property\\s*:\\s*([^,]+)',
      ).firstMatch(settings);
      expect(
        setting?.group(1)?.trim(),
        anyOf(isNull, 'false'),
        reason:
            '$property must retain its false default for continuous reading',
      );
    }
  });
}

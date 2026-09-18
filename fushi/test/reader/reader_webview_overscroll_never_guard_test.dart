import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2578 源码守卫：阅读器 WebView 的 Android 过滚回弹必须关死。
///
/// 阅读器自己拥有两条轴的滚动语义（分页 `touch-action: none` 不走原生滚动；连续
/// 模式只沿书写轴原生滚动、章边界由 onBoundarySwipe 跨章），平台层的 EdgeEffect
/// 辉光 / Android 12+ 拉伸在任一轴上都不对应阅读动作。默认 `IF_CONTENT_SCROLLS`
/// 只看「文档比视口高不高」，不看 CSS 有没有锁轴——竖排连续下 html 已
/// `overflow-y: hidden`，章内任一元素纵向溢出就让上下滑动整页回弹（用户录屏）。
void main() {
  test('reader InAppWebViewSettings pins overScrollMode to NEVER', () {
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
    final String settings = src.substring(settingsStart, settingsEnd);
    expect(
      settings,
      contains('verticalScrollBarEnabled: false'),
      reason: 'anchor drifted: not the reader settings block',
    );
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
}

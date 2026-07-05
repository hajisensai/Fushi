import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// TODO-1168（实验性）：悬浮底栏毛玻璃 + 半透明的源码守卫。
///
/// reader 页含真实 `InAppWebView` 平台视图，widget 测试挂不上整页、观测不到底栏
/// 真实像素，故用结构守卫钉死两条不变式：
/// 1. **零回归**：关闭实验开关时，毛玻璃包裹 [_wrapBottomChromeFrost] 与填充色
///    [_bottomChromeFillColor] 都必须原样早退（返回 child / 不透明主题背景色），不引入
///    任何 ClipRect / BackdropFilter / alpha 叠加 → 底栏行为完全同现状。
/// 2. **只改视觉不改占位高**：毛玻璃走 `ClipRect > BackdropFilter`（取子级尺寸，不改
///    布局高），底栏两处背景 + 有声书条背景都统一取 [_bottomChromeFillColor]，底栏
///    预留高（ReaderChromeScaler / _readerChromeBaseHeight）不受触碰。
void main() {
  final String src = readReaderPageSource();

  test('frost helpers early-return when the experimental flag is off', () {
    final String fill = _functionSource(
      src,
      '  Color _bottomChromeFillColor() {',
      '  Widget _wrapBottomChromeFrost(',
    );
    expect(
      fill,
      contains(
          'if (!ReaderHibikiSource.instance.frostedBottomBar) return base;'),
      reason: '关闭毛玻璃时必须返回不透明主题背景色（零回归），不叠加 alpha。',
    );

    final String wrap = _functionSource(
      src,
      '  Widget _wrapBottomChromeFrost(Widget child) {',
      '  Widget _buildBottomChrome() {',
    );
    expect(
      wrap,
      contains(
          'if (!ReaderHibikiSource.instance.frostedBottomBar) return child;'),
      reason: '关闭毛玻璃时必须原样返回 child，不引入 ClipRect/BackdropFilter 包裹层。',
    );
    expect(
      wrap,
      contains('ClipRect('),
      reason: '开启态毛玻璃走 ClipRect > BackdropFilter(ImageFilter.blur) 配方。',
    );
    expect(wrap, contains('ImageFilter.blur('));
  });

  test('both bottom bars use the shared frost fill + wrapper', () {
    final String audiobook = _functionSource(
      src,
      '  Widget _buildAudiobookBar() {',
      '  Widget _buildSettingsBar() {',
    );
    expect(audiobook, contains('_wrapBottomChromeFrost('));
    expect(audiobook, contains('backgroundColor: _bottomChromeFillColor()'));
    expect(
      audiobook,
      isNot(contains('color: _themeBackgroundColor()')),
      reason: '有声书底栏背景必须走 _bottomChromeFillColor，不得直接用不透明主题色。',
    );

    final String settings = _functionSource(
      src,
      '  Widget _buildSettingsBar() {',
      '  // TODO-796:',
    );
    expect(settings, contains('_wrapBottomChromeFrost('));
    expect(
      settings,
      isNot(contains('color: _themeBackgroundColor()')),
      reason: '设置底栏两处背景必须走 _bottomChromeFillColor，不得用不透明主题色。',
    );
  });

  test('bottom-bar reserve height is independent of the frosted setting', () {
    // 「视觉高 ≡ 预留高」铁律：底栏预留高由 bottomChromeReserve 纯函数决定，其入参
    // 只有 barOccupiesLayout / floating / chromeHeight —— 绝不能因毛玻璃/不透明度
    // 而变化。若哪天有人把 frosted / opacity / blur 掺进 reserve 计算，此断言红。
    final String reserveSrc = File(
      'lib/src/reader/reader_chrome_floating.dart',
    ).readAsStringSync();
    for (final String forbidden in <String>['frost', 'opacity', 'blur']) {
      expect(
        reserveSrc.toLowerCase(),
        isNot(contains(forbidden)),
        reason: 'reader_chrome_floating.dart（底栏/顶栏预留高的单一真相）不得引用 '
            '$forbidden —— 毛玻璃只改视觉，绝不改占位高。',
      );
    }
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

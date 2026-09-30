import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// 阅读器专注模式：开启后顶栏 / 底栏收起且任何入口都唤不出来，只有关掉专注
/// 模式才恢复。状态本身的行为在 `reader_chrome_controller_test.dart`；这里钉
/// 页面上**每一条**唤出 / 切换入口都过了专注模式闸门——漏一条，栏就能被那条
/// 路唤出来，专注模式形同虚设；以及点词、VN 推进、退出通道不被它误伤。
String _body(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNot(-1), reason: '找不到 $signature');
  final int end = src.indexOf('\n  }\n', start);
  return src.substring(start, end);
}

void main() {
  final String src = readReaderPageSource();

  test('布局判据经专注模式闸门，不去翻 _showChrome', () {
    expect(
      src,
      contains('bool get _chromeBarsExpanded => _showChrome && !_focusMode;'),
    );
    expect(src, contains('chromeExpanded: _chromeBarsExpanded'));
    expect(
      'barOccupiesLayout: _hasEverLoaded && _chromeBarsExpanded'
          .allMatches(src)
          .length,
      2,
      reason: '顶栏预留与底栏预留两处都要经闸门',
    );
    expect(
      src,
      contains('chromeOccupiesLayout: _hasEverLoaded && _chromeBarsExpanded'),
    );
    expect(
      _body(src, 'void _setFocusMode(bool enabled) {'),
      isNot(contains('_showChrome =')),
      reason: '_showChrome 是 JS 点词门控镜像，翻了点正文就变成唤栏',
    );
  });

  test('每条唤出 / 切换入口在专注模式下都被拦住', () {
    for (final String sig in <String>[
      'void _toggleChromeFromShortcut() {',
      'void _toggleChrome() {',
      'bool _handleFloatingChromeReveal() {',
    ]) {
      final String body = _body(src, sig);
      expect(body, contains('if (_focusMode) {'), reason: '$sig 缺专注模式闸门');
      expect(body, contains('_showFocusModeBarsLockedHint();'), reason: sig);
    }
    // 控制器层兜底：直接写 transientVisible / showTransient / reveal 都无效
    // （行为单测在 reader_chrome_controller_test.dart）。
  });

  test('专注模式下点正文照常查词：点词门控读 _tapGateChrome', () {
    expect(
      src,
      contains('bool get _tapGateChrome => _showChrome || _focusMode;'),
    );
    expect(
      src,
      contains(
        "'{ chrome: \$_tapGateChrome, lookup: \$lookup, maxLen: 400 };'",
      ),
    );
    expect(src, contains('showChrome: _tapGateChrome,'));
    expect(src, contains('if (!_tapGateChrome && !shiftKey) {'));
    expect(src, isNot(contains('if (!_showChrome && !shiftKey) {')));
  });

  test('VN 空白点在专注模式下直接推进（不被「只唤栏」吞掉）', () {
    final String body = _body(src, 'void _handleVnBlankTap() {');
    final int gate = body.indexOf('if (_focusMode) {');
    expect(gate, isNot(-1));
    expect(
      body.substring(gate),
      contains('_paginate(ReaderNavigationDirection.forward)'),
    );
    expect(gate, lessThan(body.indexOf('dispatchReaderVnBlankTapAction(')));
  });

  test('退出通道：返回先退专注模式；点空白弹带退出动作的提示', () {
    final int pop = src.indexOf(
      'onPopInvokedWithResult: (didPop, dynamic result) {',
    );
    expect(pop, isNot(-1));
    final String popBody = src.substring(
      pop,
      src.indexOf('exitAfterPersist(', pop),
    );
    expect(popBody, contains('if (_focusMode) {'));
    expect(popBody, contains('_setFocusMode(false);'));
    expect(
      popBody.indexOf('if (_focusMode) {'),
      lessThan(popBody.indexOf('_popInProgress = true')),
      reason: '专注模式那一级必须在退书闸之前，否则返回直接退书',
    );

    final String hint = _body(src, 'void _showFocusModeBarsLockedHint() {');
    expect(hint, contains('SnackBarAction('));
    expect(hint, contains('_setFocusMode(false)'));

    final int tapEmpty = src.indexOf("handlerName: 'onTapEmpty'");
    final String tapEmptyBody = src.substring(
      tapEmpty,
      src.indexOf("handlerName: 'onVnBlankTap'"),
    );
    expect(
      tapEmptyBody,
      contains(
        'if (_focusMode) {\n              _showFocusModeBarsLockedHint();',
      ),
      reason: '挤压态点空白本来不响应；专注模式下它是触屏唯一的退出通道',
    );
  });

  test('按钮登记：栏与悬浮球共用同一个执行体', () {
    expect(
      src,
      contains('case ReaderControlItem.focusMode:\n        return true;'),
    );
    expect(src, contains('onPressed: _toggleFocusMode,'));
  });
}

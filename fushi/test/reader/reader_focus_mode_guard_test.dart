import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_chrome_floating.dart';

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

  group('VN 空白点在专注模式下：照常推进 + 附带退出提示', () {
    test('决策表：专注模式压过栏的一切状态', () {
      for (final bool expanded in <bool>[true, false]) {
        for (final bool floating in <bool>[true, false]) {
          for (final bool visible in <bool>[true, false]) {
            expect(
              readerVnBlankTapAction(
                chromeExpanded: expanded,
                bottomBarFloating: floating,
                transientVisible: visible,
                focusMode: true,
              ),
              ReaderVnBlankTapAction.advanceAndOfferFocusModeExit,
              reason: 'expanded=$expanded floating=$floating visible=$visible',
            );
          }
        }
      }
    });

    test('生产分派器：推进且提示，绝不唤栏 / 展开栏', () {
      final List<String> calls = <String>[];
      dispatchReaderVnBlankTapAction(
        readerVnBlankTapAction(
          chromeExpanded: false,
          bottomBarFloating: true,
          transientVisible: false,
          focusMode: true,
        ),
        expandChrome: () => calls.add('expand'),
        revealChrome: () => calls.add('reveal'),
        advance: () => calls.add('advance'),
        offerFocusModeExit: () => calls.add('hint'),
      );
      expect(
        calls,
        <String>['advance', 'hint'],
        reason:
            'VN 开点击推进时空白点到不了 onTapEmpty，这条提示是触屏唯一的退出通道；'
            '提示是附带的，不能吞掉推进',
      );
    });

    test('非专注模式不弹提示（既有 BUG-1245 行为不变）', () {
      final List<String> calls = <String>[];
      for (final bool visible in <bool>[false, true]) {
        dispatchReaderVnBlankTapAction(
          readerVnBlankTapAction(
            chromeExpanded: true,
            bottomBarFloating: true,
            transientVisible: visible,
            focusMode: false,
          ),
          expandChrome: () => calls.add('expand'),
          revealChrome: () => calls.add('reveal'),
          advance: () => calls.add('advance'),
          offerFocusModeExit: () => calls.add('hint'),
        );
      }
      expect(calls, <String>['reveal', 'reveal', 'advance']);
    });

    test('页面把专注模式位与提示接进决策表，不另开短路分支', () {
      final String body = _body(src, 'void _handleVnBlankTap() {');
      expect(body, contains('focusMode: _focusMode,'));
      expect(
        body,
        contains('offerFocusModeExit: _showFocusModeBarsLockedHint,'),
      );
      expect(
        body,
        isNot(contains('if (_focusMode)')),
        reason: '专注模式的裁决只在决策表里一处；页面再短路一次就会绕过提示',
      );
    });
  });

  test('关了点词时点正文：专注模式下弹退出提示（onTap 的 !highlightOnTap 分支）', () {
    final int start = src.indexOf("handlerName: 'onTap',");
    expect(start, isNot(-1));
    final int end = src.indexOf("handlerName: 'onShiftHover'", start);
    expect(end, greaterThan(start));
    final String handler = src.substring(start, end);
    const String branchHead =
        'if (!shiftKey && !ReaderFushiSource.instance.highlightOnTap) {';
    final int branch = handler.indexOf(branchHead);
    expect(branch, isNot(-1), reason: '点词关闭分支不见了');
    final String branchBody = handler.substring(
      branch,
      handler.indexOf('return;', branch),
    );
    expect(
      branchBody,
      contains('if (_focusMode) _showFocusModeBarsLockedHint();'),
      reason:
          'highlightOnTap=false 时 JS 的点击（含空白）全走 onTap、到不了 '
          'onTapEmpty；不在这里提示，iOS 触屏就没有任何退出通道',
    );
  });

  test('提示条不跨页：_setFocusMode 守 mounted，dispose 关提示条', () {
    final String setBody = _body(src, 'void _setFocusMode(bool enabled) {');
    expect(
      setBody.indexOf('if (!mounted) return;'),
      allOf(isNot(-1), lessThan(setBody.indexOf('_rebuild('))),
      reason: '提示条挂在根 ScaffoldMessenger，退出动作可能在页面拆掉后才按下',
    );
    final int dispose = src.indexOf('  void dispose() {');
    expect(dispose, isNot(-1));
    final String disposeBody = src.substring(
      dispose,
      src.indexOf('super.dispose();', dispose),
    );
    // dispose 在锁树阶段：读屏开着时直接 close() 会同步对根 ScaffoldMessenger
    // setState 而抛错，必须走帧后关闭（行为测试见 test/utils/owned_snack_bar_test.dart）。
    expect(disposeBody, contains('_focusModeHint?.closeAfterOwnerDisposed();'));
    expect(disposeBody, isNot(contains('_focusModeHint?.close();')));
  });

  group('明确的退书一次到底，不被「先退专注模式」截成两下', () {
    test('唯一退书助手：关提示条、只在这次 maybePop 期间放行 PopScope', () {
      final String body = _body(
        src,
        'Future<void> _exitBookPastFocusMode() async {',
      );
      expect(body, contains('_focusModeHint?.close();'));
      final int set = body.indexOf('_explicitExitInFlight = true;');
      final int pop = body.indexOf('await Navigator.of(context).maybePop();');
      final int reset = body.indexOf('_explicitExitInFlight = false;');
      expect(set, isNot(-1));
      expect(pop, greaterThan(set));
      expect(reset, greaterThan(pop));
      expect(body, contains('finally {'));
      expect(
        body,
        isNot(contains('focusMode = false')),
        reason: '离场前翻 focusMode 会在退场动画里把挤压栏画回来',
      );
    });

    test('PopScope 的专注模式那一级认明确退书', () {
      expect(src, contains('if (_focusMode && !_explicitExitInFlight) {'));
    });

    test('没有入口再绕过助手直接写 focusMode', () {
      expect(
        src,
        isNot(contains('_chrome.focusMode = false;')),
        reason: '只有 _setFocusMode（含提示条 / inset / 点词门控同步）能改它',
      );
    });

    test('四个明确退书入口都走助手', () {
      String around(String anchor, int span) {
        final int at = src.indexOf(anchor);
        expect(at, isNot(-1), reason: '找不到 $anchor');
        return src.substring(at, at + span);
      }

      expect(
        around('onExitReader: () {', 200),
        contains('_exitBookPastFocusMode()'),
      );
      expect(
        around('onReturn: () {', 120),
        contains('_exitBookPastFocusMode()'),
      );
      expect(
        around("'reader_unloaded_back',", 500),
        contains('_exitBookPastFocusMode()'),
      );
      final String reimport = around('if (outcome.bodyRebuilt) {', 500);
      expect(reimport, contains('_exitBookPastFocusMode()'));
      expect(reimport, isNot(contains('maybePop()')));
    });
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
    expect(popBody, contains('if (_focusMode && !_explicitExitInFlight) {'));
    expect(popBody, contains('_setFocusMode(false);'));
    expect(
      popBody.indexOf('if (_focusMode && !_explicitExitInFlight) {'),
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

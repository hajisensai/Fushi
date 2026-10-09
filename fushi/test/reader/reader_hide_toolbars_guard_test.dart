import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_chrome_floating.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// 阅读器「关掉顶栏和底栏，由悬浮球接管」（取代已删除的专注模式）。
///
/// 状态本身的行为在 `reader_chrome_controller_test.dart`，悬浮球宿主的接管在
/// `floating_ball/app_floating_ball_host_test.dart`；这里钉：
///  * 生效判据只在应用内悬浮球开着时成立（否则人会被关在没有 chrome 的书里）；
///  * 页面上**每一条**唤出 / 切换入口都过了闸门——漏一条，栏就能被那条路唤出来；
///  * 点词、VN 推进不被它误伤；返回键照常退书（专注模式那一级已删）；
///  * 阅读器场景把返回 / 设置 / 开回栏固定在球上。
String _body(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNot(-1), reason: '找不到 $signature');
  final int end = src.indexOf('\n  }\n', start);
  return src.substring(start, end);
}

void main() {
  final String src = readReaderPageSource();

  test('生效判据：偏好开且应用内悬浮球开着才关栏', () {
    for (final bool pref in <bool>[true, false]) {
      for (final bool ball in <bool>[true, false]) {
        expect(
          readerToolbarsHidden(
            hideToolbarsPreference: pref,
            inAppFloatingBallEnabled: ball,
          ),
          pref && ball,
          reason: 'pref=$pref ball=$ball',
        );
      }
    }
  });

  test('页面按偏好 + 应用内悬浮球开关同步状态，并跟随球开关变化', () {
    final String sync = _body(src, 'void _syncToolbarsHidden({');
    expect(sync, contains('readerToolbarsHidden('));
    expect(sync, contains('ReaderFushiSource.instance.hideToolbars'));
    expect(sync, contains('prefsRepo.floatingBallInApp'));
    expect(sync, contains('_syncTapGateJs();'));
    expect(src, contains('prefsRepo.addListener(_onPrefsRepoChanged);'));
    expect(src, contains('prefsRepo.removeListener(_onPrefsRepoChanged);'));
    // 设置页拨开关走重锚通道，那条回调里要同步状态。
    final int hook = src.indexOf('chromeReanchor: () {');
    expect(hook, isNot(-1));
    expect(
      src.substring(hook, src.indexOf('},', hook)),
      contains('_syncToolbarsHidden(reanchor: false);'),
    );
  });

  test('布局判据经闸门，不去翻 _showChrome', () {
    expect(
      src,
      contains(
        'bool get _chromeBarsExpanded => _showChrome && !_toolbarsHidden;',
      ),
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
      _body(src, 'void _syncToolbarsHidden({'),
      isNot(contains('_showChrome =')),
      reason: '_showChrome 是 JS 点词门控镜像，翻了点正文就变成唤栏',
    );
  });

  test('每条唤出 / 切换入口在栏关掉时都被拦住', () {
    for (final String sig in <String>[
      'void _toggleChromeFromShortcut() {',
      'void _toggleChrome() {',
    ]) {
      expect(
        _body(src, sig),
        contains('if (_toolbarsHidden) return;'),
        reason: '$sig 缺闸门',
      );
    }
    expect(
      _body(src, 'bool _handleFloatingChromeReveal() {'),
      contains('if (_toolbarsHidden) return true;'),
    );
  });

  test('栏关掉时点正文照常查词：点词门控读 _tapGateChrome', () {
    expect(
      src,
      contains('bool get _tapGateChrome => _showChrome || _toolbarsHidden;'),
    );
    expect(
      src,
      contains(
        "'{ chrome: \$_tapGateChrome, lookup: \$lookup, maxLen: 400 };'",
      ),
    );
    expect(src, contains('showChrome: _tapGateChrome,'));
    expect(src, contains('if (!_tapGateChrome && !shiftKey) {'));
  });

  group('VN 空白点在栏关掉时只推进', () {
    test('决策表：栏关掉压过栏的一切状态', () {
      for (final bool expanded in <bool>[true, false]) {
        for (final bool floating in <bool>[true, false]) {
          for (final bool visible in <bool>[true, false]) {
            expect(
              readerVnBlankTapAction(
                chromeExpanded: expanded,
                bottomBarFloating: floating,
                transientVisible: visible,
                toolbarsHidden: true,
              ),
              ReaderVnBlankTapAction.advance,
              reason: 'expanded=$expanded floating=$floating visible=$visible',
            );
          }
        }
      }
    });

    test('页面把栏关掉位喂给决策表', () {
      final String body = _body(src, 'void _handleVnBlankTap() {');
      expect(body, contains('toolbarsHidden: _toolbarsHidden,'));
    });
  });

  test('专注模式已删：返回照常退书，没有提示条 / 明确退书助手', () {
    for (final String gone in <String>[
      '_focusMode',
      '_setFocusMode',
      '_showFocusModeBarsLockedHint',
      '_exitBookPastFocusMode',
      '_explicitExitInFlight',
      'reader_focus_mode',
    ]) {
      expect(src, isNot(contains(gone)), reason: gone);
    }
  });

  test('悬浮球接管：阅读器场景在栏关掉时固定返回 / 设置 / 开回栏', () {
    final String scene = _body(src, 'Widget _buildReaderFloatingBallScene() {');
    expect(scene, contains('pinnedIds: <String>['));
    expect(scene, contains('_hasEverLoaded && _toolbarsHidden'));
    expect(scene, contains('kReaderToolbarsTakeoverItems'));
    // 开关键在栏与球上共用同一个执行体，按运行态换文案。
    expect(
      src,
      contains('case ReaderControlItem.toolbars:\n        return true;'),
    );
    expect(
      src,
      contains('onPressed: () => unawaited(_setHideToolbars(!hidden)),'),
    );
    expect(
      _body(src, 'Future<void> _setHideToolbars(bool hide) async {'),
      contains('setHideReaderToolbars(appModelNoUpdate, hide)'),
    );
  });
}

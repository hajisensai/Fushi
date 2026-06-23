import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// 查词弹窗焦点系统守卫。
///
/// 阅读器整页含真实 InAppWebView，普通 widget 测试无法稳定挂载完整弹窗栈；
/// 这里锁住最强可落地的源码契约：
/// - 弹窗 header 工具栏按钮必须注册进 HibikiFocusRoot，不能再用裸 IconButton；
/// - reader/popup 的 WebView 字级 caret 属于焦点导航，必须跟随全局焦点导航开关。
void main() {
  final String source = readReaderPageSource();
  final String code = _collapse(_stripDartLineComments(source));

  test('popup header toolbar uses Hibiki focus-aware icon buttons', () {
    final String popupHeader = _functionSource(
      source,
      '  Widget? buildPopupAudioControls()',
      '  // ── Helpers',
    );

    expect(
      popupHeader,
      contains('HibikiIconButton('),
      reason: '查词弹窗 header 是 Flutter 兄弟层，手柄/键盘方向导航只走 '
          'HibikiFocusTarget；裸 IconButton 会被自定义焦点系统跳过。',
    );
    expect(
      popupHeader.replaceAll('HibikiIconButton(', ''),
      isNot(contains('IconButton(')),
      reason: '查词弹窗 header 不得再使用未注册的裸 IconButton。',
    );
  });

  test('reader and popup caret focus navigation is gated by the global switch',
      () {
    expect(
      code,
      contains(
        'bool get _focusNavEnabled => appModel.experimentalFocusNavigationEnabled;',
      ),
      reason: 'reader/popup WebView 字级 caret 是焦点导航，必须读取全局总开关。',
    );
    expect(
      code,
      contains('_focusNavEnabled ? _handleGamepadAKeyEvent(event) : null'),
      reason: '手柄 A 的进/操作 caret 路径必须跟随总开关。',
    );
    expect(
      'if (_focusNavEnabled && _caretActive)'.allMatches(code).length,
      greaterThanOrEqualTo(2),
      reason: '键盘与手柄的 caret 激活分支都必须用总开关短路。',
    );
    expect(
      'focusNavEnabled: _focusNavEnabled'.allMatches(code).length,
      greaterThanOrEqualTo(2),
      reason: '键盘 Enter 与手柄 A 的进 caret 判定都必须透传总开关。',
    );
    // TODO-700 T8：底栏被 ExcludeFocus 排出焦点遍历池后，「↓ 跳底栏」的焦点搬运整段
    // 删除（底栏不再是焦点目标），原 BUG-161「↓ 跳底栏要门控在开关上」诉求随之消失。
    // 两条断言改为断言搬运分支已删，防回退（与 reader_focus_nav_switch_static_test 一致）。
    expect(
      code.contains(
        'if (_focusNavEnabled && !_caretActive && event.logicalKey == LogicalKeyboardKey.arrowDown',
      ),
      isFalse,
      reason: 'TODO-700 T8：键盘 ↓ 把焦点塞进底栏的分支必须删除（底栏退出焦点遍历）。',
    );
    expect(
      code.contains(
        'if (_focusNavEnabled && button == GamepadButton.dpadDown && _showChrome)',
      ),
      isFalse,
      reason: 'TODO-700 T8：手柄 ↓ 把焦点塞进底栏的分支必须删除（底栏退出焦点遍历）。',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _stripDartLineComments(String source) => source
    .split('\n')
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');

String _collapse(String source) =>
    source.replaceAll(RegExp(r'\s+'), ' ').trim();

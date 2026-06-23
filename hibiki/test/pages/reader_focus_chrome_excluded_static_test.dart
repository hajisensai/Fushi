import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-700 T8 源码守卫：阅读器底栏退出焦点遍历池（焦点的唯一家是正文）。
///
/// 设计病根（docs/superpowers/plans/2026-06-23-todo700-focus-redesign.md §0）：
/// 「底栏控件是焦点遍历目标」是一连串焦点问题的共同根因——焦点飘到底栏、底栏焦点
/// 抢快捷键、底栏空格不暂停、隐藏快捷键被 `_chromeFocusScope.hasFocus` 短路。
///
/// T8 的根因修复 = 把底栏用 [ExcludeFocus] 排出焦点遍历池，使 `_chromeFocusScope`
/// 永不获得焦点（`.hasFocus` 恒 false），焦点恒留在正文 WebView（`_focusNode`）。
/// 随之，事件处理器里所有手写的「进出底栏」分支都成不可达死代码，必须整段删除而非
/// 留作死分支（好品味：消除特殊情况，而不是加条件判断绕过）。
///
/// 整页含真实 `InAppWebView` 平台视图，widget 测试无法挂载整页观测真实焦点遍历，
/// 故以源码结构守卫钉死不变式；任一退回，对应断言红。
void main() {
  String chromeSource() => File(
        'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');

  String caretSource() => File(
        'lib/src/pages/implementations/reader_hibiki/caret.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');

  // 去掉 `//` 行注释，使断言匹配真实代码而非记录被删路径的散文
  // （散文里会出现 `moveFocusToChrome` 字样）。
  String stripLineComments(String source) => source
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('两条底栏（有声书条 + 设置条）都被 ExcludeFocus 包住', () {
    final String chrome = chromeSource();
    final int excludes = RegExp(r'ExcludeFocus\(').allMatches(chrome).length;
    expect(
      excludes,
      greaterThanOrEqualTo(2),
      reason: '_buildAudiobookBar 与 _buildSettingsBar 必须各用 ExcludeFocus 包住 '
          '_chromeFocusScope，把底栏控件排出焦点遍历池（T8 根因修复）。',
    );
  });

  test('事件处理器不再有 if (_chromeFocusScope.hasFocus) 顶部分支（死分支已删）', () {
    final String caret = caretSource();
    expect(
      caret.contains('if (_chromeFocusScope.hasFocus) {'),
      isFalse,
      reason: '底栏退出焦点遍历后 _chromeFocusScope.hasFocus 恒 false，键盘/手柄事件'
          '处理器里的 chrome-focus 顶部分支不可达，必须整段删除（不留死分支）。',
    );
  });

  test('按方向键进入底栏的手写遍历已删（Down/dpadDown → 底栏的搬运不复存在）', () {
    final String caret = caretSource();
    expect(
      caret.contains('event.logicalKey == LogicalKeyboardKey.arrowDown &&'),
      isFalse,
      reason: '键盘 arrowDown 把焦点塞进底栏的分支必须删除（底栏不再接受焦点）。',
    );
    expect(
      caret.contains('button == GamepadButton.dpadDown && _showChrome'),
      isFalse,
      reason: '手柄 dpadDown 把焦点塞进底栏的分支必须删除（底栏不再接受焦点）。',
    );
  });

  test('_toggleChrome 不再把焦点搬进底栏（moveFocusToChrome 路径已删）', () {
    final String chrome = stripLineComments(chromeSource());
    expect(
      chrome.contains('moveFocusToChrome'),
      isFalse,
      reason: '显示底栏不得把焦点搬进底栏；_toggleChrome 的 moveFocusToChrome 形参与'
          '其分支必须删除（焦点恒留正文）。',
    );
    expect(
      chrome.contains('void _toggleChrome() {'),
      isTrue,
      reason: '_toggleChrome 应为无参版本（不再有 moveFocusToChrome）。',
    );
  });
}

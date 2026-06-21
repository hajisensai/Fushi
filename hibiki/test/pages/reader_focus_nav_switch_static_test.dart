import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-161 — 书籍阅读器的键盘/手柄焦点导航不跟随全局「键盘/手柄焦点导航」开关。
///
/// 全局开关 `AppModel.experimentalFocusNavigationEnabled`（默认关闭）原本只在
/// `main.dart`（挂 HibikiFocusRoot/Ring + wrapWithGlobalNavigation）和
/// `global_navigation.dart`（手柄分发/方向键移焦/手柄 B）被消费。阅读器页面自带一套
/// 独立的 WebView 字符光标（hoshiCaret）焦点导航，挂在自己的 `Focus.onKeyEvent`
/// 与 `GamepadButtonIntent` action 上，与开关解耦 —— 所以开关关闭时书里仍能用
/// 键盘/手柄进光标查词、显示焦点环、方向键跳底栏。
///
/// 根因修复：阅读器所有「焦点导航」分支（进光标、光标动作、方向键/手柄跳底栏、
/// 焦点环）都先判 `_focusNavEnabled`（= appModel.experimentalFocusNavigationEnabled）；
/// 「阅读控制类」（翻页/空格/快捷键）不受影响。
///
/// 进光标的门控在纯函数 `ReaderCaretRouter.isEnterTrigger*` 上有行为单测
/// （reader_caret_router_test.dart）。inline 的焦点环/跳底栏门控涉及真实焦点树与
/// WebView，无法脱离设备单测行为，故用源码守卫锁住接线（最强可落地层，见
/// docs/BUGS.md，与 reader_esc_focus_reclaim_static_test 同范式）。
void main() {
  group('BUG-161 · 源码守卫：阅读器焦点导航分支门控在开关上', () {
    final File file =
        File('lib/src/pages/implementations/reader_hibiki_page.dart');
    // 去 `//` 行注释（避免匹配记录守卫的散文）+ 折叠空白，便于跨行匹配。
    final String code =
        _collapse(_stripDartLineComments(readReaderPageSource()));

    test('阅读器页面源文件存在', () {
      expect(file.existsSync(), isTrue);
    });

    test('_focusNavEnabled getter 读全局开关', () {
      expect(
        code.contains(
            'bool get _focusNavEnabled => appModel.experimentalFocusNavigationEnabled;'),
        isTrue,
        reason:
            '_focusNavEnabled 必须等于 appModel.experimentalFocusNavigationEnabled，'
            '否则阅读器焦点导航不会跟随全局开关（BUG-161）。',
      );
    });

    test('手柄 A 进/操作光标的处理门控在开关上', () {
      expect(
        code.contains(
            '_focusNavEnabled ? _handleGamepadAKeyEvent(event) : null'),
        isTrue,
        reason: '手柄 A 是焦点导航（进/操作光标），开关关闭时不应运行（BUG-161）。',
      );
    });

    test('进光标的 enter-trigger 把开关透传给纯函数 router（键盘 + 手柄两处）', () {
      final int count =
          'focusNavEnabled: _focusNavEnabled'.allMatches(code).length;
      expect(
        count,
        greaterThanOrEqualTo(2),
        reason: 'isEnterTriggerKeyboard / isEnterTriggerGamepad 必须收到 '
            'focusNavEnabled: _focusNavEnabled，开关关闭时不进光标（BUG-161）。',
      );
    });

    test('光标激活分支（键盘 + 手柄两处）以 _focusNavEnabled 短路', () {
      final int count =
          'if (_focusNavEnabled && _caretActive)'.allMatches(code).length;
      expect(
        count,
        greaterThanOrEqualTo(2),
        reason: '光标动作是焦点导航；开关关闭（含中途关闭）时必须短路回退到翻页（BUG-161）。',
      );
    });

    test('方向键 ↓ 跳底栏焦点域门控在开关上', () {
      expect(
        code.contains(
            'if (_focusNavEnabled && !_caretActive && event.logicalKey == LogicalKeyboardKey.arrowDown'),
        isTrue,
        reason: '方向键 ↓ 跳底栏是焦点导航；关闭时 ↓ 应回退为翻页快捷键（BUG-161）。',
      );
    });

    test('手柄 D-pad ↓ 跳底栏焦点域门控在开关上', () {
      expect(
        code.contains(
            'if (_focusNavEnabled && button == GamepadButton.dpadDown && _showChrome)'),
        isTrue,
        reason: '手柄 D-pad ↓ 跳底栏是焦点导航；关闭时应回退到手柄翻页快捷键（BUG-161）。',
      );
    });

    test('阅读内容焦点环门控在开关上', () {
      expect(
        code.contains('final bool show = _focusNavEnabled &&'),
        isTrue,
        reason: '阅读内容焦点环属于焦点导航；关闭时不应显示（BUG-161）。',
      );
    });
  });
}

/// 去掉 `//` 行注释，使断言匹配真实代码而非记录守卫的散文。
String _stripDartLineComments(String source) => source
    .split('\n')
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// 折叠所有连续空白为单个空格，便于匹配被 dart format 折行的多行表达式。
String _collapse(String source) =>
    source.replaceAll(RegExp(r'\s+'), ' ').trim();

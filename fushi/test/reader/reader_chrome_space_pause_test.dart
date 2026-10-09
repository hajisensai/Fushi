import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-204：焦点落在阅读器底栏控件（_chromeFocusScope）时，裸 Space 仍应
/// 播放/暂停有声书，而不是被吞成 ignored、冒泡到全局导航被中和成
/// DoNothingIntent。底栏焦点路径与正文焦点路径（BUG-062）共用同一
/// [resolveReaderSpaceOverride] 闸门，**不回退**裸空格中和。
void main() {
  group('BUG-204 底栏焦点 Space 暂停判据（resolveReaderSpaceOverride 共用闸门）', () {
    test('有声书激活 + 无修饰 Space → audiobookPlayPause（底栏焦点也暂停）', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
        ),
        ShortcutAction.audiobookPlayPause,
      );
    });

    test('无有声书 + 无修饰 Space → null（底栏控件自身的 Space 语义不被拦）', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: false,
        ),
        isNull,
      );
    });

    test('有声书激活 + 带修饰键的 Space → null（只拦裸 Space）', () {
      for (final ModifierKey mod in <ModifierKey>[
        ModifierKey.ctrl,
        ModifierKey.shift,
        ModifierKey.alt,
        ModifierKey.meta,
      ]) {
        expect(
          resolveReaderSpaceOverride(
            key: LogicalKeyboardKey.space,
            modifiers: <ModifierKey>{mod},
            hasActiveAudiobook: true,
          ),
          isNull,
        );
      }
    });

    test('非 Space 键 → null（不影响底栏其它键的原义）', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.enter,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });
  });

  group('BUG-204 / TODO-700 T8 源码守卫：底栏退出焦点遍历，裸 Space 仍经正文路径暂停', () {
    final String source = readReaderPageSource();

    test(
        'TODO-700 T8：底栏不再是焦点目标 —— _chromeFocusScope.hasFocus 顶部分支已删，'
        '正文路径仍调用 resolveReaderSpaceOverride 暂停有声书', () {
      // 根因变了：底栏被 ExcludeFocus 排出焦点遍历池（见下方独立守卫），
      // `_chromeFocusScope.hasFocus` 恒为 false，旧的 chrome-focus 顶部分支不可达，
      // 已整段移除（不留死分支）。BUG-204 的行为（裸 Space 暂停有声书）由正文焦点
      // 路径同一个 [resolveReaderSpaceOverride] 闸门保证 —— 焦点恒在正文，Space 直达。
      expect(
        source.contains('if (_chromeFocusScope.hasFocus) {'),
        isFalse,
        reason: 'TODO-700 T8：底栏退出焦点遍历后，_chromeFocusScope.hasFocus 顶部分支'
            '应被删除（不可达死分支），不得保留。',
      );
      // 正文主流程仍有裸 Space → audiobook 覆写（BUG-062/204 共用闸门）。
      expect(
        source.contains('resolveReaderSpaceOverride('),
        isTrue,
        reason: '正文焦点路径必须仍调用 resolveReaderSpaceOverride，否则裸 Space '
            '不再暂停有声书（BUG-204 行为回归）。',
      );
    });

    test('TODO-700 T8：两条底栏都用 ExcludeFocus 退出焦点遍历池', () {
      final String chrome = File(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      ).readAsStringSync();
      // 底栏 ExcludeFocus 外壳已收敛到单一 _wrapBottomChromeBar helper
      //（清理 wave2）：ExcludeFocus 唯一在 helper 内、两条底栏都经它包装。
      // 不变量不变——两条底栏仍都被排出焦点遍历池（TODO-700 T8 根因修复）。
      expect(
        chrome,
        contains('Widget _wrapBottomChromeBar('),
        reason: '底栏（有声书条 + 设置条）的 ExcludeFocus 外壳必须收敛在 '
            '_wrapBottomChromeBar 内 —— TODO-700 T8 根因修复（焦点恒在正文）。',
      );
      // M3E 浮动工具栏（772f479e468）：`_floatingToolbars` 时底部换成另一形态的
      // 浮动底栏 `_buildFloatingBottomChrome`（几何不同，不经 helper），它同样必须
      // 退出焦点遍历池。不变量因此改为：底栏焦点作用域 `_chromeFocusScope` 的
      // **每个**挂载点都被 ExcludeFocus 直接包住，且 ExcludeFocus 只出现在这些
      // 挂载点上（helper + 浮动底栏各一处）。
      final RegExp scopeMount = RegExp(r'node: _chromeFocusScope,');
      final RegExp excludedMount = RegExp(
        r'ExcludeFocus\(\s*child: FocusScope\(\s*node: _chromeFocusScope,',
      );
      expect(scopeMount.allMatches(chrome).length, 2);
      expect(
        excludedMount.allMatches(chrome).length,
        scopeMount.allMatches(chrome).length,
        reason: '每个 _chromeFocusScope 挂载点（helper 底栏 + 浮动底栏）都必须'
            '直接包在 ExcludeFocus 里，否则那条底栏重新进入焦点遍历池。',
      );
      expect(RegExp(r'ExcludeFocus\(').allMatches(chrome).length, 2);
      expect(
        chrome,
        contains('if (_floatingToolbars) return _buildFloatingBottomChrome();'),
      );
      expect(
        RegExp(r'_wrapBottomChromeBar\(').allMatches(chrome).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('未回退裸空格中和：全局导航仍中和裸空格，且仅在非文本输入时（BUG-962 门控）', () {
      final String nav = File(
        'lib/src/shortcuts/global_navigation.dart',
      ).readAsStringSync();
      // 裸空格中和（c152fcd91 用户裁定的正确全局行为）不得回退。实现已从无条件
      // SingleActivator→DoNothingIntent 重构为 _neutralizeBareSpace（BUG-962）：既守
      // 中和仍在，也守它按 focusedEditableText 门控——文本框聚焦时放行，否则重命名等
      // 输入框打不出空格。两条不变量任一被回退即视为回归。
      expect(
        nav,
        contains('KeyEventResult _neutralizeBareSpace('),
        reason: '裸空格中和不得回退：必须保留 _neutralizeBareSpace 中和裸空格按下沿，'
            'BUG-204 的暂停行为靠正文路径的 resolveReaderSpaceOverride，不靠回退中和。',
      );
      expect(
        nav,
        contains('focusedEditableText() != null'),
        reason: 'BUG-962 门控不得回退：裸空格中和必须放行文本框（focusedEditableText '
            '非空时不消费），否则重命名等输入框打不出空格（只有屏幕键盘 IME 能绕过）。',
      );
    });
  });
}

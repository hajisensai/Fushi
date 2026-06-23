import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

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
        'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
      ).readAsStringSync();
      // 有声书条 + 设置条各一个 ExcludeFocus 包住 _chromeFocusScope。
      expect(
        RegExp(r'ExcludeFocus\(').allMatches(chrome).length,
        greaterThanOrEqualTo(2),
        reason: '底栏（有声书条 + 设置条）必须各被 ExcludeFocus 包住，把控件排出焦点'
            '遍历池 —— 这是 TODO-700 T8 的根因修复（焦点恒在正文）。',
      );
    });

    test('未回退裸空格中和：全局导航仍把 SingleActivator(space) 中和', () {
      final String nav = File(
        'lib/src/shortcuts/global_navigation.dart',
      ).readAsStringSync();
      expect(
        nav,
        contains(
            'const SingleActivator(LogicalKeyboardKey.space): const DoNothingIntent()'),
        reason: '裸空格中和（c152fcd91 用户裁定的正确全局行为）不得回退；'
            'BUG-204 的暂停行为靠正文路径的 resolveReaderSpaceOverride，不靠回退中和。',
      );
    });
  });
}

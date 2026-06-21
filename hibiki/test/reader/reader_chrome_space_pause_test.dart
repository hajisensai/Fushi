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

  group('BUG-204 源码守卫：chrome-focus 分支把 Space 路由到 audiobook 覆写', () {
    final String source = readReaderPageSource();

    String chromeBranch() {
      const String start = 'if (_chromeFocusScope.hasFocus) {';
      final int startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative,
          reason: '缺 _chromeFocusScope.hasFocus 分支');
      // 分支以最后一条 `return KeyEventResult.ignored;` + 收尾 `}` 结束，取到
      // 这之后的下一段（gamepad A）起点即可覆盖整个分支体。
      const String end = 'final KeyEventResult? gamepadAResult =';
      final int endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative, reason: '缺 chrome 分支结尾锚点');
      return source.substring(startIndex, endIndex);
    }

    test('chrome 分支内调用 resolveReaderSpaceOverride 并执行其结果', () {
      final String branch = chromeBranch();
      expect(
        branch,
        contains('resolveReaderSpaceOverride('),
        reason: '底栏焦点下裸 Space 必须路由到有声书播放/暂停覆写，'
            '否则被吞成 ignored、冒泡到全局被中和（BUG-204）。',
      );
      expect(
        branch,
        contains('_executeShortcutAction('),
        reason: '解析出的 Space 覆写动作必须在 chrome 分支内执行。',
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
            'BUG-204 只是补底栏焦点路径漏接的有声书 Space 覆写。',
      );
    });
  });
}

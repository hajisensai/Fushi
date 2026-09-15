import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 阅读统计计时的停 / 续此前只有指针入口（状态行 / 播放条内联读数里那颗
/// `ReaderStudyClockButton`）：键盘 / 手柄用户中途离开得先唤出底栏再找按钮。
/// `readerToggleStudyClock` 把它做成 reader scope 的可改键动作（默认 P），执行体
/// 与那颗按钮同一入口 `_toggleStudyClockManualPause`。
void main() {
  group('readerToggleStudyClock', () {
    test('lives in the reader scope', () {
      expect(ShortcutAction.readerToggleStudyClock.scope, ShortcutScope.reader);
    });

    test('default-binds keyboard P on every platform, no gamepad', () {
      for (final TargetPlatform p in const <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            p)[ShortcutAction.readerToggleStudyClock]!;
        expect(
          set.keyboardBindings,
          contains(const InputBinding(key: LogicalKeyboardKey.keyP)),
          reason: 'P on $p',
        );
        expect(set.gamepadBindings, isEmpty,
            reason: 'no gamepad default on $p');
      }
    });

    test('registry resolves P to readerToggleStudyClock in the reader scope',
        () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyP,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.reader,
        ),
        ShortcutAction.readerToggleStudyClock,
      );
    });

    test('no other reader co-active action shadows P', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      const InputBinding plainP = InputBinding(key: LogicalKeyboardKey.keyP);
      for (final ShortcutScope scope in ShortcutScope.reader.coactiveScopes) {
        for (final ShortcutAction action
            in ShortcutAction.actionsForScope(scope)) {
          if (action == ShortcutAction.readerToggleStudyClock) continue;
          expect(
            defaults[action]!.keyboardBindings.map((b) => b.serialize()),
            isNot(contains(plainP.serialize())),
            reason: '${action.key} also binds P — would shadow '
                'readerToggleStudyClock',
          );
        }
      }
    });

    test(
        'reader page dispatches it to the same manual-pause entry as the '
        'status-row clock button', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/caret.part.dart',
      ).readAsStringSync();
      final RegExpMatch? m = RegExp(
        r'case ShortcutAction\.readerToggleStudyClock:[\s\S]*?'
        r'return KeyEventResult\.handled;',
      ).firstMatch(src);
      expect(m, isNotNull,
          reason: 'caret.part.dart must dispatch readerToggleStudyClock');
      expect(
        m!.group(0),
        contains('_toggleStudyClockManualPause();'),
        reason: 'the shortcut must share the button entry so stop / resume '
            'semantics (settle segment, re-anchor tick) stay in one place',
      );
      // 纯状态切换：不得像开面板动作那样先关词典弹窗再执行。
      expect(m.group(0), isNot(contains('clearDictionaryResult')));
    });
  });
}

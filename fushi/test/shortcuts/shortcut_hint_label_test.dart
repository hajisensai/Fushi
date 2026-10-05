import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

// BUG-2960：阅读器工具栏 / 溢出菜单的快捷键后缀显示了持久化 token
// （`导航 · Ctrl+KeyF`），且在 Android 平板（触屏）上也挂。

void main() {
  final List<InputBinding> ctrlF = <InputBinding>[
    InputBinding(
      key: LogicalKeyboardKey.keyF,
      modifiers: const {ModifierKey.ctrl},
    ),
  ];

  test('desktop appends the human-readable key', () {
    expect(
      labelWithShortcutHint('Navigation', ctrlF, keyboardHints: true),
      'Navigation · Ctrl+F',
    );
  });

  test('touch platforms show the bare label', () {
    expect(
      labelWithShortcutHint('Navigation', ctrlF, keyboardHints: false),
      'Navigation',
    );
  });

  test('unbound action shows the bare label', () {
    expect(
      labelWithShortcutHint(
        'Navigation',
        const <InputBinding>[],
        keyboardHints: true,
      ),
      'Navigation',
    );
  });
}

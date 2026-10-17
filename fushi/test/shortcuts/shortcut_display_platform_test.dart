import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

// BUG-3203：快捷键显示的统一入口按平台出修饰键名。macOS（及 iPad）显示键帽上
// 印的 ⌃ ⌥ ⇧ ⌘、按 HIG 顺序排、不加 `+`；其它平台保持 Ctrl+Shift+Alt+Meta。
// 持久化 token（serialize / ModifierKey.label）与平台无关、不得跟着变。
void main() {
  const InputBinding ctrlAltD = InputBinding(
    key: LogicalKeyboardKey.keyD,
    modifiers: <ModifierKey>{ModifierKey.alt, ModifierKey.ctrl},
  );
  const InputBinding allMods = InputBinding(
    key: LogicalKeyboardKey.keyF,
    modifiers: <ModifierKey>{
      ModifierKey.meta,
      ModifierKey.shift,
      ModifierKey.alt,
      ModifierKey.ctrl,
    },
  );

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS shows Apple modifier symbols in HIG order', () {
    expect(ctrlAltD.displayPartsOn(TargetPlatform.macOS), <String>[
      '⌃',
      '⌥',
      'D',
    ]);
    expect(allMods.displayPartsOn(TargetPlatform.macOS), <String>[
      '⌃',
      '⌥',
      '⇧',
      '⌘',
      'F',
    ]);
    expect(allMods.displayPartsOn(TargetPlatform.iOS).first, '⌃');
  });

  test('other platforms keep the Ctrl+Shift+Alt+Meta text form', () {
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.android,
    ]) {
      expect(ctrlAltD.displayPartsOn(p), <String>['Ctrl', 'Alt', 'D']);
      expect(allMods.displayPartsOn(p), <String>[
        'Ctrl',
        'Shift',
        'Alt',
        'Meta',
        'F',
      ]);
    }
  });

  test('displayLabel / tooltip / wheel label follow the display platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(ctrlAltD.displayLabel, '⌃⌥D');
    expect(
      tooltipWithShortcutHint('Lookup', const <InputBinding>[
        ctrlAltD,
      ], keyboardHints: true),
      'Lookup (⌃⌥D)',
    );
    const WheelBinding wheel = WheelBinding(
      WheelDirection.down,
      modifiers: <ModifierKey>{ModifierKey.alt},
    );
    expect(wheel.displayLabel, '⌥WheelDown');
    expect(wheel.label.startsWith('⌥ '), isTrue, reason: wheel.label);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(ctrlAltD.displayLabel, 'Ctrl+Alt+D');
    expect(wheel.displayLabel, 'Alt+WheelDown');
    expect(wheel.label.startsWith('Alt+'), isTrue, reason: wheel.label);
  });

  test('persistence tokens stay platform independent', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(ctrlAltD.serialize(), 'Ctrl+Alt+KeyD');
    expect(InputBinding.deserialize(ctrlAltD.serialize()), ctrlAltD);
    expect(ModifierKey.meta.label, 'Meta');
  });
}

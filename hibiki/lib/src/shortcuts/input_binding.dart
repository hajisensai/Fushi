import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ModifierKey {
  ctrl,
  shift,
  alt,
  meta;

  static ModifierKey? fromKeyboardKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.control) {
      return ctrl;
    }
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.shift) {
      return shift;
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.alt) {
      return alt;
    }
    if (key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.meta) {
      return meta;
    }
    return null;
  }

  String get label {
    switch (this) {
      case ctrl:
        return 'Ctrl';
      case shift:
        return 'Shift';
      case alt:
        return 'Alt';
      case meta:
        return 'Meta';
    }
  }

  static ModifierKey? fromLabel(String label) {
    for (final mod in values) {
      if (mod.label == label) return mod;
    }
    return null;
  }
}

@immutable
class InputBinding {
  const InputBinding({
    required this.key,
    this.modifiers = const {},
  });

  final LogicalKeyboardKey key;
  final Set<ModifierKey> modifiers;

  static final Map<String, LogicalKeyboardKey> _keyByLabel = () {
    final map = <String, LogicalKeyboardKey>{};
    for (final entry in _knownKeys.entries) {
      map[entry.value] = entry.key;
    }
    return map;
  }();

  // Cannot use const here: LogicalKeyboardKey lacks primitive equality required
  // for const Map keys (dart2js / CFE restriction).
  static final Map<LogicalKeyboardKey, String> _knownKeys = {
    LogicalKeyboardKey.space: 'Space',
    LogicalKeyboardKey.escape: 'Escape',
    LogicalKeyboardKey.pageUp: 'PageUp',
    LogicalKeyboardKey.pageDown: 'PageDown',
    LogicalKeyboardKey.arrowUp: 'ArrowUp',
    LogicalKeyboardKey.arrowDown: 'ArrowDown',
    LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
    LogicalKeyboardKey.arrowRight: 'ArrowRight',
    LogicalKeyboardKey.enter: 'Enter',
    LogicalKeyboardKey.tab: 'Tab',
    LogicalKeyboardKey.backspace: 'Backspace',
    LogicalKeyboardKey.delete: 'Delete',
    LogicalKeyboardKey.home: 'Home',
    LogicalKeyboardKey.end: 'End',
    LogicalKeyboardKey.f1: 'F1',
    LogicalKeyboardKey.f2: 'F2',
    LogicalKeyboardKey.f3: 'F3',
    LogicalKeyboardKey.f4: 'F4',
    LogicalKeyboardKey.f5: 'F5',
    LogicalKeyboardKey.f6: 'F6',
    LogicalKeyboardKey.f7: 'F7',
    LogicalKeyboardKey.f8: 'F8',
    LogicalKeyboardKey.f9: 'F9',
    LogicalKeyboardKey.f10: 'F10',
    LogicalKeyboardKey.f11: 'F11',
    LogicalKeyboardKey.f12: 'F12',
    LogicalKeyboardKey.digit0: 'Digit0',
    LogicalKeyboardKey.digit1: 'Digit1',
    LogicalKeyboardKey.digit2: 'Digit2',
    LogicalKeyboardKey.digit3: 'Digit3',
    LogicalKeyboardKey.digit4: 'Digit4',
    LogicalKeyboardKey.digit5: 'Digit5',
    LogicalKeyboardKey.digit6: 'Digit6',
    LogicalKeyboardKey.digit7: 'Digit7',
    LogicalKeyboardKey.digit8: 'Digit8',
    LogicalKeyboardKey.digit9: 'Digit9',
    LogicalKeyboardKey.keyA: 'KeyA',
    LogicalKeyboardKey.keyB: 'KeyB',
    LogicalKeyboardKey.keyC: 'KeyC',
    LogicalKeyboardKey.keyD: 'KeyD',
    LogicalKeyboardKey.keyE: 'KeyE',
    LogicalKeyboardKey.keyF: 'KeyF',
    LogicalKeyboardKey.keyG: 'KeyG',
    LogicalKeyboardKey.keyH: 'KeyH',
    LogicalKeyboardKey.keyI: 'KeyI',
    LogicalKeyboardKey.keyJ: 'KeyJ',
    LogicalKeyboardKey.keyK: 'KeyK',
    LogicalKeyboardKey.keyL: 'KeyL',
    LogicalKeyboardKey.keyM: 'KeyM',
    LogicalKeyboardKey.keyN: 'KeyN',
    LogicalKeyboardKey.keyO: 'KeyO',
    LogicalKeyboardKey.keyP: 'KeyP',
    LogicalKeyboardKey.keyQ: 'KeyQ',
    LogicalKeyboardKey.keyR: 'KeyR',
    LogicalKeyboardKey.keyS: 'KeyS',
    LogicalKeyboardKey.keyT: 'KeyT',
    LogicalKeyboardKey.keyU: 'KeyU',
    LogicalKeyboardKey.keyV: 'KeyV',
    LogicalKeyboardKey.keyW: 'KeyW',
    LogicalKeyboardKey.keyX: 'KeyX',
    LogicalKeyboardKey.keyY: 'KeyY',
    LogicalKeyboardKey.keyZ: 'KeyZ',
    LogicalKeyboardKey.bracketLeft: 'BracketLeft',
    LogicalKeyboardKey.bracketRight: 'BracketRight',
    LogicalKeyboardKey.minus: 'Minus',
    LogicalKeyboardKey.equal: 'Equal',
    LogicalKeyboardKey.comma: 'Comma',
    LogicalKeyboardKey.period: 'Period',
    LogicalKeyboardKey.slash: 'Slash',
    LogicalKeyboardKey.semicolon: 'Semicolon',
    LogicalKeyboardKey.backquote: 'Backquote',
    LogicalKeyboardKey.gameButtonA: 'GameA',
    LogicalKeyboardKey.gameButtonB: 'GameB',
    LogicalKeyboardKey.gameButtonX: 'GameX',
    LogicalKeyboardKey.gameButtonY: 'GameY',
    LogicalKeyboardKey.gameButtonLeft1: 'GameLB',
    LogicalKeyboardKey.gameButtonRight1: 'GameRB',
    LogicalKeyboardKey.gameButtonLeft2: 'GameLT',
    LogicalKeyboardKey.gameButtonRight2: 'GameRT',
    LogicalKeyboardKey.gameButtonThumbLeft: 'GameL3',
    LogicalKeyboardKey.gameButtonThumbRight: 'GameR3',
    LogicalKeyboardKey.gameButtonStart: 'GameStart',
    LogicalKeyboardKey.gameButtonSelect: 'GameSelect',
    LogicalKeyboardKey.gameButtonMode: 'GameMode',
  };

  String _keyLabel(LogicalKeyboardKey k) => _knownKeys[k] ?? k.keyLabel;

  String serialize() {
    final sortedMods = modifiers.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final parts = <String>[
      ...sortedMods.map((m) => m.label),
      _keyLabel(key),
    ];
    return parts.join('+');
  }

  static InputBinding? deserialize(String s) {
    if (s.isEmpty) return null;
    final parts = s.split('+');
    final mods = <ModifierKey>{};
    String? keyPart;
    for (final part in parts) {
      final mod = ModifierKey.fromLabel(part);
      if (mod != null) {
        mods.add(mod);
      } else {
        keyPart = (keyPart == null) ? part : '$keyPart+$part';
      }
    }
    if (keyPart == null) return null;
    final key = _keyByLabel[keyPart];
    if (key == null) return null;
    return InputBinding(key: key, modifiers: mods);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InputBinding &&
          key == other.key &&
          setEquals(modifiers, other.modifiers);

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(modifiers));

  @override
  String toString() => 'InputBinding(${serialize()})';
}

enum GamepadButton {
  a('A'),
  b('B'),
  x('X'),
  y('Y'),
  lb('LB'),
  rb('RB'),
  lt('LT'),
  rt('RT'),
  dpadUp('DpadUp'),
  dpadDown('DpadDown'),
  dpadLeft('DpadLeft'),
  dpadRight('DpadRight'),
  thumbLeft('L3'),
  thumbRight('R3'),
  start('Start'),
  select('Select'),
  mode('Mode');

  const GamepadButton(this.label);
  final String label;

  // D-Pad buttons share LogicalKeyboardKey with the arrow keys, so this reverse
  // map intentionally includes them. Resolution is sequential (keyboard first,
  // gamepad fallback), so a keyboard arrow binding always wins over a D-Pad
  // gamepad binding for the same key — no ambiguity. Including D-Pad here is
  // what makes a standalone D-Pad gamepad binding actually resolve.
  static final Map<LogicalKeyboardKey, GamepadButton> _byLogicalKey = {
    for (final b in values) b.logicalKey: b,
  };

  static GamepadButton? fromLogicalKey(LogicalKeyboardKey key) =>
      _byLogicalKey[key];

  static GamepadButton? fromLabel(String label) {
    for (final button in values) {
      if (button.label == label) return button;
    }
    return null;
  }

  LogicalKeyboardKey get logicalKey {
    switch (this) {
      case a:
        return LogicalKeyboardKey.gameButtonA;
      case b:
        return LogicalKeyboardKey.gameButtonB;
      case x:
        return LogicalKeyboardKey.gameButtonX;
      case y:
        return LogicalKeyboardKey.gameButtonY;
      case lb:
        return LogicalKeyboardKey.gameButtonLeft1;
      case rb:
        return LogicalKeyboardKey.gameButtonRight1;
      case lt:
        return LogicalKeyboardKey.gameButtonLeft2;
      case rt:
        return LogicalKeyboardKey.gameButtonRight2;
      case dpadUp:
        return LogicalKeyboardKey.arrowUp;
      case dpadDown:
        return LogicalKeyboardKey.arrowDown;
      case dpadLeft:
        return LogicalKeyboardKey.arrowLeft;
      case dpadRight:
        return LogicalKeyboardKey.arrowRight;
      case thumbLeft:
        return LogicalKeyboardKey.gameButtonThumbLeft;
      case thumbRight:
        return LogicalKeyboardKey.gameButtonThumbRight;
      case start:
        return LogicalKeyboardKey.gameButtonStart;
      case select:
        return LogicalKeyboardKey.gameButtonSelect;
      case mode:
        return LogicalKeyboardKey.gameButtonMode;
    }
  }
}

@immutable
class GamepadBinding {
  const GamepadBinding(this.button);
  final GamepadButton button;

  String serialize() => button.label;

  static GamepadBinding? deserialize(String s) {
    final button = GamepadButton.fromLabel(s);
    return button != null ? GamepadBinding(button) : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GamepadBinding && button == other.button;

  @override
  int get hashCode => button.hashCode;
}

@immutable
class ShortcutBindingSet {
  const ShortcutBindingSet({
    this.keyboardBindings = const [],
    this.gamepadBindings = const [],
  });

  final List<InputBinding> keyboardBindings;
  final List<GamepadBinding> gamepadBindings;

  Map<String, dynamic> toJson() => {
        'keyboard':
            keyboardBindings.map((b) => b.serialize()).toList(growable: false),
        'gamepad':
            gamepadBindings.map((b) => b.serialize()).toList(growable: false),
      };

  factory ShortcutBindingSet.fromJson(Map<String, dynamic> json) {
    final kbRaw = json['keyboard'];
    final gpRaw = json['gamepad'];
    return ShortcutBindingSet(
      keyboardBindings: kbRaw is List
          ? kbRaw
              .cast<String>()
              .map(InputBinding.deserialize)
              .whereType<InputBinding>()
              .toList(growable: false)
          : const [],
      gamepadBindings: gpRaw is List
          ? gpRaw
              .cast<String>()
              .map(GamepadBinding.deserialize)
              .whereType<GamepadBinding>()
              .toList(growable: false)
          : const [],
    );
  }

  ShortcutBindingSet copyWith({
    List<InputBinding>? keyboardBindings,
    List<GamepadBinding>? gamepadBindings,
  }) =>
      ShortcutBindingSet(
        keyboardBindings: keyboardBindings ?? this.keyboardBindings,
        gamepadBindings: gamepadBindings ?? this.gamepadBindings,
      );
}

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
    LogicalKeyboardKey.mediaPlay: 'MediaPlay',
    LogicalKeyboardKey.mediaPause: 'MediaPause',
    LogicalKeyboardKey.mediaPlayPause: 'MediaPlayPause',
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

  // TODO-847 / BUG: Windows 微软 IME 激活时，Flutter 引擎把 KeyDownEvent 的
  // logicalKey 改写成 LogicalKeyboardKey.process（输入法占用），导致 [==] 精确相等
  // 永远失败、全表面快捷键失效。physicalKey（USB HID 扫描码）不受 IME 改写影响，
  // 故 [HibikiShortcutRegistry.resolveKeyboard] 仅在 key==process 时启用 physical
  // 回退。这里把每个 binding 的逻辑键映射到对应物理键，供回退分支按物理键比对。
  //
  // 覆盖与 [_knownKeys] 相同的非 game* 键集；缺键会让该键在 IME 下仍然失效，由
  // input_binding_test 的 `_knownKeys⊇` 守卫防漏。
  //
  // 已知限制：physical↔logical 一一对应仅在 US-QWERTY 物理布局下成立。非美式物理
  // 键盘（如 AZERTY/德语 QWERTZ）上字母/符号键的物理位与逻辑键不一致，回退可能错绑
  // 到相邻键。因为回退仅在 key==process（IME 激活，本就全失效）时启用，所以最坏只
  // 是“按某键触发了另一个快捷键”，不会比现状（全部失效）更糟；标记为 known
  // limitation 而非根治，待引擎提供 IME 下稳定的逻辑键时清理。
  //
  // 不能用 const：PhysicalKeyboardKey/LogicalKeyboardKey 缺少 const Map key 所需的
  // primitive equality（同 [_knownKeys] 的 CFE 限制）。
  static final Map<LogicalKeyboardKey, PhysicalKeyboardKey> _logicalToPhysical =
      {
    LogicalKeyboardKey.space: PhysicalKeyboardKey.space,
    LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
    LogicalKeyboardKey.pageUp: PhysicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown: PhysicalKeyboardKey.pageDown,
    LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter: PhysicalKeyboardKey.enter,
    LogicalKeyboardKey.tab: PhysicalKeyboardKey.tab,
    LogicalKeyboardKey.backspace: PhysicalKeyboardKey.backspace,
    LogicalKeyboardKey.mediaPlay: PhysicalKeyboardKey.mediaPlay,
    LogicalKeyboardKey.mediaPause: PhysicalKeyboardKey.mediaPause,
    LogicalKeyboardKey.mediaPlayPause: PhysicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.delete: PhysicalKeyboardKey.delete,
    LogicalKeyboardKey.home: PhysicalKeyboardKey.home,
    LogicalKeyboardKey.end: PhysicalKeyboardKey.end,
    LogicalKeyboardKey.f1: PhysicalKeyboardKey.f1,
    LogicalKeyboardKey.f2: PhysicalKeyboardKey.f2,
    LogicalKeyboardKey.f3: PhysicalKeyboardKey.f3,
    LogicalKeyboardKey.f4: PhysicalKeyboardKey.f4,
    LogicalKeyboardKey.f5: PhysicalKeyboardKey.f5,
    LogicalKeyboardKey.f6: PhysicalKeyboardKey.f6,
    LogicalKeyboardKey.f7: PhysicalKeyboardKey.f7,
    LogicalKeyboardKey.f8: PhysicalKeyboardKey.f8,
    LogicalKeyboardKey.f9: PhysicalKeyboardKey.f9,
    LogicalKeyboardKey.f10: PhysicalKeyboardKey.f10,
    LogicalKeyboardKey.f11: PhysicalKeyboardKey.f11,
    LogicalKeyboardKey.f12: PhysicalKeyboardKey.f12,
    LogicalKeyboardKey.digit0: PhysicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1: PhysicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2: PhysicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3: PhysicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4: PhysicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5: PhysicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6: PhysicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7: PhysicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8: PhysicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9: PhysicalKeyboardKey.digit9,
    LogicalKeyboardKey.keyA: PhysicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyB: PhysicalKeyboardKey.keyB,
    LogicalKeyboardKey.keyC: PhysicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyD: PhysicalKeyboardKey.keyD,
    LogicalKeyboardKey.keyE: PhysicalKeyboardKey.keyE,
    LogicalKeyboardKey.keyF: PhysicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyG: PhysicalKeyboardKey.keyG,
    LogicalKeyboardKey.keyH: PhysicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyI: PhysicalKeyboardKey.keyI,
    LogicalKeyboardKey.keyJ: PhysicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyK: PhysicalKeyboardKey.keyK,
    LogicalKeyboardKey.keyL: PhysicalKeyboardKey.keyL,
    LogicalKeyboardKey.keyM: PhysicalKeyboardKey.keyM,
    LogicalKeyboardKey.keyN: PhysicalKeyboardKey.keyN,
    LogicalKeyboardKey.keyO: PhysicalKeyboardKey.keyO,
    LogicalKeyboardKey.keyP: PhysicalKeyboardKey.keyP,
    LogicalKeyboardKey.keyQ: PhysicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyR: PhysicalKeyboardKey.keyR,
    LogicalKeyboardKey.keyS: PhysicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyT: PhysicalKeyboardKey.keyT,
    LogicalKeyboardKey.keyU: PhysicalKeyboardKey.keyU,
    LogicalKeyboardKey.keyV: PhysicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyW: PhysicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyX: PhysicalKeyboardKey.keyX,
    LogicalKeyboardKey.keyY: PhysicalKeyboardKey.keyY,
    LogicalKeyboardKey.keyZ: PhysicalKeyboardKey.keyZ,
    LogicalKeyboardKey.bracketLeft: PhysicalKeyboardKey.bracketLeft,
    LogicalKeyboardKey.bracketRight: PhysicalKeyboardKey.bracketRight,
    LogicalKeyboardKey.minus: PhysicalKeyboardKey.minus,
    LogicalKeyboardKey.equal: PhysicalKeyboardKey.equal,
    LogicalKeyboardKey.comma: PhysicalKeyboardKey.comma,
    LogicalKeyboardKey.period: PhysicalKeyboardKey.period,
    LogicalKeyboardKey.slash: PhysicalKeyboardKey.slash,
    LogicalKeyboardKey.semicolon: PhysicalKeyboardKey.semicolon,
    LogicalKeyboardKey.backquote: PhysicalKeyboardKey.backquote,
  };

  /// 本 binding 逻辑键对应的物理键（USB HID 扫描码）；不在覆盖表内（如 game* 键、
  /// numpad、F13+）返回 null。仅供 IME 改写 logicalKey 时的物理键回退使用，绝不进入
  /// [==] / [hashCode] / [serialize]（保持 Set 去重、冲突检测、JSON 兼容不变）。
  PhysicalKeyboardKey? get physicalKey => _logicalToPhysical[key];

  List<String> get _sortedModifierLabels =>
      (modifiers.toList()..sort((a, b) => a.index.compareTo(b.index)))
          .map((m) => m.label)
          .toList(growable: false);

  // Persistence token for the key part. Known keys keep their human-readable
  // label (keeps existing JSON valid and readable); any other key falls back to
  // its stable keyId behind a '#' sentinel so it survives a save/reload round
  // trip instead of being silently dropped on the next launch.
  String _keyToken(LogicalKeyboardKey k) => _knownKeys[k] ?? '#${k.keyId}';

  // Human-readable label for the key part, used only for display in the UI.
  String _keyLabel(LogicalKeyboardKey k) => _knownKeys[k] ?? k.keyLabel;

  String serialize() => <String>[
        ..._sortedModifierLabels,
        _keyToken(key),
      ].join('+');

  String get displayLabel => <String>[
        ..._sortedModifierLabels,
        _keyLabel(key),
      ].join('+');

  /// Flutter [SingleActivator] for this binding, so a registry binding can be
  /// installed into widgets that take a `Map<ShortcutActivator, VoidCallback>`
  /// (e.g. media_kit's `keyboardShortcuts`). [includeRepeats] is exposed so the
  /// video player can keep its press-edge-only keys (e.g. subtitle blur toggle)
  /// non-repeating while everything else honours OS key-repeat.
  SingleActivator toActivator({bool includeRepeats = true}) => SingleActivator(
        key,
        control: modifiers.contains(ModifierKey.ctrl),
        shift: modifiers.contains(ModifierKey.shift),
        alt: modifiers.contains(ModifierKey.alt),
        meta: modifiers.contains(ModifierKey.meta),
        includeRepeats: includeRepeats,
      );

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
    final key = _resolveKeyToken(keyPart);
    if (key == null) return null;
    return InputBinding(key: key, modifiers: mods);
  }

  static LogicalKeyboardKey? _resolveKeyToken(String token) {
    if (token.startsWith('#')) {
      final id = int.tryParse(token.substring(1));
      return id == null ? null : LogicalKeyboardKey(id);
    }
    return _keyByLabel[token];
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

  bool get isDpad {
    switch (this) {
      case dpadUp:
      case dpadDown:
      case dpadLeft:
      case dpadRight:
        return true;
      default:
        return false;
    }
  }

  // D-Pad buttons share LogicalKeyboardKey with keyboard arrows, so raw key
  // event handling must use [fromKeyEvent] instead of this helper. This map is
  // still useful for persistence, labels, and tests that explicitly translate a
  // logical gamepad key.
  static final Map<LogicalKeyboardKey, GamepadButton> _byLogicalKey = {
    for (final b in values) b.logicalKey: b,
  };

  static GamepadButton? fromLogicalKey(LogicalKeyboardKey key) =>
      _byLogicalKey[key];

  static bool isGamepadLikeDevice(ui.KeyEventDeviceType deviceType) {
    switch (deviceType) {
      case ui.KeyEventDeviceType.directionalPad:
      case ui.KeyEventDeviceType.gamepad:
      case ui.KeyEventDeviceType.joystick:
        return true;
      case ui.KeyEventDeviceType.keyboard:
      case ui.KeyEventDeviceType.hdmi:
        return false;
    }
  }

  /// Converts a Flutter key event into a gamepad button only when the event
  /// source really is a controller-like device. The exception is Flutter's
  /// `gameButton*` logical keys: those are gamepad-only keys and older tests /
  /// engines may still label them as keyboard events.
  static GamepadButton? fromKeyEvent(KeyEvent event) {
    final GamepadButton? button = fromLogicalKey(event.logicalKey);
    if (button == null) return null;
    if (!button.isDpad) return button;
    return isGamepadLikeDevice(event.deviceType) ? button : null;
  }

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
class MouseBinding {
  const MouseBinding(this.button);

  /// DOM `MouseEvent.button`: 1=middle, 2=right, 3=back, 4=forward.
  final int button;

  static const Map<int, String> _knownButtons = {
    1: 'MouseMiddle',
    2: 'MouseRight',
    3: 'MouseBack',
    4: 'MouseForward',
  };

  String serialize() => _knownButtons[button] ?? 'Mouse$button';

  static MouseBinding? deserialize(String s) {
    for (final entry in _knownButtons.entries) {
      if (entry.value == s) return MouseBinding(entry.key);
    }
    if (s.startsWith('Mouse')) {
      final n = int.tryParse(s.substring(5));
      if (n != null) return MouseBinding(n);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MouseBinding && button == other.button;

  @override
  int get hashCode => button.hashCode;

  @override
  String toString() => 'MouseBinding(${serialize()})';
}

@immutable
class ShortcutBindingSet {
  const ShortcutBindingSet({
    this.keyboardBindings = const [],
    this.gamepadBindings = const [],
    this.mouseBindings = const [],
  });

  final List<InputBinding> keyboardBindings;
  final List<GamepadBinding> gamepadBindings;
  final List<MouseBinding> mouseBindings;

  Map<String, dynamic> toJson() => {
        'keyboard':
            keyboardBindings.map((b) => b.serialize()).toList(growable: false),
        'gamepad':
            gamepadBindings.map((b) => b.serialize()).toList(growable: false),
        'mouse':
            mouseBindings.map((b) => b.serialize()).toList(growable: false),
      };

  factory ShortcutBindingSet.fromJson(Map<String, dynamic> json) {
    final kbRaw = json['keyboard'];
    final gpRaw = json['gamepad'];
    final msRaw = json['mouse'];
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
      mouseBindings: msRaw is List
          ? msRaw
              .cast<String>()
              .map(MouseBinding.deserialize)
              .whereType<MouseBinding>()
              .toList(growable: false)
          : const [],
    );
  }

  ShortcutBindingSet copyWith({
    List<InputBinding>? keyboardBindings,
    List<GamepadBinding>? gamepadBindings,
    List<MouseBinding>? mouseBindings,
  }) =>
      ShortcutBindingSet(
        keyboardBindings: keyboardBindings ?? this.keyboardBindings,
        gamepadBindings: gamepadBindings ?? this.gamepadBindings,
        mouseBindings: mouseBindings ?? this.mouseBindings,
      );
}

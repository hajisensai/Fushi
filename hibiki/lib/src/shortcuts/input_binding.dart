import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show
        kBackMouseButton,
        kForwardMouseButton,
        kMiddleMouseButton,
        kPrimaryMouseButton,
        kSecondaryMouseButton;
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
  // 故 [FushiShortcutRegistry.resolveKeyboard] 仅在 key==process 时启用 physical
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

  /// [_logicalToPhysical] 的反向索引（同一张真相源，不是第二份手写表）。
  ///
  /// 正向表是 1:1 的（每个物理键只被一个逻辑键映射），由
  /// `input_binding_test` 的「反向表与正向表等大」守卫锁死；一旦有人往正向表
  /// 里塞出第二个指向同一物理键的逻辑键，反向表会静默丢一条，守卫直接红。
  static final Map<PhysicalKeyboardKey, LogicalKeyboardKey> _physicalToLogical =
      <PhysicalKeyboardKey, LogicalKeyboardKey>{
    for (final MapEntry<LogicalKeyboardKey, PhysicalKeyboardKey> entry
        in _logicalToPhysical.entries)
      entry.value: entry.key,
  };

  /// 仅供守卫测试比对两表基数用；不参与运行时逻辑。
  @visibleForTesting
  static int get logicalToPhysicalLength => _logicalToPhysical.length;

  /// 同上。
  @visibleForTesting
  static int get physicalToLogicalLength => _physicalToLogical.length;

  /// BUG-1422：把「快捷键录入」拿到的按键归一化成应当持久化的逻辑键。
  ///
  /// Windows 微软 IME 激活时引擎会把按下字母的 [KeyEvent.logicalKey] 改写成
  /// [LogicalKeyboardKey.process]，而 USB-HID 的 [KeyEvent.physicalKey] 不受影响。
  /// 运行时解析（`FushiShortcutRegistry.resolveKeyboard`）早就有这条物理键回退，
  /// **录入侧却直接存 `event.logicalKey`**：于是 IME 下按物理 Z 存进去的是
  /// `Process`（显示成一个没人认识的键，且运行时永远匹配不上），用户看到的就是
  /// 「录不进去 / 录完没反应」。捕获侧与运行时必须共用同一条契约。
  ///
  /// 回退**只在 `logicalKey == process` 时启用**，与运行时判据逐字一致：引擎给出
  /// 真实逻辑键时一律原样返回，非美式布局（AZERTY / QWERTZ）的字母语义不被物理位
  /// 覆盖。表外的物理键（numpad、F13+、game*）保持 `process` 原样返回，由调用方的
  /// 既有流程处理，不猜。
  static LogicalKeyboardKey normalizeCapturedKey({
    required LogicalKeyboardKey logicalKey,
    required PhysicalKeyboardKey physicalKey,
  }) {
    if (logicalKey != LogicalKeyboardKey.process) return logicalKey;
    return _physicalToLogical[physicalKey] ?? logicalKey;
  }

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

/// 把 Flutter 的 [PointerDownEvent.buttons] 位掩码折成 [MouseBinding] / DOM
/// `MouseEvent.button` 用的**单个**按钮号，无法绑定的按下返回 null。
///
/// 左键（[kPrimaryMouseButton]）**故意**不可绑：WebView 运行时的分发在
/// `e.button === 0` 上直接早退（左键是主交互键，绑它会吞掉正常点击 / 划词选区），
/// 所以左键绑定永远不可能触发。多键同按（chord）按 中键(1) → 右键(2) → 后退(3) →
/// 前进(4) 的优先级取第一个非左键。
///
/// 绑定捕获（设置页的按键录制）与运行时分发（查词弹窗表面的 [Listener]）必须用
/// **同一个**折叠规则，否则会出现「设置里录到侧键、运行时却按另一个号去解析」的
/// 错位。故收在这里，两侧共用（TODO-1088 originally, BUG-1269 复诉时提升为共享）。
int? domMouseButtonFromPointerButtons(int buttons) {
  if (buttons & kMiddleMouseButton != 0) return 1;
  if (buttons & kSecondaryMouseButton != 0) return 2;
  if (buttons & kBackMouseButton != 0) return 3;
  if (buttons & kForwardMouseButton != 0) return 4;
  return null; // primary (kPrimaryMouseButton) or unknown → not bindable
}

/// 滚轮方向。滚轮是**离散事件**（没有按下/抬起），故它自成一个绑定通道，而不是
/// 塞进 [MouseBinding] 的按钮编号：按钮绑定按 `MouseEvent.button` 分发（中键/右键/
/// 侧键），滚轮按 `WheelEvent.deltaY` 的符号分发，两者的运行时判据根本不同。
enum WheelDirection {
  /// 向上滚（`deltaY < 0`）。
  up('WheelUp'),

  /// 向下滚（`deltaY > 0`）。
  down('WheelDown');

  const WheelDirection(this.token);

  /// 持久化 / 显示用的稳定 token（与 [InputBinding] 的键名同风格）。
  final String token;

  static WheelDirection? fromToken(String token) {
    for (final WheelDirection d in values) {
      if (d.token == token) return d;
    }
    return null;
  }
}

/// 「修饰键 + 滚轮方向」绑定（Yomitan 式 Alt+滚轮）。裸滚轮永远是滚动内容，故这个
/// 通道**要求至少一个修饰键**才有意义——但数据结构不强制（空修饰集合可序列化往返），
/// 强制留给 UI 的捕获入口，保持数据层纯粹。
@immutable
class WheelBinding {
  const WheelBinding(this.direction, {this.modifiers = const {}});

  final WheelDirection direction;
  final Set<ModifierKey> modifiers;

  List<String> get _sortedModifierLabels =>
      (modifiers.toList()..sort((a, b) => a.index.compareTo(b.index)))
          .map((m) => m.label)
          .toList(growable: false);

  String serialize() => <String>[
        ..._sortedModifierLabels,
        direction.token,
      ].join('+');

  /// 与 [InputBinding.displayLabel] 同形（`Alt+WheelDown`）。本地化显示名在
  /// `shortcut_labels.dart` 的 [WheelBindingLabel] 里（那里把方向换成人话）。
  String get displayLabel => serialize();

  static WheelBinding? deserialize(String s) {
    if (s.isEmpty) return null;
    final List<String> parts = s.split('+');
    final Set<ModifierKey> mods = <ModifierKey>{};
    WheelDirection? direction;
    for (final String part in parts) {
      final ModifierKey? mod = ModifierKey.fromLabel(part);
      if (mod != null) {
        mods.add(mod);
        continue;
      }
      direction ??= WheelDirection.fromToken(part);
    }
    if (direction == null) return null;
    return WheelBinding(direction, modifiers: mods);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WheelBinding &&
          direction == other.direction &&
          setEquals(modifiers, other.modifiers);

  @override
  int get hashCode =>
      Object.hash(direction, Object.hashAllUnordered(modifiers));

  @override
  String toString() => 'WheelBinding(${serialize()})';
}

@immutable
class ShortcutBindingSet {
  const ShortcutBindingSet({
    this.keyboardBindings = const [],
    this.gamepadBindings = const [],
    this.mouseBindings = const [],
    this.wheelBindings = const [],
  });

  final List<InputBinding> keyboardBindings;
  final List<GamepadBinding> gamepadBindings;
  final List<MouseBinding> mouseBindings;

  /// 修饰键 + 滚轮方向（查词弹窗的「上/下一个词条」）。老快照没有这个 key，
  /// [fromJson] 缺席即空表，不影响任何既有绑定（Never break userspace）。
  final List<WheelBinding> wheelBindings;

  Map<String, dynamic> toJson() => {
        'keyboard':
            keyboardBindings.map((b) => b.serialize()).toList(growable: false),
        'gamepad':
            gamepadBindings.map((b) => b.serialize()).toList(growable: false),
        'mouse':
            mouseBindings.map((b) => b.serialize()).toList(growable: false),
        'wheel':
            wheelBindings.map((b) => b.serialize()).toList(growable: false),
      };

  factory ShortcutBindingSet.fromJson(Map<String, dynamic> json) {
    final kbRaw = json['keyboard'];
    final gpRaw = json['gamepad'];
    final msRaw = json['mouse'];
    final whRaw = json['wheel'];
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
      wheelBindings: whRaw is List
          ? whRaw
              .cast<String>()
              .map(WheelBinding.deserialize)
              .whereType<WheelBinding>()
              .toList(growable: false)
          : const [],
    );
  }

  ShortcutBindingSet copyWith({
    List<InputBinding>? keyboardBindings,
    List<GamepadBinding>? gamepadBindings,
    List<MouseBinding>? mouseBindings,
    List<WheelBinding>? wheelBindings,
  }) =>
      ShortcutBindingSet(
        keyboardBindings: keyboardBindings ?? this.keyboardBindings,
        gamepadBindings: gamepadBindings ?? this.gamepadBindings,
        mouseBindings: mouseBindings ?? this.mouseBindings,
        wheelBindings: wheelBindings ?? this.wheelBindings,
      );
}

/// 当前按下的修饰键集合（Ctrl / Shift / Alt / Meta）。
///
/// 所有页面解析键盘绑定前都要拼这个集合，各自重建一份只会漂——阅读器与漫画页
/// 共用本函数，新页面也应直接调它，不要再抄一遍 [HardwareKeyboard] 四连判。
Set<ModifierKey> activeModifierKeys() {
  final Set<ModifierKey> modifiers = <ModifierKey>{};
  if (HardwareKeyboard.instance.isControlPressed) {
    modifiers.add(ModifierKey.ctrl);
  }
  if (HardwareKeyboard.instance.isShiftPressed) {
    modifiers.add(ModifierKey.shift);
  }
  if (HardwareKeyboard.instance.isAltPressed) {
    modifiers.add(ModifierKey.alt);
  }
  if (HardwareKeyboard.instance.isMetaPressed) {
    modifiers.add(ModifierKey.meta);
  }
  return modifiers;
}

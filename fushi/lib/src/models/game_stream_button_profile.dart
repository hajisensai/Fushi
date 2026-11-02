import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/sync/game_stream_client.dart'
    show GameStreamVirtualButton;

/// A physical controller button on the receiving device (a handheld such as
/// the AYN Thor, or a paired gamepad).
///
/// Stored by [name], so values may be added but never renamed.
enum GameStreamPhysicalButton {
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
  a,
  b,
  x,
  y,
  l1,
  r1,
  l2,
  r2,
  l3,
  r3,
  start,
  select;

  bool get isDpad => switch (this) {
    dpadUp || dpadDown || dpadLeft || dpadRight => true,
    _ => false,
  };

  /// Controller face / shoulder / stick / menu button for [key]; null for
  /// every other key. The D-pad is not here: Android reports it as arrow
  /// keys, the same as a keyboard (see [dpadFor]).
  static GameStreamPhysicalButton? gameButtonFor(LogicalKeyboardKey key) =>
      switch (key) {
        LogicalKeyboardKey.gameButtonA => a,
        LogicalKeyboardKey.gameButtonB => b,
        LogicalKeyboardKey.gameButtonX => x,
        LogicalKeyboardKey.gameButtonY => y,
        LogicalKeyboardKey.gameButtonLeft1 => l1,
        LogicalKeyboardKey.gameButtonRight1 => r1,
        LogicalKeyboardKey.gameButtonLeft2 => l2,
        LogicalKeyboardKey.gameButtonRight2 => r2,
        LogicalKeyboardKey.gameButtonThumbLeft => l3,
        LogicalKeyboardKey.gameButtonThumbRight => r3,
        LogicalKeyboardKey.gameButtonStart => start,
        LogicalKeyboardKey.gameButtonSelect => select,
        _ => null,
      };

  /// D-pad direction for an arrow [key]; null for every other key.
  static GameStreamPhysicalButton? dpadFor(LogicalKeyboardKey key) =>
      switch (key) {
        LogicalKeyboardKey.arrowUp => dpadUp,
        LogicalKeyboardKey.arrowDown => dpadDown,
        LogicalKeyboardKey.arrowLeft => dpadLeft,
        LogicalKeyboardKey.arrowRight => dpadRight,
        _ => null,
      };
}

/// Mouse actions a button can perform at the stream cursor.
enum GameStreamMouseAction {
  leftClick,
  rightClick,
  middleClick,
  wheelUp,
  wheelDown;

  bool get isWheel => this == wheelUp || this == wheelDown;

  /// Host pointer button name for a click; null for the wheel.
  String? get pointerButton => switch (this) {
    leftClick => 'left',
    rightClick => 'right',
    middleClick => 'middle',
    wheelUp || wheelDown => null,
  };

  /// Wheel notches (positive is down, as the host expects); 0 for clicks.
  double get wheelNotches => switch (this) {
    wheelUp => -1,
    wheelDown => 1,
    _ => 0,
  };
}

/// Actions handled on the receiver itself instead of being sent to the game.
enum GameStreamReceiverAction { toggleLookupPanel, toggleOnScreenPad }

/// What one physical button does.
///
/// Encoded as a short string (`pad:confirm`, `key:Enter`, `mouse:rightClick`,
/// `app:toggleLookupPanel`, `none`) so the stored profile stays readable.
@immutable
sealed class GameStreamButtonAction {
  const GameStreamButtonAction();

  /// Decodes [raw]; null when it names nothing this build knows (a value
  /// written by a newer build, or a corrupted entry).
  static GameStreamButtonAction? tryParse(Object? raw) {
    if (raw is! String) return null;
    if (raw == GameStreamNoAction.wire) return const GameStreamNoAction();
    final int colon = raw.indexOf(':');
    if (colon <= 0) return null;
    final String kind = raw.substring(0, colon);
    final String value = raw.substring(colon + 1);
    T? byName<T extends Enum>(List<T> values) {
      for (final T item in values) {
        if (item.name == value) return item;
      }
      return null;
    }

    switch (kind) {
      case GameStreamPadAction.prefix:
        final GameStreamVirtualButton? button = byName(
          GameStreamVirtualButton.values,
        );
        return button == null ? null : GameStreamPadAction(button);
      case GameStreamHostKeyAction.prefix:
        return GameStreamHostKeyAction.keys.contains(value)
            ? GameStreamHostKeyAction(value)
            : null;
      case GameStreamMouseButtonAction.prefix:
        final GameStreamMouseAction? mouse = byName(
          GameStreamMouseAction.values,
        );
        return mouse == null ? null : GameStreamMouseButtonAction(mouse);
      case GameStreamAppAction.prefix:
        final GameStreamReceiverAction? action = byName(
          GameStreamReceiverAction.values,
        );
        return action == null ? null : GameStreamAppAction(action);
    }
    return null;
  }

  String toWire();
}

/// Sends the matching on-screen pad button. The host maps it to a key
/// (confirm = Enter, cancel = Escape, L/R = Q/E, …) and, for engines with a
/// native confirm adapter such as SGRE, presses the game's own confirm.
final class GameStreamPadAction extends GameStreamButtonAction {
  const GameStreamPadAction(this.button);

  static const String prefix = 'pad';

  final GameStreamVirtualButton button;

  @override
  String toWire() => '$prefix:${button.name}';

  @override
  bool operator ==(Object other) =>
      other is GameStreamPadAction && other.button == button;

  @override
  int get hashCode => Object.hash(prefix, button);
}

/// Holds a host keyboard key for as long as the button is held.
final class GameStreamHostKeyAction extends GameStreamButtonAction {
  const GameStreamHostKeyAction(this.key);

  static const String prefix = 'key';

  /// Host key names a button may send (runner `ResolveVirtualKey`).
  static final List<String> keys = List<String>.unmodifiable(<String>[
    'Enter',
    'Escape',
    'Space',
    'Control',
    'Shift',
    'Alt',
    'Tab',
    'Backspace',
    'Up',
    'Down',
    'Left',
    'Right',
    for (int code = 65; code <= 90; code++) String.fromCharCode(code),
    for (int digit = 0; digit <= 9; digit++) '$digit',
    for (int number = 1; number <= 12; number++) 'F$number',
  ]);

  final String key;

  @override
  String toWire() => '$prefix:$key';

  @override
  bool operator ==(Object other) =>
      other is GameStreamHostKeyAction && other.key == key;

  @override
  int get hashCode => Object.hash(prefix, key);
}

/// A mouse click or wheel notch at the stream cursor. Needs the host's
/// pointer-button / wheel features (left click works on every host).
final class GameStreamMouseButtonAction extends GameStreamButtonAction {
  const GameStreamMouseButtonAction(this.mouse);

  static const String prefix = 'mouse';

  final GameStreamMouseAction mouse;

  @override
  String toWire() => '$prefix:${mouse.name}';

  @override
  bool operator ==(Object other) =>
      other is GameStreamMouseButtonAction && other.mouse == mouse;

  @override
  int get hashCode => Object.hash(prefix, mouse);
}

/// Runs a receiver action (nothing is sent to the game).
final class GameStreamAppAction extends GameStreamButtonAction {
  const GameStreamAppAction(this.action);

  static const String prefix = 'app';

  final GameStreamReceiverAction action;

  @override
  String toWire() => '$prefix:${action.name}';

  @override
  bool operator ==(Object other) =>
      other is GameStreamAppAction && other.action == action;

  @override
  int get hashCode => Object.hash(prefix, action);
}

/// The button does nothing.
final class GameStreamNoAction extends GameStreamButtonAction {
  const GameStreamNoAction();

  static const String wire = 'none';

  @override
  String toWire() => wire;

  @override
  bool operator ==(Object other) => other is GameStreamNoAction;

  @override
  int get hashCode => wire.hashCode;
}

/// Which action each physical controller button performs while streaming.
///
/// Only the buttons the user changed are stored ([overrides]); the rest
/// follow [defaults], so a better default reaches everyone who did not pick
/// their own. Stored per device: the buttons that exist, and which ones feel
/// natural, depend on the controller in this user's hands.
@immutable
class GameStreamButtonProfile {
  const GameStreamButtonProfile({
    this.overrides = const <GameStreamPhysicalButton, GameStreamButtonAction>{},
  });

  /// Decodes a stored value. Unknown buttons or actions are dropped, so a
  /// value written by a newer build keeps the entries this build understands.
  factory GameStreamButtonProfile.fromJson(Object? json) {
    if (json is! Map) return const GameStreamButtonProfile();
    final Map<GameStreamPhysicalButton, GameStreamButtonAction> overrides =
        <GameStreamPhysicalButton, GameStreamButtonAction>{};
    for (final GameStreamPhysicalButton button
        in GameStreamPhysicalButton.values) {
      final GameStreamButtonAction? action = GameStreamButtonAction.tryParse(
        json[button.name],
      );
      if (action != null && action != defaults[button]) {
        overrides[button] = action;
      }
    }
    return GameStreamButtonProfile(overrides: Map.unmodifiable(overrides));
  }

  /// Buttons that already worked before profiles existed keep doing what
  /// they did (the pad mapping, so SGRE's native confirm still applies); the
  /// rest get common visual-novel controls.
  static const Map<GameStreamPhysicalButton, GameStreamButtonAction> defaults =
      <GameStreamPhysicalButton, GameStreamButtonAction>{
        GameStreamPhysicalButton.dpadUp: GameStreamPadAction(
          GameStreamVirtualButton.up,
        ),
        GameStreamPhysicalButton.dpadDown: GameStreamPadAction(
          GameStreamVirtualButton.down,
        ),
        GameStreamPhysicalButton.dpadLeft: GameStreamPadAction(
          GameStreamVirtualButton.left,
        ),
        GameStreamPhysicalButton.dpadRight: GameStreamPadAction(
          GameStreamVirtualButton.right,
        ),
        GameStreamPhysicalButton.a: GameStreamPadAction(
          GameStreamVirtualButton.confirm,
        ),
        GameStreamPhysicalButton.b: GameStreamPadAction(
          GameStreamVirtualButton.cancel,
        ),
        GameStreamPhysicalButton.x: GameStreamMouseButtonAction(
          GameStreamMouseAction.rightClick,
        ),
        GameStreamPhysicalButton.y: GameStreamAppAction(
          GameStreamReceiverAction.toggleLookupPanel,
        ),
        GameStreamPhysicalButton.l1: GameStreamPadAction(
          GameStreamVirtualButton.shoulderLeft,
        ),
        GameStreamPhysicalButton.r1: GameStreamPadAction(
          GameStreamVirtualButton.shoulderRight,
        ),
        // Most visual novels open the backlog on wheel up and skip while
        // Control is held.
        GameStreamPhysicalButton.l2: GameStreamMouseButtonAction(
          GameStreamMouseAction.wheelUp,
        ),
        GameStreamPhysicalButton.r2: GameStreamHostKeyAction('Control'),
        GameStreamPhysicalButton.l3: GameStreamAppAction(
          GameStreamReceiverAction.toggleOnScreenPad,
        ),
        GameStreamPhysicalButton.r3: GameStreamNoAction(),
        GameStreamPhysicalButton.start: GameStreamPadAction(
          GameStreamVirtualButton.menu,
        ),
        GameStreamPhysicalButton.select: GameStreamPadAction(
          GameStreamVirtualButton.menu,
        ),
      };

  final Map<GameStreamPhysicalButton, GameStreamButtonAction> overrides;

  GameStreamButtonAction actionFor(GameStreamPhysicalButton button) =>
      overrides[button] ?? defaults[button] ?? const GameStreamNoAction();

  bool isCustomized(GameStreamPhysicalButton button) =>
      overrides.containsKey(button);

  /// This profile with [button] doing [action]; choosing the default removes
  /// the override.
  GameStreamButtonProfile withAction(
    GameStreamPhysicalButton button,
    GameStreamButtonAction action,
  ) {
    final Map<GameStreamPhysicalButton, GameStreamButtonAction> next =
        <GameStreamPhysicalButton, GameStreamButtonAction>{...overrides};
    if (action == defaults[button]) {
      next.remove(button);
    } else {
      next[button] = action;
    }
    return GameStreamButtonProfile(overrides: Map.unmodifiable(next));
  }

  Map<String, String> toJson() => <String, String>{
    for (final MapEntry<GameStreamPhysicalButton, GameStreamButtonAction> entry
        in overrides.entries)
      entry.key.name: entry.value.toWire(),
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamButtonProfile && mapEquals(other.overrides, overrides);

  @override
  int get hashCode => Object.hashAllUnordered(
    overrides.entries.map(
      (MapEntry<GameStreamPhysicalButton, GameStreamButtonAction> entry) =>
          Object.hash(entry.key, entry.value),
    ),
  );

  @override
  String toString() => 'GameStreamButtonProfile(${toJson()})';
}

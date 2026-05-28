import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

class ShortcutDefaults {
  ShortcutDefaults._();

  static Map<ShortcutAction, ShortcutBindingSet> forPlatform(
    TargetPlatform platform,
  ) {
    switch (platform) {
      case TargetPlatform.macOS:
        return _macOS;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return _mobile;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return _desktop;
    }
  }

  static ShortcutBindingSet _kb(
    List<InputBinding> keyboard, [
    List<GamepadBinding> gamepad = const [],
  ]) =>
      ShortcutBindingSet(
        keyboardBindings: keyboard,
        gamepadBindings: gamepad,
      );

  static InputBinding _key(LogicalKeyboardKey key,
          [Set<ModifierKey> modifiers = const {}]) =>
      InputBinding(key: key, modifiers: modifiers);

  static const _gRB = GamepadBinding(GamepadButton.rb);
  static const _gLB = GamepadBinding(GamepadButton.lb);
  static const _gA = GamepadBinding(GamepadButton.a);
  static const _gB = GamepadBinding(GamepadButton.b);
  static const _gX = GamepadBinding(GamepadButton.x);
  static const _gY = GamepadBinding(GamepadButton.y);
  static const _gDpadRight = GamepadBinding(GamepadButton.dpadRight);
  static const _gDpadLeft = GamepadBinding(GamepadButton.dpadLeft);

  static final Map<ShortcutAction, ShortcutBindingSet> _desktop = {
    ShortcutAction.readerPageForward: _kb([
      _key(LogicalKeyboardKey.pageDown),
      _key(LogicalKeyboardKey.arrowRight),
      _key(LogicalKeyboardKey.arrowDown),
      _key(LogicalKeyboardKey.space),
    ], [
      _gRB,
      _gDpadRight
    ]),
    ShortcutAction.readerPageBackward: _kb([
      _key(LogicalKeyboardKey.pageUp),
      _key(LogicalKeyboardKey.arrowLeft),
      _key(LogicalKeyboardKey.arrowUp),
      _key(LogicalKeyboardKey.space, {ModifierKey.shift}),
    ], [
      _gLB,
      _gDpadLeft
    ]),
    ShortcutAction.readerToggleChrome: _kb([
      _key(LogicalKeyboardKey.escape),
    ], [
      _gY
    ]),
    ShortcutAction.readerDismissDict: _kb([
      _key(LogicalKeyboardKey.escape),
    ], [
      _gB
    ]),
    ShortcutAction.readerToggleBookmark: _kb([
      _key(LogicalKeyboardKey.keyD, {ModifierKey.ctrl}),
    ], [
      _gX
    ]),
    ShortcutAction.homeTabBooks: _kb([
      _key(LogicalKeyboardKey.digit1, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabDict: _kb([
      _key(LogicalKeyboardKey.digit2, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabSettings: _kb([
      _key(LogicalKeyboardKey.digit3, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeFocusSearch: _kb([
      _key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.globalBack: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.alt}),
    ]),
    ShortcutAction.audiobookPlayPause: _kb([
      _key(LogicalKeyboardKey.space, {ModifierKey.ctrl}),
    ], [
      _gA
    ]),
    ShortcutAction.audiobookNextSentence: _kb([
      _key(LogicalKeyboardKey.arrowRight, {ModifierKey.ctrl}),
    ], [
      _gRB
    ]),
    ShortcutAction.audiobookPrevSentence: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.ctrl}),
    ], [
      _gLB
    ]),
  };

  static final Map<ShortcutAction, ShortcutBindingSet> _macOS = {
    for (final entry in _desktop.entries)
      entry.key: ShortcutBindingSet(
        keyboardBindings: entry.value.keyboardBindings.map((b) {
          if (b.modifiers.contains(ModifierKey.ctrl)) {
            final newMods = Set<ModifierKey>.of(b.modifiers)
              ..remove(ModifierKey.ctrl)
              ..add(ModifierKey.meta);
            return InputBinding(key: b.key, modifiers: newMods);
          }
          return b;
        }).toList(growable: false),
        gamepadBindings: entry.value.gamepadBindings,
      ),
  };

  static final Map<ShortcutAction, ShortcutBindingSet> _mobile = {
    for (final action in ShortcutAction.values)
      action: () {
        final desktop = _desktop[action]!;
        switch (action.scope) {
          case ShortcutScope.reader:
            return ShortcutBindingSet(
              keyboardBindings: desktop.keyboardBindings,
              gamepadBindings: desktop.gamepadBindings,
            );
          case ShortcutScope.audiobook:
            return ShortcutBindingSet(
              gamepadBindings: desktop.gamepadBindings,
            );
          case ShortcutScope.home:
          case ShortcutScope.global:
            return ShortcutBindingSet(
              gamepadBindings: desktop.gamepadBindings,
            );
        }
      }(),
  };
}

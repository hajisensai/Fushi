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
  static const _gLT = GamepadBinding(GamepadButton.lt);
  static const _gRT = GamepadBinding(GamepadButton.rt);
  static const _gB = GamepadBinding(GamepadButton.b);
  static const _gX = GamepadBinding(GamepadButton.x);
  static const _gY = GamepadBinding(GamepadButton.y);
  static const _gDpadRight = GamepadBinding(GamepadButton.dpadRight);
  static const _gDpadLeft = GamepadBinding(GamepadButton.dpadLeft);
  static const _gL3 = GamepadBinding(GamepadButton.thumbLeft);
  static const _gR3 = GamepadBinding(GamepadButton.thumbRight);

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
    // R3 toggles furigana (gamepad-only; keyboard furigana stays in settings).
    ShortcutAction.readerToggleFurigana: _kb([], [_gR3]),
    ShortcutAction.homeTabBooks: _kb([
      _key(LogicalKeyboardKey.digit1, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabDict: _kb([
      _key(LogicalKeyboardKey.digit2, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabSettings: _kb([
      _key(LogicalKeyboardKey.digit3, {ModifierKey.ctrl}),
    ]),
    // LT/RT cycle the three home tabs (prev/next), per the global key map.
    // Keyboard stays on Ctrl+1/2/3 absolute jumps above.
    ShortcutAction.homeTabPrev: _kb([], [_gLT]),
    ShortcutAction.homeTabNext: _kb([], [_gRT]),
    ShortcutAction.homeFocusSearch: _kb([
      _key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
    ], [
      _gY
    ]),
    ShortcutAction.globalBack: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.alt}),
    ]),
    // LB/RB = 整页翻屏（gamepad-only；键盘留空，避免与 reader PageDown 在不同
    // scope 的重复语义）。global scope，对所有非阅读器页通用；reader 页只解析
    // reader+audiobook，不会被遮蔽。执行体见 wrapWithGlobalNavigation。
    ShortcutAction.globalScrollPageDown: _kb([], [_gRB]),
    ShortcutAction.globalScrollPageUp: _kb([], [_gLB]),
    // Play/pause moved off controller A → L3: on the reader page A is now
    // "enter the char-level reading cursor" (and, once inside, "look up the word
    // at the cursor"), which the page intercepts before the audiobook scope is
    // consulted. Keeping A here would be a permanently shadowed binding. Keyboard
    // stays on Ctrl+Space.
    ShortcutAction.audiobookPlayPause: _kb([
      _key(LogicalKeyboardKey.space, {ModifierKey.ctrl}),
    ], [
      _gL3
    ]),
    // No gamepad default: RB/LB are already reader page-turn, and the reader
    // page resolves the reader scope before audiobook, so an RB/LB binding here
    // would be permanently shadowed (never fire). Sentence navigation stays on
    // the keyboard Ctrl+Arrow bindings. Same philosophy as globalBack leaving
    // its gamepad empty to avoid a shadowed/double-trigger binding.
    ShortcutAction.audiobookNextSentence: _kb([
      _key(LogicalKeyboardKey.arrowRight, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.audiobookPrevSentence: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.ctrl}),
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

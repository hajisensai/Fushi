import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

class ShortcutDefaults {
  ShortcutDefaults._();

  /// Gamepad is a mobile-only input modality in Hibiki: physical controllers
  /// (and Android's gamepad→keyevent translation) only exist on Android/iOS.
  /// Desktop embedders do not deliver gameButton* logical keys, so desktop and
  /// macOS get keyboard shortcuts only. This is the single source of truth that
  /// the defaults, the registry's runtime resolution, the settings UI and the
  /// global gameButton-B pop all gate on.
  static bool gamepadSupported(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

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

  // Canonical full binding set: keyboard + gamepad for every action. This is
  // the source the per-platform maps are derived from — it is NOT returned to
  // any platform directly. Desktop/macOS strip the gamepad half; mobile keeps
  // gamepad and (outside the reader scope) drops keyboard.
  static final Map<ShortcutAction, ShortcutBindingSet> _canonical = {
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

  // Desktop (Windows/Linux/Fuchsia): keyboard only — gamepad is mobile-only.
  static final Map<ShortcutAction, ShortcutBindingSet> _desktop = {
    for (final entry in _canonical.entries)
      entry.key: ShortcutBindingSet(
        keyboardBindings: entry.value.keyboardBindings,
      ),
  };

  // macOS derives from the (already gamepad-free) desktop map, swapping ctrl for
  // the command/meta modifier on modified shortcuts.
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
      ),
  };

  // Mobile (Android/iOS): keeps gamepad everywhere it exists. The reader scope
  // also keeps its keyboard bindings (bluetooth keyboards are common while
  // reading); home/global/audiobook expose gamepad only.
  static final Map<ShortcutAction, ShortcutBindingSet> _mobile = {
    for (final action in ShortcutAction.values)
      action: () {
        final canonical = _canonical[action]!;
        switch (action.scope) {
          case ShortcutScope.reader:
            return ShortcutBindingSet(
              keyboardBindings: canonical.keyboardBindings,
              gamepadBindings: canonical.gamepadBindings,
            );
          case ShortcutScope.audiobook:
            return ShortcutBindingSet(
              gamepadBindings: canonical.gamepadBindings,
            );
          case ShortcutScope.home:
          case ShortcutScope.global:
            return ShortcutBindingSet(
              gamepadBindings: canonical.gamepadBindings,
            );
        }
      }(),
  };
}

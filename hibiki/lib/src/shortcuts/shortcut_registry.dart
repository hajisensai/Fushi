import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

class HibikiShortcutRegistry extends ChangeNotifier {
  final Map<ShortcutAction, ShortcutBindingSet> _bindings = {};
  final Map<String, dynamic> _unknownEntries = {};

  ShortcutBindingSet bindingsFor(ShortcutAction action) =>
      _bindings[action] ?? const ShortcutBindingSet();

  void loadDefaults(TargetPlatform platform) {
    _bindings
      ..clear()
      ..addAll(ShortcutDefaults.forPlatform(platform));
    _unknownEntries.clear();
  }

  void loadFromJson(Map<String, dynamic> json) {
    for (final entry in json.entries) {
      final action = ShortcutAction.fromKey(entry.key);
      if (action == null) {
        _unknownEntries[entry.key] = entry.value;
        continue;
      }
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        _bindings[action] = ShortcutBindingSet.fromJson(value);
      }
    }
    notifyListeners();
  }

  Map<String, dynamic> toJson() {
    return {
      for (final entry in _bindings.entries)
        entry.key.key: entry.value.toJson(),
      ..._unknownEntries,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  void loadFromJsonString(String jsonString, TargetPlatform platform) {
    loadDefaults(platform);
    try {
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      loadFromJson(decoded);
    } catch (_) {
      // Corrupted JSON — keep defaults.
    }
  }

  void updateBinding(ShortcutAction action, ShortcutBindingSet bindings) {
    _bindings[action] = bindings;
    notifyListeners();
  }

  void resetToDefaults(TargetPlatform platform) {
    loadDefaults(platform);
    notifyListeners();
  }

  void resetScopeToDefaults(ShortcutScope scope, TargetPlatform platform) {
    final defaults = ShortcutDefaults.forPlatform(platform);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      _bindings[action] = defaults[action] ?? const ShortcutBindingSet();
    }
    notifyListeners();
  }

  ShortcutAction? resolveKeyboard(
    LogicalKeyboardKey key, {
    required Set<ModifierKey> modifiers,
    required ShortcutScope scope,
  }) {
    final target = InputBinding(key: key, modifiers: modifiers);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final kb in bindings.keyboardBindings) {
        if (kb == target) return action;
      }
    }
    return null;
  }

  ShortcutAction? resolveGamepad(
    GamepadButton button, {
    required ShortcutScope scope,
  }) {
    final target = GamepadBinding(button);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final gp in bindings.gamepadBindings) {
        if (gp == target) return action;
      }
    }
    return null;
  }

  ShortcutAction? hasKeyboardConflict(
    ShortcutScope scope,
    InputBinding binding, {
    required ShortcutAction? exclude,
  }) {
    for (final coactive in scope.coactiveScopes) {
      for (final action in ShortcutAction.actionsForScope(coactive)) {
        if (action == exclude) continue;
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final kb in bindings.keyboardBindings) {
          if (kb == binding) return action;
        }
      }
    }
    return null;
  }

  ShortcutAction? hasGamepadConflict(
    ShortcutScope scope,
    GamepadBinding binding, {
    required ShortcutAction? exclude,
  }) {
    for (final coactive in scope.coactiveScopes) {
      for (final action in ShortcutAction.actionsForScope(coactive)) {
        if (action == exclude) continue;
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final gp in bindings.gamepadBindings) {
          if (gp == binding) return action;
        }
      }
    }
    return null;
  }
}

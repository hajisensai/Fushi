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
    // HBK-AUDIT-135: 先把整段 JSON 解析进本地 map，全部成功后再原子地提交到
    // _bindings/_unknownEntries。之前是逐条写入 _bindings，一旦
    // ShortcutBindingSet.fromJson 在中途抛错（如 cast<String>() 命中非字符串
    // 元素），就会留下 "defaults + 已解析的部分条目" 的混合状态，与
    // loadFromJsonString 中 "keep defaults" 的契约矛盾。
    final Map<ShortcutAction, ShortcutBindingSet> parsedBindings = {};
    final Map<String, dynamic> parsedUnknown = {};
    for (final entry in json.entries) {
      final action = ShortcutAction.fromKey(entry.key);
      if (action == null) {
        parsedUnknown[entry.key] = entry.value;
        continue;
      }
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        parsedBindings[action] = ShortcutBindingSet.fromJson(value);
      }
    }
    // 解析全部成功，覆盖默认值中被显式声明的条目（保留未在 JSON 中出现的默认）。
    _bindings.addAll(parsedBindings);
    _unknownEntries.addAll(parsedUnknown);
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

  void updateBindingWithReassignments(
    ShortcutAction action,
    ShortcutBindingSet bindings, {
    Iterable<InputBinding> removeKeyboardConflicts = const <InputBinding>[],
    Iterable<GamepadBinding> removeGamepadConflicts = const <GamepadBinding>[],
  }) {
    final Set<InputBinding> keyboardToRemove =
        Set<InputBinding>.of(removeKeyboardConflicts);
    final Set<GamepadBinding> gamepadToRemove =
        Set<GamepadBinding>.of(removeGamepadConflicts);

    if (keyboardToRemove.isNotEmpty || gamepadToRemove.isNotEmpty) {
      for (final ShortcutScope scope in action.scope.coactiveScopes) {
        for (final ShortcutAction oldAction
            in ShortcutAction.actionsForScope(scope)) {
          if (oldAction == action) continue;
          final ShortcutBindingSet oldBindings = bindingsFor(oldAction);
          final List<InputBinding> keyboard = oldBindings.keyboardBindings
              .where((InputBinding b) => !keyboardToRemove.contains(b))
              .toList(growable: false);
          final List<GamepadBinding> gamepad = oldBindings.gamepadBindings
              .where((GamepadBinding b) => !gamepadToRemove.contains(b))
              .toList(growable: false);
          if (keyboard.length != oldBindings.keyboardBindings.length ||
              gamepad.length != oldBindings.gamepadBindings.length) {
            _bindings[oldAction] = oldBindings.copyWith(
              keyboardBindings: keyboard,
              gamepadBindings: gamepad,
            );
          }
        }
      }
    }

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

  ShortcutAction? resolveMouse(
    int button, {
    required ShortcutScope scope,
  }) {
    final target = MouseBinding(button);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final mb in bindings.mouseBindings) {
        if (mb == target) return action;
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

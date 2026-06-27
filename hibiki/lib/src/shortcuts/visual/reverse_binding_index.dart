import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// 反向绑定索引（TODO-612 阶段 0）。
///
/// 快捷键系统的真相是 `Map<ShortcutAction, ShortcutBindingSet>`（按 action 查键）。
/// 可视化键盘/手柄图需要反过来「按物理键/按钮查哪些 action 绑了它」，用于高亮判定。
/// 本类只是该映射的**只读反向投影**，不持有状态、不写注册表、不改任何序列化契约。
///
/// 按 [ShortcutScope.coactiveScopes] 过滤：同一物理键在不同 co-active 组里可能绑给
/// 不同 action，可视化图一次只渲染一个 scope 视角，故构造时按传入 scope 的整组
/// （含 co-active）展开，与 [HibikiShortcutRegistry.resolveKeyboard] 的解析口径一致。
///
/// 纯数据类：给定相同的注册表绑定 + scope，反向结果完全确定。
@immutable
class ReverseBindingIndex {
  const ReverseBindingIndex._({
    required this.keyboard,
    required this.gamepad,
    required Map<LogicalKeyboardKey, List<InputBinding>> keyboardBindings,
  }) : _keyboardBindings = keyboardBindings;

  /// 逻辑键 → 绑定了该键（任意 modifier 组合）的 action 列表。
  ///
  /// 注意：key 只取 [InputBinding.key]（裸逻辑键），modifier 不进 key —— 可视化图按
  /// 键帽渲染，一个键帽对应「按下该物理键」，无论是否带 Ctrl/Shift。需要区分 modifier
  /// 组合时由调用方读 [keyboardBindingsFor] 拿完整 binding 列表。
  final Map<LogicalKeyboardKey, List<ShortcutAction>> keyboard;

  /// 手柄按钮 → 绑定了该按钮的 action 列表。
  final Map<GamepadButton, List<ShortcutAction>> gamepad;

  /// 逻辑键 → 完整 [InputBinding] 列表（保留 modifier），按需查证具体组合。
  final Map<LogicalKeyboardKey, List<InputBinding>> _keyboardBindings;

  /// 从注册表为指定 [scope] 构建反向索引：展开该 scope 的整个 co-active 组，让
  /// 高亮口径与运行时解析（resolveKeyboard 按 coactiveScopes 扫描）一致。
  factory ReverseBindingIndex.fromRegistry(
    HibikiShortcutRegistry registry,
    ShortcutScope scope,
  ) {
    final Map<LogicalKeyboardKey, List<ShortcutAction>> keyboard =
        <LogicalKeyboardKey, List<ShortcutAction>>{};
    final Map<GamepadButton, List<ShortcutAction>> gamepad =
        <GamepadButton, List<ShortcutAction>>{};
    final Map<LogicalKeyboardKey, List<InputBinding>> keyboardBindings =
        <LogicalKeyboardKey, List<InputBinding>>{};

    for (final ShortcutScope coactive in scope.coactiveScopes) {
      for (final ShortcutAction action
          in ShortcutAction.actionsForScope(coactive)) {
        final ShortcutBindingSet set = registry.bindingsFor(action);
        for (final InputBinding kb in set.keyboardBindings) {
          (keyboard[kb.key] ??= <ShortcutAction>[]).add(action);
          (keyboardBindings[kb.key] ??= <InputBinding>[]).add(kb);
        }
        for (final GamepadBinding gp in set.gamepadBindings) {
          (gamepad[gp.button] ??= <ShortcutAction>[]).add(action);
        }
      }
    }

    return ReverseBindingIndex._(
      keyboard: Map<LogicalKeyboardKey, List<ShortcutAction>>.unmodifiable(
        keyboard.map(
          (LogicalKeyboardKey k, List<ShortcutAction> v) =>
              MapEntry<LogicalKeyboardKey, List<ShortcutAction>>(
            k,
            List<ShortcutAction>.unmodifiable(v),
          ),
        ),
      ),
      gamepad: Map<GamepadButton, List<ShortcutAction>>.unmodifiable(
        gamepad.map(
          (GamepadButton k, List<ShortcutAction> v) =>
              MapEntry<GamepadButton, List<ShortcutAction>>(
            k,
            List<ShortcutAction>.unmodifiable(v),
          ),
        ),
      ),
      keyboardBindings:
          Map<LogicalKeyboardKey, List<InputBinding>>.unmodifiable(
        keyboardBindings.map(
          (LogicalKeyboardKey k, List<InputBinding> v) =>
              MapEntry<LogicalKeyboardKey, List<InputBinding>>(
            k,
            List<InputBinding>.unmodifiable(v),
          ),
        ),
      ),
    );
  }

  /// 该逻辑键是否已绑给本 scope（含 co-active）的任意 action。
  bool isKeyboardBound(LogicalKeyboardKey key) =>
      keyboard.containsKey(key) && keyboard[key]!.isNotEmpty;

  /// 该手柄按钮是否已绑。
  bool isGamepadBound(GamepadButton button) =>
      gamepad.containsKey(button) && gamepad[button]!.isNotEmpty;

  /// 绑给该逻辑键的 action 列表（未绑返回空表）。
  List<ShortcutAction> actionsForKey(LogicalKeyboardKey key) =>
      keyboard[key] ?? const <ShortcutAction>[];

  /// 绑给该手柄按钮的 action 列表（未绑返回空表）。
  List<ShortcutAction> actionsForButton(GamepadButton button) =>
      gamepad[button] ?? const <ShortcutAction>[];

  /// 绑到该逻辑键的完整 binding 列表（保留 modifier；未绑返回空表）。
  List<InputBinding> keyboardBindingsFor(LogicalKeyboardKey key) =>
      _keyboardBindings[key] ?? const <InputBinding>[];
}

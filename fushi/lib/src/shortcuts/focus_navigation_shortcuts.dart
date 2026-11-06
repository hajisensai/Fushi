// 焦点导航快捷键（反馈 bjPjRHsaUy，所有者拍板）：上 / 下 / 左 / 右移焦 + 确认，
// 作为快捷键系统里的一等动作（[ShortcutScope.gamepad]，设置页显示「焦点导航」）。
//
// 本文件只放与输入通道无关的纯判据与预设：
//   · 动作 → 方向（键盘 wrapper 与手柄服务共用，同一张映射）；
//   · 「这个键是不是框架内建就会处理的那一枚」（裸方向键 / Enter / 手柄 A）；
//   · 设置页的两组**可选**备选键预设（WASD、Shift+方向键），默认关闭。
// 键盘派发在 `global_navigation.dart` 的 `_handleGlobalFocusNavigation`，手柄派发
// 在 `GamepadService._dispatchButton`。
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter/widgets.dart' show TraversalDirection;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 焦点导航的四个移焦动作对应的方向；其它动作（含 [ShortcutAction.focusActivate]）
/// 返回 null。
TraversalDirection? focusNavigationDirectionOf(ShortcutAction? action) {
  switch (action) {
    case ShortcutAction.dpadUp:
      return TraversalDirection.up;
    case ShortcutAction.dpadDown:
      return TraversalDirection.down;
    case ShortcutAction.dpadLeft:
      return TraversalDirection.left;
    case ShortcutAction.dpadRight:
      return TraversalDirection.right;
    default:
      return null;
  }
}

/// [key] + [modifiers] 是不是**裸方向键**（无任何修饰键）。
///
/// 裸方向键是焦点导航的内建契约：实验性焦点导航关闭时由框架 `WidgetsApp` 的
/// `DirectionalFocusIntent` 处理，开启时由 `global_navigation.dart` 的既有判据
/// （受管控件门 + 单行文本框逃逸 + 尽头落到滚页）处理。注册表只决定「往哪个方向」，
/// 不改变这两条既有路径——这就是「默认绑定行为不变」的落点。
bool isBareArrowKey(LogicalKeyboardKey key, Set<ModifierKey> modifiers) {
  if (modifiers.isNotEmpty) return false;
  return key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;
}

/// [key] + [modifiers] 是不是框架 `WidgetsApp` 默认 shortcuts 里**本来就**映射成
/// `ActivateIntent` 的确认键（裸 Enter / 小键盘 Enter / 手柄 A 键事件）。
///
/// 这些键冒泡过 app 根 wrapper 后由框架自己激活焦点控件；wrapper 再激活一次就是
/// 双重确认，故 [ShortcutAction.focusActivate] 只接管用户**另加**的确认键。
bool isFrameworkActivateKey(
  LogicalKeyboardKey key,
  Set<ModifierKey> modifiers,
) {
  if (modifiers.isNotEmpty) return false;
  return key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;
}

/// 设置页「焦点导航」分组里的一键备选键预设。**默认关闭**：开启 = 把对应键追加到
/// 四个移焦动作的键盘绑定里（不替换方向键），关闭 = 只移除这几枚键。
///
/// 不进 [ShortcutDefaults]：W/A/S/D 在视频页是 seek / 截图，Shift+←/→ 在音乐页是
/// ±5 秒——页面 scope 先解析、优先级更高（见 [ShortcutScope.gamepad] 注释），这些
/// 页面上它们仍执行页面动作；默认塞进来只会让用户以为「按了没反应」。
enum FocusNavigationPreset {
  wasd,
  shiftArrows;

  /// 该预设给每个移焦动作追加的键。
  Map<ShortcutAction, InputBinding> get bindings => switch (this) {
    FocusNavigationPreset.wasd => const <ShortcutAction, InputBinding>{
      ShortcutAction.dpadUp: InputBinding(key: LogicalKeyboardKey.keyW),
      ShortcutAction.dpadLeft: InputBinding(key: LogicalKeyboardKey.keyA),
      ShortcutAction.dpadDown: InputBinding(key: LogicalKeyboardKey.keyS),
      ShortcutAction.dpadRight: InputBinding(key: LogicalKeyboardKey.keyD),
    },
    FocusNavigationPreset.shiftArrows => const <ShortcutAction, InputBinding>{
      ShortcutAction.dpadUp: InputBinding(
        key: LogicalKeyboardKey.arrowUp,
        modifiers: <ModifierKey>{ModifierKey.shift},
      ),
      ShortcutAction.dpadLeft: InputBinding(
        key: LogicalKeyboardKey.arrowLeft,
        modifiers: <ModifierKey>{ModifierKey.shift},
      ),
      ShortcutAction.dpadDown: InputBinding(
        key: LogicalKeyboardKey.arrowDown,
        modifiers: <ModifierKey>{ModifierKey.shift},
      ),
      ShortcutAction.dpadRight: InputBinding(
        key: LogicalKeyboardKey.arrowRight,
        modifiers: <ModifierKey>{ModifierKey.shift},
      ),
    },
  };
}

/// [preset] 当前是否完整生效（四个移焦动作都带着它的那枚键）。
bool isFocusNavigationPresetEnabled(
  FushiShortcutRegistry registry,
  FocusNavigationPreset preset,
) {
  for (final MapEntry<ShortcutAction, InputBinding> entry
      in preset.bindings.entries) {
    if (!registry
        .bindingsFor(entry.key)
        .keyboardBindings
        .contains(entry.value)) {
      return false;
    }
  }
  return true;
}

/// 打开 / 关闭 [preset]。打开时把缺的键追加到对应动作末尾（已有的不重复加）；
/// 关闭时只移除这几枚键，用户自己加的其它键原样保留。
///
/// 预设键可能已被**同组**另一个焦点动作占着（例如用户把 W 绑成了「确认」）：
/// 打开时先从同组其它动作上摘掉这枚键再追加——同一 co-active 组里一键只能归一个
/// 动作，否则按声明序解析会让后者永远不触发。跨组（页面 scope）不动：页面优先是
/// 设计（见 [ShortcutScope.gamepad]），不是冲突。
void setFocusNavigationPreset(
  FushiShortcutRegistry registry,
  FocusNavigationPreset preset, {
  required bool enabled,
}) {
  for (final MapEntry<ShortcutAction, InputBinding> entry
      in preset.bindings.entries) {
    final ShortcutBindingSet current = registry.bindingsFor(entry.key);
    final List<InputBinding> keyboard = current.keyboardBindings;
    if (enabled) {
      if (keyboard.contains(entry.value)) continue;
      registry.updateBindingWithReassignments(
        entry.key,
        current.copyWith(
          keyboardBindings: <InputBinding>[...keyboard, entry.value],
        ),
        removeKeyboardConflicts: <InputBinding>[entry.value],
      );
    } else {
      if (!keyboard.contains(entry.value)) continue;
      registry.updateBinding(
        entry.key,
        current.copyWith(
          keyboardBindings: keyboard
              .where((InputBinding b) => b != entry.value)
              .toList(growable: false),
        ),
      );
    }
  }
}

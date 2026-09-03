import 'package:flutter/widgets.dart';

import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;

/// 只消费自己那几个手柄键、**其余原样交还给祖先** [Actions] 的动作。
///
/// 为什么不能靠覆写 [Action.isEnabled] 来「让位」——[Actions.maybeInvoke] 的循环体
/// （flutter/lib/src/widgets/actions.dart）是：
///
/// ```dart
/// _visitActionsAncestors(context, (InheritedElement element) {
///   final Action<T>? result = _castAction(actions, intent: intent);
///   if (result != null && result._isEnabled(intent, context)) {
///     returnValue = _findDispatcher(element).invokeAction(result, intent, context);
///   }
///   return result != null;   // ← 停止条件只看「本层注册了这个 Intent 类型没有」
/// });
/// ```
///
/// 上溯停在**第一个注册了该 Intent 类型的层**，`isEnabled` 只决定要不要 invoke。
/// 所以 isEnabled 门控的真实效果是：本层不认的按钮既不被本层执行、也永远到不了
/// 祖先，被静默吞掉。实测后果——游戏卡聚焦时 home 的 LT/RT 换 tab 与 Y 搜索全失灵；
/// 设置页的可调值行同样吞掉 Y / LT / RT。三处原先的注释都写着「Flutter 停在第一个
/// **enabled** 的 action」，那句话不成立。
///
/// 让位因此必须**显式转发**。[ancestorContext] 必须取「构建本层 [Actions] 的那个
/// `build` 的 context」：它在本层 Actions 元素**之上**，转发才会跳过自己继续上溯；
/// 传本层内部的 context 会原地自我循环。
class GamepadButtonForwardingAction extends Action<GamepadButtonIntent> {
  GamepadButtonForwardingAction({
    required this.handle,
    required this.ancestorContext,
  });

  /// 返回 true = 本层消费掉这个按钮；false = 本层不认，转发给祖先 [Actions]。
  final bool Function(GamepadButton button) handle;

  /// 本层 [Actions] 之上的 context（构建它的那个 `build` 的 context）。
  final BuildContext ancestorContext;

  @override
  Object? invoke(GamepadButtonIntent intent) {
    if (handle(intent.button)) return true;
    if (!ancestorContext.mounted) return null;
    return Actions.maybeInvoke<GamepadButtonIntent>(ancestorContext, intent);
  }
}

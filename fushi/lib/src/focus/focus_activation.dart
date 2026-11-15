import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 本应用里会被框架映射成 [ActivateIntent] 的「确认」键。
///
/// 框架默认（[WidgetsApp.defaultShortcuts]）是 Enter / 小键盘 Enter / 空格 / 手柄 A /
/// Select；本应用在全局把**裸空格**中和掉了（`global_navigation.dart` 的
/// `_neutralizeBareSpace`：焦点确认永不走空格），所以空格不在这里——持焦控件本来就收不到
/// 空格激活，页面照常把空格当自己的快捷键用，不会和控件抢。
final Set<LogicalKeyboardKey> kFushiActivationKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
  LogicalKeyboardKey.select,
};

/// 页面级 key sink（挂在整页外层的 `Focus(onKeyEvent: …)`）该不该把 [key] 让给持焦的子控件。
///
/// 按键分发先到主焦点，再沿祖先链冒泡：整页 `Focus.onKeyEvent` 在**应用级** [Shortcuts]
/// （`WidgetsApp` 那层，Enter / 手柄 A → [ActivateIntent]）**之前**就看到这个键。页面若把
/// Enter 当自己的快捷键（翻面 / 打开详情）并返回 handled，焦点所在的按钮 / 分段按钮 / 开关
/// 就永远收不到激活——键盘和手柄用户「按 Enter 没反应」。
///
/// 判据：[key] 是确认键，且主焦点是 [owner] 子树里的一个**别的**节点，它（或它与 [owner]
/// 之间的祖先）挂着启用的 [ActivateIntent] 动作。[owner] 自己持焦、或焦点上找到的激活动作
/// 就是 [owner] 那一层也能找到的同一个（页面外层提供的，不属于子控件）时，返回 false——
/// 页面照常处理。
bool focusedDescendantClaimsActivation(
  FocusNode owner,
  LogicalKeyboardKey key,
) {
  if (!kFushiActivationKeys.contains(key)) return false;
  final FocusNode? primary = FocusManager.instance.primaryFocus;
  if (primary == null || identical(primary, owner)) return false;
  if (!primary.ancestors.contains(owner)) return false;
  final BuildContext? context = primary.context;
  if (context == null) return false;
  const ActivateIntent intent = ActivateIntent();
  final Action<ActivateIntent>? action = Actions.maybeFind<ActivateIntent>(
    context,
    intent: intent,
  );
  if (action == null) return false;
  final BuildContext? ownerContext = owner.context;
  if (ownerContext != null &&
      identical(
        action,
        Actions.maybeFind<ActivateIntent>(ownerContext, intent: intent),
      )) {
    return false;
  }
  return action is ContextAction<ActivateIntent>
      ? action.isEnabled(intent, context)
      : action.isEnabled(intent);
}

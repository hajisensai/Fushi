import 'package:flutter/widgets.dart';

/// 把压在页面自己的路由 [route] 上面的路由（对话框 / 弹出菜单 / 子页）全部弹掉，让 [route]
/// 回到最上面；之后调用方的 `Navigator.pop` / `pushReplacement` 作用的就是 [route] 本身。
///
/// 为什么需要：被动触发的退出（站点自己跳页、会话过期）发生时，本页上面可能还压着对话框。
/// 直接 `pop` 弹的是**最顶层**路由——关掉的是那个对话框、本页留在栈里继续活着；直接
/// `pushReplacement` 换掉的也是对话框。
///
/// [route] 已不在栈里（别的路径先关了它）返回 false、什么都不弹——这时调用方不能再 pop，
/// 否则弹掉的是别人的页面。
bool popRoutesAbove(NavigatorState navigator, Route<dynamic> route) {
  if (!route.isActive) return false;
  navigator.popUntil((Route<dynamic> r) => identical(r, route));
  return route.isCurrent;
}

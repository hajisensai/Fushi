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

/// 只关掉 [context] 自己所在的那条路由，并以 [result] 结束它；压在它上面的路由原样保留。
///
/// 为什么不用 `Navigator.pop(context, result)`：那弹的是导航器**最顶层**的路由，不是
/// [context] 所在的路由。长耗时的对话框（导入、抓轨）在 await 结束后才关自己，期间用户
/// 可能从悬浮反馈球、全局快捷键把别的页面推到它上面——裸 `pop` 会关掉那一页（结果还被
/// 当成那一页的返回值，类型不对直接抛），对话框自己则留成关不掉的孤儿。
///
/// 自己就在最顶层时走普通 `pop`（照常播退场动画、触发 PopScope 回调语义）；不在顶层时
/// `removeRoute` 只摘掉自己。[context] 不在任何路由里、或路由已不在栈里（别的路径先关了
/// 它）返回 false、什么都不做——这时绝不能退回去 pop 别人的页面。
bool closeOwnRoute<R extends Object?>(BuildContext context, [R? result]) {
  final ModalRoute<Object?>? route = ModalRoute.of(context);
  if (route == null || !route.isActive) return false;
  final NavigatorState navigator = Navigator.of(context);
  if (route.isCurrent) {
    navigator.pop<R>(result);
  } else {
    navigator.removeRoute<Object?>(route, result);
  }
  return true;
}

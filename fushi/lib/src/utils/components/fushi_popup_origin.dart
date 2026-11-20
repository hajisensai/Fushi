/// 弹层的「来源配色」：带自定义配色的组件（色块卡等）把自己的局部主题交给从它
/// 弹出的对话框 / 底部弹层 / 菜单，弹层不退回全局主题色。
///
/// 两条路都在公共层接好，调用点不用管：
/// - 弹出调用的 `context` 本身在色块子树里：`showAppDialog` /
///   `adaptiveModalSheet` 用 [InheritedTheme.capture] 把局部主题带进弹层路由
///   （Flutter 自带的 Material 路由已捕获；Cupertino / 玻璃 sheet 路由不捕获，
///   这两个入口补上）。
/// - 弹出调用的 `context` 不在色块里（色块的点按回调转到页面 State 上、用页面
///   的 context 弹框，例如导入页「导入文件夹」块 → `MediaSourcesView`）：色块里
///   的点按目标（`FushiCard`）经 [fushiPopupOriginTap] 把回调放进带来源的
///   [Zone] 里跑，这次点按引出的弹层（跨 await 也算）由入口读
///   [fushiPopupOriginOfZone] 套上同一份局部主题。
///
/// 本文件是叶子（只依赖 material_ui），点按组件与弹层入口都能直接 import，不
/// 拉进色块 / 主题工厂的依赖。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// 弹层来源：把弹层内容包进来源组件的局部配色。
@immutable
class FushiPopupOrigin {
  const FushiPopupOrigin(this.wrap);

  /// 把弹层内容 [child] 包进来源的局部配色（主题 + 来源标记）。
  final Widget Function(Widget child) wrap;
}

/// 向子树声明「这里的弹层来源是 [origin]」（由色块的局部配色作用域放）。
class FushiPopupOriginScope extends InheritedWidget {
  const FushiPopupOriginScope({
    required this.origin,
    required super.child,
    super.key,
  });

  final FushiPopupOrigin origin;

  /// [context] 所在的来源；不在任何带配色组件里时为 null。
  static FushiPopupOrigin? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FushiPopupOriginScope>()?.origin;

  @override
  bool updateShouldNotify(FushiPopupOriginScope oldWidget) =>
      !identical(origin, oldWidget.origin);
}

final Object _zoneKey = Object();

/// 当前这次点按引出的弹层来源（在 [fushiPopupOriginTap] 包过的回调里，跨
/// await 有效）；不在其中时为 null。
FushiPopupOrigin? fushiPopupOriginOfZone() {
  final Object? origin = Zone.current[_zoneKey];
  return origin is FushiPopupOrigin ? origin : null;
}

/// 把点按回调 [onTap] 包成「在 [context] 的来源里跑」：[context] 不在带配色组件
/// 里、或 [onTap] 为 null 时原样返回。
VoidCallback? fushiPopupOriginTap(BuildContext context, VoidCallback? onTap) {
  if (onTap == null) return null;
  final FushiPopupOrigin? origin = FushiPopupOriginScope.maybeOf(context);
  if (origin == null) return onTap;
  return () =>
      runZoned<void>(onTap, zoneValues: <Object?, Object?>{_zoneKey: origin});
}

/// 弹层入口用：[context] 自身不在带配色组件里、但这次弹出是由某个来源的点按
/// 引出的（[fushiPopupOriginOfZone]）时，返回该来源；否则 null（[context] 在
/// 色块里时由主题捕获负责，不重复包）。
FushiPopupOrigin? fushiPopupOriginFor(BuildContext context) {
  if (FushiPopupOriginScope.maybeOf(context) != null) return null;
  return fushiPopupOriginOfZone();
}

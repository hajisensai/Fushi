import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 每一页的底：页面底色 + 角落 M3E 形状背景（[LibraryShapeBackdrop]），并把子树
/// 的 `scaffoldBackgroundColor` 换成透明，让页面里默认底色的 [Scaffold] 透出形状。
///
/// 用户 2026-10-25 拍板「背景整个应用都加」：由 [FushiBackdropPageTransitionsBuilder]
/// 在路由层统一垫，不逐页改。持有底层合成的页经 [setFushiPageRouteTransparent]
/// 整个让开。底色仍画在本组件里，所以整条路由照旧是不透明的，
/// 转场时上下两页不会互相透出。自己指定了 `backgroundColor` 的页面（播放器、
/// 阅读器等）照旧盖住形状。
///
/// Apple 设计系统 / 墨水屏不画形状、不改底色（玻璃主题的半透明底色要透出窗口
/// 材质），但子树结构不变，切换设计系统时页面 State 不重建。
///
/// 页面里拿 `scaffoldBackgroundColor` 当「不透明页底」用的地方（渐隐遮罩、加载罩）
/// 改用 [fushiOpaquePageColor]。
class FushiPageBackdrop extends StatelessWidget {
  const FushiPageBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Route<Object?>? route = ModalRoute.of(context);
    return ValueListenableBuilder<Set<Route<Object?>>>(
      valueListenable: _transparentPageRoutes,
      builder: (BuildContext context, Set<Route<Object?>> transparent, _) {
        final ThemeData theme = Theme.of(context);
        final bool seeThrough = route != null && transparent.contains(route);
        final bool enabled =
            !seeThrough && LibraryShapeBackdrop.enabledOf(context);
        return ColoredBox(
          color: enabled ? theme.scaffoldBackgroundColor : Colors.transparent,
          child: LibraryShapeBackdrop(
            show: !seeThrough,
            child: Theme(
              data: enabled || seeThrough
                  ? theme.copyWith(scaffoldBackgroundColor: Colors.transparent)
                  : theme,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 整页必须透明的路由（不画底色、不画形状）。
final ValueNotifier<Set<Route<Object?>>> _transparentPageRoutes =
    ValueNotifier<Set<Route<Object?>>>(<Route<Object?>>{});

/// 让 [route] 的 [FushiPageBackdrop] 整个让开（[transparent] = true）或恢复。
///
/// 给底层合成用（`underlay_composition.dart`：窗口宿主档的 WebView2 子窗口垫在 Flutter
/// 下面、从透明像素处透出来）：这一页的底色和角落形状一旦画出来，就把网页整个盖住——
/// 2026-10-26 用户截图「加载不出来」，Netflix 登录页只剩一片底色和三块形状。只让开持有
/// 底层合成的那一页，盖在它上面的其它页照旧不透明。
///
/// 页面 dispose 里恢复时树是锁着的，通知要等这一帧画完（与 underlay 归还同一做法）。
void setFushiPageRouteTransparent(Route<Object?> route, bool transparent) {
  final SchedulerBinding binding = SchedulerBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    binding.addPostFrameCallback(
      (Duration _) => _applyPageRouteTransparent(route, transparent),
    );
    return;
  }
  _applyPageRouteTransparent(route, transparent);
}

void _applyPageRouteTransparent(Route<Object?> route, bool transparent) {
  final Set<Route<Object?>> current = _transparentPageRoutes.value;
  if (current.contains(route) == transparent) return;
  _transparentPageRoutes.value = <Route<Object?>>{
    for (final Route<Object?> r in current)
      if (r != route) r,
    if (transparent) route,
  };
}

/// 不透明的页面底色：[FushiPageBackdrop] 把脚手架底色换成了透明，需要「盖住」
/// 内容的遮罩 / 渐隐改取这里（透明时退回 `colorScheme.surface`，与主题的脚手架
/// 底色同值）。玻璃主题的半透明底色原样返回。
Color fushiOpaquePageColor(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final Color scaffold = theme.scaffoldBackgroundColor;
  return scaffold.a > 0 ? scaffold : theme.colorScheme.surface;
}

/// 给任意转场 builder 垫上 [FushiPageBackdrop]：转场作用在「底 + 页面」整体上。
class FushiBackdropPageTransitionsBuilder extends PageTransitionsBuilder {
  const FushiBackdropPageTransitionsBuilder(this.inner);

  /// 真正负责转场动效 / 返回手势的 builder。
  final PageTransitionsBuilder inner;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      inner.delegatedTransition;

  @override
  Duration get transitionDuration => inner.transitionDuration;

  @override
  Duration get reverseTransitionDuration => inner.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => inner.buildTransitions<T>(
    route,
    context,
    animation,
    secondaryAnimation,
    FushiPageBackdrop(child: child),
  );
}

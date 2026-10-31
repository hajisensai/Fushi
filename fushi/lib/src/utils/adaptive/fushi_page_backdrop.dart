import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 每一页的底：页面底色 + 可切换的装饰背景（[LibraryShapeBackdrop]：M3E 形状 / 用户图片），并把子树
/// 的 `scaffoldBackgroundColor` 换成透明，让页面里默认底色的 [Scaffold] 透出形状。
///
/// 用户 2026-10-25 拍板「背景整个应用都加」：由 [FushiBackdropPageTransitionsBuilder]
/// 在路由层统一垫，不逐页改。持有底层合成的页经 [setFushiPageRouteTransparent]
/// 整个让开。底色仍画在本组件里，所以整条路由照旧是不透明的，
/// 转场时上下两页不会互相透出。自己指定了 `backgroundColor` 的页面（播放器、
/// 阅读器等）照旧盖住形状。
///
/// Apple 设计系统 / 墨水屏不画形状、不改底色（玻璃主题的半透明底色要透出窗口
/// 材质）；用户选的自定义图片 Apple 下照画、墨水屏不画；「纯色」预设一律不画。
/// 子树结构不变，切换设计系统 / 背景预设时页面 State 不重建。
///
/// 页面里拿 `scaffoldBackgroundColor` 当「不透明页底」用的地方（渐隐遮罩、加载罩）
/// 改用 [fushiOpaquePageColor]；整页底色（Scaffold / 整页 Material）一律用
/// [fushiPageBackgroundColor]，否则实色页底会把形状整片盖成白底。
class FushiPageBackdrop extends StatelessWidget {
  const FushiPageBackdrop({required this.child, super.key});

  final Widget child;

  /// [context] 所在页的页底是否已被 [FushiPageBackdrop] 换成透明：正在画形状，
  /// 或整页经 [setFushiPageRouteTransparent] 让给底层合成。对话框 / 底部面板挂在
  /// Navigator 的 overlay 上、不在页面子树里，这里恒为 false。
  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_FushiPageBackdropScope>()
          ?.active ??
      false;

  @override
  Widget build(BuildContext context) {
    final Route<Object?>? route = ModalRoute.of(context);
    // 背景预设切换（纯色 ↔ 形状 ↔ 图片）会改变「这页底色要不要换成透明」，
    // 与整页让开一起监听。
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _transparentPageRoutes,
        pageBackdropSettings,
      ]),
      builder: (BuildContext context, _) {
        final Set<Route<Object?>> transparent = _transparentPageRoutes.value;
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
              child: _FushiPageBackdropScope(
                active: enabled || seeThrough,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FushiPageBackdropScope extends InheritedWidget {
  const _FushiPageBackdropScope({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_FushiPageBackdropScope oldWidget) =>
      active != oldWidget.active;
}

/// 整页底色：在画形状的 [FushiPageBackdrop] 里是透明（底色与形状由背景层画），
/// 否则是设计 token 的页面底色。页面级 Scaffold / 整页 Material 的底色走这里，
/// 不要直接写 `tokens.surfaces.page`。
Color fushiPageBackgroundColor(BuildContext context) =>
    FushiPageBackdrop.activeOf(context)
    ? Colors.transparent
    : FushiDesignTokens.of(context).surfaces.page;

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

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/home_tab.dart';
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
///
/// 按模块取背景（反馈 DYI1IOZxSM）：每页属于一个模块（[HomeTab]），画的是
/// [pageBackdropSettingsFor] 给这个模块解析出的设置（模块没单独设就是全局）。
/// 主导航外壳那一页（HomePage 经 [setFushiPageRouteModuleShell] 登记）跟着当前
/// 选中的 tab 走；其它页属于**打开它时**主导航所在的模块（从书架打开的页用书架的
/// 背景），之后切 tab 不变。
class FushiPageBackdrop extends StatefulWidget {
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
  State<FushiPageBackdrop> createState() => _FushiPageBackdropState();
}

class _FushiPageBackdropState extends State<FushiPageBackdrop> {
  /// 首次挂载时主导航所在的模块：非外壳页的归属。
  final HomeTab _openedFrom = homeShellTabNotifier.value;

  /// 背景预设切换（纯色 ↔ 形状 ↔ 图片）会改变「这页底色要不要换成透明」，
  /// 与整页让开、外壳登记、主导航切 tab 一起监听。
  late final Listenable _inputs = Listenable.merge(<Listenable>[
    _transparentPageRoutes,
    _moduleShellRoutes,
    pageBackdropSettings,
    pageBackdropModuleOverrides,
    homeShellTabNotifier,
  ]);

  Route<Object?>? _route;

  /// 上一次构建用的输入；输入没变就不重建（切 tab 时非外壳页、设置没变的外壳页
  /// 都不该重建整棵页面子树——`theme.copyWith` 每次都是新 ThemeData）。
  ({bool seeThrough, PageBackdropSettings settings})? _built;

  @override
  void initState() {
    super.initState();
    _inputs.addListener(_onInputsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _inputs.removeListener(_onInputsChanged);
    super.dispose();
  }

  /// 这一页当前属于哪个模块。
  HomeTab _module() {
    final Route<Object?>? route = _route;
    if (route != null && _moduleShellRoutes.value.contains(route)) {
      return homeShellTabNotifier.value;
    }
    return _openedFrom;
  }

  ({bool seeThrough, PageBackdropSettings settings}) _resolve() {
    final Route<Object?>? route = _route;
    return (
      seeThrough: route != null && _transparentPageRoutes.value.contains(route),
      settings: pageBackdropSettingsFor(_module()),
    );
  }

  void _onInputsChanged() {
    if (!mounted || _resolve() == _built) return;
    // HomePage.initState 在构建期改写主导航 tab：树正锁着，不能标脏祖先，
    // 等这一帧画完再重建（与 [setFushiPageRouteTransparent] 同一做法）。
    final SchedulerBinding binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((Duration _) => _onInputsChanged());
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ({bool seeThrough, PageBackdropSettings settings}) resolved =
        _resolve();
    _built = resolved;
    final ThemeData theme = Theme.of(context);
    final bool seeThrough = resolved.seeThrough;
    final bool enabled =
        !seeThrough &&
        LibraryShapeBackdrop.enabledFor(context, resolved.settings);
    return ColoredBox(
      color: enabled ? theme.scaffoldBackgroundColor : Colors.transparent,
      child: LibraryShapeBackdrop(
        show: !seeThrough,
        settings: resolved.settings,
        child: Theme(
          data: enabled || seeThrough
              ? theme.copyWith(scaffoldBackgroundColor: Colors.transparent)
              : theme,
          child: _FushiPageBackdropScope(
            active: enabled || seeThrough,
            child: widget.child,
          ),
        ),
      ),
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

/// 主导航外壳路由（跟着当前选中 tab 换模块背景的那一页）。
final ValueNotifier<Set<Route<Object?>>> _moduleShellRoutes =
    ValueNotifier<Set<Route<Object?>>>(<Route<Object?>>{});

/// 登记 / 注销主导航外壳页（HomePage）：登记了的路由，其 [FushiPageBackdrop] 按
/// [homeShellTabNotifier] 当前的 tab 取模块背景，而不是固定在打开时的模块。
///
/// 外壳在 didChangeDependencies / dispose 里调，树是锁着的，通知等这一帧画完。
void setFushiPageRouteModuleShell(Route<Object?> route, bool shell) {
  final SchedulerBinding binding = SchedulerBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    binding.addPostFrameCallback(
      (Duration _) => _applyModuleShell(route, shell),
    );
    return;
  }
  _applyModuleShell(route, shell);
}

void _applyModuleShell(Route<Object?> route, bool shell) {
  final Set<Route<Object?>> current = _moduleShellRoutes.value;
  if (current.contains(route) == shell) return;
  _moduleShellRoutes.value = <Route<Object?>>{
    for (final Route<Object?> r in current)
      if (r != route) r,
    if (shell) route,
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

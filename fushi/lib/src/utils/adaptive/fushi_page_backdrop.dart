import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';

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
///
/// 按页面取背景（拍板台 xxbbL0j15l）：页面经 [FushiBackdropPage] 把自己的路由登记成
/// 某个 [PageBackdropPage]，就按「全局 → 所属模块 → 本页」解析（[pageBackdropSettingsFor]
/// 的 `page`），与从哪个 tab 打开无关。
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

  /// [context] 所在页底下画的是用户选的**自定义图片**（不是形状 / 纯色）。
  ///
  /// 图片明暗、花纹不可控：直接压在图上的小字（侧栏导航、分组标题）对比度跟着
  /// 图片忽高忽低，要自己垫一层底（2026-11-20 用户截图：设置侧栏的字糊在樱花
  /// 壁纸上）。形状预设是低对比的大色块，不需要。
  static bool imageOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_FushiPageBackdropScope>()
          ?.image ??
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
    _pageRoutes,
    pageBackdropSettings,
    pageBackdropModuleOverrides,
    pageBackdropPageOverrides,
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
      settings: pageBackdropSettingsFor(
        _module(),
        page: route == null ? null : _pageRoutes.value[route],
      ),
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
            image:
                enabled &&
                resolved.settings.effectivePreset == PageBackdropPreset.custom,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _FushiPageBackdropScope extends InheritedWidget {
  const _FushiPageBackdropScope({
    required this.active,
    required this.image,
    required super.child,
  });

  final bool active;
  final bool image;

  @override
  bool updateShouldNotify(_FushiPageBackdropScope oldWidget) =>
      active != oldWidget.active || image != oldWidget.image;
}

/// 整页底色：在画形状的 [FushiPageBackdrop] 里是透明（底色与形状由背景层画），
/// 否则是设计 token 的页面底色。页面级 Scaffold / 整页 Material 的底色走这里，
/// 不要直接写 `tokens.surfaces.page`。
Color fushiPageBackgroundColor(BuildContext context) =>
    fushiPageBackgroundColorOr(
      context,
      FushiDesignTokens.of(context).surfaces.page,
    );

/// [fushiPageBackgroundColor] 的自带底色版：整页底色不是 `surfaces.page` 的地方
/// （Apple 设计的分组底 `groupedBackground`、玻璃外壳内容区的实色底）用它——
/// 背景层在画（用户的背景图片）时一律透明，否则 [opaque]。直接画 [opaque] 会把
/// 背景图片整片盖住（Apple 下选了图首页 / 设置页仍是白底）。
Color fushiPageBackgroundColorOr(BuildContext context, Color opaque) =>
    FushiPageBackdrop.activeOf(context) ? Colors.transparent : opaque;

/// 整页必须透明的路由（不画底色、不画形状）。
final ValueNotifier<Set<Route<Object?>>> _transparentPageRoutes =
    ValueNotifier<Set<Route<Object?>>>(<Route<Object?>>{});

/// 让 [route] 的 [FushiPageBackdrop] 整个让开（[transparent] = true）或恢复。
///
/// 给底层合成用（`underlay_composition.dart`：窗口宿主档的 WebView2 子窗口垫在 Flutter
/// 下面、从透明像素处透出来）：这一页的底色和背景装饰一旦画出来，就把网页整个盖住——
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

/// 登记成某个 [PageBackdropPage] 的路由（按页面取背景，拍板台 xxbbL0j15l）。
final ValueNotifier<Map<Route<Object?>, PageBackdropPage>> _pageRoutes =
    ValueNotifier<Map<Route<Object?>, PageBackdropPage>>(
      <Route<Object?>, PageBackdropPage>{},
    );

/// 把 [route] 登记成 [page]（null = 注销），其 [FushiPageBackdrop] 按这一页单独的
/// 背景设置画。页面一般不直接调，包一层 [FushiBackdropPage]。
///
/// 页面在 didChangeDependencies / dispose 里调，树是锁着的，通知等这一帧画完
/// （与 [setFushiPageRouteModuleShell] 同一做法）。
void setFushiPageRoutePage(Route<Object?> route, PageBackdropPage? page) {
  final SchedulerBinding binding = SchedulerBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    binding.addPostFrameCallback((Duration _) => _applyPageRoute(route, page));
    return;
  }
  _applyPageRoute(route, page);
}

void _applyPageRoute(Route<Object?> route, PageBackdropPage? page) {
  final Map<Route<Object?>, PageBackdropPage> current = _pageRoutes.value;
  if (current[route] == page) return;
  _pageRoutes.value = <Route<Object?>, PageBackdropPage>{
    for (final MapEntry<Route<Object?>, PageBackdropPage> e in current.entries)
      if (e.key != route) e.key: e.value,
    if (page != null) route: page,
  };
}

/// 声明 [child] 所在的这一页是 [page]：挂上时把所在路由登记给 [FushiPageBackdrop]，
/// 卸载时注销。只改背景层的取值，不往子树里加任何东西。
class FushiBackdropPage extends StatefulWidget {
  const FushiBackdropPage({required this.page, required this.child, super.key});

  final PageBackdropPage page;
  final Widget child;

  @override
  State<FushiBackdropPage> createState() => _FushiBackdropPageState();
}

class _FushiBackdropPageState extends State<FushiBackdropPage> {
  Route<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Route<Object?>? route = ModalRoute.of(context);
    if (route == _route) return;
    if (_route case final Route<Object?> previous) {
      setFushiPageRoutePage(previous, null);
    }
    _route = route;
    if (route != null) setFushiPageRoutePage(route, widget.page);
  }

  @override
  void didUpdateWidget(FushiBackdropPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      if (_route case final Route<Object?> route) {
        setFushiPageRoutePage(route, widget.page);
      }
    }
  }

  @override
  void dispose() {
    if (_route case final Route<Object?> route) {
      setFushiPageRoutePage(route, null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 不透明的页面底色：[FushiPageBackdrop] 把脚手架底色换成了透明，需要「盖住」
/// 内容的遮罩 / 渐隐改取这里（透明时退回 `colorScheme.surface`，与主题的脚手架
/// 底色同值）。玻璃主题的半透明底色原样返回。
Color fushiOpaquePageColor(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final Color scaffold = theme.scaffoldBackgroundColor;
  return scaffold.a > 0 ? scaffold : theme.colorScheme.surface;
}

/// 去掉 [theme] 页面转场里垫的 [FushiPageBackdrop]：每个平台的
/// [FushiBackdropPageTransitionsBuilder] 还原成它包着的内层 builder，转场动效 / 返回
/// 手势不变，只是路由不再垫页面底色和背景装饰。
///
/// 给盖在别的 app 上的透明浮窗用（app 外查词 `popup_main`、悬浮词典
/// `floating_dict_main`）：这类窗口没有「页」，卡片以外必须透出背后的 app。
/// 用户主题的转场里带着背景层，`home` 路由一经它就把整窗铺成页面底色 + 形状
/// （反馈 jDuyvS-Hly「app 外查词底下有多余的背景」）。主题本身（配色 / 组件 /
/// 墨水屏）照旧跟用户设置走。没垫背景层的主题原样返回。
ThemeData withoutFushiPageBackdrop(ThemeData theme) {
  final Map<TargetPlatform, PageTransitionsBuilder> builders =
      theme.pageTransitionsTheme.builders;
  if (!builders.values.any(
    (PageTransitionsBuilder b) => b is FushiBackdropPageTransitionsBuilder,
  )) {
    return theme;
  }
  return theme.copyWith(
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        for (final MapEntry<TargetPlatform, PageTransitionsBuilder> e
            in builders.entries)
          e.key: e.value is FushiBackdropPageTransitionsBuilder
              ? (e.value as FushiBackdropPageTransitionsBuilder).inner
              : e.value,
      },
    ),
  );
}

/// 给任意转场 builder 垫上 [FushiPageBackdrop]：转场作用在「底 + 页面」整体上。
///
/// 同时给这一页装 [FushiCoveredPageSnapshot]：被新页盖住 / 重新露出的转场途中
/// 画快照，不逐帧实时重画整页。
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
    FushiCoveredPageSnapshot(
      secondaryAnimation: secondaryAnimation,
      enabled: route.allowSnapshotting,
      child: FushiPageBackdrop(child: child),
    ),
  );
}

/// 被盖住的那一页在转场途中画成一张快照（[SnapshotWidget]）：新页推入 / 弹出、
/// 侧滑返回跟手时（[secondaryAnimation] 正在动），这一页从转场第 3 帧起只完整画
/// 一次，之后每帧贴这张图，随转场位移 / 压暗；转场一落定立刻回实时绘制。
///
/// **前两帧照常实时画再拍**：推页这一刻被盖住的页还会变——[Hero] 飞行在第一帧
/// 画完后才起飞（`HeroController` 的 post-frame），起点的 Hero 第二帧才换成占位；
/// `isCurrent` / `RouteAware.didPushNext` 引起的重建也在第一帧。快照拍下后子树
/// 再变不会反映到图上（[SnapshotWidget] 的语义），拍早了就会留下一个重影 Hero。
///
/// 起因（2026-11-27「打开视频系列这种二级页面会掉帧」，BUG-5582）：被盖住的页在
/// UI 侧并不重画（路由的 RepaintBoundary 层原样复用），但桌面 Impeller 没有 raster
/// cache，转场的每一帧都要把上下两页的绘制命令整页重放。视频库页静止一帧的 raster
/// 就要 5.5–6.4 ms（4K、RTX 4070 Ti，真实库），合集页约 2 ms，转场 600 ms 内平均
/// 约 10 ms 一帧，165 Hz 屏每帧预算约 6 ms，推入 / 返回全程掉帧；关掉玻璃材质与
/// 页面背景也只降 1–2 ms。同一次运行交替对照（`video_collection_perf_itest`，各 3
/// 次）：推入 raster 均值 9.6–11.1 → 4.5–4.9 ms、超 6 ms 的帧 44–54 → 13–23；
/// 返回 10.0–12.7 → 3.4–4.5 ms、38–43 → 5–7。被盖住的页在转场里不可交互，画快照
/// 与实时绘制看起来一样——Flutter 自己的 Zoom 转场也是这样做的（`allowSnapshotting`）。
///
/// - 转场途中页内若有东西在动（加载圈、视频画面），快照里它停在第一帧，落定后
///   恢复；这与 Flutter Zoom 转场的取舍一致。
/// - 含平台视图（WebView）的页拍不了快照，[SnapshotMode.permissive] 下照常实时画。
/// - 路由的 [TransitionRoute.allowSnapshotting] 为 false 时不拍。
/// - 子树结构恒定（[SnapshotWidget] 一直在，只切换控制器），转场前后页面 State
///   不重建。
///
/// 纯合成层优化，与设计系统无关（M3E / Apple 两套转场都经过这里）。
class FushiCoveredPageSnapshot extends StatefulWidget {
  const FushiCoveredPageSnapshot({
    required this.secondaryAnimation,
    required this.child,
    this.enabled = true,
    super.key,
  });

  /// 本页被上面那页盖住的进度（路由的 secondaryAnimation）。
  final Animation<double> secondaryAnimation;

  /// 允许拍快照（[TransitionRoute.allowSnapshotting]）。
  final bool enabled;

  final Widget child;

  @override
  State<FushiCoveredPageSnapshot> createState() =>
      _FushiCoveredPageSnapshotState();
}

class _FushiCoveredPageSnapshotState extends State<FushiCoveredPageSnapshot>
    with StateResourceScope<FushiCoveredPageSnapshot> {
  final SnapshotController _controller = SnapshotController();

  /// 已排了「隔两帧开拍」、还没轮到。转场途中页面照常重建（`didUpdateWidget`
  /// 每帧都可能来），不能每次都把计时重来，否则永远等不满两帧。
  bool _pending = false;

  /// 每次「不该拍」+1：作废还没轮到的延迟开拍。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.secondaryAnimation.addStatusListener(_onStatus);
    onTeardown(() => widget.secondaryAnimation.removeStatusListener(_onStatus));
    _sync();
  }

  @override
  void didUpdateWidget(FushiCoveredPageSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      oldWidget.secondaryAnimation.removeStatusListener(_onStatus);
      widget.secondaryAnimation.addStatusListener(_onStatus);
    }
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus _) => _sync();

  bool get _wanted =>
      widget.enabled && widget.secondaryAnimation.status.isAnimating;

  void _sync() {
    if (!_wanted) {
      _generation++;
      _pending = false;
      _controller.allowSnapshotting = false;
      return;
    }
    if (_controller.allowSnapshotting || _pending) return;
    _pending = true;
    final int generation = _generation;
    // 隔两帧再开拍（见类注释）。转场本身每帧都在出帧，post-frame 不必自己要帧。
    void afterFrames(int left) {
      SchedulerBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted || generation != _generation) return;
        if (left > 1) {
          afterFrames(left - 1);
          return;
        }
        _pending = false;
        if (_wanted) _controller.allowSnapshotting = true;
      });
    }

    afterFrames(2);
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _controller,
    mode: SnapshotMode.permissive,
    autoresize: true,
    child: widget.child,
  );
}

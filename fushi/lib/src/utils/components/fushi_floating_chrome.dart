import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiShellHeaderActions;
import 'package:fushi/src/utils/components/fushi_toolbar.dart'
    show FushiToolbarScope;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot;
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart'
    show SmoothWheelScrollScope;

// 库页的 M3 Expressive 浮动工具栏（2026-10-05「视频库页面也用浮动工具栏统一」）。
//
// 一组小件，组成「顶部悬浮的分区页签胶囊 + 悬浮动作组，滚动下行收起、上行弹回」：
//
// - [FushiFloatingChromeController]：显隐真相。宿主把视口滚动通知喂给
//   [FushiFloatingChromeController.handleScrollNotification]，下行累计超过阈值
//   收起、上行或回到顶部弹回。
// - [FushiFloatingChromeScope]：把 controller 下发给子树（页面里自己的工具行
//   用 [FushiFloatingChromeOverlay] 叠在内容上、跟着同一份显隐走）。
// - [FushiFloatingChromeOverlay]：工具区叠在内容上，收起只做位移 + 淡出，
//   **不改滚动视口的版面**；内容经 [FushiFloatingChromeInset] 让出恒定的顶部
//   高度。（曾经是「高度收到 0 把空间还给内容」：收起 / 弹回改变视口高度 →
//   滚动位置被夹紧 / 内容跳动 → 又被判成反向滚动 → 工具栏来回切，滚轮上下
//   都「回弹、滚不动」。）
// - [FushiSpringReveal]：弹簧驱动的「从边缘滑出 + 高度展开 + 淡入」，只给不随
//   滚动显隐的表面用（多选批量栏这类由状态切换驱动的工具栏）。
// - [FushiFloatingToolbarSurface]：M3E floating toolbar 的容器，与阅读器 / 首页
//   悬浮栏共用 `fushi_floating_toolbar.dart` 的同一枚胶囊（[FushiFloatingPill]）。
// - [FushiFloatingActionsPill]：把页头登记进 [FushiShellActionsSlot] 的动作画成
//   悬浮动作组；动作集合变了（如进入多选）按 M3E 上下文切换做形变交叉切换。
//
// 墨水屏与系统「减弱动态效果」下不做任何位移 / 形变（[fushiExpressiveMotionEnabled]），
// 显隐直接切换。

/// 浮动工具栏的显隐状态。
///
/// 判据只看**竖直**滚动：横滚的卡片行、页签条自身的横滑都不算。用户往下读
/// （内容上移）累计超过 [_kHideDistance] 且已经离开顶部 [_kHideAfterOffset] 才
/// 收起，往回拉超过同一距离、或回到顶部时立刻弹回——阈值去抖，手指在原地微抖
/// 不会让工具栏一闪一闪。
class FushiFloatingChromeController extends ChangeNotifier {
  FushiFloatingChromeController({bool visible = true}) : _visible = visible;

  /// 收起 / 弹回所需的同向累计滚动距离。
  static const double _kHideDistance = 24;

  /// 离顶部至少这么远才允许收起：首屏还看得见页头的时候没有收起的理由。
  static const double _kHideAfterOffset = 64;

  bool _visible;
  double _accumulated = 0;

  /// 上一条竖向通知的来源与视口高度：同一滚动视图的视口高度变了，说明这一帧的
  /// 位移来自版面修正（夹紧 / 重新布局），不是用户在滚。
  BuildContext? _lastContext;
  double? _lastViewportDimension;

  /// 驱动显隐的滚动区深度（见过的最浅竖向滚动区）。
  int? _ownerDepth;

  /// 内容是否已滚离顶部（有内容在工具区底下）。顶部渐隐遮罩只在此时出现：
  /// 没滚动时工具区下面就是内容的第一行，遮罩只会把它压暗一截。
  bool get contentUnderTop => _contentUnderTop;
  bool _contentUnderTop = false;

  /// 工具栏此刻应当显示。
  bool get visible => _visible;

  void show() => _set(true);

  /// 换了视图 / 分区（新页面从顶部开始）：工具栏回来，遮罩撤掉，重新认主滚动区。
  void resetToTop() {
    _ownerDepth = null;
    _lastContext = null;
    _lastViewportDimension = null;
    if (_contentUnderTop) {
      _contentUnderTop = false;
      notifyListeners();
    }
    show();
  }

  void hide() => _set(false);

  void _set(bool value) {
    _accumulated = 0;
    if (_visible == value) return;
    _visible = value;
    notifyListeners();
  }

  /// 喂一条滚动通知；永远返回 false（不拦截冒泡，外壳的大标题收起照常收到）。
  bool handleScrollNotification(ScrollNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    // 平滑滚轮补间的「拉回起点」不是用户在往回滚（见
    // [SmoothWheelScrollScope.isRewinding]）：不当方向、也不当手势结束。
    if (SmoothWheelScrollScope.isRewinding) return false;
    // 只认最外层的竖向滚动区：卡片里嵌套的竖向列表（展开的源列表、弹层里的
    // 小列表）有自己的位置与方向，混进来会和主列表互相打架。
    final int depth = notification.depth;
    final int? owner = _ownerDepth;
    if (owner != null && depth > owner) return false;
    if (notification is ScrollUpdateNotification &&
        (owner == null || depth < owner)) {
      _ownerDepth = depth;
    }
    final bool underTop = metrics.extentBefore > 0.5;
    if (underTop != _contentUnderTop) {
      _contentUnderTop = underTop;
      notifyListeners();
    }
    final bool sameScrollable = identical(notification.context, _lastContext);
    final bool viewportChanged =
        sameScrollable &&
        _lastViewportDimension != null &&
        _lastViewportDimension != metrics.viewportDimension;
    _lastContext = notification.context;
    _lastViewportDimension = metrics.viewportDimension;
    // 不在 [ScrollEndNotification] 清零：滚轮每一档都是一组完整的
    // start / update / end，高精度滚轮一档只有十来 px，逐档清零就永远攒不到
    // 阈值。累计只在反向时清零（滞回），以及在顶部「不许收起」的区间里不攒。
    if (notification is! ScrollUpdateNotification) return false;
    if (metrics.pixels <= metrics.minScrollExtent + 0.5) {
      show();
      return false;
    }
    final double delta = notification.scrollDelta ?? 0;
    if (delta == 0) return false;
    // 只认用户滚动带来的位移（BUG：滚轮上下都「回弹」）：
    // - 视口高度变了 = 版面修正，位移是被夹紧出来的；
    // - 停在底部还在往回走 = 内容总长缩短后的夹紧（用户往上滚一格就离开底部了）；
    // - 越界回弹（Apple 弹性滚动）不是方向意图。
    if (viewportChanged || metrics.outOfRange) return false;
    if (delta < 0 && metrics.extentAfter <= 0.5) return false;
    if (_accumulated != 0 && delta.sign != _accumulated.sign) {
      _accumulated = 0;
    }
    if (delta > 0 && metrics.pixels <= _kHideAfterOffset) {
      _accumulated = 0;
      return false;
    }
    _accumulated += delta;
    if (_accumulated > _kHideDistance && metrics.pixels > _kHideAfterOffset) {
      hide();
    } else if (_accumulated < -_kHideDistance) {
      show();
    }
    return false;
  }
}

/// 下发 [FushiFloatingChromeController]。
class FushiFloatingChromeScope
    extends InheritedNotifier<FushiFloatingChromeController> {
  const FushiFloatingChromeScope({
    required FushiFloatingChromeController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  /// 最近的浮动工具栏 controller；不在库页浮动外壳里为 null。
  static FushiFloatingChromeController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiFloatingChromeScope>()
      ?.notifier;

  /// 同 [maybeOf]，但不建立依赖（initState / 回调里取用）。
  static FushiFloatingChromeController? peek(BuildContext context) => context
      .getInheritedWidgetOfExactType<FushiFloatingChromeScope>()
      ?.notifier;
}

/// 浮动工具区叠在内容上时，内容顶部要让出的高度（逻辑 px）。
///
/// 由 [FushiFloatingChromeOverlay] 下发，**恒等于工具区的实测高度，不随显隐
/// 变**：收起只是把工具区移出画面，滚动视口的尺寸与内容的版面一帧都不动——
/// 这样收起 / 弹回不会反过来改变滚动位置，也就不会自激（滚轮上下都「回弹、
/// 滚不动」的根因）。主滚动视图把它加成顶部内边距（内容滚到工具区底下），
/// 其它页面用 [FushiFloatingChromeInsetPadding] 整体让开。没挂时为 0。
class FushiFloatingChromeInset extends InheritedWidget {
  const FushiFloatingChromeInset({
    required this.top,
    required super.child,
    super.key,
  });

  final double top;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiFloatingChromeInset>()
          ?.top ??
      0;

  @override
  bool updateShouldNotify(FushiFloatingChromeInset oldWidget) =>
      top != oldWidget.top;
}

/// 把 [child] 整体下移 [FushiFloatingChromeInset] 的高度（不会自己加顶部内边距
/// 的页面用；高度恒定，不随工具区显隐变）。子树里的 inset 归零，不重复让。
class FushiFloatingChromeInsetPadding extends StatelessWidget {
  const FushiFloatingChromeInsetPadding({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double top = FushiFloatingChromeInset.of(context);
    final FushiFloatingChromeController? controller =
        FushiFloatingChromeScope.maybeOf(context);
    final Widget inner = FushiFloatingChromeInset(top: 0, child: child);
    return Padding(
      padding: EdgeInsets.only(top: top),
      // 工具区收起后上方让出的那段是空的，内容在它下沿被齐刷刷切断；给下沿
      // 加一道渐隐（只在收起时出现——显示时工具区自己的遮罩已经盖住这里），
      // 让内容柔和地淡出而不是硬切。版面不动。
      // 结构只随「有没有作用域」变（恒定），inset 首帧为 0 时只是不显示，
      // 不会因为高度回报而重挂子树。
      child: controller == null
          ? inner
          : Stack(
              fit: StackFit.passthrough,
              children: <Widget>[
                inner,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity:
                        controller.visible ||
                            top <= 0 ||
                            !controller.contentUnderTop
                        ? 0
                        : 1,
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    // 遮罩顶边紧贴让出的那段（页面底色），从 1 起才没有接缝。
                    child: const FushiTopFadeScrim(
                      solidHeight: 0,
                      topOpacity: 1,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 跟随 [FushiFloatingChromeScope] 显隐的一段工具区，**叠在 [child] 上**
/// （外壳的页签 / 动作行、页面里的页头与搜索筛选行共用同一份显隐，一起收）。
///
/// [child] 恒占满整个区域，工具区浮在它顶部；[child] 经
/// [FushiFloatingChromeInset] 拿到「顶部要让出多少」（外层 inset + 本工具区
/// 实测高度）。收起 = 工具区向上滑出画面 + 淡出（M3E default spatial 弹簧），
/// 不改任何版面。嵌套时内层工具区排在外层工具区下方，收起时一起滑出。
///
/// 收起后键盘 / 手柄焦点走进来（Tab 遍历到页签或按钮）立刻弹回：收起只是让出
/// 屏幕，不能让控件变得够不着。没挂作用域时退化成常驻的「工具区 + 内容」竖排。
class FushiFloatingChromeOverlay extends StatefulWidget {
  const FushiFloatingChromeOverlay({
    required this.chrome,
    required this.child,
    super.key,
  });

  final Widget chrome;
  final Widget child;

  @override
  State<FushiFloatingChromeOverlay> createState() =>
      _FushiFloatingChromeOverlayState();
}

class _FushiFloatingChromeOverlayState extends State<FushiFloatingChromeOverlay>
    with SingleTickerProviderStateMixin {
  /// 工具区的实测高度（展开态的版面高度；收起不改它）。
  double _chromeHeight = 0;

  /// 1 = 完全显示，0 = 收起。M3E default spatial 弹簧，重定向带着速度续上。
  /// 只在挂着作用域时创建（首次 [didChangeDependencies] 里按当时的显隐定初值）。
  FushiSpring? _shown;

  FushiFloatingChromeController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final FushiFloatingChromeController? controller =
        FushiFloatingChromeScope.maybeOf(context);
    _controller = controller;
    if (controller == null) return;
    final FushiSpring? spring = _shown;
    if (spring == null) {
      _shown = FushiSpring(
        vsync: this,
        initial: controller.visible ? 1 : 0,
        spring: fushiExpressiveDefaultSpatial,
      );
    } else {
      spring.animateTo(
        controller.visible ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _shown?.dispose();
    super.dispose();
  }

  void _onChromeHeight(double height) {
    if (!mounted || height == _chromeHeight) return;
    setState(() => _chromeHeight = height);
  }

  @override
  Widget build(BuildContext context) {
    final FushiFloatingChromeController? controller = _controller;
    final FushiSpring? spring = _shown;
    if (controller == null || spring == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          widget.chrome,
          Expanded(child: widget.child),
        ],
      );
    }
    final double outer = FushiFloatingChromeInset.of(context);
    final double travel = outer + _chromeHeight;
    final Widget chrome = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool focused) {
        if (focused) controller.show();
      },
      child: FushiHeightReporter(
        onHeight: _onChromeHeight,
        child: widget.chrome,
      ),
    );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: FushiFloatingChromeInset(top: travel, child: widget.child),
        ),
        // 顶部渐隐遮罩 + 工具区：同一弹簧驱动。遮罩只盖「此刻看得见的工具区」
        // 再往下渐隐一段，收起后只剩顶边一条柔和淡出——不再有整块实色底带把
        // 内容齐刷刷切掉。胶囊自己有表面色与投影，不靠底色遮挡内容。
        AnimatedBuilder(
          animation: spring.animation,
          child: chrome,
          builder: (BuildContext context, Widget? chrome) {
            final double value = spring.value;
            final double shown = value.clamp(0.0, 1.0);
            final bool hidden = shown <= 0.001;
            return Stack(
              children: <Widget>[
                // 遮罩在内容之上、所有 chrome（外壳标题、页签、按钮组、搜索行）
                // 之下：实色段盖住外壳标题区（[outer]）+ 此刻可见的工具区，
                // 再往下渐隐。没滚动时不画（工具区下面就是第一行内容）。
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: controller.contentUnderTop ? 1 : 0,
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    child: FushiTopFadeScrim(
                      solidHeight: outer + shown * _chromeHeight,
                    ),
                  ),
                ),
                Positioned(
                  top: outer,
                  left: 0,
                  right: 0,
                  child: ExcludeSemantics(
                    excluding: hidden,
                    child: IgnorePointer(
                      // 收起途中就不再接指针（正在离开的工具栏不该还能被点到）。
                      ignoring: hidden || !controller.visible,
                      child: Opacity(
                        opacity: hidden ? 0 : shown,
                        child: Transform.translate(
                          // 用未截断的弹簧值：轻微回弹体现在位置上。
                          offset: Offset(0, -(1 - value) * travel),
                          child: chrome,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 浮动工具区背后的顶部渐隐遮罩（M3E 浮动工具栏：内容滚到工具栏底下时柔和
/// 淡出，而不是被一条实色底带硬切）。**所有浮动顶栏页面的顶部可读性只走这一个
/// 组件**（顶栏 [FushiAppBar] 悬浮形态、[FushiPageScaffold] 页头、库页
/// [FushiFloatingChromeOverlay]），页面不得自己画整宽底带 / 渐变。
///
/// 不透明度曲线自顶向下**单调、连续、无平台**：
/// - [solidHeight] 内是一段「肩」：从 [topOpacity] 二次缓降到 0.82 倍（顶端
///   斜率为 0，没有一刀切的实色矩形）；
/// - 其后 [fadeExtent] 内按 smoothstep 降到 0（两端斜率都为 0）。
///
/// 曾经的形态是「0.92 → 0.8 的实色段 + 20 px 线性降到 0」：线性渐变的起止点
/// 斜率突变，在模糊 fanart 上看得见一道 Mach 带；而顶栏把它从栏下沿开始画（栏内
/// 透明），不透明度在下沿处从 0 跳到 0.92——详情页滚动后栏下沿那条「水平硬边」
/// 就是它。
///
/// [topOpacity] 的取法：遮罩顶边紧贴一块**不透明的同色底**（正文视口被页头 /
/// 顶栏裁在这条线上，线以上是页面底色）时传 1，接缝两侧颜色一致、看不出切线；
/// 遮罩从窗口顶端起盖在可滚动内容上（[Scaffold.extendBodyBehindAppBar]）时用
/// [kFushiTopScrimOverlayOpacity]。
///
/// 不接指针、不参与语义。颜色取 [color]，缺省为页面底色
/// （[fushiTopFadeScrimColor]）。
class FushiTopFadeScrim extends StatelessWidget {
  const FushiTopFadeScrim({
    required this.solidHeight,
    this.fadeExtent = kFushiTopFadeExtent,
    this.topOpacity = 0.92,
    this.color,
    super.key,
  });

  final double solidHeight;
  final double fadeExtent;

  /// 顶边的不透明度（乘在 [color] 自身的 alpha 上）。
  final double topOpacity;
  final Color? color;

  /// 肩段末端相对 [topOpacity] 的比例。
  static const double _kShoulderFloor = 0.82;

  /// 肩段 / 渐隐段各取多少个采样点（多段线性近似平滑曲线，段数足够多时
  /// 肉眼看不到折点）。
  static const int _kShoulderSamples = 4;
  static const int _kFadeSamples = 10;

  @override
  Widget build(BuildContext context) {
    final double solid = math.max(0.0, solidHeight);
    final double fade = math.max(1.0, fadeExtent);
    final double height = solid + fade;
    final Color base = color ?? fushiTopFadeScrimColor(context);
    final double top = base.a * topOpacity.clamp(0.0, 1.0);
    final List<Color> colors = <Color>[];
    final List<double> stops = <double>[];
    void sample(double y, double alpha) {
      colors.add(base.withValues(alpha: alpha.clamp(0.0, 1.0)));
      stops.add((y / height).clamp(0.0, 1.0));
    }

    final double fadeStart;
    if (solid > 0) {
      for (int i = 0; i <= _kShoulderSamples; i++) {
        final double u = i / _kShoulderSamples;
        sample(solid * u, top * (1 - (1 - _kShoulderFloor) * u * u));
      }
      fadeStart = top * _kShoulderFloor;
    } else {
      fadeStart = top;
    }
    for (int i = solid > 0 ? 1 : 0; i <= _kFadeSamples; i++) {
      final double v = i / _kFadeSamples;
      final double eased = v * v * (3 - 2 * v);
      sample(solid + fade * v, fadeStart * (1 - eased));
    }
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
                stops: stops,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部渐隐遮罩的缺省颜色：页面底色。玻璃主题下脚手架底色可能是半透明的，
/// 退回设计 token 的页面底色，免得遮罩形同虚设。
Color fushiTopFadeScrimColor(BuildContext context) {
  final Color scaffold = Theme.of(context).scaffoldBackgroundColor;
  if (scaffold.a >= 1) return scaffold;
  return FushiDesignTokens.of(context).surfaces.page;
}

/// [FushiTopFadeScrim] 渐隐段的默认长度（胶囊 / 栏下沿再往下 32）。
const double kFushiTopFadeExtent = 32;

/// 遮罩盖在可滚动内容上、从窗口顶端起画时的顶边不透明度（见
/// [FushiTopFadeScrim.topOpacity]）：够让悬浮胶囊之间的内容退后，又不至于在
/// fanart 上压出一条浅色带。
const double kFushiTopScrimOverlayOpacity = 0.72;

/// 版面完成后把子组件高度报给 [onHeight]（变了才报，本帧结束后回调）。
class FushiHeightReporter extends SingleChildRenderObjectWidget {
  const FushiHeightReporter({
    required this.onHeight,
    required super.child,
    super.key,
  });

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFushiHeightReporter(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFushiHeightReporter renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderFushiHeightReporter extends RenderProxyBox {
  _RenderFushiHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final double height = size.height;
    if (_reported == height) return;
    _reported = height;
    // 版面阶段不能 setState：本帧结束后再报（当前正处在一帧之内，回调必跑）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}

/// 弹簧驱动的显隐：[visible] 由 false 变 true 时内容从 [edge] 那一侧滑出、
/// 高度展开、淡入；反之收回、高度归零。
///
/// 弹簧取 M3 Expressive「default spatial」（刚度 700、阻尼比 0.9，轻微回弹）。
/// 重定向带着当前速度续上，滚动方向来回切也不会跳帧。墨水屏 / 减弱动态效果
/// 下直接切换。收起后 [child] 默认不卸载（State 与焦点注册都保留），只是零高度、
/// 不可点、不可读（[ExcludeSemantics]）；再次显示时原样回来。收起途中就不再
/// 接指针（正在离开的工具栏不该还能被点到）。
class FushiSpringReveal extends StatefulWidget {
  const FushiSpringReveal({
    required this.visible,
    required this.child,
    this.edge = VerticalDirection.up,
    this.maintainState = true,
    super.key,
  });

  final bool visible;
  final Widget child;

  /// false：完全收起后把 [child] 换成零尺寸占位（上下文工具栏这类每次重建
  /// 内容的表面用；收起后树里不再有它的按钮）。
  final bool maintainState;

  /// 内容从哪条边滑出：[VerticalDirection.up] = 顶部工具栏（向上收起），
  /// [VerticalDirection.down] = 底部工具栏（向下收起）。
  final VerticalDirection edge;

  @override
  State<FushiSpringReveal> createState() => _FushiSpringRevealState();
}

class _FushiSpringRevealState extends State<FushiSpringReveal>
    with SingleTickerProviderStateMixin {
  late final FushiSpring _spring = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );

  @override
  void didUpdateWidget(covariant FushiSpringReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _spring.animateTo(
        widget.visible ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool fromTop = widget.edge == VerticalDirection.up;
    return AnimatedBuilder(
      animation: _spring.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double value = _spring.value;
        // 弹簧按容差收敛，静止值离目标还差 1e-4 量级：两端吸附，免得「收起」
        // 留下一丝几何、「展开」一直走裁剪分支。
        double extent = value.clamp(0.0, 1.0);
        if (extent >= 0.999 && widget.visible) return child!;
        final bool hidden = extent <= 0.001;
        if (hidden) extent = 0;
        if (hidden && !widget.visible && !widget.maintainState) {
          return const SizedBox.shrink();
        }
        // 位移用未截断的弹簧值：轻微回弹体现在位置上，高度不会超过 1。
        final double slide = (1 - value) * 16 * (fromTop ? -1 : 1);
        return ExcludeSemantics(
          excluding: hidden,
          child: IgnorePointer(
            ignoring: hidden || !widget.visible,
            child: ClipRect(
              child: Align(
                alignment: fromTop
                    ? Alignment.bottomCenter
                    : Alignment.topCenter,
                heightFactor: extent,
                child: Opacity(
                  opacity: extent,
                  child: Transform.translate(
                    offset: Offset(0, slide),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// M3 Expressive floating toolbar 的容器：与阅读器 / 首页的悬浮工具栏同一枚
/// 胶囊（[FushiFloatingPill] + [fushiFloatingToolbarPalette]，见
/// `fushi_floating_toolbar.dart`）。
///
/// - MD3：surfaceContainer 全胶囊 + Elevation 3 两层投影；[vibrant] 时
///   primaryContainer（上下文工具栏用）；
/// - Apple：分组背景色胶囊 + 发丝描边 + 柔和偏下投影（不做实时背景模糊，
///   与阅读器悬浮栏同口径）；
/// - 墨水屏：无阴影，一圈 outline。
class FushiFloatingToolbarSurface extends StatelessWidget {
  const FushiFloatingToolbarSurface({
    required this.child,
    this.height = 56,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    this.vibrant = false,
    super.key,
  });

  final Widget child;

  /// 胶囊最小高度（M3E floating toolbar 紧凑档 56）。
  final double height;
  final EdgeInsetsGeometry padding;

  /// M3E 的「vibrant」配色（primaryContainer）。Apple 设计系统下忽略。
  final bool vibrant;

  /// 胶囊底色（页签条两端渐隐要用同一个颜色才盖得住）。
  static Color colorOf(BuildContext context, {bool vibrant = false}) =>
      fushiFloatingToolbarPalette(
        context,
        variant: vibrant
            ? FushiFloatingToolbarVariant.vibrant
            : FushiFloatingToolbarVariant.standard,
      ).container;

  @override
  Widget build(BuildContext context) {
    return FushiFloatingPill(
      color: colorOf(context, vibrant: vibrant),
      padding: padding,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: math.max(0, height - padding.vertical),
        ),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
      ),
    );
  }
}

/// 悬浮动作组：画出 [slot] 里当前可见页头登记的动作。
///
/// 动作集合变了（切分区多 / 少一个按钮、进入多选换成「完成」）时整组按
/// M3E 上下文切换交叉形变：旧组缩小淡出、新组从 0.8 弹到 1，胶囊宽度跟着
/// 弹簧过渡。没有动作时零尺寸。
///
/// MD3 下是 [FushiFloatingToolbarSurface] 胶囊里一排无底图标按钮；Apple 下
/// 动作本身已由 [FushiShellHeaderActions] 收进玻璃胶囊，这里只补悬浮投影，
/// 不再套第二层玻璃（玻璃叠玻璃会出两圈折射边）。
class FushiFloatingActionsPill extends StatelessWidget {
  const FushiFloatingActionsPill({required this.slot, super.key});

  final FushiShellActionsSlot slot;

  /// 动作集合的身份：按 key（没有就按类型）逐个取，数量或成员变了才算换组。
  static Object _signatureOf(Widget actions) {
    if (actions is! FushiShellHeaderActions) return actions.runtimeType;
    return Object.hashAll(<Object>[
      for (final Widget item in actions.actions) item.key ?? item.runtimeType,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: slot,
      builder: (BuildContext context, Widget? _) {
        final Widget? actions = slot.actions;
        final bool motion = fushiExpressiveMotionEnabled(context);
        final Widget pill = actions == null
            ? const SizedBox.shrink(key: ValueKey<String>('empty'))
            : KeyedSubtree(
                key: ValueKey<Object>(_signatureOf(actions)),
                child: _FloatingActionsBody(actions: actions),
              );
        return AnimatedSize(
          duration: motion ? const Duration(milliseconds: 420) : Duration.zero,
          curve: const FushiSpringCurve(),
          alignment: AlignmentDirectional.centerEnd,
          clipBehavior: Clip.none,
          child: AnimatedSwitcher(
            duration: motion
                ? const Duration(milliseconds: 360)
                : Duration.zero,
            reverseDuration: motion
                ? const Duration(milliseconds: 160)
                : Duration.zero,
            switchInCurve: const FushiSpringCurve(),
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: AlignmentDirectional.centerEnd,
              clipBehavior: Clip.none,
              children: <Widget>[...previous, if (current != null) current],
            ),
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
                    alignment: AlignmentDirectional.centerEnd.resolve(
                      Directionality.of(context),
                    ),
                    child: child,
                  ),
                ),
            child: pill,
          ),
        );
      },
    );
  }
}

class _FloatingActionsBody extends StatelessWidget {
  const _FloatingActionsBody({required this.actions});

  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (isGlassDesign(context) && actions is FushiShellHeaderActions) {
      // Apple：外壳动作组自带一层玻璃胶囊（[FushiToolbar]），放进悬浮胶囊里会
      // 叠出两圈边。直接把按钮排进胶囊，并告诉它们「已在胶囊组里」（不再各自
      // 带玻璃底）；放不下时横滑兜底。
      content = FushiToolbarScope(
        inGlassGroup: true,
        child: HorizontalDragScrollable(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: (actions as FushiShellHeaderActions).actions,
            ),
          ),
        ),
      );
    } else if (actions is FushiShellHeaderActions) {
      // MD3（M3E）：外壳动作组自己就把图标收进一枚 56 高的按钮组胶囊（与页签
      // 胶囊同高同表面）、文字动作画成同高的 tonal 胶囊按钮
      // （[fushiFloatingHeaderActionGroups]）。这里**不能**再套悬浮面，也不能
      // 把全部按钮直接排进一颗悬浮面——前者是两圈胶囊、后者把「开始串流」
      // 这类文字按钮关进图标组里（2026-10-06 用户两次截图「胶囊包胶囊」）。
      return actions;
    } else {
      content = actions;
    }
    return FushiFloatingToolbarSurface(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: content,
    );
  }
}

/// M3 Expressive 弹簧的曲线近似（给只吃 [Curve] 的隐式动画用，如
/// [AnimatedSize] / [AnimatedSwitcher]）：刚度 [stiffness]、阻尼比
/// [dampingRatio]，在 [seconds] 秒内走完；末端钉死在 1（隐式动画要求终值精确）。
class FushiSpringCurve extends Curve {
  const FushiSpringCurve({
    this.stiffness = 700,
    this.dampingRatio = 0.8,
    this.seconds = 0.42,
  });

  final double stiffness;
  final double dampingRatio;
  final double seconds;

  @override
  double transformInternal(double t) {
    final SpringSimulation simulation = SpringSimulation(
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: stiffness,
        ratio: dampingRatio,
      ),
      0,
      1,
      0,
    );
    return simulation.x(t * seconds);
  }
}

/// 页签胶囊与动作胶囊之间的间距，以及工具栏到页面边缘 / 内容的外边距。
const double kFushiFloatingChromeGap = 8;

/// 浮动工具栏一行：左边分区页签胶囊（[tabs]），右边悬浮动作组（[slot]）。
///
/// 页签按自然宽贴左（摆不下时在胶囊里横滑），动作组按自然宽贴右；窄屏上
/// 动作组最多占一半行宽，再多由 [FushiShellHeaderActions] 收进 ⋯。整行跟随
/// [FushiFloatingChromeOverlay] 显隐（由外壳把整行叠在内容上）。
class FushiFloatingChromeBar extends StatelessWidget {
  const FushiFloatingChromeBar({
    required this.tabs,
    required this.slot,
    this.padding,
    this.leading,
    super.key,
  });

  final Widget tabs;
  final FushiShellActionsSlot slot;
  final EdgeInsetsGeometry? padding;

  /// 页签胶囊左边的前导（独立 push 进来的页面的返回键，一枚圆胶囊）；与
  /// 页签胶囊同一行、间距 [kFushiFloatingChromeGap]。
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // M3E 收紧（2026-10-06 用户截图「标题与页签、页签与内容留白偏大」）：
      // 顶边不再加距——外壳大标题自带 8 的下沿留白，就是标题到胶囊的那段
      // 间距；底边只留 4 容胶囊投影（elevation 3），收起动画的裁剪不切到
      // 影子，页面页头自己再给 12，合计约 16。左右与外壳大标题、页面内容
      // 同一条页边（[FushiSpacingTokens.page]），胶囊左缘对齐标题左缘。
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            FushiDesignTokens.of(context).spacing.page,
            0,
            FushiDesignTokens.of(context).spacing.page,
            kFushiFloatingChromeGap / 2,
          ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double maxActions = constraints.maxWidth.isFinite
              ? math.max(56.0, constraints.maxWidth / 2)
              : double.infinity;
          return FocusTraversalGroup(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (leading != null) ...<Widget>[
                  leading!,
                  const SizedBox(width: kFushiFloatingChromeGap),
                ],
                Expanded(child: tabs),
                const SizedBox(width: kFushiFloatingChromeGap),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxActions),
                  child: FushiFloatingActionsPill(slot: slot),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

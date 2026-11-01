import 'dart:math' as math;

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart'
    show
        FushiHeaderSearchBar,
        FushiHeaderSearchController,
        fushiVisibleHeaderSearch;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiHeaderCrampScope, FushiShellHeaderActions;
import 'package:fushi/src/utils/components/fushi_toolbar.dart'
    show FushiToolbar;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart'
    show
        FushiPageChromeTitle,
        fushiAppleChromeSpatial,
        fushiChromeRevealFadeSpring,
        fushiChromeRevealSpring,
        kFushiPageChromeExtent;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot, FushiShellTitleScope;
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
//
// Apple 设计系统（[isGlassDesign]）：显隐 / 换组改走 `context.fushiMotion` 的 Apple
// 弹簧（临界阻尼，不过冲，[fushiChromeRevealSpring]），换组只交叉淡变不缩放；动作组
// 是 [FushiToolbar] 的悬浮分组玻璃胶囊，标题是纯文字（iOS 26 / macOS 26 工具栏）。

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

  /// 喂一条 [ScrollMetricsNotification]（内容长度 / 视口变化后的版面修正）。
  ///
  /// BUG-3133：版面把滚动位置夹回去（删掉视频后列表缩短到一屏放得下）只发这类
  /// 通知、**不发** ScrollUpdate——[handleScrollNotification] 看不见它。工具区停在
  /// 收起态，内容却已经滚不动，用户再也唤不回顶部那一块（只能改缩放 / 重启）。
  /// 这里只认主滚动区：位置落回顶部（含「整页都放得下」）就弹回工具区并撤遮罩。
  bool handleScrollMetricsNotification(ScrollMetricsNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    final int? owner = _ownerDepth;
    if (owner != null && notification.depth > owner) return false;
    final bool underTop = metrics.extentBefore > 0.5;
    if (underTop != _contentUnderTop) {
      _contentUnderTop = underTop;
      notifyListeners();
    }
    if (metrics.pixels <= metrics.minScrollExtent + 0.5) show();
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

/// 浮动工具区此刻的**可见下沿**（逻辑 px，相对页面顶边；随收起 / 弹回动画
/// 连续变化，完全收起为 0）。由 [FushiFloatingChromeOverlay] 下发，嵌套时取
/// 最内层（它的下沿最低）。
///
/// 只给「跟随工具区」的东西用：固定版面的顶部让位
/// （[FushiFloatingChromeVisiblePadding]）、吸顶小标题的钉住位置
/// （[FushiFloatingChromePinnedOffset]）、跳转定位
/// （[fushiRevealBelowFloatingChrome]）。滚动内容的让位仍是恒定的
/// [FushiFloatingChromeInset]（让位随动画变会改视口，滚轮来回自激）。
class FushiFloatingChromeVisibleExtent extends InheritedWidget {
  const FushiFloatingChromeVisibleExtent({
    required this.extent,
    required super.child,
    super.key,
  });

  final ValueListenable<double> extent;

  /// 最近的可见下沿；不在浮动工具区下为 null。不建立依赖（值本身可监听）。
  static ValueListenable<double>? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<FushiFloatingChromeVisibleExtent>()
      ?.extent;

  /// 此刻的可见下沿；不在浮动工具区下为 0。
  static double valueOf(BuildContext context) => maybeOf(context)?.value ?? 0;

  @override
  bool updateShouldNotify(FushiFloatingChromeVisibleExtent oldWidget) =>
      !identical(extent, oldWidget.extent);
}

/// **固定版面**（没有整页滚动视图可以让位的页面，如游戏捕获工作台）的顶部
/// 让位：顶部 padding = 工具区此刻的可见下沿，随收起动画连续缩到 0——工具区
/// 收起后版面跟着上移、不留空白。子树里的 inset 归零。
///
/// 滚动页面不要用它（视口随动画变会让滚动位置被夹紧、自激），用
/// [FushiFloatingChromeScrollInset]。
class FushiFloatingChromeVisiblePadding extends StatelessWidget {
  const FushiFloatingChromeVisiblePadding({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Widget inner = FushiFloatingChromeInset(top: 0, child: child);
    final ValueListenable<double>? extent =
        FushiFloatingChromeVisibleExtent.maybeOf(context);
    if (extent == null) {
      return Padding(
        padding: EdgeInsets.only(top: FushiFloatingChromeInset.of(context)),
        child: inner,
      );
    }
    return ValueListenableBuilder<double>(
      valueListenable: extent,
      child: inner,
      builder: (BuildContext context, double top, Widget? child) => Padding(
        padding: EdgeInsets.only(top: top),
        child: child,
      ),
    );
  }
}

/// 把 [target] 所在分组滚到**工具区可见下沿之下**（再隔 [gap]），而不是视口顶
/// ——视口顶在浮动工具区底下，目标会被胶囊挡住。跳转条（设置分组、诊断分组
/// 等）统一用它。不在浮动工具区下返回 false，调用方走原来的定位。
bool fushiRevealBelowFloatingChrome(
  BuildContext target, {
  required Duration duration,
  double gap = 8,
}) {
  final ValueListenable<double>? extent =
      FushiFloatingChromeVisibleExtent.maybeOf(target);
  if (extent == null) return false;
  final RenderObject? object = target.findRenderObject();
  final ScrollableState? scrollable = Scrollable.maybeOf(target);
  if (object == null || scrollable == null || !object.attached) return false;
  final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
    object,
  );
  if (viewport == null) return false;
  final ScrollPosition position = scrollable.position;
  final double reveal = viewport.getOffsetToReveal(object, 0).offset;
  final double to = (reveal - extent.value - gap).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if (duration == Duration.zero) {
    position.jumpTo(to);
  } else {
    position.animateTo(to, duration: duration, curve: FushiMotion.standard);
  }
  return true;
}

/// 吸顶小标题（[PinnedHeaderSliver] 等的子组件）钉住时**钉在工具区可见下沿**，
/// 而不是视口顶（那里被浮动工具区挡住）：自己贴着视口顶时，按可见下沿把内容
/// 往下画，随收起动画跟着上移。只改绘制位置（小标题不接指针），不改版面。
class FushiFloatingChromePinnedOffset extends SingleChildRenderObjectWidget {
  const FushiFloatingChromePinnedOffset({required super.child, super.key});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPinnedOffset(FushiFloatingChromeVisibleExtent.maybeOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPinnedOffset renderObject,
  ) {
    renderObject.extent = FushiFloatingChromeVisibleExtent.maybeOf(context);
  }
}

class _RenderPinnedOffset extends RenderProxyBox {
  _RenderPinnedOffset(this._extent);

  ValueListenable<double>? _extent;

  set extent(ValueListenable<double>? value) {
    if (identical(value, _extent)) return;
    if (attached) _extent?.removeListener(markNeedsPaint);
    _extent = value;
    if (attached) _extent?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _extent?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _extent?.removeListener(markNeedsPaint);
    super.detach();
  }

  double _shift() {
    final double extent = _extent?.value ?? 0;
    if (extent <= 0) return 0;
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
      this,
    );
    if (viewport is! RenderBox) return 0;
    final double top = MatrixUtils.transformPoint(
      getTransformTo(viewport),
      Offset.zero,
    ).dy;
    // 贴着视口顶 = 正在钉住（还在正常位置时不动）。
    return top <= 0.5 ? extent : 0;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? box = child;
    if (box == null) return;
    context.paintChild(box, offset + Offset(0, _shift()));
  }
}

/// 库页浮动工具区下的**唯一页面入口**（2026-10-06 结构收口）：把叠放工具区的
/// 让位高度 [FushiFloatingChromeInset] 换成 `MediaQuery` 顶部 padding 交给
/// [child]，子树里的 inset 归零。
///
/// 这样页面的主滚动视图按 Flutter 的通用约定自己吃掉这段让位——
/// `ListView` / `GridView`（`padding` 为 null 时）、`SafeArea` / `SliverSafeArea`、
/// 或显式读 `MediaQuery.paddingOf(context).top` 加进内容内边距——内容从工具区
/// 下方开始、往下滚时**滚到工具区胶囊底下**，工具区收起后顶部不留空白。
///
/// 与 [FushiFloatingChromeInsetPadding] 的区别：那个是整体 `Padding` 下移，
/// 让出的那段永远是空的页面底色，工具区一收起就是顶部一整块白（游戏 / 设置
/// 等页 2026-10-06 用户截图）。它只留给**不滚动**的占位 / 加载 / 错误态。
class FushiFloatingChromeScrollInset extends StatelessWidget {
  const FushiFloatingChromeScrollInset({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double top = FushiFloatingChromeInset.of(context);
    final MediaQueryData media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(top: media.padding.top + top),
      ),
      child: FushiFloatingChromeInset(top: 0, child: child),
    );
  }
}

/// 高度 = 所在位置的 [FushiFloatingChromeInset] 的空白：主滚动视图的第一个
/// sliver / 子项用它让出叠放在上面的浮动工具区。自己读 inset（用它自己的
/// context），所以页面在 State 方法里构建正文时也能拿到嵌套工具区的值——直接
/// 用 State 的 context 读只会读到外层（嵌套的 [FushiFloatingChromeOverlay] 在
/// 它下面）。
class FushiFloatingChromeInsetSpacer extends StatelessWidget {
  const FushiFloatingChromeInsetSpacer({super.key});

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: FushiFloatingChromeInset.of(context));
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
/// 实测高度）。收起 = 工具区向上滑出画面（M3E default spatial 弹簧）+ 淡出
/// （default effects 弹簧：透明度不过冲，不借空间弹簧的轨迹），
/// 不改任何版面。嵌套时内层工具区排在外层工具区下方，收起时一起滑出。
///
/// 收起后键盘 / 手柄焦点走进来（Tab 遍历到页签或按钮）立刻弹回：收起只是让出
/// 屏幕，不能让控件变得够不着。没挂作用域时退化成常驻的「工具区 + 内容」竖排。
class FushiFloatingChromeOverlay extends StatefulWidget {
  const FushiFloatingChromeOverlay({
    required this.chrome,
    required this.child,
    this.nestedGap = kFushiFloatingChromeGap,
    this.opaqueChrome = false,
    super.key,
  });

  final Widget chrome;
  final Widget child;

  /// 嵌套时本层与上一层之间的间距（本层为空时不算）。默认
  /// [kFushiFloatingChromeGap]；库页的二级下划线页签没有底色、自带行内留白，
  /// 传 0 贴着顶栏（2026-10-30 用户嫌缝大）。
  final double nestedGap;

  /// 工具行自己没有底面（库页二级下划线页签）时为 true：只要本层此刻有内容，
  /// 整摞工具区（最外层顶栏 + 各嵌套行）的顶部遮罩一律改成页面底色实底、只在
  /// 最下沿渐隐一次——内容滚到下面时文字不落在半透明薄纱 + 封面上，也不会一段
  /// 薄纱一段实底拼成两截（2026-10-30 用户截图「顶部白雾」「有点违和」）。
  /// 胶囊类工具行自带表面，保持 false。
  final bool opaqueChrome;

  @override
  State<FushiFloatingChromeOverlay> createState() =>
      _FushiFloatingChromeOverlayState();
}

class _FushiFloatingChromeOverlayState extends State<FushiFloatingChromeOverlay>
    with TickerProviderStateMixin {
  /// 工具区的实测高度（展开态的版面高度；收起不改它）。
  double _chromeHeight = 0;

  /// 1 = 完全显示，0 = 收起。M3E default spatial 弹簧，重定向带着速度续上。
  /// 只在挂着作用域时创建（首次 [didChangeDependencies] 里按当时的显隐定初值）。
  FushiSpring? _shown;

  /// 工具区透明度：1 = 不透明。M3E default **effects** 弹簧（临界阻尼，不过冲）
  /// ——透明度是 effects 属性，不跟位移共用 spatial 弹簧（HBK-AUDIT-023）。
  /// 与 [_shown] 同时创建、同目标、同一降级开关。
  FushiSpring? _fade;

  FushiFloatingChromeController? _controller;

  /// 工具区此刻的可见下沿（相对本层顶边，含收起动画中途）：下发给页面做
  /// 「跟随工具区」的让位 / 吸顶 / 跳转定位（[FushiFloatingChromeVisibleExtent]）。
  final ValueNotifier<double> _visibleBottom = ValueNotifier<double>(0);

  /// 本层工具区完全显示时的下沿（外层 inset + 本层实测高度）。
  double _travel = 0;

  /// 最近的外层工具区（本层是页面自己的搜索 / 筛选行时非 null）。
  _FushiFloatingChromeOverlayState? _parent;

  /// 本层是否在可见子树里（保活的隐藏分区 [TickerMode] 关着，不该撑大遮罩）。
  bool _active = true;

  /// 嵌套工具区此刻的可见下沿（**全局**坐标），按上报者分开存。
  final Map<_FushiFloatingChromeOverlayState, double> _nestedBottoms =
      <_FushiFloatingChromeOverlayState, double>{};

  /// 嵌套工具区里最深的可见下沿（本层坐标）。BUG-3132：顶部遮罩只归最外层画，
  /// 但它必须盖到页面自己那几行工具（搜索框、标签行）的下沿，否则那几行背后整片
  /// 透出内容。
  final ValueNotifier<double> _nestedReach = ValueNotifier<double>(0);

  /// 只在最外层有意义：整摞工具区里是否有一层要求实底（[FushiFloatingChromeOverlay
  /// .opaqueChrome] 且此刻有内容、且在可见子树里）。各层的遮罩都读最外层这一份。
  final ValueNotifier<bool> _opaqueStack = ValueNotifier<bool>(false);
  final Set<_FushiFloatingChromeOverlayState> _opaqueLayers =
      <_FushiFloatingChromeOverlayState>{};

  _FushiFloatingChromeOverlayState get _root {
    _FushiFloatingChromeOverlayState layer = this;
    while (layer._parent != null) {
      layer = layer._parent!;
    }
    return layer;
  }

  void _setOpaqueLayer(_FushiFloatingChromeOverlayState layer, bool on) {
    if (on) {
      _opaqueLayers.add(layer);
    } else {
      _opaqueLayers.remove(layer);
    }
    _opaqueStack.value = _opaqueLayers.isNotEmpty;
  }

  /// 把「本层要不要实底」报给最外层；构建期不能改外层的通知值，推到帧末。
  void _reportOpaque() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _root._setOpaqueLayer(
        this,
        widget.opaqueChrome && _active && _chromeHeight > 0,
      );
    });
  }

  double? _globalTop() {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero).dy;
  }

  /// 把本层（含更深的嵌套层）此刻的可见下沿报给外层。
  ///
  /// 构建期间（本层在 didChangeDependencies 里把弹簧跳到位、可见下沿随之变）不能
  /// 直接改外层的通知值——外层的 AnimatedBuilder 不是本层的祖先，构建中标脏会断言；
  /// 推到帧末再报。
  void _reportReach() {
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reportReach();
      });
      return;
    }
    final _FushiFloatingChromeOverlayState? parent = _parent;
    if (parent == null || !parent.mounted) return;
    final double? top = _active ? _globalTop() : null;
    parent._setNestedBottom(
      this,
      top == null
          ? null
          : top + math.max(_visibleBottom.value, _nestedReach.value),
    );
  }

  void _setNestedBottom(
    _FushiFloatingChromeOverlayState child,
    double? globalBottom,
  ) {
    if (globalBottom == null) {
      _nestedBottoms.remove(child);
    } else {
      _nestedBottoms[child] = globalBottom;
    }
    final double? top = _globalTop();
    double reach = 0;
    if (top != null) {
      for (final double bottom in _nestedBottoms.values) {
        reach = math.max(reach, bottom - top);
      }
    }
    _nestedReach.value = reach;
  }

  bool _onScrollMetrics(ScrollMetricsNotification notification) {
    // 隐藏的保活分区也会发版面通知，不能拿它去撤遮罩 / 弹工具区。
    if (!TickerMode.getValuesNotifier(notification.context).value.enabled) {
      return false;
    }
    _controller?.handleScrollMetricsNotification(notification);
    return false;
  }

  void _syncVisibleBottom() {
    final FushiSpring? spring = _shown;
    final double shown = spring == null
        ? 1
        : spring.value.clamp(0.0, 1.0).toDouble();
    _visibleBottom.value = _travel * shown;
  }

  @override
  void initState() {
    super.initState();
    // 本层的可见下沿 / 更深层的下沿变了都要往上报（弹簧逐帧推进时也是）。
    _visibleBottom.addListener(_reportReach);
    _nestedReach.addListener(_reportReach);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = context
        .findAncestorStateOfType<_FushiFloatingChromeOverlayState>();
    _active = TickerMode.of(context);
    _reportOpaque();
    final FushiFloatingChromeController? controller =
        FushiFloatingChromeScope.maybeOf(context);
    _controller = controller;
    if (controller == null) return;
    final FushiSpring? spring = _shown;
    if (spring == null) {
      final FushiSpring created = FushiSpring(
        vsync: this,
        initial: controller.visible ? 1 : 0,
        spring: fushiChromeRevealSpring(context, fushiExpressiveDefaultSpatial),
      );
      created.animation.addListener(_syncVisibleBottom);
      _shown = created;
      _fade = FushiSpring(
        vsync: this,
        initial: controller.visible ? 1 : 0,
        spring: fushiChromeRevealFadeSpring(context),
      );
    } else {
      final bool animate = fushiExpressiveMotionEnabled(context);
      spring.animateTo(controller.visible ? 1 : 0, animate: animate);
      _fade?.animateTo(controller.visible ? 1 : 0, animate: animate);
    }
  }

  @override
  void dispose() {
    _shown?.animation.removeListener(_syncVisibleBottom);
    _shown?.dispose();
    _fade?.dispose();
    _visibleBottom.dispose();
    _nestedReach.dispose();
    _opaqueStack.dispose();
    // 卸载期间不能让外层重建（树已锁定）：下一帧再把本层从外层的遮罩范围里摘掉。
    final _FushiFloatingChromeOverlayState? parent = _parent;
    if (parent != null) {
      final _FushiFloatingChromeOverlayState root = _root;
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (parent.mounted) parent._setNestedBottom(this, null);
          if (root.mounted) root._setOpaqueLayer(this, false);
        })
        ..ensureVisualUpdate();
    }
    super.dispose();
  }

  void _onChromeHeight(double height) {
    // 嵌套层与上一层之间的 [kFushiFloatingChromeGap] 只在本层真有内容时才算：
    // 本层为空（如库页当前组只有一个视图、不画二级胶囊）时不占高度，否则内容
    // 顶上平白多出一条缝。
    final double next = _parent != null && height > 0
        ? height + widget.nestedGap
        : height;
    if (!mounted || next == _chromeHeight) return;
    setState(() => _chromeHeight = next);
    _reportOpaque();
  }

  @override
  Widget build(BuildContext context) {
    final FushiFloatingChromeController? controller = _controller;
    final FushiSpring? spring = _shown;
    final FushiSpring? fade = _fade;
    if (controller == null || spring == null || fade == null) {
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
    if (travel != _travel) {
      _travel = travel;
      // 构建期间不改通知值（监听者会在构建中 setState）：本帧末再同步。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncVisibleBottom();
      });
    }
    // 嵌套的工具区（页面自己的搜索 / 筛选行叠在外壳页签之下）不再画第二层
    // 遮罩：两层「从视口顶边起、顶端不透明」的渐隐叠在一起，就是库页往下滚
    // 时页签下面那一整块白底（2026-10-06 用户截图）。顶部可读性只归最外层。
    final bool nested = _parent != null;
    if (nested) {
      // 版面（本层位置 / 高度）每次重建后都可能变：帧末把可见下沿报给外层遮罩。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reportReach();
      });
    }
    final Widget chrome = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool focused) {
        if (focused) controller.show();
      },
      // 嵌套工具行（页面自己的搜索 / 筛选行）与上一层页签胶囊之间统一隔
      // [kFushiFloatingChromeGap]（加上外壳工具栏底边的 4 合计 12，M3E 组
      // 间距），不再各页自己凑、贴在一起；本层为空时不隔（见 [_onChromeHeight]）。
      // 量的是工具行本身，间距在外面加，树形恒定。
      child: Padding(
        padding: EdgeInsets.only(
          top: nested && _chromeHeight > 0 ? widget.nestedGap : 0,
        ),
        child: FushiHeightReporter(
          onHeight: _onChromeHeight,
          // 顶层胶囊行整体缩到 [kFushiFloatingCapsuleScale]；嵌套的二级行（下划线
          // 页签 / 搜索筛选行）不是浮动胶囊，不缩。
          child: nested
              ? widget.chrome
              : FushiCapsuleScale(child: widget.chrome),
        ),
      ),
    );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: FushiFloatingChromeVisibleExtent(
            extent: _visibleBottom,
            child: FushiFloatingChromeInset(
              top: travel,
              // 版面修正（列表缩短被夹回顶部）只发 ScrollMetricsNotification，
              // 由最外层统一喂给 controller（BUG-3133）。
              child: nested
                  ? widget.child
                  : NotificationListener<ScrollMetricsNotification>(
                      onNotification: _onScrollMetrics,
                      child: widget.child,
                    ),
            ),
          ),
        ),
        // 顶部渐隐遮罩 + 工具区：同一弹簧驱动。遮罩只盖「此刻看得见的工具区」
        // 再往下渐隐一段；工具区完全收起时遮罩也随弹簧整体淡出、不留任何底色
        // 带（反馈 03cff3908u / Sb7jHbNO43，见下方 Positioned 处的说明）。胶囊
        // 自己有表面色与投影，不靠底色遮挡内容。
        AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            spring.animation,
            fade.animation,
            _nestedReach,
            _root._opaqueStack,
          ]),
          child: chrome,
          builder: (BuildContext context, Widget? chrome) {
            final double value = spring.value;
            final double shown = value.clamp(0.0, 1.0);
            // effects 弹簧临界阻尼不过冲；clamp 只吸收收敛容差。
            final double opacity = fade.value.clamp(0.0, 1.0);
            final bool opaque = _root._opaqueStack.value;
            final bool hidden = opacity <= 0.001 && shown <= 0.001;
            // BUG-3338：本层遮罩的起点 / 终点（本层坐标）。嵌套层从外层此刻的
            // 可见下沿起画（BUG-3283），外层画到本层可见下沿；两者在接缝处必须
            // **恰好拼接**——接缝 y 对齐到物理像素格（两层用同一个取整），不然
            // 非整数 DPR / 小数高度下两块矩形的抗锯齿边各盖半个像素，叠出一条
            // 比薄纱浅的亮缝。
            final double dpr = MediaQuery.devicePixelRatioOf(context);
            double snap(double y) => (y * dpr).roundToDouble() / dpr;
            final double scrimTop = nested ? snap(outer * shown) : 0;
            final double scrimSeam = snap(
              (nested ? outer * shown : outer) + shown * _chromeHeight,
            );
            // 下面还接着嵌套工具行：本层在接缝处硬停在薄纱不透明度，由下一层
            // 接着画。曾经在这里多画 1 px 渐隐（0.72 → 0），叠在下一层顶端的
            // 0.72 薄纱上合成成一条比上下都深的横线（BUG-3338）。
            final bool continuesBelow =
                _nestedReach.value > outer + shown * _chromeHeight + 0.5;
            return Stack(
              children: <Widget>[
                // 遮罩在内容之上、本层工具区之下，沿用 2026-10-06 定的「短渐隐、
                // 不垫整块底色」：只在视口顶边是页面底色（不透明，与上方底色 /
                // 窗口标题行无接缝），随即缓降到一层半透明的
                // [kFushiTopScrimOverlayOpacity] 薄纱——工具行背后的封面退后、
                // 不再花得看不清胶囊，但不是一块实底——薄纱铺到**最后一行**
                // 可见工具栏的下沿，再往下 [kFushiTopFadeExtent] 短距离渐隐到 0。
                // 页面自己的工具行（嵌套层：搜索 / 标签行）各画自己那一段薄纱，
                // 接在上一层下沿、画在**它自己的**工具行之下——只能各画各的：
                // 嵌套工具行住在外层的内容层里，外层的遮罩若一路盖下来会把它们
                // 也压成半透明。只有最深一层渐隐（[_nestedReach] 判「下面还有没有
                // 工具行」），上面各层在接缝处停在同一不透明度。
                // BUG-3132：曾经只伸进第一行胶囊 40 px，搜索 / 标签行背后整片透出
                // 封面。遮罩跟着弹簧走：工具区收起时一起收回顶边。没滚动时不画。
                // BUG-3283：嵌套层的起点是**外层此刻的可见下沿**（外层 inset 乘同一
                // 弹簧的显隐）。`outer` 本身是恒定不随收起变的让位量（滚动内容的
                // 让位不能随动画变），拿它当遮罩起点，收起后外壳页签早已滑出画面，
                // 嵌套遮罩却仍从页签高度处起画——内容中间凭空出现一条顶端 0.72
                // 不透明的硬边亮带。完全收起时嵌套层没有可见工具行，不画；顶边那一条
                // 渐隐由最外层负责。
                Positioned(
                  top: scrimTop,
                  left: 0,
                  right: 0,
                  // 嵌套层本身为空（库页当前组不画二级页签）时也不画：外层已经
                  // 在自己下沿收尾渐隐，这里再从 0.72 起画一段会与之叠成一道
                  // 更浓的白边（2026-10-30 用户截图「白雾」）。
                  //
                  // 最外层同理：遮罩只为「看得见的工具区」垫底，整段不透明度乘同一
                  // 弹簧的显隐。曾经收起后仍从视口顶边画一段页面底色（让位区
                  // `outer` 实色 + [kFushiTopFadeExtent] 渐隐）——让位区里此时已
                  // 没有任何可见工具（MD3 库页的外壳标题条是收起态），这条纯色带
                  // 只会盖住页面背景装饰，成了「下滑后顶部一条白边」（2026-11
                  // 用户截图，反馈 03cff3908u / Sb7jHbNO43）。
                  child: shown <= 0.001 || (nested && _chromeHeight <= 0)
                      ? const SizedBox.shrink()
                      : AnimatedOpacity(
                          opacity: controller.contentUnderTop ? 1 : 0,
                          duration: fushiMotionDuration(
                            context,
                            FushiMotion.short,
                          ),
                          child: Opacity(
                            opacity: nested ? 1 : shown,
                            child: FushiTopFadeScrim(
                              solidHeight: scrimSeam - scrimTop,
                              fadeExtent: continuesBelow
                                  ? 0
                                  : kFushiTopFadeExtent,
                              // 整摞要实底（见 [FushiFloatingChromeOverlay
                              // .opaqueChrome]）时每层都是页面底色实底，只在最下沿
                              // 渐隐；否则沿用顶端实色 → 薄纱。
                              topOpacity: opaque
                                  ? 1
                                  : nested
                                  ? kFushiTopScrimOverlayOpacity
                                  : 1,
                              shoulderOpacity: opaque
                                  ? 1
                                  : kFushiTopScrimOverlayOpacity,
                            ),
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
                        opacity: hidden ? 0 : opacity,
                        child: Transform.translate(
                          // 用未截断的弹簧值：MD3 的轻微回弹体现在位置上
                          // （Apple 弹簧临界阻尼，本就不越界）。
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
/// - 其后 [fadeExtent] 内按 smoothstep 降到 0（两端斜率都为 0）。[fadeExtent]
///   为 0 时在肩段末端硬停——只用于下面紧接着另一段遮罩的拼接处。
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
    this.shoulderOpacity,
    this.color,
    super.key,
  });

  final double solidHeight;
  final double fadeExtent;

  /// 肩段末端的不透明度（同 [topOpacity]，乘在 [color] 的 alpha 上）。缺省为
  /// [topOpacity] 的 0.82 倍；库页工具区用它把肩段压成一层半透明薄纱
  /// （[kFushiTopScrimOverlayOpacity]），而不是近乎实色的底块。
  final double? shoulderOpacity;

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
    // 0 = 不渐隐，在肩段末端硬停（下面紧接着另一段遮罩，见
    // [FushiFloatingChromeOverlay]）。不能偷偷钳成 1 px：多出的那一条会叠在
    // 下一段的顶端上，合成出一条横线（BUG-3338）。
    final double fade = math.max(0.0, fadeExtent);
    final double height = solid + fade;
    if (height <= 0) return const SizedBox.shrink();
    final Color base = color ?? fushiTopFadeScrimColor(context);
    final double top = base.a * topOpacity.clamp(0.0, 1.0);
    final double floor = shoulderOpacity == null
        ? top * _kShoulderFloor
        : base.a * shoulderOpacity!.clamp(0.0, 1.0);
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
        // 缺省肩段：顶端斜率为 0 的缓降（u²）。薄纱形态（floor 远低于 top）
        // 改用 1-(1-u)²：在视口顶边很快落到薄纱、末端斜率为 0 平顺接上渐隐段，
        // 不在顶部拖出一大段近实色。
        final double ease = shoulderOpacity == null
            ? u * u
            : 1 - (1 - u) * (1 - u);
        sample(solid * u, top + (floor - top) * ease);
      }
      fadeStart = floor;
    } else {
      fadeStart = top;
    }
    for (int i = solid > 0 ? 1 : 0; fade > 0 && i <= _kFadeSamples; i++) {
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
/// 高度与位移取 M3 Expressive「default spatial」弹簧（轻微回弹），透明度取
/// 「default effects」弹簧（临界阻尼、不过冲；HBK-AUDIT-023）。Apple 设计系统下
/// 两者都换成 `context.fushiMotion` 的 Apple 弹簧（位移临界阻尼，不回弹）。
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
    with TickerProviderStateMixin {
  // 首次访问在 build / didUpdateWidget 里（可读设计系统）。
  late final FushiSpring _spring = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: fushiChromeRevealSpring(context, fushiExpressiveDefaultSpatial),
  );

  /// 透明度：effects 弹簧，与 [_spring] 同目标、同一降级开关。
  late final FushiSpring _fade = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: fushiChromeRevealFadeSpring(context),
  );

  @override
  void didUpdateWidget(covariant FushiSpringReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      final bool animate = fushiExpressiveMotionEnabled(context);
      _spring.animateTo(widget.visible ? 1 : 0, animate: animate);
      _fade.animateTo(widget.visible ? 1 : 0, animate: animate);
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool fromTop = widget.edge == VerticalDirection.up;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _spring.animation,
        _fade.animation,
      ]),
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double value = _spring.value;
        final double opacity = _fade.value.clamp(0.0, 1.0);
        // 弹簧按容差收敛，静止值离目标还差 1e-4 量级：两端吸附，免得「收起」
        // 留下一丝几何、「展开」一直走裁剪分支。
        double extent = value.clamp(0.0, 1.0);
        if (extent >= 0.999 && opacity >= 0.999 && widget.visible) {
          return child!;
        }
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
                  opacity: hidden ? 0 : opacity,
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
/// - Apple：[FushiFloatingPill] 的无色液态玻璃胶囊 + 柔和投影，缺省高
///   [fushiAppleFloatingExtent]（iOS 26 悬浮栏 44 / macOS 26 工具栏 36）；
/// - 墨水屏：无阴影，一圈 outline。
///
/// 高度是**定值**而不是「至少」（与 `FushiPageChromeCapsule` 同一契约）：胶囊
/// 总和别的控件并排（库页工具行里与搜索框、页头里与页签胶囊），只有定高才能
/// 保证同一行等高。此前是 `minHeight`，里面的图标按钮命中盒（44 / 48）一比
/// 胶囊内高大就把胶囊撑高——库页工具行的按钮组胶囊因此比 40 高的搜索框高一截
/// （2026-10-14 用户截图「这里不等高」）。内容按 `高 − 竖向内边距` 的上限排，
/// 按钮的命中盒随之收进胶囊，不再反过来撑它。
class FushiFloatingToolbarSurface extends StatelessWidget {
  const FushiFloatingToolbarSurface({
    required this.child,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    this.vibrant = false,
    super.key,
  });

  final Widget child;

  /// 胶囊高度（定值，见类注释）；缺省 MD3 = M3E floating toolbar 紧凑档 56，
  /// Apple = [fushiAppleFloatingExtent]。
  final double? height;
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
    final double extent =
        height ??
        (isGlassDesign(context)
            ? fushiAppleFloatingExtent(context)
            : kFushiFloatingToolbarCompactExtent);
    return SizedBox(
      height: extent,
      child: FushiFloatingPill(
        color: colorOf(context, vibrant: vibrant),
        padding: padding,
        child: Center(widthFactor: 1, child: child),
      ),
    );
  }
}

/// 悬浮动作组：画出 [slot] 里当前可见页头登记的动作。
///
/// 动作集合变了（切分区多 / 少一个按钮、进入多选换成「完成」）时整组按
/// M3E 上下文切换交叉形变：旧组缩小淡出、新组从 0.8 弹到 1，胶囊宽度跟着
/// 弹簧过渡。Apple 设计系统下不缩放：新旧组交叉淡变（effects 弹簧），宽度走
/// 临界阻尼的 Apple 弹簧（iOS 26 工具栏换组）。没有动作时零尺寸。
///
/// MD3 下是 [FushiFloatingToolbarSurface] 胶囊里一排无底图标按钮；Apple 下
/// 外壳动作画成 [FushiToolbar] 的悬浮玻璃胶囊（iOS 26 / macOS 26 工具栏按钮组，
/// 高 [fushiAppleFloatingExtent]），不再外套一层 56 高的悬浮面。
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
        final bool apple = isGlassDesign(context);
        final Widget pill = actions == null
            ? const SizedBox.shrink(key: ValueKey<String>('empty'))
            : KeyedSubtree(
                key: ValueKey<Object>(_signatureOf(actions)),
                child: _FloatingActionsBody(actions: actions),
              );
        if (apple) return _appleSwitcher(context, pill);
        return FushiAnimatedSize(
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
            // 曲线放进 transitionBuilder 里分属性施加（缩放 spatial、透明度
            // effects），这里交出线性进度。
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: AlignmentDirectional.centerEnd,
              clipBehavior: Clip.none,
              children: <Widget>[...previous, if (current != null) current],
            ),
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(
                  // 透明度走 effects 弹簧形状（临界阻尼、不过冲，HBK-AUDIT-023）；
                  // 缩放走 spatial 弹簧，保留回弹。
                  opacity: animation.drive(
                    CurveTween(curve: FushiMotion.enter),
                  ),
                  child: ScaleTransition(
                    scale: animation
                        .drive(CurveTween(curve: const FushiSpringCurve()))
                        .drive(Tween<double>(begin: 0.8, end: 1)),
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

  /// Apple：换组只交叉淡变（effects 弹簧，不缩放），胶囊宽度走临界阻尼的
  /// Apple 弹簧（不回弹）。降级时两者时长归零。
  static Widget _appleSwitcher(BuildContext context, Widget pill) {
    final FushiMotionScheme motion = context.fushiMotion;
    final FushiSpringSpec size = fushiAppleChromeSpatial(context);
    return FushiAnimatedSize(
      duration: size.duration,
      curve: size.curve,
      alignment: AlignmentDirectional.centerEnd,
      clipBehavior: Clip.none,
      child: AnimatedSwitcher(
        duration: motion.effectsSlow.duration,
        reverseDuration: motion.effectsFast.duration,
        switchInCurve: motion.effectsSlow.curve,
        switchOutCurve: motion.effectsFast.curve,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: AlignmentDirectional.centerEnd,
          clipBehavior: Clip.none,
          children: <Widget>[...previous, if (current != null) current],
        ),
        child: pill,
      ),
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
      // Apple：iOS 26 / macOS 26 工具栏按钮组——[FushiToolbar] 的悬浮形态就是
      // 一枚无色玻璃胶囊 + 柔和投影（高 [fushiAppleFloatingExtent]），按钮在组里
      // 不再各自带玻璃底。不再外套 56 高的悬浮面（玻璃叠玻璃两圈折射边、
      // 比工具栏高一截）。放不下时与 MD3 同一套判据逐颗收进 ⋯，全收仍不够才
      // 横滑兜底；横滑视口不裁投影。
      final FushiShellHeaderActions shellActions =
          actions as FushiShellHeaderActions;
      return FushiShellHeaderActions(
        actions: shellActions.actions,
        appleFloating: true,
        search: shellActions.search,
        menuAnchor: shellActions.menuAnchor,
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
/// 页签按自然宽贴左（摆不下时在胶囊里横滑），动作组按自然宽贴右。动作组
/// 可用宽 = 页签上报的自然宽（[FushiHeaderCrampScope]）之外的剩余宽，且至少
/// 半行；放不下的由 [FushiShellHeaderActions] 按优先级逐颗收进 ⋯。整行跟随
/// [FushiFloatingChromeOverlay] 显隐（由外壳把整行叠在内容上）。
/// 首页外壳告诉本 tab 里的 [FushiFloatingChromeBar]：外壳**不**另画大标题行，
/// 页面名由工具栏行自己在页签胶囊左边画一枚标题胶囊（宽窗 M3E 库页 / 浏览，
/// 2026-10-10「库页顶部只留两行」）。不在外壳里（push 出来的页面、组件测试）
/// 时为 false，工具栏行照旧只有页签与动作。
class FushiShellInlineTitle extends InheritedWidget {
  const FushiShellInlineTitle({
    required this.enabled,
    required super.child,
    super.key,
  });

  final bool enabled;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiShellInlineTitle>()
          ?.enabled ??
      false;

  @override
  bool updateShouldNotify(FushiShellInlineTitle oldWidget) =>
      enabled != oldWidget.enabled;
}

class FushiFloatingChromeBar extends StatefulWidget {
  const FushiFloatingChromeBar({
    required this.tabs,
    required this.slot,
    this.padding,
    this.leading,
    this.trailing,
    super.key,
  });

  final Widget tabs;
  final FushiShellActionsSlot slot;
  final EdgeInsetsGeometry? padding;

  /// 页签胶囊左边的前导（独立 push 进来的页面的返回键，一枚圆胶囊）；与
  /// 页签胶囊同一行、间距 [kFushiFloatingChromeGap]。
  final Widget? leading;

  /// 动作组右边的一枚圆胶囊（库页壳的「导入」入口，见 `libraryImportChromeButton`）；
  /// 与动作组同一行、间距 [kFushiFloatingChromeGap]，不随动作组收进「⋯」。
  final Widget? trailing;

  @override
  State<FushiFloatingChromeBar> createState() => _FushiFloatingChromeBarState();
}

class _FushiFloatingChromeBarState extends State<FushiFloatingChromeBar> {
  /// 页签胶囊（经 [FushiHeaderCrampScope]）最近一次上报的自然宽；null = 未上报，
  /// 动作组按半行封顶（旧口径）。
  double? _tabsNaturalWidth;

  void _onTabsWidthReported(double width) {
    if (_tabsNaturalWidth == width) return;
    // 上报发生在页签 build 期，不能同帧 setState；post-frame 再落。自然宽只依赖
    // 文案 / 字号 / 缩放，与本行布局结果无关，不会形成反馈环。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabsNaturalWidth == width) return;
      setState(() => _tabsNaturalWidth = width);
    });
  }

  // 顶部浮动胶囊统一按 [kFushiFloatingCapsuleScale] 缩（外层已缩过时不叠加）。
  @override
  Widget build(BuildContext context) =>
      FushiCapsuleScale(child: _buildChrome(context));

  Widget _buildChrome(BuildContext context) {
    final Widget? leading = widget.leading;
    final EdgeInsetsGeometry? padding = widget.padding;
    // 首页外壳把页面名交给本行画（[FushiShellInlineTitle]，宽窗 M3E 库页）：
    // 标题胶囊排在页签胶囊左边，不再单独占页签上面那一行（2026-10-10「库页
    // 顶部只留两行」）。
    final String? shellTitle =
        leading == null && FushiShellInlineTitle.of(context)
        ? FushiShellTitleScope.maybeTitleOf(context)
        : null;
    final bool inlineTitle = shellTitle != null && shellTitle.isNotEmpty;
    final Widget? lead = inlineTitle
        ? KeyedSubtree(
            key: const ValueKey<String>('floating-chrome-shell-title'),
            child: FushiPageChromeTitle(title: Text(shellTitle)),
          )
        : leading;
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
          final double minActions = isGlassDesign(context)
              ? fushiAppleFloatingExtent(context)
              : kFushiFloatingToolbarCompactExtent;
          // 标题胶囊是 Row 里的非弹性子项，不限宽时长页面名会按自然宽把页签
          // 胶囊挤没（甚至整行溢出）。限到行宽的 1/3，超长名在胶囊里省略号
          // 截断；页签保有剩余宽度（2026-10-10 审查，BUG-3250）。
          final double maxTitle = constraints.maxWidth.isFinite
              ? constraints.maxWidth / 3
              : double.infinity;
          // 动作组至少拿半行（页签很宽时页签在胶囊里横滑）；页签自然宽放得下
          // 时，剩下的宽度都归动作组——位置够就不收进 ⋯。
          final double? tabsNatural = _tabsNaturalWidth;
          final double leadReserve = lead == null
              ? 0
              : (inlineTitle ? maxTitle : kFushiPageChromeExtent) +
                    kFushiFloatingChromeGap;
          final Widget? trailing = widget.trailing;
          final double trailReserve = trailing == null
              ? 0
              : kFushiPageChromeExtent + kFushiFloatingChromeGap;
          final double maxActions = constraints.maxWidth.isFinite
              ? math.max(
                  math.max(
                    minActions,
                    (constraints.maxWidth - trailReserve) / 2,
                  ),
                  tabsNatural == null
                      ? 0
                      : constraints.maxWidth -
                            leadReserve -
                            trailReserve -
                            tabsNatural -
                            kFushiFloatingChromeGap,
                )
              : double.infinity;
          final Widget row = FocusTraversalGroup(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (lead != null) ...<Widget>[
                  if (inlineTitle)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxTitle),
                      child: lead,
                    )
                  else
                    lead,
                  const SizedBox(width: kFushiFloatingChromeGap),
                ],
                Expanded(
                  child: FushiHeaderCrampScope(
                    reportTitleNaturalWidth: _onTabsWidthReported,
                    child: widget.tabs,
                  ),
                ),
                const SizedBox(width: kFushiFloatingChromeGap),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxActions),
                  child: FushiFloatingActionsPill(slot: widget.slot),
                ),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: kFushiFloatingChromeGap),
                  trailing,
                ],
              ],
            ),
          );
          return _withExpandableSearch(context, row, minActions);
        },
      ),
    );
  }

  /// 当前视图没有可展开搜索时 [_withExpandableSearch] 监听的占位。
  static final ChangeNotifier _noSearch = ChangeNotifier();

  /// 当前视图页头带可展开搜索（[FushiHeaderSearchController]）时：展开后**整行**
  /// （标题胶囊 + 页签 + 动作组）换成搜索栏，收起换回（2026-10-14 库页单行
  /// 页头）。两态之间淡入淡出 + 轻微缩放（M3E，墨水屏 / 减弱动效归零）。
  Widget _withExpandableSearch(
    BuildContext context,
    Widget row,
    double rowExtent,
  ) {
    return ListenableBuilder(
      listenable: widget.slot,
      builder: (BuildContext context, Widget? _) {
        final FushiHeaderSearchController? search = fushiVisibleHeaderSearch(
          widget.slot,
        );
        // 树形恒定（没有搜索时也套同一个切换器）：在有 / 无搜索的视图之间切换
        // 不重挂页签与动作组。
        return ListenableBuilder(
          listenable: search ?? _noSearch,
          builder: (BuildContext context, Widget? _) {
            final bool expanded = search?.expanded ?? false;
            return AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              switchInCurve: FushiMotion.standard,
              switchOutCurve: FushiMotion.standard,
              transitionBuilder: (Widget child, Animation<double> animation) =>
                  FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.96,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: Alignment.center,
                children: <Widget>[...previous, if (current != null) current],
              ),
              child: expanded
                  ? SizedBox(
                      key: const ValueKey<String>('floating-chrome-search'),
                      height: rowExtent,
                      child: Center(
                        child: FushiHeaderSearchBar(controller: search!),
                      ),
                    )
                  : KeyedSubtree(
                      key: const ValueKey<String>('floating-chrome-row'),
                      child: row,
                    ),
            );
          },
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart'
    show SmoothWheelScrollScope;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassBarMinimizeBehavior,
        GlassTabBarMinimizeController,
        ProgressiveBlur,
        ProgressiveBlurDirection;

// Apple 设计系统（iOS 26 / macOS 26）随滚动变化的导航层行为：
// - scroll edge effect：内容滚到顶栏 / 底部标签栏下面时，边缘是一段柔和的
//   渐隐 + 渐进模糊（UIKit `.scrollEdgeEffectStyle(.soft)`），不是一刀硬切；
// - 底部标签栏随下滑最小化（`.tabBarMinimizeBehavior(.onScrollDown)`）。
// 渐隐曲线照抄 liquid_glass_widgets 的 GlassScrollEdgeEffect（soft 档）；
// 那个组件本身要求「内容在栏下面」的整页布局（GlassPage / extendBody），
// Fushi 的页面是 Scaffold 把正文排在顶栏之下，所以这里只取它的曲线与
// ProgressiveBlur，贴在栏的边缘自己画。

/// 边缘带贴在哪条边上：[top] = 顶栏下沿（上实下透），[bottom] = 底栏
/// （下实上透）。
enum FushiScrollEdgeSide { top, bottom }

/// soft 档渐隐曲线（GlassScrollEdgeEffect `_kFadeCurves[soft]`）：边缘处
/// 不透明，先缓后急地消失，留一段很长的低 alpha 尾巴，避免出现接缝。
const List<double> _kSoftAlphas = <double>[1.0, 0.70, 0.30, 0.04, 0.0];
const List<double> _kSoftStops = <double>[0.0, 0.15, 0.45, 0.75, 0.92];

/// 一条 scroll edge 带：页面底色的 soft 渐隐，液态 / 磨砂材质下再叠一层
/// 从边缘往内减弱的渐进模糊。[visible] 为 false（内容没滚到栏下面）时淡出、
/// 不画任何东西（AnimatedOpacity 在 0 时跳过子树绘制，模糊层不占 GPU）。
///
/// 系统「降低透明度」（[glassMaterialOf] == off，含墨水屏 / 增强对比度）下
/// 不模糊，只剩实色渐隐；减弱动态效果下显隐瞬间到位。
class FushiAppleScrollEdge extends StatelessWidget {
  const FushiAppleScrollEdge({
    super.key,
    required this.side,
    required this.visible,
    this.color,
    this.blur = true,
    this.maxSigma = 8,
    this.maxAlpha = 1,
  });

  final FushiScrollEdgeSide side;
  final bool visible;

  /// 渐隐的底色；默认页面底色（不透明化，半透明的 Mica 底会让渐隐发灰）。
  final Color? color;

  /// 是否叠渐进模糊。窗口顶部那条（下面常是静止的页头）只要渐隐。
  final bool blur;

  /// 最强边缘处的模糊 sigma。
  final double maxSigma;

  /// 渐隐底色在最靠边处的不透明度（整条曲线按它等比缩）。底部标签栏那条用
  /// 小值：玻璃胶囊要透出并折射后面的内容，底色铺满就只剩一块平板。
  final double maxAlpha;

  @override
  Widget build(BuildContext context) {
    final Color base = (color ?? Theme.of(context).scaffoldBackgroundColor)
        .withValues(alpha: 1);
    final bool top = side == FushiScrollEdgeSide.top;
    final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (blur && !solid)
              ProgressiveBlur(
                maxSigma: maxSigma,
                // 与 GlassScrollEdgeEffect 同一个 2.0：前四成几乎不糊，
                // 内容进到栏里才化开。
                falloff: 2.0,
                direction: top
                    ? ProgressiveBlurDirection.topToBottom
                    : ProgressiveBlurDirection.bottomToTop,
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                  end: top ? Alignment.bottomCenter : Alignment.topCenter,
                  colors: <Color>[
                    for (final double a in _kSoftAlphas)
                      base.withValues(alpha: a * maxAlpha),
                  ],
                  stops: _kSoftStops,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首页外壳的滚动状态：内容是否滚到了顶部 / 底部导航层下面，以及底部标签栏
/// 的最小化状态（库的 [GlassTabBarMinimizeController]，下滑累计 20 收起、
/// 上滑 12 展开，与刷新率无关）。外壳在内容区挂一个
/// `NotificationListener<Notification>` 把通知喂给 [handleNotification]。
class FushiAppleScrollChrome extends ChangeNotifier {
  FushiAppleScrollChrome() {
    minimize.addListener(_notifySafely);
  }

  /// 底部标签栏最小化状态机。
  final GlassTabBarMinimizeController minimize = GlassTabBarMinimizeController(
    behavior: GlassBarMinimizeBehavior.onScrollDown,
  );

  bool _underTop = false;
  bool _underBottom = false;
  Object? _scope;

  /// 内容的开头已滚到顶部导航层下面（extentBefore > 0）。
  bool get contentUnderTop => _underTop;

  /// 内容的末尾还压在底部导航层下面（extentAfter > 0）。
  bool get contentUnderBottom => _underBottom;

  /// 底部标签栏当前是否最小化。
  bool get minimized => minimize.minimized;

  /// 展开底部标签栏（点最小化胶囊 / 切 tab）。
  void expand() => minimize.expand();

  /// 切换了内容（首页 tab）：边缘与最小化状态都属于上一个 tab 的滚动视图，
  /// 静默复位（在 build 里调用，不通知——调用方正在重建）。
  void syncScope(Object scope) {
    if (identical(scope, _scope) || scope == _scope) return;
    final bool first = _scope == null;
    _scope = scope;
    if (first) return;
    _underTop = false;
    _underBottom = false;
    if (minimize.minimized) {
      // 展开要通知监听者（底栏），推到帧后，避免 build 期间 setState。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) minimize.expand();
      });
    }
  }

  /// 喂一条冒泡上来的通知；恒返回 false（让它继续冒泡）。横向滚动（轮播、
  /// 横向书架行）不参与。
  bool handleNotification(Notification notification) {
    if (SmoothWheelScrollScope.isRewinding) return false;
    final ScrollMetrics metrics;
    if (notification is ScrollNotification) {
      metrics = notification.metrics;
      if (metrics.axis != Axis.vertical) return false;
      minimize.handleNotification(notification);
    } else if (notification is ScrollMetricsNotification) {
      metrics = notification.metrics;
      if (metrics.axis != Axis.vertical) return false;
    } else {
      return false;
    }
    if (!metrics.hasContentDimensions || !metrics.hasPixels) return false;
    final bool reversed = metrics.axisDirection == AxisDirection.up;
    final bool underTop =
        (reversed ? metrics.extentAfter : metrics.extentBefore) > 0.5;
    final bool underBottom =
        (reversed ? metrics.extentBefore : metrics.extentAfter) > 0.5;
    if (underTop != _underTop || underBottom != _underBottom) {
      _underTop = underTop;
      _underBottom = underBottom;
      _notifySafely();
    }
    return false;
  }

  bool _notifyScheduled = false;
  bool _disposed = false;

  /// 布局期间（内容尺寸变化引起的位置修正也会发 ScrollUpdate）不能让监听者
  /// setState，推到帧后统一通知一次。
  void _notifySafely() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    minimize.removeListener(_notifySafely);
    minimize.dispose();
    super.dispose();
  }
}

/// 首页外壳大标题（[FushiShellLargeTitleBar]）的收起状态：随当前可见内容的
/// 纵向滚动收起 / 展开。两套设计系统共用（Apple 大标题 / MD3 large top app
/// bar 都是「滚离顶部收起、回到顶部展开」）。
///
/// 大标题条不在滚动视图里（库页的分区页签行与各分区的滚动视图都在它下面），
/// 收起会让下面的视口变高；所以这里是二值状态 + 滞回，而不是逐像素跟手：
/// - 只有**用户 / 动画滚动**（[ScrollUpdateNotification]）越过 [collapseExtent]
///   才收起——视口变高引起的位置钳制只发 [ScrollMetricsNotification]，不会
///   反过来再触发收起，不会振荡；
/// - 回到顶部（extentBefore ≈ 0）展开；尺寸 / 越界通知只认「让它收起的那个
///   滚动视图」，旁边一个停在顶部的小列表（侧栏、下拉）不会把标题拽出来。
class FushiLargeTitleCollapse extends ChangeNotifier {
  /// 滚离顶部多少逻辑像素后收起（iOS 大标题约在滚过自身一半时收进栏里）。
  static const double collapseExtent = 24;

  bool _collapsed = false;
  Object? _scope;

  /// 让标题收起的那个滚动视图（通知的 context）；只有它的尺寸 / 越界通知
  /// 能把标题展开。
  BuildContext? _owner;

  /// 大标题当前是否收起。
  bool get collapsed => _collapsed;

  /// 切换了内容（首页 tab）：新 tab 从展开态开始。在 build 里调用，不通知
  /// ——调用方正在重建。
  void syncScope(Object scope) {
    if (scope == _scope) return;
    _scope = scope;
    _collapsed = false;
    _owner = null;
  }

  /// 喂一条冒泡上来的通知；恒返回 false（让它继续冒泡）。横向滚动不参与。
  bool handleNotification(Notification notification) {
    // 平滑滚轮补间的「拉回起点」不是用户滚动（[SmoothWheelScrollScope.isRewinding]）：
    // 第一档离顶时会先拉回 0 再补间，按它展开会让大标题每档闪一次。
    if (SmoothWheelScrollScope.isRewinding) return false;
    final ScrollMetrics metrics;
    final BuildContext? source;
    bool userScroll = false;
    bool pulledPastTop = false;
    if (notification is ScrollUpdateNotification) {
      metrics = notification.metrics;
      source = notification.context;
      userScroll = true;
    } else if (notification is OverscrollNotification) {
      metrics = notification.metrics;
      source = notification.context;
      pulledPastTop = notification.overscroll < 0;
    } else if (notification is ScrollMetricsNotification) {
      metrics = notification.metrics;
      source = notification.context;
    } else {
      return false;
    }
    if (metrics.axis != Axis.vertical) return false;
    if (!metrics.hasContentDimensions || !metrics.hasPixels) return false;
    final bool reversed = metrics.axisDirection == AxisDirection.up;
    final double before = reversed ? metrics.extentAfter : metrics.extentBefore;
    final BuildContext? owner = _owner;
    final bool fromOwner =
        owner == null || !owner.mounted || identical(owner, source);
    bool next = _collapsed;
    if (userScroll) {
      if (before > collapseExtent) {
        next = true;
        _owner = source;
      } else if (before <= 0.5) {
        next = false;
      }
    } else if (_collapsed && fromOwner && (before <= 0.5 || pulledPastTop)) {
      next = false;
    }
    if (next != _collapsed) {
      _collapsed = next;
      if (!next) _owner = null;
      _notifySafely();
    }
    return false;
  }

  bool _notifyScheduled = false;
  bool _disposed = false;

  /// 与 [FushiAppleScrollChrome] 同理：布局期间的通知推到帧后再通知监听者。
  void _notifySafely() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 通知是否来自当前可见的子树：首页保活 tab（以及库页里保活的分区）隐藏时
/// 都关掉了 [TickerMode]，它们后台加载引起的尺寸通知不该改动可见页的导航层。
/// 用 [TickerMode.getValuesNotifier] 读值，不在发通知的元素上建立依赖。
bool fushiNotificationFromVisibleSubtree(Notification notification) {
  final BuildContext? source = switch (notification) {
    ScrollNotification(:final BuildContext? context) => context,
    ScrollMetricsNotification(:final BuildContext context) => context,
    _ => null,
  };
  if (source == null || !source.mounted) return true;
  return TickerMode.getValuesNotifier(source).value.enabled;
}

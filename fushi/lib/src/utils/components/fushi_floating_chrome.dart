import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiShellHeaderActions;
import 'package:fushi/src/utils/components/fushi_toolbar.dart'
    show FushiToolbarScope;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot;
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

// 库页的 M3 Expressive 浮动工具栏（2026-10-05「视频库页面也用浮动工具栏统一」）。
//
// 一组小件，组成「顶部悬浮的分区页签胶囊 + 悬浮动作组，滚动下行收起、上行弹回」：
//
// - [FushiFloatingChromeController]：显隐真相。宿主把视口滚动通知喂给
//   [FushiFloatingChromeController.handleScrollNotification]，下行累计超过阈值
//   收起、上行或回到顶部弹回。
// - [FushiFloatingChromeScope]：把 controller 下发给子树（页面里自己的工具行
//   用 [FushiFloatingChromeReveal] 跟着同一份显隐走）。
// - [FushiSpringReveal]：弹簧驱动的「从边缘滑出 + 高度展开 + 淡入」，收起时
//   高度归零把空间还给内容（不是盖在内容上——页面的首行永远不会被工具栏挡住）。
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

  /// 工具栏此刻应当显示。
  bool get visible => _visible;

  void show() => _set(true);

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
    if (notification is ScrollEndNotification) {
      _accumulated = 0;
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    if (metrics.pixels <= metrics.minScrollExtent + 0.5) {
      show();
      return false;
    }
    final double delta = notification.scrollDelta ?? 0;
    if (delta == 0) return false;
    if (_accumulated != 0 && delta.sign != _accumulated.sign) {
      _accumulated = 0;
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
}

/// 跟随 [FushiFloatingChromeScope] 显隐的一段工具区（外壳的页签 / 动作行、页面
/// 里的搜索筛选行共用同一份显隐，收起时一起收）。
///
/// 收起后键盘 / 手柄焦点走进来（Tab 遍历到页签或按钮）立刻弹回：收起只是让出
/// 屏幕空间，不能让控件变得够不着。没挂作用域时原样返回 [child]。
class FushiFloatingChromeReveal extends StatelessWidget {
  const FushiFloatingChromeReveal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final FushiFloatingChromeController? controller =
        FushiFloatingChromeScope.maybeOf(context);
    if (controller == null) return child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool focused) {
        if (focused) controller.show();
      },
      child: FushiSpringReveal(visible: controller.visible, child: child),
    );
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
/// [FushiFloatingChromeReveal] 显隐。
class FushiFloatingChromeBar extends StatelessWidget {
  const FushiFloatingChromeBar({
    required this.tabs,
    required this.slot,
    this.padding,
    super.key,
  });

  final Widget tabs;
  final FushiShellActionsSlot slot;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return FushiFloatingChromeReveal(
      child: Padding(
        // 下边距要容得下胶囊的投影（elevation 3），收起动画的裁剪才不切到影子。
        padding:
            padding ??
            const EdgeInsets.fromLTRB(
              12,
              kFushiFloatingChromeGap / 2,
              12,
              kFushiFloatingChromeGap,
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
      ),
    );
  }
}

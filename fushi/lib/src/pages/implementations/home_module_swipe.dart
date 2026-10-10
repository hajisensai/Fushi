/// 手机底栏布局里「左右滑动切换功能模块」（2026-10-09 用户反馈：比点「⋯」再点
/// 目标顺手）。
///
/// 规则都收在这里的纯函数里，[HomePage] 只负责接线：
/// - **顺序 = 底栏顺序**（含「⋯」溢出里的模块；跟随「反转导航栏」与 RTL）；
///   只在已启用的模块 tab 之间走，到头不循环。设置不是模块、查词是底栏旁的独立
///   搜索钮（不在胶囊序列里），两者都不参与（[homeSwipeTabs]）。
/// - **只在模块根**：tab 内容里有页内状态在接系统返回（多选模式、媒体服务器
///   嵌套栈钻进去一层）时不切（[ModuleRootTracker]）。阅读器 / 播放器 / 漫画是
///   压在首页之上的路由，手势根本到不了这里。
/// - **子组件优先**：识别器挂在 tab 内容的祖先上，手势竞技场里更深的横向识别器
///   （页签横滑 [TabBarView]、横排封面列表、轮播、滑块、Dismissible）先拿到并消费
///   手势；只有没人要的横向拖动才落到这里。
/// - **库页分区接力**：书架 / 漫画 / 视频 / 游戏库页自己就有整页横滑切分区
///   （`SectionSwipeNavigator`，书架 → 发现 → 来源 …），那一层更深、恒先赢。它在
///   首 / 末分区再往外滑时经 [SectionSwipeOverflowScope] 把手势交到这里切模块——
///   与「浏览」二级页签越界接力顶层页签同一个形态，分区横滑一格都不丢。
/// - **只认触摸**：桌面鼠标 / 触控板拖不切（窄窗桌面也走底栏布局）。
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart'
    show SectionSwipeOverflowScope;
import 'package:fushi/src/utils/components/section_visibility.dart';

/// 参与横滑切换的 tab，按**屏幕上的从左到右**排列（LTR）。
///
/// [tabs] 是 `homeActiveTabs` 的逻辑顺序；[reversed] 是「反转导航栏」。
List<HomeTab> homeSwipeTabs({
  required List<HomeTab> tabs,
  required bool reversed,
}) {
  final List<HomeTab> modules = <HomeTab>[
    for (final HomeTab tab in tabs)
      if (tab != HomeTab.settings && tab != HomeTab.dictionaries) tab,
  ];
  return reversed ? modules.reversed.toList() : modules;
}

/// 一次横滑的目标 tab；`null` = 当前 tab 不参与横滑或已经到头。
///
/// [fingerTowardStart]：手指朝**屏幕左侧**移动（拖动位移为负）。像翻页一样，
/// 手指左移露出右边那一项。RTL 下底栏整排镜像，屏幕右边那一项是逻辑上的前一项，
/// 所以按 [textDirection] 再翻一次。
HomeTab? homeModuleSwipeTarget({
  required List<HomeTab> tabs,
  required HomeTab current,
  required bool reversed,
  required bool fingerTowardStart,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final List<HomeTab> order = homeSwipeTabs(tabs: tabs, reversed: reversed);
  final int index = order.indexOf(current);
  if (index < 0) return null;
  final bool towardScreenRight = fingerTowardStart;
  final bool towardListEnd = textDirection == TextDirection.ltr
      ? towardScreenRight
      : !towardScreenRight;
  final int next = index + (towardListEnd ? 1 : -1);
  if (next < 0 || next >= order.length) return null;
  return order[next];
}

/// 拖动结束时距离 / 速度够不够算一次「切换」。
///
/// 两种成立方式：拖过视口宽度的 [kModuleSwipeCommitFraction]；或者至少拖了
/// [kModuleSwipeMinDistance] 且以 [kModuleSwipeFlingVelocity] 以上的速度朝同一
/// 方向甩出。只轻轻蹭一下（纵向滚动时手指略斜）两条都不满足。
bool homeModuleSwipeCommits({
  required double dragDistance,
  required double velocity,
  required double viewportWidth,
}) {
  final double distance = dragDistance.abs();
  if (distance >= viewportWidth * kModuleSwipeCommitFraction) return true;
  return distance >= kModuleSwipeMinDistance &&
      velocity.abs() >= kModuleSwipeFlingVelocity &&
      velocity.sign == dragDistance.sign;
}

/// 拖过视口宽度的这个比例就算切换（不看速度）。
const double kModuleSwipeCommitFraction = 0.3;

/// 甩动切换的最小拖动距离（逻辑像素）。
const double kModuleSwipeMinDistance = 56;

/// 甩动切换的最小速度（逻辑像素 / 秒）。
const double kModuleSwipeFlingVelocity = 400;

/// 共享轴（X）转场的位移距离：与新手引导换步同一个值（M3 shared axis 30dp）。
const double _kSharedAxisDistance = 30;

/// 让外部入口（底栏长按拖选）切完模块后播同一段进场转场。
///
/// 宿主持有它并交给 [HomeModuleSwipeDetector]；没挂载时 [playEnter] 什么都不做。
class HomeModuleSwipeController {
  _HomeModuleSwipeDetectorState? _state;

  /// 播一次共享轴（X）进场。[fromScreenRight]：新页从屏幕右侧滑入（目标模块在
  /// 当前模块的屏幕右边）。
  void playEnter({required bool fromScreenRight}) =>
      _state?._playEnter(fromScreenRight: fromScreenRight);
}

/// 把横滑切模块接到 tab 内容上，并在切换后播一次共享轴（X）进场转场。
///
/// 只有被切到的那一页做进场（离开的那页由宿主立即 Offstage，不保留截图）：保活
/// tab 的 State 不能为了转场重挂，这是在不动宿主 IndexedStack 结构下能做的
/// 共享轴的那一半。时长 / 曲线取 M3E spatial default 弹簧 token，系统「减弱
/// 动态效果」下不播。
class HomeModuleSwipeDetector extends StatefulWidget {
  const HomeModuleSwipeDetector({
    required this.enabled,
    required this.tracker,
    required this.targetFor,
    required this.onSwipe,
    required this.child,
    this.controller,
    super.key,
  });

  /// 外部入口（底栏长按拖选）借用进场转场的把手。
  final HomeModuleSwipeController? controller;

  /// 当前布局 / 当前 tab 是否参与横滑。false 时不挂识别器（不进手势竞技场）。
  final bool enabled;

  /// tab 内容的「模块根」登记表（多选 / 嵌套栈时不切）。
  final ModuleRootTracker tracker;

  /// 手指朝屏幕左侧（true）/ 右侧（false）横滑时要切到的 tab；`null` = 到头。
  final HomeTab? Function({required bool fingerTowardStart}) targetFor;

  /// 切换落地（走宿主的统一切 tab 入口）。
  final ValueChanged<HomeTab> onSwipe;

  final Widget child;

  @override
  State<HomeModuleSwipeDetector> createState() =>
      _HomeModuleSwipeDetectorState();
}

class _HomeModuleSwipeDetectorState extends State<HomeModuleSwipeDetector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    value: 1,
  );

  /// 本次拖动的累计横向位移；`null` = 本次拖动不算（开始时不在模块根）。
  double? _drag;

  /// 进场方向：+1 = 新页从右侧滑入（手指左移），-1 = 从左侧滑入。
  double _enterSign = 1;

  Curve _curve = FushiSprings.spatialDefault.curve;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(HomeModuleSwipeDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller?._state, this)) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _enter.dispose();
    super.dispose();
  }

  void _onStart(DragStartDetails details) {
    _drag = widget.tracker.atRoot ? 0 : null;
  }

  void _onUpdate(DragUpdateDetails details) {
    final double? drag = _drag;
    if (drag == null) return;
    _drag = drag + details.delta.dx;
  }

  void _onEnd(DragEndDetails details) {
    final double? drag = _drag;
    _drag = null;
    if (drag == null || !mounted) return;
    // 拖动途中进了多选之类的页内状态，同样不切。
    if (!widget.tracker.atRoot) return;
    final double width = context.size?.width ?? 0;
    if (width <= 0) return;
    if (!homeModuleSwipeCommits(
      dragDistance: drag,
      velocity: details.primaryVelocity ?? 0,
      viewportWidth: width,
    )) {
      return;
    }
    final bool fingerTowardStart = drag < 0;
    final HomeTab? target = widget.targetFor(
      fingerTowardStart: fingerTowardStart,
    );
    if (target == null) return;
    widget.onSwipe(target);
    _playEnter(fromScreenRight: fingerTowardStart);
  }

  /// 库页分区横滑越过首 / 末分区时的接力（[SectionSwipeOverflowScope]）。
  /// [forward] 是阅读方向上的「下一个」；换回手指的物理方向再走同一条判据。
  void _onSectionOverflow({required bool forward}) {
    if (!widget.enabled || !mounted || !widget.tracker.atRoot) return;
    final bool fingerTowardStart =
        Directionality.of(context) == TextDirection.ltr ? forward : !forward;
    final HomeTab? target = widget.targetFor(
      fingerTowardStart: fingerTowardStart,
    );
    if (target == null) return;
    widget.onSwipe(target);
    _playEnter(fromScreenRight: fingerTowardStart);
  }

  void _onCancel() => _drag = null;

  void _playEnter({required bool fromScreenRight}) {
    final FushiSpringSpec spec = context.fushiMotion.spatialDefault;
    if (!fushiMotionEnabled(context) || !spec.enabled) {
      _enter.value = 1;
      return;
    }
    _enterSign = fromScreenRight ? 1 : -1;
    _curve = spec.curve;
    _enter.duration = spec.duration;
    _enter.forward(from: 0);
  }

  static const Interval _fadeIn = Interval(
    0.2,
    1,
    curve: FushiSpringCurve.effects,
  );

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled;
    return ModuleRootScope(
      tracker: widget.tracker,
      child: GestureDetector(
        // 空白区（空库页、空态插画四周）没有可命中的子组件，deferToChild 会让
        // 那里的横滑落空；translucent 让本层自己也参与命中，子组件照常先拿。
        behavior: HitTestBehavior.translucent,
        supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.touch},
        // 横滑切模块只是触摸捷径（底栏同样能切）。不排除语义的话，横向拖动
        // 识别器会给整个正文挂上 scrollLeft / scrollRight 无障碍动作，读屏的
        // 横滚手势就会误切模块（2026-10-10 审查）。
        excludeFromSemantics: true,
        onHorizontalDragStart: enabled ? _onStart : null,
        onHorizontalDragUpdate: enabled ? _onUpdate : null,
        onHorizontalDragEnd: enabled ? _onEnd : null,
        onHorizontalDragCancel: enabled ? _onCancel : null,
        child: AnimatedBuilder(
          animation: _enter,
          child: SectionSwipeOverflowScope(
            onOverflow: _onSectionOverflow,
            child: widget.child,
          ),
          // 静止时也恒套 Opacity + Transform（值为 1 / 零位移，不产生合成层）：
          // 按动画状态增删这两层会让整棵 tab 正文重挂，保活 tab 的 State 全丢。
          builder: (BuildContext context, Widget? child) {
            final double t = _enter.value;
            final double travel = t >= 1 ? 0 : 1 - _curve.transform(t);
            return Opacity(
              key: const ValueKey<String>('home-module-swipe-transition'),
              opacity: t >= 1 ? 1 : _fadeIn.transform(t),
              child: Transform.translate(
                offset: Offset(travel * _kSharedAxisDistance * _enterSign, 0),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}

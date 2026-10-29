import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

/// 卡片悬浮抬升：鼠标移入时轻微放大，并把 hover 态交给 [builder]，由调用方决定
/// 还要不要顺带加深阴影/描边。
///
/// 抽出来的原因：这套动效原本只长在 [GalgamePosterCard] 里（全 app 唯一一处
/// `AnimatedScale`），书架 / 漫画 / 视频库的卡片都只有 `InkWell` 水波纹、鼠标
/// 悬停毫无反馈。把它复制到各库页会得到 N 份互相漂移的实现，所以先收成一个壳。
///
/// 两处降级是 [GalgamePosterCard] 原实现缺的，推广前必须补上——否则动效铺开
/// 之后这两类设备/偏好会明显变差：
/// - **墨水屏**（[isEinkTheme]）：持续缩放会不断触发整屏重绘刷屏，直接关掉动效，
///   hover 反馈交给 builder 自己（通常改成描边）。
/// - **减弱动态效果**（`MediaQuery.disableAnimations`，系统无障碍开关）：同样
///   关掉缩放，但 hover 状态照常传给 builder，静态反馈保留。
///
/// 触屏平台上 [MouseRegion] 本就不会触发，无需按平台分流。
///
/// **Apple 设计系统**（[isGlassDesign]）同样悬停放大、按压下沉（所有者
/// 2026-10-13 拍板），只是默认放大倍数换成更轻的 [kFushiAppleHoverLiftScale]。
/// 设计系统只改倍数、不增删包装层：切换设计系统时子树结构不变，[builder] 建出
/// 的 State 不重建。
///
/// **不变式（BUG-2124）**：屏幕上被放大的卡 ⟺ 指针正下方的卡。滚动会破坏它——
/// Flutter 的鼠标命中判定在帧末才重算，`onExit` 到达时卡片已经位移，而复位又走
/// [kFushiHoverLiftDuration] 缓动，于是那张已经滚走的卡在**新位置**上继续放大
/// 8 帧（实测 128ms / 偏离 120px），指针底下的新卡同时才刚开始涨——滚动全程没有
/// 一张放大的卡跟指针对齐，用户看到的就是「另一个地方的卡片被选中了」。
///
/// 修法是把不变式补成「放大 = 指针悬停 **且** 不在滚动中」，滚动一起步就同帧落回
/// 1.0（所以缩放走显式 [AnimationController] 而不是 `AnimatedScale`——隐式动画
/// 即使时长为 0 也要晚两三帧才落值，那几帧正是症状本身）。两条纪律：
/// - **不能**顺手把 [_hovering] 清掉：`MouseRegion` 只在命中集真的变化时才发事件，
///   指针没动的话滚动停止后不会补一个 `onEnter`，清了就再也涨不回来，直到用户挪
///   一下鼠标。所以 hover 与 scrolling 是两个正交的位。
/// - 压制要同时认「`ScrollStart..ScrollEnd` 之间」和「本帧发生过位移」两个位：
///   桌面粗滚轮经 根部 `SmoothWheelScrollScope` 的补间动画跨十几帧，靠前者；而 Flutter
///   默认的滚轮路径在同一次事件处理里就把 start/update/end 全发完，只能靠后者。
class FushiHoverLift extends StatefulWidget {
  const FushiHoverLift({
    super.key,
    required this.builder,
    this.enabled = true,
    this.scale = kFushiHoverLiftScale,
    this.forceLifted = false,
  });

  /// 拿到当前 hover 态自行构建内容。hover 态在 [enabled] 为 false 时恒为 false。
  final Widget Function(BuildContext context, bool hovering) builder;

  /// false 时既不建 [MouseRegion] 也不缩放（例如多选态、或调用方不想要动效）。
  final bool enabled;

  /// 悬停时的缩放倍数。默认与游戏库既有观感一致。
  final double scale;

  /// 不靠指针也保持抬升（例如桌面拖文件悬停在导入卡上：拖拽期间 [MouseRegion]
  /// 收不到 enter/exit，由调用方从 `FushiFileDropTarget.onHoverChanged` 传进来）。
  /// [enabled] 为 false 时无效；滚动压制不作用于它（拖拽期间不会滚动）。
  final bool forceLifted;

  @override
  State<FushiHoverLift> createState() => _FushiHoverLiftState();

  /// 最近一层 [FushiHoverLift] 当前是否处于抬升态（没有祖先时为 false）。
  ///
  /// 卡片内部的封面框（`ShelfCoverFrame`）靠它在悬停时加深阴影——各库页调用点
  /// 的 builder 都把 hovering 位丢掉了（`(_, __) => card`），逐个改调用点要动一
  /// 批高冲突的页面文件，故由壳自己往下广播。
  static bool liftedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_FushiHoverLiftScope>()
          ?.lifted ??
      false;

  /// 最近一层 [FushiHoverLift] 的指针位置（卡片内归一化到 -1..1，中心为 0）；
  /// 不在倾斜态时为 null。notifier 本身恒定，取它不建立依赖、不触发重建。
  static ValueListenable<Offset?>? tiltOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_FushiHoverLiftScope>()?.tilt;
}

/// [FushiHoverLift.liftedOf] 的载体。
class _FushiHoverLiftScope extends InheritedWidget {
  const _FushiHoverLiftScope({
    required this.lifted,
    required this.tilt,
    required super.child,
  });

  final bool lifted;
  final ValueListenable<Offset?> tilt;

  @override
  bool updateShouldNotify(_FushiHoverLiftScope oldWidget) =>
      oldWidget.lifted != lifted;
}

/// 由外层代收悬停：子树里的 [FushiHoverLift] 把 [hovering] 当作自己的指针悬停。
///
/// 给「卡片整张包在 `IgnorePointer` 里、手势由外层格子统一接管」的场景用（合集
/// 详情页拖排网格）：`IgnorePointer` 同时挡掉了命中测试，卡片自己的
/// [MouseRegion] 永远收不到 enter，悬停抬升 / 封面扫光 / 接触阴影收窄就全没了。
/// 外层格子自己测悬停再经本组件往下传，卡片照常走同一套悬停动效。
class FushiHoverLiftHost extends InheritedWidget {
  const FushiHoverLiftHost({
    required this.hovering,
    required super.child,
    super.key,
  });

  final bool hovering;

  static bool hoveringOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiHoverLiftHost>()
          ?.hovering ??
      false;

  @override
  bool updateShouldNotify(FushiHoverLiftHost oldWidget) =>
      oldWidget.hovering != hovering;
}

/// 悬停缩放倍数：与 `docs/design/galgame-library-reina-visual-parity.md` 里定的
/// 游戏库观感一致，推广到其余库页时不另立数值。
const double kFushiHoverLiftScale = 1.05;

/// Apple 设计系统下的悬停放大（macOS 26 的卡片悬停只是轻轻一抬，1.05 读作
/// 「跳」）。只替换默认值；调用方显式传了别的 scale 时照用。
const double kFushiAppleHoverLiftScale = 1.03;

/// 悬停动画时长（游戏库既有实现的落地值）。
const Duration kFushiHoverLiftDuration = Duration(milliseconds: 120);

class _FushiHoverLiftState extends State<FushiHoverLift>
    with SingleTickerProviderStateMixin {
  /// 指针是否真的在这张卡上（[MouseRegion] 的真值，滚动**不得**改它）。
  bool _hovering = false;

  /// 外层 [FushiHoverLiftHost] 代收的悬停（同样是指针真值，与 [_hovering] 取或）。
  bool _hostHovering = false;

  bool get _pointerOver => _hovering || _hostHovering;

  /// 本帧发生过滚动位移。**这是唯一的压制位**——覆盖三条路径：Flutter 默认滚轮
  /// （同一次事件处理里把 Start/Update/End 全发完）、拖拽滚动、以及
  /// `SmoothWheelScrollScope` 的 140ms 补间（走 `DrivenScrollActivity`，每帧一条
  /// ScrollUpdate）。
  ///
  /// 置位与落位写在同一处（[_onScrollNotification]）：落位若挂在 build 里，
  /// `!enabled` 那条提前 return 就会让它永远注册不上、这一位永久为真。
  bool _moved = false;

  /// 缩放动效是否开启（墨水屏 / 减弱动态效果两处降级）。依赖 InheritedWidget，
  /// 在 [didChangeDependencies] 里算好缓存，供事件回调同步取用。
  bool _animate = true;

  ScrollNotificationObserverState? _scrollObserver;

  /// 抬升用**显式** controller 而不是 `AnimatedScale`：隐式动画即使时长为 0，
  /// 目标值到渲染值之间也隔一帧，滚动压制会晚 2~3 帧落地——那几帧的放大正画在
  /// 已经滚走的卡上，就是 BUG-2124 的症状本身。显式 controller 可以在收到滚动
  /// 通知的同一帧直接 `value = 0`。
  ///
  /// 在 [initState] 里建而不是 `late final` 懒建：`enabled == false` 的卡从不读
  /// 它，懒建会推迟到 [dispose] 那一次访问才触发构造，此时 element 已 deactivate，
  /// `AnimationController` 去查 `TickerMode` 祖先会直接抛
  /// 「Looking up a deactivated widget's ancestor is unsafe」（已实测踩过）。
  late final AnimationController _lift;
  late final CurvedAnimation _curved;

  /// 3D 倾斜视差的指针位置（-1..1）。鼠标：悬停抬升期间跟随指针；触屏：按住
  /// 期间跟随手指（触屏没有 hover）。滚动、退出、抬起都落回 null。
  final ValueNotifier<Offset?> _tilt = ValueNotifier<Offset?>(null);
  Offset? _pointer;
  bool _touching = false;

  @override
  void initState() {
    super.initState();
    _lift = AnimationController(vsync: this, duration: kFushiHoverLiftDuration);
    _curved = CurvedAnimation(parent: _lift, curve: FushiSpringCurve.effects);
  }

  /// 抬升的唯一判据：指针在这张卡上，且**这一帧刚滚过**（BUG-2124）。
  ///
  /// **刻意不看 ScrollStart/End 那对通知**：Flutter 不保证它们配对——
  /// `ScrollPosition.dispose()` 不调 `didEndScroll()`，而首页各 tab 的卡挂在同一个
  /// Scaffold 的 observer 下、被 `TickerMode` 冻住的惯性滚动永远发不出 ScrollEnd。
  /// 拿一个「开始了就置 true、只靠 End 落下」的位当判据，命中即整片卡的悬停放大**永久**
  /// 失效。而按帧位判本来就更准：ScrollStart 那一刻还没有任何位移，第一条 ScrollUpdate
  /// 才是真的滚起来了；`SmoothWheelScrollScope` 的 140ms 补间走 `DrivenScrollActivity`，
  /// 每帧都发 ScrollUpdate，同样被这一位盖住。
  bool get _lifted =>
      widget.enabled && (widget.forceLifted || (_pointerOver && !_moved));

  /// [immediate] 为真时同帧落位，不走缓动。
  void _syncLift({bool immediate = false}) {
    final double target = _lifted ? 1.0 : 0.0;
    if (immediate || !_animate) {
      _lift.stop();
      _lift.value = target;
      return;
    }
    _syncTilt();
    if (_lift.value == target && !_lift.isAnimating) return;
    // 曲线由 [_curved] 施加，这里给 controller 线性推进即可。
    _lift.animateTo(target);
  }

  void _syncTilt() {
    final bool on =
        widget.enabled &&
        _animate &&
        !_moved &&
        (_touching || (_pointerOver && _lifted));
    _tilt.value = on ? _pointer : null;
  }

  /// 把卡片内的局部坐标归一化到 -1..1。
  void _trackPointer(Offset local) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final Size size = box.size;
    if (size.isEmpty) return;
    _pointer = Offset(
      (local.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
      (local.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
    );
    _syncTilt();
  }

  void _onPointerDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return;
    _touching = true;
    _trackPointer(e.localPosition);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      _trackPointer(e.localPosition);
      return;
    }
    if (_touching) _trackPointer(e.localPosition);
  }

  void _onPointerEnd(PointerEvent e) {
    if (e.kind == PointerDeviceKind.mouse || !_touching) return;
    _touching = false;
    _syncTilt();
  }

  void _setHover(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
    _syncLift();
  }

  void _onScrollNotification(ScrollNotification notification) {
    // depth 不过滤：横滚行卡在纵向页里滚动时通知来自更外层的 Scrollable，
    // 同样必须压制抬升。
    //
    // 只认 ScrollUpdate：它是「真的滚了」的唯一可靠信号，且不依赖任何配对通知。
    if (notification is! ScrollUpdateNotification) return;
    // 触屏按住后拖动 = 在滚列表，不是在掰卡片。
    if (_touching) {
      _touching = false;
      _syncTilt();
    }
    // 本帧位只在正悬停时才置：没悬停的卡抬升本来就是 0，这一位对它毫无意义，
    // 而置了却不重建就会一直挂着。
    if (!_pointerOver || _moved) return;
    _moved = true;
    // 落下这一位的 post-frame **在这里挂**，不在 build 里挂：build 有 `!enabled`
    // 的提前 return 分支（长按进多选正好会在指针停在卡上时把 enabled 翻假），
    // 从那条分支走过去就永远注册不上，`_moved` 永久为真、之后再也不抬升。
    // 置位与落位是同一件事的两半，必须写在一起。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_moved) return;
      setState(() => _moved = false);
      _syncLift();
    });
    setState(() {});
    // 压制必须同帧落位；解除则走正常缓动涨回来。
    _syncLift(immediate: !_lifted);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final bool hostHovering = FushiHoverLiftHost.hoveringOf(context);
    if (hostHovering != _hostHovering) {
      _hostHovering = hostHovering;
      _syncLift();
    }
    final bool animate = !reduceMotion && !isEinkTheme(context);
    if (animate != _animate) {
      _animate = animate;
      _syncLift(immediate: true);
    }
    final ScrollNotificationObserverState? next =
        ScrollNotificationObserver.maybeOf(context);
    if (identical(next, _scrollObserver)) return;
    _scrollObserver?.removeListener(_onScrollNotification);
    _scrollObserver = next;
    _scrollObserver?.addListener(_onScrollNotification);
  }

  @override
  void didUpdateWidget(covariant FushiHoverLift oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.scale != widget.scale) {
      _syncLift(immediate: true);
    } else if (oldWidget.forceLifted != widget.forceLifted) {
      _syncLift();
    }
  }

  @override
  void dispose() {
    _scrollObserver?.removeListener(_onScrollNotification);
    _scrollObserver = null;
    _tilt.dispose();
    _curved.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      // 保证 builder 拿到的 hover 态与「没有 MouseRegion」一致。
      if (_hovering) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _setHover(false);
        });
      }
      return _FushiHoverLiftScope(
        lifted: false,
        tilt: _tilt,
        child: widget.builder(context, false),
      );
    }
    // 2026-10 交互重做：悬停抬升之外再叠按压下沉——触屏上没有 hover，卡片
    // 此前点下去只有水波纹；按压反馈放在抬升**内层**，两者独立叠乘（桌面上
    // 悬停 1.05 × 按下 0.97），抬升的显式 Transform 仍是本组件最外层变换。
    final Widget content = FushiPressScale(
      child: _FushiHoverLiftScope(
        lifted: _lifted,
        tilt: _tilt,
        child: widget.builder(context, _lifted),
      ),
    );
    // 设计系统只换倍数，不改子树结构（切换设计系统时 builder 的 State 不重建）。
    final double scale =
        widget.scale == kFushiHoverLiftScale && isGlassDesign(context)
        ? kFushiAppleHoverLiftScale
        : widget.scale;
    if (!_animate) return _wrapHover(content);
    return _wrapHover(
      AnimatedBuilder(
        animation: _curved,
        builder: (BuildContext _, Widget? child) => Transform.scale(
          scale: 1.0 + (scale - 1.0) * _curved.value,
          child: child,
        ),
        child: content,
      ),
    );
  }

  Widget _wrapHover(Widget child) => MouseRegion(
    onEnter: (PointerEnterEvent e) {
      _trackPointer(e.localPosition);
      _setHover(true);
    },
    onHover: (PointerHoverEvent e) => _trackPointer(e.localPosition),
    onExit: (_) {
      _pointer = null;
      _setHover(false);
      _syncTilt();
    },
    child: Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: child,
    ),
  );
}

/// 3D 倾斜视差的最大偏转角（度）。
const double kFushiTiltMaxDegrees = 9;

/// 倾斜跟随指针的缓动时长。
const Duration kFushiTiltFollowDuration = Duration(milliseconds: 160);

/// 3D 倾斜视差（2026-10-29 用户：「全部媒体选中都要网上那种 3D 斜视差，PC 跟
/// 鼠标位置」）：读最近一层 [FushiHoverLift] 的指针位置，把 [child] 朝指针一侧
/// 按下去（指针下那一边远离观察者），平滑跟随，离开时缓回平面。
///
/// 树结构恒定：没有 [FushiHoverLift] 祖先时原样返回 [child]；有祖先时不在倾斜态
/// 也照样包着（单位变换）。墨水屏 / 减弱动态效果下 [FushiHoverLift] 不发指针
/// 位置，这里自然不动。
class FushiTilt extends StatelessWidget {
  const FushiTilt({required this.child, this.enabled = true, super.key});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<Offset?>? tilt = enabled
        ? FushiHoverLift.tiltOf(context)
        : null;
    if (tilt == null) return child;
    return ValueListenableBuilder<Offset?>(
      valueListenable: tilt,
      child: child,
      builder: (BuildContext context, Offset? p, Widget? child) =>
          TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(end: p ?? Offset.zero),
            duration: kFushiTiltFollowDuration,
            curve: FushiSpringCurve.effects,
            child: child,
            builder: (BuildContext context, Offset v, Widget? child) {
              const double a = kFushiTiltMaxDegrees * math.pi / 180;
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateX(v.dy * a)
                  ..rotateY(-v.dx * a),
                child: child,
              );
            },
          ),
    );
  }
}

/// 倾斜时跟着指针走的镜面高光：一团径向柔光落在指针位置，越靠边越亮一点，
/// 读作「光面封面在灯下转动」。画在封面裁切区内、点击穿透。
class FushiTiltGlare extends StatelessWidget {
  const FushiTiltGlare({super.key});

  @override
  Widget build(BuildContext context) {
    final ValueListenable<Offset?>? tilt = FushiHoverLift.tiltOf(context);
    if (tilt == null) return const SizedBox.shrink();
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: ValueListenableBuilder<Offset?>(
        valueListenable: tilt,
        builder: (BuildContext context, Offset? p, Widget? _) =>
            TweenAnimationBuilder<Offset>(
              tween: Tween<Offset>(end: p ?? Offset.zero),
              duration: kFushiTiltFollowDuration,
              curve: FushiSpringCurve.effects,
              builder: (BuildContext context, Offset v, Widget? _) =>
                  AnimatedOpacity(
                    opacity: p == null ? 0 : 1,
                    duration: kFushiTiltFollowDuration,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(v.dx, v.dy),
                          radius: 1.1,
                          colors: <Color>[
                            Colors.white.withValues(
                              alpha:
                                  (dark ? 0.16 : 0.22) +
                                  0.06 * v.distance.clamp(0.0, 1.0),
                            ),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
            ),
      ),
    );
  }
}

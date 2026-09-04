import 'package:flutter/material.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

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
///   桌面粗滚轮经 `FushiScrollController` 的补间动画跨十几帧，靠前者；而 Flutter
///   默认的滚轮路径在同一次事件处理里就把 start/update/end 全发完，只能靠后者。
class FushiHoverLift extends StatefulWidget {
  const FushiHoverLift({
    super.key,
    required this.builder,
    this.enabled = true,
    this.scale = kFushiHoverLiftScale,
  });

  /// 拿到当前 hover 态自行构建内容。hover 态在 [enabled] 为 false 时恒为 false。
  final Widget Function(BuildContext context, bool hovering) builder;

  /// false 时既不建 [MouseRegion] 也不缩放（例如多选态、或调用方不想要动效）。
  final bool enabled;

  /// 悬停时的缩放倍数。默认与游戏库既有观感一致。
  final double scale;

  @override
  State<FushiHoverLift> createState() => _FushiHoverLiftState();
}

/// 悬停缩放倍数：与 `docs/design/galgame-library-reina-visual-parity.md` 里定的
/// 游戏库观感一致，推广到其余库页时不另立数值。
const double kFushiHoverLiftScale = 1.05;

/// 悬停动画时长（游戏库既有实现的落地值）。
const Duration kFushiHoverLiftDuration = Duration(milliseconds: 120);

class _FushiHoverLiftState extends State<FushiHoverLift>
    with SingleTickerProviderStateMixin {
  /// 指针是否真的在这张卡上（[MouseRegion] 的真值，滚动**不得**改它）。
  bool _hovering = false;

  /// 祖先滚动区处在 `ScrollStart..ScrollEnd` 之间。覆盖走补间动画的滚动
  /// （桌面粗滚轮经 `FushiScrollController` 的 `animateTo`，跨十几帧）。
  bool _scrolling = false;

  /// 本帧发生过滚动位移。覆盖 Flutter 默认的滚轮路径——它在**同一次事件处理里**
  /// 就把 `ScrollStart / ScrollUpdate / ScrollEnd` 全发完（已用探针实测），
  /// [_scrolling] 那一位置起又立刻落下，单靠它压不住这条路径。
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

  @override
  void initState() {
    super.initState();
    _lift = AnimationController(
      vsync: this,
      duration: kFushiHoverLiftDuration,
    );
    _curved = CurvedAnimation(parent: _lift, curve: Curves.easeOut);
  }

  /// 抬升的唯一判据：指针在这张卡上，且没在滚动（BUG-2124）。
  bool get _lifted => widget.enabled && _hovering && !_scrolling && !_moved;

  /// [immediate] 为真时同帧落位，不走缓动。
  void _syncLift({bool immediate = false}) {
    final double target = _lifted ? 1.0 : 0.0;
    if (immediate || !_animate) {
      _lift.stop();
      _lift.value = target;
      return;
    }
    if (_lift.value == target && !_lift.isAnimating) return;
    // 曲线由 [_curved] 施加，这里给 controller 线性推进即可。
    _lift.animateTo(target);
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
    // **不要**把 ScrollUpdateNotification 也当作 [_scrolling] 的起点：
    // `jumpTo` / 恢复滚动位置这类一次性位移会单发 update 而没有配对的 end，
    // [_scrolling] 会永久卡在 true、连初次悬停都不再抬升（已实测踩过）。
    // 它只用来置本帧位 [_moved]，由 build 的 post-frame 负责落下。
    bool changed = false;
    if (notification is ScrollStartNotification) {
      changed = !_scrolling;
      _scrolling = true;
    } else if (notification is ScrollEndNotification) {
      changed = _scrolling;
      _scrolling = false;
    } else if (notification is ScrollUpdateNotification) {
      // 本帧位只在正悬停时才置：它靠 build 的 post-frame 落下，而没悬停的卡这里
      // 不 setState、也就走不到那次 build，置了就会永久卡住、之后鼠标移上来再也
      // 不抬升。没悬停时抬升本来就是 0，这一位对它毫无意义。
      if (!_hovering) return;
      changed = !_moved;
      _moved = true;
    } else {
      return;
    }
    // 只有正抬升着的那张卡需要重建；其余卡记下位即可，避免一次滚动把整墙刷一遍。
    if (!changed || !_hovering) return;
    setState(() {});
    // 压制必须同帧落位；解除则走正常缓动涨回来。
    _syncLift(immediate: !_lifted);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
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
    }
  }

  @override
  void dispose() {
    _scrollObserver?.removeListener(_onScrollNotification);
    _scrollObserver = null;
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
      return widget.builder(context, false);
    }
    // 本帧位只压这一帧：下一帧 MouseTracker 已经重算过 hover，[_hovering] 就是
    // 新的真值，该不该抬升由它说了算。
    if (_moved) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_moved) return;
        setState(() => _moved = false);
        _syncLift();
      });
    }
    final Widget content = widget.builder(context, _lifted);
    if (!_animate) return _wrapHover(content);
    return _wrapHover(
      AnimatedBuilder(
        animation: _curved,
        builder: (BuildContext _, Widget? child) => Transform.scale(
          scale: 1.0 + (widget.scale - 1.0) * _curved.value,
          child: child,
        ),
        child: content,
      ),
    );
  }

  Widget _wrapHover(Widget child) => MouseRegion(
        onEnter: (_) => _setHover(true),
        onExit: (_) => _setHover(false),
        child: child,
      );
}

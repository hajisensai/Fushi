import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 加载指示器的显示门：查询开始后先等 [kDeferredLoadingDelay] 才露出指示器（快
/// 查询根本不闪），一旦露出至少停留 [kDeferredLoadingMinVisible]（避免一闪而过），
/// 出入场淡入淡出 [kDeferredLoadingFade]。与 popup.js 的 WebView 内加载态同一组数。
const Duration kDeferredLoadingDelay = Duration(milliseconds: 150);
const Duration kDeferredLoadingMinVisible = Duration(milliseconds: 300);
const Duration kDeferredLoadingFade = Duration(milliseconds: 150);

/// 查询结果区的三态。「无结果」只能在查询**真的结束**且确认为空之后出现——
/// 查询进行中、或输入已变但新查询还在去抖窗口里（旧结果不属于当前输入）都算加载中，
/// 否则用户会先看到一闪「未找到」再跳成结果（假空态）。
enum QueryBodyState { results, loading, empty }

/// [hasResults]：手里的结果非空（加载中也继续展示旧结果，不清屏）；
/// [searching]：查询在途；[queryPending]：已排定、尚未发出的查询（去抖计时中）。
QueryBodyState resolveQueryBodyState({
  required bool hasResults,
  required bool searching,
  required bool queryPending,
}) {
  if (hasResults) return QueryBodyState.results;
  if (searching || queryPending) return QueryBodyState.loading;
  return QueryBodyState.empty;
}

/// 盖在内容之上的「延迟加载」层（常驻在树里，结构恒定）。
///
/// - [active] 变 true：立即铺 [background]（null = 不铺，只出指示器），指示器在
///   [kDeferredLoadingDelay] 之后淡入；
/// - [active] 变 false：指示器还没露出 → 立即撤掉；已露出 → 补足
///   [kDeferredLoadingMinVisible] 后整层淡出，下面的内容随之淡入。
///
/// 撤掉后是零尺寸空盒、不拦指针（盖在查词 WebView 上时不能吞点击，BUG-1692）。
class FushiDeferredLoading extends StatefulWidget {
  const FushiDeferredLoading({
    required this.active,
    super.key,
    this.background,
    this.compact = false,
    this.color,
  });

  final bool active;
  final Color? background;
  final bool compact;
  final Color? color;

  @override
  State<FushiDeferredLoading> createState() => _FushiDeferredLoadingState();
}

class _FushiDeferredLoadingState extends State<FushiDeferredLoading> {
  /// 延迟露出 / 淡出收尾的计时器。
  Timer? _timer;

  /// 最短停留计时器（指示器露出时启动）。用计时器而不是比墙钟：测试的假时钟只管
  /// Timer，不管 DateTime.now()。
  Timer? _minVisibleTimer;

  /// 层是否在场（铺底 / 拦指针）。
  bool _present = false;

  /// 指示器是否已露出。
  bool _indicatorShown = false;

  /// 露出后是否已满最短停留时间。
  bool _minVisibleElapsed = false;

  /// 整层淡出中。
  bool _fadingOut = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _begin();
  }

  @override
  void didUpdateWidget(FushiDeferredLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _begin();
    } else {
      _end();
    }
  }

  void _begin() {
    _timer?.cancel();
    _present = true;
    _fadingOut = false;
    if (_indicatorShown) return; // 撤场途中又开始：指示器原样留着
    _timer = Timer(kDeferredLoadingDelay, () {
      if (!mounted || !widget.active) return;
      setState(() {
        _indicatorShown = true;
        _minVisibleElapsed = false;
      });
      _minVisibleTimer?.cancel();
      _minVisibleTimer = Timer(kDeferredLoadingMinVisible, () {
        _minVisibleElapsed = true;
        if (mounted && !widget.active) _fadeOut();
      });
    });
  }

  void _end() {
    _timer?.cancel();
    if (!_indicatorShown) {
      _present = false;
      return;
    }
    // 露出不足最短停留：等最短停留计时器到点再淡出（它的回调会接手）。
    if (_minVisibleElapsed) _fadeOut();
  }

  void _fadeOut() {
    if (!mounted || widget.active || _fadingOut) return;
    setState(() => _fadingOut = true);
    _timer?.cancel();
    _timer = Timer(kDeferredLoadingFade, () {
      if (!mounted || widget.active) return;
      setState(() {
        _present = false;
        _indicatorShown = false;
        _minVisibleElapsed = false;
        _fadingOut = false;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _minVisibleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_present) return const SizedBox.shrink();
    final bool instant =
        isEinkTheme(context) ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final Duration fade = instant ? Duration.zero : kDeferredLoadingFade;
    final Color? background = widget.background;
    // 延迟期内不建指示器（不跑它的动画）；露出时从 0 淡入。
    Widget content = _indicatorShown
        ? TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: fade,
            curve: FushiSpringCurve.effects,
            builder: (BuildContext context, double t, Widget? child) =>
                Opacity(opacity: t, child: child),
            child: Center(
              child: FushiLoadingView(
                compact: widget.compact,
                color: widget.color,
              ),
            ),
          )
        : const SizedBox.expand();
    if (background != null) {
      content = ColoredBox(color: background, child: content);
    }
    return AnimatedOpacity(
      opacity: _fadingOut ? 0 : 1,
      duration: fade,
      curve: FushiSpringCurve.effects,
      child: content,
    );
  }
}

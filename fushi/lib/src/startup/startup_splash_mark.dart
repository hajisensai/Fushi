import 'dart:async';

import 'package:flutter/material.dart';

/// 启动品牌标的前景图：与 Android 12+ 系统启动画面
/// `windowSplashScreenAnimatedIcon`（`ic_splash_minimal_foreground`）同一张图。
const String kStartupSplashForegroundAsset =
    'assets/meta/splash_foreground.png';

/// 与 `values*-v31/styles.xml` 的 `windowSplashScreenIconBackgroundColor` 同值。
const Color kStartupSplashIconBackground = Color(0xFFE6E2F6);

/// Android 12+ 带图标背景的启动图标规格：图标画布 240dp，被直径 160dp 的圆裁切。
const double kStartupSplashIconCanvas = 240;
const double kStartupSplashIconDiameter = 160;

/// 初始化快于这个时长就什么进度都不显示（多数冷启动），避免「一闪而过的转圈」。
const Duration kStartupProgressRevealDelay = Duration(milliseconds: 900);

/// 延迟 [delay] 后才构建并淡入 [child]；在此之前只占 0 尺寸。
///
/// 加载指示器是持续动画，延迟期间干脆不构建它，而不是透明地让它空转。
class DelayedReveal extends StatefulWidget {
  const DelayedReveal({
    super.key,
    required this.delay,
    required this.child,
    this.fadeDuration = const Duration(milliseconds: 220),
  });

  final Duration delay;
  final Duration fadeDuration;
  final Widget child;

  @override
  State<DelayedReveal> createState() => _DelayedRevealState();
}

class _DelayedRevealState extends State<DelayedReveal> {
  Timer? _timer;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    if (widget.delay <= Duration.zero) {
      _revealed = true;
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) setState(() => _revealed = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_revealed) return const SizedBox.shrink();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: widget.fadeDuration,
      curve: Curves.easeOut,
      builder: (BuildContext context, double opacity, Widget? child) =>
          Opacity(opacity: opacity, child: child),
      child: widget.child,
    );
  }
}

/// 启动加载态：原样延续 Android 12+ 系统启动画面的图标（同尺寸、同位置、同配色），
/// 系统画面撤下、Flutter 首帧接手时视觉上没有跳变；初始化超过
/// [kStartupProgressRevealDelay] 才在图标下方淡入一条细进度条。
class StartupSplashMark extends StatelessWidget {
  const StartupSplashMark({
    super.key,
    required this.colorScheme,
    this.progressDelay = kStartupProgressRevealDelay,
  });

  final ColorScheme colorScheme;
  final Duration progressDelay;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // 图标必须保持在屏幕正中（系统 splash 的位置），进度条用平移挂在下方，
          // 不参与居中计算，否则它一出现图标就会上跳。
          SizedBox.square(
            dimension: kStartupSplashIconDiameter,
            child: ClipOval(
              child: ColoredBox(
                color: kStartupSplashIconBackground,
                child: OverflowBox(
                  maxWidth: kStartupSplashIconCanvas,
                  maxHeight: kStartupSplashIconCanvas,
                  child: Image.asset(
                    kStartupSplashForegroundAsset,
                    width: kStartupSplashIconCanvas,
                    height: kStartupSplashIconCanvas,
                    filterQuality: FilterQuality.medium,
                    // 解码是异步的：首帧只有底色圆，兔子随后淡入，不会硬闪。
                    frameBuilder: (
                      BuildContext context,
                      Widget child,
                      int? frame,
                      bool wasSynchronouslyLoaded,
                    ) {
                      if (wasSynchronouslyLoaded) return child;
                      return AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 150),
                        child: child,
                      );
                    },
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, kStartupSplashIconDiameter / 2 + 40),
            child: DelayedReveal(
              delay: progressDelay,
              child: SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                  color: colorScheme.primary,
                  backgroundColor: colorScheme.primary.withValues(alpha: 0.16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

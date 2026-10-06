import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 反馈族（进度条 / 转圈 / tooltip）的「设计系统分派」包装：构造参数与
// Material 原控件逐个同名同型，调用点只改类名。
//
// MD3 设计系统：Material 3 Expressive（2025）的波浪进度——线性
// [FushiWavyLinearProgress]、圆形 [FushiWavyCircularProgress]（见
// fushi_expressive_progress.dart；Flutter 3.44 内核没有 Expressive 组件，
// 自绘）。墨水屏、显式 `year2023: true`、外部 `controller` 驱动时退回
// Material 原控件（墨水屏的处理在主题里），`.adaptive` 在 iOS / macOS 平台
// 仍是原控件的 Cupertino 菊花。
//
// Apple 设计系统（都是内容层实色，不是玻璃）：
// - 线性进度 = [FushiAppleLinearProgress]：全圆角细轨（触屏 4 / 桌面 3），
//   已填段强调色、轨道 systemFill；不定态是一段短条左右往返（macOS 形态）；
// - 圆形进度：不定态 = iOS / macOS 菊花（[fushiAppleActivityIndicator]，灰），
//   确定态 = [FushiAppleProgressRing] 细圆环；
// - tooltip 保留 [Tooltip] 的触发 / 定位 / 无障碍行为，只把气泡换成小号中性
//   玻璃胶囊 [GlassContainer]（浮层控件）。

/// Apple 控件尺寸档：桌面（macOS / Windows / Linux）用 macOS 尺寸。
bool _appleDesktop(BuildContext context) {
  return switch (Theme.of(context).platform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

/// MD3 下是否退回 Material 原控件：墨水屏（波浪 / 动画在墨水屏上是持续局部
/// 刷新）、调用方显式要 2023 版、外部 controller 驱动动画（自绘控件不吃它）、
/// 主题关了 Material 3。
bool _useNativeMaterial(
  BuildContext context,
  bool? year2023,
  AnimationController? controller,
) {
  return isEinkTheme(context) ||
      year2023 == true ||
      controller != null ||
      !Theme.of(context).useMaterial3;
}

/// Apple 下进度色：调用方显式给的照用，否则强调色。**不读**主题的
/// progressIndicatorTheme——那是 MD3 的配色（secondaryContainer 轨道等），
/// 在 Apple 下会把 systemFill 轨道染成别的灰。
Color _appleIndicatorColor(
  BuildContext context,
  Color? color,
  Animation<Color?>? valueColor,
) {
  return valueColor?.value ?? color ?? appleColorsOf(context).accent;
}

/// MD3 下进度色：显式参数 → 主题 → primary（与 Material 原控件同优先级）。
Color _md3IndicatorColor(
  BuildContext context,
  Color? color,
  Animation<Color?>? valueColor,
) {
  final ThemeData theme = Theme.of(context);
  return valueColor?.value ??
      color ??
      theme.progressIndicatorTheme.color ??
      theme.colorScheme.primary;
}

/// 有 [valueColor] 动画时随动画重建（Material 原控件同样跟随它）。
Widget _followValueColor(Animation<Color?>? valueColor, WidgetBuilder builder) {
  if (valueColor == null) return Builder(builder: builder);
  return AnimatedBuilder(
    animation: valueColor,
    builder: (BuildContext context, _) => builder(context),
  );
}

/// [LinearProgressIndicator] 的设计系统分派版。
class FushiLinearProgressIndicator extends StatelessWidget {
  const FushiLinearProgressIndicator({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.valueColor,
    this.minHeight,
    this.semanticsLabel,
    this.semanticsValue,
    this.borderRadius,
    this.stopIndicatorColor,
    this.stopIndicatorRadius,
    this.trackGap,
    this.year2023,
    this.controller,
  });

  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final Animation<Color?>? valueColor;
  final double? minHeight;
  final String? semanticsLabel;
  final String? semanticsValue;
  final BorderRadiusGeometry? borderRadius;
  final Color? stopIndicatorColor;
  final double? stopIndicatorRadius;
  final double? trackGap;
  final bool? year2023;
  final AnimationController? controller;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      if (_useNativeMaterial(context, year2023, controller)) {
        return LinearProgressIndicator(
          value: value,
          backgroundColor: backgroundColor,
          color: color,
          valueColor: valueColor,
          minHeight: minHeight,
          semanticsLabel: semanticsLabel,
          semanticsValue: semanticsValue,
          borderRadius: borderRadius,
          stopIndicatorColor: stopIndicatorColor,
          stopIndicatorRadius: stopIndicatorRadius,
          trackGap: trackGap,
          year2023: year2023,
          controller: controller,
        );
      }
      return _followValueColor(valueColor, (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        final ProgressIndicatorThemeData it = theme.progressIndicatorTheme;
        return FushiWavyLinearProgress(
          value: value,
          color: _md3IndicatorColor(context, color, valueColor),
          trackColor:
              backgroundColor ??
              it.linearTrackColor ??
              theme.colorScheme.secondaryContainer,
          strokeWidth: minHeight ?? it.linearMinHeight ?? 4,
          trackGap: trackGap ?? it.trackGap ?? 4,
          stopIndicatorColor: stopIndicatorColor ?? it.stopIndicatorColor,
          stopIndicatorRadius: stopIndicatorRadius ?? it.stopIndicatorRadius,
          semanticsLabel: semanticsLabel,
          semanticsValue: semanticsValue,
        );
      });
    }
    return _followValueColor(valueColor, (BuildContext context) {
      return FushiAppleLinearProgress(
        value: value,
        height: minHeight,
        color: _appleIndicatorColor(context, color, valueColor),
        trackColor: backgroundColor ?? appleColorsOf(context).fill,
        semanticsLabel: semanticsLabel,
        semanticsValue: semanticsValue,
      );
    });
  }
}

/// Apple 线性进度条（**不是玻璃**）：全圆角细轨，撑满父级宽度（与 Material
/// 线性进度条一致）。
///
/// - 高度：[height] 给了就用；否则触屏 4、桌面 3（macOS 的细进度条）；
/// - 确定态：已填段强调色，值变化时 200ms 平滑过渡（iOS UIProgressView 的
///   setProgress(animated:)）；
/// - 不定态：一段 30% 宽的短条在轨道里左右往返（macOS 不定态进度条形态），
///   系统「减少动态效果」时改成静止的半透明满条。
class FushiAppleLinearProgress extends StatefulWidget {
  const FushiAppleLinearProgress({
    super.key,
    this.value,
    this.height,
    this.color,
    this.trackColor,
    this.semanticsLabel,
    this.semanticsValue,
  });

  final double? value;
  final double? height;
  final Color? color;
  final Color? trackColor;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  State<FushiAppleLinearProgress> createState() =>
      _FushiAppleLinearProgressState();
}

class _FushiAppleLinearProgressState extends State<FushiAppleLinearProgress>
    with SingleTickerProviderStateMixin {
  AnimationController? _sweep;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSweep();
  }

  @override
  void didUpdateWidget(FushiAppleLinearProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSweep();
  }

  /// 只在不定态且允许动画时跑往返动画；确定态不留常驻 ticker。
  void _syncSweep() {
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.value == null && !reduceMotion) {
      final AnimationController sweep = _sweep ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      );
      if (!sweep.isAnimating) sweep.repeat(reverse: true);
    } else {
      _sweep?.stop();
    }
  }

  @override
  void dispose() {
    _sweep?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double height = widget.height ?? (_appleDesktop(context) ? 3.0 : 4.0);
    final Color color = widget.color ?? apple.accent;
    final Color track = widget.trackColor ?? apple.fill;
    final BorderRadius radius = BorderRadius.circular(height / 2);
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final double? value = widget.value;
    final AnimationController? sweep = _sweep;

    final Widget bar;
    if (value != null) {
      bar = TweenAnimationBuilder<double>(
        tween: Tween<double>(end: value.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        builder: (BuildContext context, double v, Widget? _) {
          return Align(
            alignment: rtl ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: v,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, borderRadius: radius),
              ),
            ),
          );
        },
      );
    } else if (sweep == null || !sweep.isAnimating) {
      bar = DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: color.a * 0.5),
          borderRadius: radius,
        ),
      );
    } else {
      bar = AnimatedBuilder(
        animation: sweep,
        builder: (BuildContext context, Widget? _) {
          final double t = Curves.easeInOut.transform(sweep.value);
          return Align(
            alignment: Alignment(t * 2 - 1, 0),
            child: FractionallySizedBox(
              widthFactor: 0.3,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, borderRadius: radius),
              ),
            ),
          );
        },
      );
    }

    return Semantics(
      label: widget.semanticsLabel,
      value:
          widget.semanticsValue ??
          (value == null ? null : '${(value.clamp(0.0, 1.0) * 100).round()}%'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: double.infinity,
          minHeight: height,
          maxHeight: height,
        ),
        child: RepaintBoundary(
          child: ClipRRect(
            borderRadius: radius,
            child: DecoratedBox(
              decoration: BoxDecoration(color: track),
              child: bar,
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple 确定进度圆环（**不是玻璃**）：systemFill 底环 + 强调色圆头进度弧，
/// 从 12 点顺时针（RTL 逆时针），值变化平滑过渡。默认 [size] 36、
/// [strokeWidth] 3。
class FushiAppleProgressRing extends StatelessWidget {
  const FushiAppleProgressRing({
    super.key,
    required this.value,
    required this.color,
    required this.trackColor,
    this.strokeWidth = 3,
    this.size = 36,
    this.semanticsLabel,
    this.semanticsValue,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final double size;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    final double v = value.clamp(0.0, 1.0);
    final bool clockwise = Directionality.of(context) != TextDirection.rtl;
    return Semantics(
      label: semanticsLabel,
      value: semanticsValue ?? '${(v * 100).round()}%',
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: v),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          builder: (BuildContext context, double animated, Widget? _) {
            return CustomPaint(
              painter: _AppleProgressRingPainter(
                value: animated,
                color: color,
                trackColor: trackColor,
                strokeWidth: strokeWidth,
                clockwise: clockwise,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AppleProgressRingPainter extends CustomPainter {
  const _AppleProgressRingPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
    required this.clockwise,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final bool clockwise;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    // 外框被父级压小时线宽跟着收（不超过直径的 1/8）。
    final double stroke = math.min(strokeWidth, side / 8);
    final Rect rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: side / 2 - stroke / 2,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = trackColor,
    );
    if (value <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * value * (clockwise ? 1 : -1),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_AppleProgressRingPainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.clockwise != clockwise;
  }
}

/// Apple 不定态菊花：系统灰（secondaryLabel），半径取 iOS 的两档——常规 10
/// （外框 ≥ 28）、小号 8；外框比菊花还小（调用点常塞进 14~20 的紧 SizedBox）
/// 时整体等比缩小而不是被裁。
Widget fushiAppleActivityIndicator(
  BuildContext context, {
  double size = 36,
  Color? color,
  double? radius,
}) {
  return SizedBox.square(
    dimension: size,
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: CupertinoActivityIndicator(
          radius: radius ?? (size >= 28 ? 10 : 8),
          color: color ?? appleColorsOf(context).secondaryLabel,
        ),
      ),
    ),
  );
}

enum _CircularVariant { material, adaptive }

/// [CircularProgressIndicator] 的设计系统分派版（含 `.adaptive`）。
class FushiCircularProgressIndicator extends StatelessWidget {
  const FushiCircularProgressIndicator({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.valueColor,
    this.strokeWidth,
    this.strokeAlign,
    this.semanticsLabel,
    this.semanticsValue,
    this.strokeCap,
    this.constraints,
    this.trackGap,
    this.year2023,
    this.padding,
    this.controller,
  }) : _variant = _CircularVariant.material;

  const FushiCircularProgressIndicator.adaptive({
    super.key,
    this.value,
    this.backgroundColor,
    this.valueColor,
    this.strokeWidth,
    this.semanticsLabel,
    this.semanticsValue,
    this.strokeCap,
    this.strokeAlign,
    this.constraints,
    this.trackGap,
    this.year2023,
    this.padding,
    this.controller,
  }) : color = null,
       _variant = _CircularVariant.adaptive;

  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final Animation<Color?>? valueColor;
  final double? strokeWidth;
  final double? strokeAlign;
  final String? semanticsLabel;
  final String? semanticsValue;
  final StrokeCap? strokeCap;
  final BoxConstraints? constraints;
  final double? trackGap;
  final bool? year2023;
  final EdgeInsetsGeometry? padding;
  final AnimationController? controller;
  final _CircularVariant _variant;

  /// Apple 下的默认外框（Material 2023 版的 `_kMinCircularProgressIndicatorSize`）。
  static const double _kAppleDefaultSize = 36;

  /// MD3 2024 / Expressive 的默认外框 40、内边距 4（与原控件布局尺寸一致）。
  static const double _kMd3DefaultSize = 40;

  Widget _buildNative() {
    switch (_variant) {
      case _CircularVariant.material:
        return CircularProgressIndicator(
          value: value,
          backgroundColor: backgroundColor,
          color: color,
          valueColor: valueColor,
          strokeWidth: strokeWidth,
          strokeAlign: strokeAlign,
          semanticsLabel: semanticsLabel,
          semanticsValue: semanticsValue,
          strokeCap: strokeCap,
          constraints: constraints,
          trackGap: trackGap,
          year2023: year2023,
          padding: padding,
          controller: controller,
        );
      case _CircularVariant.adaptive:
        return CircularProgressIndicator.adaptive(
          value: value,
          backgroundColor: backgroundColor,
          valueColor: valueColor,
          strokeWidth: strokeWidth,
          semanticsLabel: semanticsLabel,
          semanticsValue: semanticsValue,
          strokeCap: strokeCap,
          strokeAlign: strokeAlign,
          constraints: constraints,
          trackGap: trackGap,
          year2023: year2023,
          padding: padding,
          controller: controller,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      final TargetPlatform platform = Theme.of(context).platform;
      final bool cupertinoAdaptive =
          _variant == _CircularVariant.adaptive &&
          (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS);
      if (cupertinoAdaptive ||
          _useNativeMaterial(context, year2023, controller)) {
        return _buildNative();
      }
      return _followValueColor(valueColor, (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        final ProgressIndicatorThemeData it = theme.progressIndicatorTheme;
        final BoxConstraints? box = constraints ?? it.constraints;
        return FushiWavyCircularProgress(
          value: value,
          size: box != null && box.minWidth > 0
              ? box.minWidth
              : _kMd3DefaultSize,
          padding:
              padding ?? it.circularTrackPadding ?? const EdgeInsets.all(4),
          strokeWidth: strokeWidth ?? it.strokeWidth ?? 4,
          trackGap: trackGap ?? it.trackGap ?? 4,
          color: _md3IndicatorColor(context, color, valueColor),
          trackColor:
              backgroundColor ??
              it.circularTrackColor ??
              theme.colorScheme.secondaryContainer,
          semanticsLabel: semanticsLabel,
          semanticsValue: semanticsValue,
        );
      });
    }
    return _followValueColor(valueColor, (BuildContext context) {
      final BoxConstraints? box = constraints;
      final double size = box != null && box.minWidth > 0
          ? box.minWidth
          : _kAppleDefaultSize;
      final double? v = value;
      Widget indicator;
      if (v == null) {
        // iOS / macOS 的不定态进度是菊花（UIActivityIndicatorView /
        // NSProgressIndicator spinning），不是转圈弧线。颜色：调用方显式给的
        // 照用，否则系统灰。
        indicator = fushiAppleActivityIndicator(
          context,
          size: size,
          color: valueColor?.value ?? color,
        );
        if (semanticsLabel != null) {
          indicator = Semantics(label: semanticsLabel, child: indicator);
        }
      } else {
        indicator = FushiAppleProgressRing(
          value: v,
          size: size,
          strokeWidth: strokeWidth ?? (size <= 24 ? 2 : 3),
          color: _appleIndicatorColor(context, color, valueColor),
          trackColor: backgroundColor ?? appleColorsOf(context).fill,
          semanticsLabel: semanticsLabel,
          semanticsValue: semanticsValue,
        );
      }
      final EdgeInsetsGeometry? p = padding;
      if (p != null) indicator = Padding(padding: p, child: indicator);
      return indicator;
    });
  }
}

/// [Tooltip] 的设计系统分派版。
///
/// 玻璃形态仍是 [Tooltip]（悬停 / 长按触发、定位、自动消失、无障碍提示全部
/// 照旧），只是气泡本体换成小号中性玻璃胶囊 [GlassContainer]（iOS 26 的
/// 浮层提示）：Tooltip 的 decoration 只能是
/// [Decoration]（画不了着色器玻璃），所以把它置空透明，再把消息包进
/// `WidgetSpan(GlassContainer(...))` 作为 richMessage。语义改由外层
/// `Semantics(tooltip:)` 提供（WidgetSpan 的纯文本是占位符，不能直接读）。
class FushiTooltip extends StatelessWidget {
  const FushiTooltip({
    super.key,
    this.message,
    this.richMessage,
    this.height,
    this.constraints,
    this.padding,
    this.margin,
    this.verticalOffset,
    this.preferBelow,
    this.excludeFromSemantics,
    this.decoration,
    this.textStyle,
    this.textAlign,
    this.waitDuration,
    this.showDuration,
    this.exitDuration,
    this.enableTapToDismiss = true,
    this.triggerMode,
    this.enableFeedback,
    this.onTriggered,
    this.mouseCursor,
    this.ignorePointer,
    this.positionDelegate,
    this.child,
  });

  final String? message;
  final InlineSpan? richMessage;
  final double? height;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? verticalOffset;
  final bool? preferBelow;
  final bool? excludeFromSemantics;
  final Decoration? decoration;
  final TextStyle? textStyle;
  final TextAlign? textAlign;
  final Duration? waitDuration;
  final Duration? showDuration;
  final Duration? exitDuration;
  final bool enableTapToDismiss;
  final TooltipTriggerMode? triggerMode;
  final bool? enableFeedback;
  final TooltipTriggeredCallback? onTriggered;
  final MouseCursor? mouseCursor;
  final bool? ignorePointer;
  final TooltipPositionDelegate? positionDelegate;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return Tooltip(
        message: message,
        richMessage: richMessage,
        height: height,
        constraints: constraints,
        padding: padding,
        margin: margin,
        verticalOffset: verticalOffset,
        preferBelow: preferBelow,
        excludeFromSemantics: excludeFromSemantics,
        decoration: decoration,
        textStyle: textStyle,
        textAlign: textAlign,
        waitDuration: waitDuration,
        showDuration: showDuration,
        exitDuration: exitDuration,
        enableTapToDismiss: enableTapToDismiss,
        triggerMode: triggerMode,
        enableFeedback: enableFeedback,
        onTriggered: onTriggered,
        mouseCursor: mouseCursor,
        ignorePointer: ignorePointer,
        positionDelegate: positionDelegate,
        child: child,
      );
    }

    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final TooltipThemeData tooltipTheme = TooltipTheme.of(context);
    final TextStyle bubbleStyle =
        (theme.textTheme.labelMedium ?? const TextStyle())
            .copyWith(
              color: apple.label,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            )
            .merge(textStyle);
    final TextAlign align =
        textAlign ?? tooltipTheme.textAlign ?? TextAlign.start;
    final InlineSpan content = richMessage ?? TextSpan(text: message ?? '');
    final String plain = message ?? richMessage?.toPlainText() ?? '';

    // 单行时是全胶囊（圆角 = 半高 15），多行退成圆角 15 的玻璃块。
    final Widget bubble = GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 15),
      quality: fushiGlassQuality(context),
      settings: fushiGlassSettings(context),
      padding:
          padding ??
          tooltipTheme.padding ??
          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text.rich(content, style: bubbleStyle, textAlign: align),
    );

    Widget result = Tooltip(
      richMessage: WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: bubble,
      ),
      height: height,
      constraints: constraints,
      padding: EdgeInsets.zero,
      margin: margin,
      verticalOffset: verticalOffset,
      preferBelow: preferBelow,
      excludeFromSemantics: true,
      decoration: const BoxDecoration(),
      textAlign: align,
      waitDuration: waitDuration,
      showDuration: showDuration,
      exitDuration: exitDuration,
      enableTapToDismiss: enableTapToDismiss,
      triggerMode: triggerMode,
      enableFeedback: enableFeedback,
      onTriggered: onTriggered,
      mouseCursor: mouseCursor,
      ignorePointer: ignorePointer,
      positionDelegate: positionDelegate,
      child: child,
    );
    final bool exclude =
        excludeFromSemantics ?? tooltipTheme.excludeFromSemantics ?? false;
    if (!exclude && plain.isNotEmpty) {
      result = Semantics(tooltip: plain, child: result);
    }
    return result;
  }
}

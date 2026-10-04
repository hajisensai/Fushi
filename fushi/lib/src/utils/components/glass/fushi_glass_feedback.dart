import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 反馈族（进度条 / 转圈 / tooltip）的「设计系统分派」包装：构造参数与
// Material 原控件逐个同名同型，调用点只改类名。MD3 下原样构造原控件；
// 「玻璃」设计系统下按 iOS 26：进度条是 [GlassProgressIndicator] 细轨（已填段
// 强调色、轨道 systemFill），不定态圆形进度是 iOS 的菊花
// [CupertinoActivityIndicator]；tooltip 保留 [Tooltip] 的触发 / 定位 / 无障碍
// 行为，只把气泡换成小号中性玻璃胶囊 [GlassContainer]。

Color _indicatorColor(
  BuildContext context,
  Color? color,
  Animation<Color?>? valueColor,
) {
  final ThemeData theme = Theme.of(context);
  return valueColor?.value ??
      color ??
      theme.progressIndicatorTheme.color ??
      appleColorsOf(context).accent;
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
      final ProgressIndicatorThemeData indicatorTheme =
          theme.progressIndicatorTheme;
      return GlassProgressIndicator.linear(
        value: value,
        // Material 的线性进度条撑满父级宽度（minWidth: infinity），玻璃同样。
        minWidth: double.infinity,
        height: minHeight ?? indicatorTheme.linearMinHeight ?? 4,
        color: _indicatorColor(context, color, valueColor),
        backgroundColor:
            backgroundColor ??
            indicatorTheme.linearTrackColor ??
            appleColorsOf(context).fill,
        quality: fushiGlassQuality(context),
        semanticLabel: semanticsLabel,
      );
    });
  }
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

  /// Material 圆形进度条的默认最小尺寸（`_kMinCircularProgressIndicatorSize`）。
  static const double _kDefaultSize = 36;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
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
    return _followValueColor(valueColor, (BuildContext context) {
      final ThemeData theme = Theme.of(context);
      final ProgressIndicatorThemeData indicatorTheme =
          theme.progressIndicatorTheme;
      final BoxConstraints? box = constraints ?? indicatorTheme.constraints;
      final double size = box != null && box.minWidth > 0
          ? box.minWidth
          : _kDefaultSize;
      final EdgeInsetsGeometry? effectivePadding =
          padding ?? indicatorTheme.circularTrackPadding;
      if (value == null) {
        // iOS 的不定态进度是菊花（UIActivityIndicatorView），不是转圈弧线。
        // 颜色：调用方显式给的照用，否则 secondaryLabel 灰（系统默认）。
        final Color? explicit =
            valueColor?.value ?? color ?? indicatorTheme.color;
        Widget spinner = SizedBox.square(
          dimension: size,
          child: Center(
            child: CupertinoActivityIndicator(
              radius: (size * 0.32).clamp(7.0, 20.0),
              color: explicit ?? appleColorsOf(context).secondaryLabel,
            ),
          ),
        );
        if (semanticsLabel != null) {
          spinner = Semantics(label: semanticsLabel, child: spinner);
        }
        if (effectivePadding != null) {
          spinner = Padding(padding: effectivePadding, child: spinner);
        }
        return spinner;
      }
      Widget indicator = GlassProgressIndicator.circular(
        value: value,
        size: size,
        strokeWidth: strokeWidth ?? indicatorTheme.strokeWidth ?? 4,
        color: _indicatorColor(context, color, valueColor),
        // 确定态轨道用 systemFill 中性灰，不用库默认的 15% 白（浅色上看不见）。
        backgroundColor:
            backgroundColor ??
            indicatorTheme.circularTrackColor ??
            appleColorsOf(context).fill,
        quality: fushiGlassQuality(context),
        semanticLabel: semanticsLabel,
      );
      if (effectivePadding != null) {
        indicator = Padding(padding: effectivePadding, child: indicator);
      }
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

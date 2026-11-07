import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:marquee/marquee.dart';

/// Wrapper for a Marquee that only displays the Marquee effect only when there
/// is insufficient space, and not all the time. Taken directly from:
/// https://gist.github.com/rtybanana/2b0639052cd5bfd701b8d892f2d1088b
/// https://github.com/MarcelGarus/marquee/issues/36
class FushiMarquee extends StatelessWidget {
  /// Create a Marquee that handles the overflow effect.
  const FushiMarquee({
    required this.text,
    this.style,
    this.textScaleFactor,
    this.textDirection = TextDirection.ltr,
    this.scrollAxis = Axis.horizontal,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.blankSpace = 20.0,
    this.velocity = 30.0,
    this.startAfter = Duration.zero,
    this.pauseAfterRound = Duration.zero,
    this.showFadingOnlyWhenScrolling = true,
    this.fadingEdgeStartFraction = 0.0,
    this.fadingEdgeEndFraction = 0.0,
    this.numberOfRounds,
    this.startPadding = 0.0,
    this.accelerationDuration = Duration.zero,
    this.accelerationCurve = Curves.decelerate,
    this.decelerationDuration = Duration.zero,
    this.decelerationCurve = Curves.decelerate,
    this.onDone,
    super.key,
  });

  /// The text to be displayed.
  ///
  /// See also:
  ///
  /// * [style] to style the text.
  final String text;

  /// The style of the text to be displayed.
  ///
  /// ## Sample code
  ///
  /// This marquee has a bold text:
  ///
  /// ```dart
  /// Marquee(
  ///   text: 'This is some bold text.',
  ///   style: TextStyle(weight: FontWeight.bold)
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [text] to provide the text itself.
  final TextStyle? style;

  /// The font scale of the text to be displayed.
  ///
  /// ## Sample code
  ///
  /// This marquee has a fixed text scale factor, indipendent to the user selected resolution:
  ///
  /// ```dart
  /// Marquee(
  ///   text: 'This is some bold text.',
  ///   textScaleFactor: 1
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [text] to provide the text itself.
  final double? textScaleFactor;

  /// The text direction of the text to be displayed.
  ///
  /// ## Sample code
  ///
  /// This marquee has a RTL (Right-to-Left) text:
  ///
  /// ```dart
  /// Marquee(
  ///   text: 'טקסט בעברית',
  ///   textDirection: TextDirection.rtl
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [text] to provide the text itself.
  final TextDirection textDirection;

  /// The scroll axis.
  ///
  /// If set to [Axis.horizontal], the default scrolling direction is to the
  /// right.
  /// If set to [Axis.vertical], the default scrolling direction is to the
  /// bottom.
  ///
  /// ## Sample code
  ///
  /// This marquee scrolls vertically:
  ///
  /// ```dart
  /// Marquee(
  ///   scrollAxis: Axis.vertical,
  ///   text: "Look what's below this:",
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * The sign of [velocity] to define the concrete scroll direction on this
  ///   axis.
  final Axis scrollAxis;

  /// The alignment along the cross axis.
  ///
  /// # Sample code
  ///
  /// ```-dart
  /// Marquee(
  ///   crossAxisAlignment: CrossAxisAlignment.start,
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [scrollAxis] for setting the primary axis.
  final CrossAxisAlignment crossAxisAlignment;

  /// The extend of blank space to display between instances of the text.
  ///
  /// ## Sample code
  ///
  /// In this example, there's 300 density pixels between the text instances:
  ///
  /// ```dart
  /// Marquee(
  ///   blankSpace: 300.0,
  ///   child: 'Wait for it...',
  /// )
  /// ```
  final double blankSpace;

  /// The scrolling velocity in pixels per second.
  ///
  /// If a negative velocity is provided, the marquee scrolls in the reverse
  /// direction (to the right for horizontal marquees and to the top for
  /// vertical ones).
  ///
  /// ## Sample code
  ///
  /// This marquee scrolls backwards with 1000 pixels per second:
  ///
  /// ```dart
  /// Marquee(
  ///   velocity: -1000.0,
  ///   text: 'Gotta go fast in the reverse direction',
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [scrollAxis] to change the axis in which the scrolling takes place.
  final double velocity;

  /// Start scrolling after this duration after the widget is first displayed.
  ///
  /// ## Sample code
  ///
  /// This [Marquee] starts scrolling one second after being displayed.
  ///
  /// ```dart
  /// Marquee(
  ///   startAfter: const Duration(seconds: 1),
  ///   text: 'Starts one second after being displayed.',
  /// )
  /// ```
  final Duration startAfter;

  /// After each round, a pause of this duration occurs.
  ///
  /// ## Sample code
  ///
  /// After every round, this marquee pauses for one second.
  ///
  /// ```dart
  /// Marquee(
  ///   pauseAfterRound: const Duration(seconds: 1),
  ///   text: 'Pausing for some time after every round.',
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [accelerationDuration] and [decelerationDuration] to make the
  ///   transitions between moving and paused state smooth.
  /// * [accelerationCurve] and [decelerationCurve] to have more control about
  ///   how the transition between moving and pausing state occur.
  final Duration pauseAfterRound;

  /// When the text scrolled around [numberOfRounds] times, it will stop scrolling
  /// `null` indicates there is no limit
  ///
  /// ## Sample code
  ///
  /// This marquee stops after 3 rounds
  ///
  /// ```dart
  /// Marquee(
  ///   numberOfRounds:3,
  ///   text: 'Stopping after three rounds.'
  /// )
  /// ```
  final int? numberOfRounds;

  /// Whether the fading edge should only appear while the text is
  /// scrolling.
  ///
  /// ## Sample code
  ///
  /// This marquee will only show the fade while scrolling.
  ///
  /// ```dart
  /// Marquee(
  ///   showFadingOnlyWhenScrolling: true,
  ///   fadingEdgeStartFraction: 0.1,
  ///   fadingEdgeEndFraction: 0.1,
  ///   text: 'Example text.',
  /// )
  /// ```
  final bool showFadingOnlyWhenScrolling;

  /// The fraction of the [Marquee] that will be faded on the left or top.
  /// By default, there won't be any fading.
  ///
  /// ## Sample code
  ///
  /// This marquee fades the edges while scrolling
  ///
  /// ```dart
  /// Marquee(
  ///   showFadingOnlyWhenScrolling: true,
  ///   fadingEdgeStartFraction: 0.1,
  ///   fadingEdgeEndFraction: 0.1,
  ///   text: 'Example text.',
  /// )
  /// ```
  final double fadingEdgeStartFraction;

  /// The fraction of the [Marquee] that will be faded on the right or down.
  /// By default, there won't be any fading.
  ///
  /// ## Sample code
  ///
  /// This marquee fades the edges while scrolling
  ///
  /// ```dart
  /// Marquee(
  ///   showFadingOnlyWhenScrolling: true,
  ///   fadingEdgeStartFraction: 0.1,
  ///   fadingEdgeEndFraction: 0.1,
  ///   text: 'Example text.',
  /// )
  /// ```
  final double fadingEdgeEndFraction;

  /// A padding for the resting position.
  ///
  /// In between rounds, the marquee stops at this position. This parameter is
  /// especially useful if the marquee pauses after rounds and some other
  /// widgets are stacked on top of the marquee and block the sides, like
  /// fading gradients.
  ///
  /// ## Sample code
  ///
  /// ```dart
  /// Marquee(
  ///   startPadding: 20.0,
  ///   pauseAfterRound: Duration(seconds: 1),
  ///   text: "During pausing, this text is shifted 20 pixel to the right."
  /// )
  /// ```
  final double startPadding;

  /// How long the acceleration takes.
  ///
  /// At the start of each round, the scrolling speed gains momentum for this
  /// duration. This parameter is only useful if you embrace a pause after
  /// every round.
  ///
  /// ## Sample code
  ///
  /// A marquee that slowly accelerates in two seconds.
  ///
  /// ```dart
  /// Marquee(
  ///   accelerationDuration: Duration(seconds: 2),
  ///   text: 'Gaining momentum in two seconds.'
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [accelerationCurve] to define a custom curve for accelerating.
  /// * [decelerationDuration], the equivalent for decelerating.
  final Duration accelerationDuration;

  /// The acceleration at the start of each round.
  ///
  /// At the start of each round, the acceleration is defined by this curve
  /// where 0.0 stands for not moving and 1.0 for the target [velocity].
  /// Notice that it's useless to set the curve if you leave the
  /// [accelerationDuration] at the default of [Duration.zero].
  /// Also notice that you don't provide the scroll positions, but the actual
  /// velocity, so this curve gets integrated.
  ///
  /// ## Sample code
  ///
  /// A marquee that accelerates with a custom curve.
  ///
  /// ```dart
  /// Marquee(
  ///   accelerationDuration: Duration(seconds: 1),
  ///   accelerationCurve: Curves.easeInOut,
  ///   text: 'Accelerating with a custom curve.'
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [accelerationDuration] to change the duration of the acceleration.
  /// * [decelerationCurve], the equivalent for decelerating.
  final Curve accelerationCurve;

  /// How long the deceleration takes.
  ///
  /// At the end of each round, the scrolling speed gradually comes to a
  /// halt in this duration. This parameter is only useful if you embrace a
  /// pause after every round.
  ///
  /// ## Sample code
  ///
  /// A marquee that gradually comes to a halt in two seconds.
  ///
  /// ```dart
  /// Marquee(
  ///   decelerationDuration: Duration(seconds: 2),
  ///   text: 'Gradually coming to a halt in two seconds.'
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [decelerationCurve] to define a custom curve for accelerating.
  /// * [accelerationDuration], the equivalent for decelerating.
  final Duration decelerationDuration;

  /// The deceleration at the end of each round.
  ///
  /// At the end of each round, the deceleration is defined by this curve where
  /// 0.0 stands for not moving and 1.0 for the target [velocity].
  /// Notice that it's useless to set this curve if you leave the
  /// [accelerationDuration] at the default of [Duration.zero].
  /// Also notice that you don't provide the scroll position, but the actual
  /// velocity, so this curve gets integrated.
  ///
  /// ## Sample code
  ///
  /// A marquee that decelerates with a custom curve.
  ///
  /// ```dart
  /// Marquee(
  ///   decelerationDuration: Duration(seconds: 1),
  ///   decelerationCurve: Curves.easeInOut,
  ///   text: 'Decelerating with a custom curve.'
  /// )
  /// ```
  ///
  /// See also:
  ///
  /// * [decelerationDuration] to change the duration of the acceleration.
  /// * [accelerationCurve], the equivalent for decelerating.
  final Curve decelerationCurve;

  /// This function will be called if [numberOfRounds] is set and the [Marquee]
  /// finished scrolled the specified number of rounds.
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    // 量字与真正画字的 Text 用同一套样式 / 缩放：列表行的标题样式来自祖先
    // DefaultTextStyle（FushiListItem 的 listTitle），只拿 [style] 量会按 14px 默认字
    // 判溢出、给滚动版定错行高（BUG-4237）。
    final TextStyle effectiveStyle = DefaultTextStyle.of(
      context,
    ).style.merge(style);
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: effectiveStyle),
      textDirection: textDirection,
      textScaler: textScaleFactor == null
          ? MediaQuery.textScalerOf(context)
          : TextScaler.linear(textScaleFactor!),
      maxLines: 1,
    )..layout();
    final Size natural = Size(painter.width, painter.height);
    final double alphabetic = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final double ideographic = painter.computeDistanceToActualBaseline(
      TextBaseline.ideographic,
    );
    painter.dispose();
    return _MarqueeIntrinsics(
      natural: natural,
      alphabeticBaseline: alphabetic,
      ideographicBaseline: ideographic,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (natural.width > constraints.maxWidth) {
            return SizedBox(
              height: natural.height,
              width: constraints.maxWidth,
              child: Marquee(
                text: text,
                style: style,
                textScaleFactor: textScaleFactor,
                textDirection: textDirection,
                scrollAxis: scrollAxis,
                crossAxisAlignment: crossAxisAlignment,
                blankSpace: blankSpace,
                velocity: velocity,
                startAfter: startAfter,
                pauseAfterRound: pauseAfterRound,
                numberOfRounds: numberOfRounds,
                showFadingOnlyWhenScrolling: showFadingOnlyWhenScrolling,
                fadingEdgeStartFraction: fadingEdgeStartFraction,
                fadingEdgeEndFraction: fadingEdgeEndFraction,
                startPadding: startPadding,
                accelerationDuration: accelerationDuration,
                accelerationCurve: accelerationCurve,
                decelerationDuration: decelerationDuration,
                decelerationCurve: decelerationCurve,
                onDone: onDone,
              ),
            );
          }
          return SizedBox(
            // 无界宽（不在列表行 / 对话框里时）按文字自然宽，别撑成无限宽。
            width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
            child: Align(
              // Remember for RTL
              alignment: Alignment.centerLeft,
              // 恒为一行高（与滚动版、intrinsic 高一致），不在有界高里撑满。
              heightFactor: 1,
              child: Text(text, style: style, textAlign: TextAlign.left),
            ),
          );
        },
      ),
    );
  }
}

/// 替 [FushiMarquee] 里的 LayoutBuilder 回答 intrinsic 尺寸与 dry layout（BUG-4237）。
///
/// AlertDialog / Apple 表单式对话框把正文包在 `IntrinsicWidth` 里量宽；往下问到
/// LayoutBuilder 时 debug 抛「LayoutBuilder does not support returning intrinsic
/// dimensions」、对话框面板没有尺寸，命中测试再抛「Cannot hit test a render box with
/// no size」，只剩遮罩挡住页面；release 跳过断言答 0，跑马灯行被量成 0 宽。
/// 这里按文字自然尺寸回答：最大宽 = 一行放下全文的宽，最小宽 0（放不下就滚动，
/// 任何宽都能显示），高恒为一行。布局 / 绘制 / 命中原样交给子树。
class _MarqueeIntrinsics extends SingleChildRenderObjectWidget {
  const _MarqueeIntrinsics({
    required this.natural,
    required this.alphabeticBaseline,
    required this.ideographicBaseline,
    required super.child,
  });

  final Size natural;
  final double alphabeticBaseline;
  final double ideographicBaseline;

  @override
  _RenderMarqueeIntrinsics createRenderObject(BuildContext context) =>
      _RenderMarqueeIntrinsics(
        natural: natural,
        alphabeticBaseline: alphabeticBaseline,
        ideographicBaseline: ideographicBaseline,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMarqueeIntrinsics renderObject,
  ) {
    renderObject
      ..natural = natural
      ..alphabeticBaseline = alphabeticBaseline
      ..ideographicBaseline = ideographicBaseline;
  }
}

class _RenderMarqueeIntrinsics extends RenderProxyBox {
  _RenderMarqueeIntrinsics({
    required Size natural,
    required double alphabeticBaseline,
    required double ideographicBaseline,
  }) : _natural = natural,
       _alphabeticBaseline = alphabeticBaseline,
       _ideographicBaseline = ideographicBaseline;

  Size _natural;
  set natural(Size value) {
    if (value == _natural) return;
    _natural = value;
    markNeedsLayout();
  }

  double _alphabeticBaseline;
  set alphabeticBaseline(double value) {
    if (value == _alphabeticBaseline) return;
    _alphabeticBaseline = value;
    markNeedsLayout();
  }

  double _ideographicBaseline;
  set ideographicBaseline(double value) {
    if (value == _ideographicBaseline) return;
    _ideographicBaseline = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => _natural.width;

  @override
  double computeMinIntrinsicHeight(double width) => _natural.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _natural.height;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.constrain(
        Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : _natural.width,
          _natural.height,
        ),
      );

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) => switch (baseline) {
    TextBaseline.alphabetic => _alphabeticBaseline,
    TextBaseline.ideographic => _ideographicBaseline,
  };
}

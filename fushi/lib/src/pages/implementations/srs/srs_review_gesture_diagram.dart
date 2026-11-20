/// 复习页卡面手势的可视化：一张示意卡片 + 每个手势的手势图（[SrsGestureGlyph]）+ 当前
/// 绑定的动作，比逐行文字一眼看懂「哪里点 / 往哪滑 = 做什么」。
///
/// 只消费 [SrsReviewGestureMap]（与复习页同一份映射与 [SrsReviewGestureMap.resolve]
/// 判据），不另存状态。设置页每面一张；改映射时对应位置的动作淡入淡出切换。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';

/// 手势的界面名。
String srsReviewGestureLabel(SrsReviewGesture g) => switch (g) {
  SrsReviewGesture.tapLeft => t.srs_review_gestures_tap_left,
  SrsReviewGesture.tapCenter => t.srs_review_gestures_tap_center,
  SrsReviewGesture.tapRight => t.srs_review_gestures_tap_right,
  SrsReviewGesture.doubleTap => t.srs_review_gestures_double_tap,
  SrsReviewGesture.longPress => t.srs_review_gestures_long_press,
  SrsReviewGesture.swipeLeft => t.srs_review_gestures_swipe_left,
  SrsReviewGesture.swipeRight => t.srs_review_gestures_swipe_right,
  SrsReviewGesture.swipeUp => t.srs_review_gestures_swipe_up,
  SrsReviewGesture.swipeDown => t.srs_review_gestures_swipe_down,
};

/// 动作的界面名：与复习页上对应按钮同一个词。
String srsReviewGestureActionLabel(SrsReviewGestureAction a) => switch (a) {
  SrsReviewGestureAction.none => t.srs_review_gestures_action_none,
  SrsReviewGestureAction.showAnswer => t.srs_review_show_answer,
  SrsReviewGestureAction.rateAgain => t.srs_rating_again,
  SrsReviewGestureAction.rateHard => t.srs_rating_hard,
  SrsReviewGestureAction.rateGood => t.srs_rating_good,
  SrsReviewGestureAction.rateEasy => t.srs_rating_easy,
  SrsReviewGestureAction.undo => t.undo,
  SrsReviewGestureAction.replayAudio => t.srs_review_replay_audio,
  SrsReviewGestureAction.toggleToolbar =>
    t.srs_review_gestures_action_toggle_toolbar,
  SrsReviewGestureAction.editNote => t.srs_note_edit,
  SrsReviewGestureAction.bury => t.srs_card_bury,
  SrsReviewGestureAction.suspend => t.srs_card_suspend,
  SrsReviewGestureAction.flag => t.srs_card_flag,
};

/// 动作的图标（与复习页上对应按钮同一个）；评分没有图标，按评分色调显示。
IconData? srsReviewGestureActionIcon(SrsReviewGestureAction a) => switch (a) {
  SrsReviewGestureAction.none => null,
  SrsReviewGestureAction.showAnswer => FushiIcons.visibility,
  SrsReviewGestureAction.rateAgain ||
  SrsReviewGestureAction.rateHard ||
  SrsReviewGestureAction.rateGood ||
  SrsReviewGestureAction.rateEasy => null,
  SrsReviewGestureAction.undo => FushiIcons.undo,
  SrsReviewGestureAction.replayAudio => FushiIcons.replay,
  SrsReviewGestureAction.toggleToolbar => FushiIcons.dashboardCustomize,
  SrsReviewGestureAction.editNote => FushiIcons.edit,
  SrsReviewGestureAction.bury => FushiIcons.schedule,
  SrsReviewGestureAction.suspend => FushiIcons.pause,
  SrsReviewGestureAction.flag => FushiIcons.flag,
};

/// 动作在示意图上的配色：评分用评分按钮同一套色调（与复习页滑动提示一致），其余用
/// secondaryContainer；没绑动作时用低对比的 surfaceContainerHighest。
({Color background, Color foreground}) srsGestureActionColors(
  BuildContext context,
  SrsReviewGestureAction action,
) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final int? rating = action.rating;
  if (rating != null) {
    return srsRatingColors(
      SrsRatingTone.values[rating - 1],
      cs,
      apple: isGlassDesign(context),
    );
  }
  if (action == SrsReviewGestureAction.none) {
    return (
      background: cs.surfaceContainerHighest,
      foreground: cs.onSurfaceVariant,
    );
  }
  return (
    background: cs.secondaryContainer,
    foreground: cs.onSecondaryContainer,
  );
}

/// 一个手势的示意图：小卡片轮廓上画手指落点与轨迹。
///
/// - 点左 / 中 / 右：对应三分之一高亮 + 落点；
/// - 双击：落点外两圈涟漪；长按：落点外一圈「按住」进度弧；
/// - 滑动：从起点到终点的轨迹与箭头。[animate] 为 true 时出现后演示两遍（落点沿轨迹
///   移动 / 涟漪扩散 / 按住弧走满）再停在终态；墨水屏与「减弱动态效果」下直接画终态
///   （[fushiMotionEnabled]）。改绑动作时上层换 key 重新演示。
class SrsGestureGlyph extends StatefulWidget {
  const SrsGestureGlyph({
    super.key,
    required this.gesture,
    required this.color,
    this.size = 28,
    this.animate = false,
  });

  final SrsReviewGesture gesture;
  final Color color;
  final double size;
  final bool animate;

  @override
  State<SrsGestureGlyph> createState() => _SrsGestureGlyphState();
}

class _SrsGestureGlyphState extends State<SrsGestureGlyph>
    with SingleTickerProviderStateMixin {
  /// 演示两遍（每遍一个 [FushiMotion.ambientBreath]）后停在终态：不常驻 ticker，
  /// 页面能 settle，也不一直在眼角晃。
  static const int _demoRounds = 2;

  late final AnimationController _demo = AnimationController(
    vsync: this,
    duration: FushiMotion.ambientBreath * _demoRounds,
    value: 1,
  );

  bool _played = false;

  void _maybePlay() {
    if (!widget.animate || !fushiMotionEnabled(context)) {
      _played = false;
      if (_demo.isAnimating) _demo.value = 1;
      return;
    }
    if (_played) return;
    _played = true;
    _demo.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybePlay();
  }

  @override
  void didUpdateWidget(SrsGestureGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gesture != widget.gesture) _played = false;
    _maybePlay();
  }

  @override
  void dispose() {
    _demo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _SrsGestureGlyphPainter(
          gesture: widget.gesture,
          color: widget.color,
          demo: _demo,
          rounds: _demoRounds,
        ),
      ),
    ),
  );
}

class _SrsGestureGlyphPainter extends CustomPainter {
  _SrsGestureGlyphPainter({
    required this.gesture,
    required this.color,
    required this.demo,
    required this.rounds,
  }) : super(repaint: demo);

  final SrsReviewGesture gesture;
  final Color color;
  final Animation<double> demo;
  final int rounds;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Offset c = size.center(Offset.zero);
    final Rect card = Rect.fromCenter(
      center: c,
      width: s * 0.66,
      height: s * 0.9,
    );
    final RRect cardShape = RRect.fromRectAndRadius(
      card,
      Radius.circular(s * 0.12),
    );
    final double stroke = math.max(1, s * 0.055);
    final Paint outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.45);
    final Paint fill = Paint()..color = color;
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final double dot = s * 0.1;
    // 演示中：本遍的相位 0..1；不在演示（播完 / 没开动效）为 null，画静态终态。
    final double? progress = demo.isAnimating
        ? (demo.value * rounds) % 1
        : null;
    final double t = progress ?? 1;

    canvas.drawRRect(cardShape, outline);

    void ripple(Offset at, double fraction) {
      final double r = dot + s * 0.2 * fraction;
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = color.withValues(alpha: (1 - fraction) * 0.8 + 0.1),
      );
    }

    if (gesture.isTap) {
      final int zone = switch (gesture) {
        SrsReviewGesture.tapLeft => 0,
        SrsReviewGesture.tapRight => 2,
        _ => 1,
      };
      final double w = card.width / 3;
      final Rect third = Rect.fromLTWH(
        card.left + w * zone,
        card.top,
        w,
        card.height,
      );
      canvas.save();
      canvas.clipRRect(cardShape);
      canvas.drawRect(third, Paint()..color = color.withValues(alpha: 0.22));
      canvas.restore();
      final Offset at = third.center;
      canvas.drawCircle(at, dot, fill);
      ripple(at, progress == null ? 0.6 : t);
      return;
    }

    switch (gesture) {
      case SrsReviewGesture.doubleTap:
        canvas.drawCircle(c, dot, fill);
        // 两圈错开半个周期的涟漪 = 「点两下」。
        ripple(c, progress == null ? 0.35 : t);
        ripple(c, progress == null ? 0.85 : (t + 0.5) % 1);
      case SrsReviewGesture.longPress:
        canvas.drawCircle(c, dot, fill);
        final double r = dot + s * 0.14;
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..color = color.withValues(alpha: 0.25),
        );
        // 「按住」进度弧：从 12 点顺时针走满。
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          -math.pi / 2,
          2 * math.pi * (progress == null ? 0.75 : t),
          false,
          line,
        );
      case SrsReviewGesture.swipeLeft:
      case SrsReviewGesture.swipeRight:
      case SrsReviewGesture.swipeUp:
      case SrsReviewGesture.swipeDown:
        final Offset dir = switch (gesture) {
          SrsReviewGesture.swipeLeft => const Offset(-1, 0),
          SrsReviewGesture.swipeRight => const Offset(1, 0),
          SrsReviewGesture.swipeUp => const Offset(0, -1),
          _ => const Offset(0, 1),
        };
        final double half = (dir.dx != 0 ? card.width : card.height) * 0.32;
        final Offset from = c - dir * half;
        final Offset to = c + dir * half;
        // 轨迹先走、落点跟着；静止时落点停在终点。
        final double eased = FushiMotion.standard.transform(t.clamp(0.0, 1.0));
        final Offset head = Offset.lerp(from, to, eased)!;
        canvas.drawLine(from, head, line);
        final Offset normal = Offset(-dir.dy, dir.dx);
        final double a = s * 0.13;
        final Path arrow = Path()
          ..moveTo(
            to.dx - dir.dx * a + normal.dx * a,
            to.dy - dir.dy * a + normal.dy * a,
          )
          ..lineTo(to.dx, to.dy)
          ..lineTo(
            to.dx - dir.dx * a - normal.dx * a,
            to.dy - dir.dy * a - normal.dy * a,
          );
        canvas.drawPath(arrow, line);
        canvas.drawCircle(head, dot, fill);
      case SrsReviewGesture.tapLeft:
      case SrsReviewGesture.tapCenter:
      case SrsReviewGesture.tapRight:
        break;
    }
  }

  @override
  bool shouldRepaint(_SrsGestureGlyphPainter oldDelegate) =>
      oldDelegate.gesture != gesture ||
      oldDelegate.color != color ||
      oldDelegate.demo != demo;
}

/// 一面的手势示意图：中间一张卡（三等分点按区），四边是四向滑动，底下是双击 / 长按。
/// 每处标出当前实际生效的动作（[SrsReviewGestureMap.resolve]，「只留重来 / 良好」屏蔽的
/// 评分显示为不生效）。
class SrsReviewGestureDiagram extends StatelessWidget {
  const SrsReviewGestureDiagram({
    super.key,
    required this.map,
    required this.side,
    required this.hideHardEasy,
  });

  final SrsReviewGestureMap map;
  final SrsReviewSide side;
  final bool hideHardEasy;

  /// 示意图最宽这么多：再宽卡片比例就失真了。
  static const double maxWidth = 420;

  SrsReviewGestureAction _action(SrsReviewGesture g) =>
      map.resolve(side, g, hideHardEasy: hideHardEasy);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    Widget swipe(SrsReviewGesture g, {required bool vertical}) =>
        _GestureCallout(
          key: ValueKey<String>('srs-gesture-diagram-${side.name}-${g.wire}'),
          gesture: g,
          action: _action(g),
          vertical: vertical,
        );

    final Widget card = _DiagramCard(
      side: side,
      actions: <SrsReviewGesture, SrsReviewGestureAction>{
        for (final SrsReviewGesture g in <SrsReviewGesture>[
          SrsReviewGesture.tapLeft,
          SrsReviewGesture.tapCenter,
          SrsReviewGesture.tapRight,
        ])
          g: _action(g),
      },
    );

    final List<SrsReviewGesture> extras = <SrsReviewGesture>[
      SrsReviewGesture.doubleTap,
      SrsReviewGesture.longPress,
    ];

    return Semantics(
      container: true,
      label: <String>[
        for (final SrsReviewGesture g in SrsReviewGesture.values)
          if (_action(g) != SrsReviewGestureAction.none)
            '${srsReviewGestureLabel(g)}: '
                '${srsReviewGestureActionLabel(_action(g))}',
      ].join('; '),
      child: ExcludeSemantics(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: Padding(
              padding: EdgeInsets.all(gap),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: gap,
                children: <Widget>[
                  swipe(SrsReviewGesture.swipeUp, vertical: false),
                  Row(
                    spacing: gap,
                    children: <Widget>[
                      Expanded(
                        flex: 2,
                        child: swipe(
                          SrsReviewGesture.swipeLeft,
                          vertical: true,
                        ),
                      ),
                      Expanded(flex: 5, child: card),
                      Expanded(
                        flex: 2,
                        child: swipe(
                          SrsReviewGesture.swipeRight,
                          vertical: true,
                        ),
                      ),
                    ],
                  ),
                  swipe(SrsReviewGesture.swipeDown, vertical: false),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: gap,
                    runSpacing: gap,
                    children: <Widget>[
                      for (final SrsReviewGesture g in extras)
                        _GestureCallout(
                          key: ValueKey<String>(
                            'srs-gesture-diagram-${side.name}-${g.wire}',
                          ),
                          gesture: g,
                          action: _action(g),
                          vertical: false,
                          showGestureName: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 示意卡片：三等分点按区，每区手势图 + 动作名。
class _DiagramCard extends StatelessWidget {
  const _DiagramCard({required this.side, required this.actions});

  final SrsReviewSide side;
  final Map<SrsReviewGesture, SrsReviewGestureAction> actions;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final BorderRadius radius = BorderRadius.circular(tokens.radii.group);
    final List<SrsReviewGesture> zones = actions.keys.toList();
    return AspectRatio(
      aspectRatio: 0.78,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: radius,
          border: Border.all(color: cs.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < zones.length; i++) ...<Widget>[
                if (i > 0)
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: cs.outlineVariant,
                  ),
                Expanded(
                  child: _TapZone(
                    key: ValueKey<String>(
                      'srs-gesture-diagram-${side.name}-${zones[i].wire}',
                    ),
                    gesture: zones[i],
                    action: actions[zones[i]]!,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TapZone extends StatelessWidget {
  const _TapZone({super.key, required this.gesture, required this.action});

  final SrsReviewGesture gesture;
  final SrsReviewGestureAction action;

  @override
  Widget build(BuildContext context) {
    final ({Color background, Color foreground}) colors =
        srsGestureActionColors(context, action);
    final bool bound = action != SrsReviewGestureAction.none;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      color: bound
          ? colors.background.withValues(alpha: 0.55)
          : Colors.transparent,
      padding: EdgeInsets.all(tokens.spacing.gap / 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          SrsGestureGlyph(
            key: ValueKey<SrsReviewGestureAction>(action),
            gesture: gesture,
            color: colors.foreground,
            animate: bound,
          ),
          _ActionLabel(action: action, color: colors.foreground),
        ],
      ),
    );
  }
}

/// 滑动 / 双击 / 长按的标注：手势图 + 动作名（[vertical] = 图在上字在下，放卡片两侧）。
class _GestureCallout extends StatelessWidget {
  const _GestureCallout({
    super.key,
    required this.gesture,
    required this.action,
    required this.vertical,
    this.showGestureName = false,
  });

  final SrsReviewGesture gesture;
  final SrsReviewGestureAction action;
  final bool vertical;

  /// 双击 / 长按单看手势图不够直白，图旁加手势名。
  final bool showGestureName;

  @override
  Widget build(BuildContext context) {
    final ({Color background, Color foreground}) colors =
        srsGestureActionColors(context, action);
    final bool bound = action != SrsReviewGestureAction.none;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    final List<Widget> children = <Widget>[
      SrsGestureGlyph(
        key: ValueKey<SrsReviewGestureAction>(action),
        gesture: gesture,
        color: colors.foreground,
        animate: bound,
      ),
      Flexible(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: vertical
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: <Widget>[
            if (showGestureName)
              Text(
                srsReviewGestureLabel(gesture),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.foreground.withValues(alpha: 0.8),
                ),
              ),
            _ActionLabel(action: action, color: colors.foreground),
          ],
        ),
      ),
    ];
    return AnimatedOpacity(
      opacity: bound ? 1 : 0.6,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: AnimatedContainer(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        padding: EdgeInsets.symmetric(
          horizontal: vertical ? gap / 2 : gap,
          vertical: gap / 2,
        ),
        decoration: ShapeDecoration(
          color: colors.background,
          shape: vertical
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(tokens.radii.group),
                )
              : const StadiumBorder(),
        ),
        child: vertical
            ? Column(
                mainAxisSize: MainAxisSize.min,
                spacing: gap / 2,
                children: children,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                spacing: gap / 2,
                children: children,
              ),
      ),
    );
  }
}

/// 动作名，改绑时淡入淡出切换。
class _ActionLabel extends StatelessWidget {
  const _ActionLabel({required this.action, required this.color});

  final SrsReviewGestureAction action;
  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: fushiMotionDuration(context, FushiMotion.short),
    switchInCurve: FushiMotion.standard,
    switchOutCurve: FushiMotion.standard,
    child: Text(
      action == SrsReviewGestureAction.none
          ? '—'
          : srsReviewGestureActionLabel(action),
      key: ValueKey<SrsReviewGestureAction>(action),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

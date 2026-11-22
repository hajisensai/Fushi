/// 群唱的逐帧场景：每帧按歌词时间算出可见消息、给每条消息推进动画状态（进出场、弹簧缩放、
/// 气泡宽高补间、时间戳淡入），再一次性画到 Canvas 上。
///
/// folia 用 framer-motion 给每个 DOM 行做这些动画（`CappellaMessageRow.tsx` /
/// `CappellaBubbleParts.tsx`）；这里把同样的参数（弹簧刚度 / 阻尼 / 质量、补间时长与缓动）
/// 放进一个由墙钟推进的状态机，字的出现仍按歌词时间走。减弱动态效果时所有动画直接到终值。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_avatar.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_messages.dart';

/// 阻尼弹簧（framer `type: 'spring'`），半隐式欧拉，子步长 ≤ 1/240s。
class CappellaSpringValue {
  CappellaSpringValue(this.x);

  double x;
  double v = 0;

  void step(double target, double dt, CappellaSpring s) {
    double left = dt;
    while (left > 1e-9) {
      final double h = math.min(left, 1 / 240);
      final double a = (-s.stiffness * (x - target) - s.damping * v) / s.mass;
      v += a * h;
      x += v * h;
      left -= h;
    }
    if ((x - target).abs() < 1e-4 && v.abs() < 1e-3) {
      x = target;
      v = 0;
    }
  }

  void snap(double target) {
    x = target;
    v = 0;
  }
}

/// 可中途改目标的补间（framer `animate` + tween：改目标时从当前值重新出发）。
class CappellaTweenValue {
  CappellaTweenValue(double value) : _from = value, _to = value;

  double _from;
  double _to;
  double _start = 0;
  double _duration = 0;
  Curve _curve = Curves.easeOut;

  double get target => _to;

  double valueAt(double now) {
    if (_duration <= 0) return _to;
    final double p = ((now - _start) / _duration).clamp(0.0, 1.0);
    return _from + (_to - _from) * _curve.transform(p);
  }

  void retarget(
    double target,
    double now,
    double duration, {
    Curve curve = Curves.easeOut,
  }) {
    if ((target - _to).abs() < 0.01) return;
    _from = valueAt(now);
    _to = target;
    _start = now;
    _duration = duration;
    _curve = curve;
  }

  void snap(double target) {
    _from = target;
    _to = target;
    _duration = 0;
  }
}

/// 一条消息的动画状态。
class _Row {
  _Row(this.message, {required this.enterStart, required Size box})
    : boxW = CappellaTweenValue(box.width),
      boxH = CappellaTweenValue(box.height);

  final CappellaMessage message;

  /// 进场开始的墙钟秒数；null = 不播进场（首帧或减弱动态效果）。
  final double? enterStart;
  double? exitStart;

  final CappellaSpringValue scale = CappellaSpringValue(1);
  final CappellaSpringValue opacity = CappellaSpringValue(1);
  final CappellaSpringValue margin = CappellaSpringValue(0);
  final CappellaTweenValue boxW;
  final CappellaTweenValue boxH;
  bool springsPrimed = false;

  double y = 0;
  bool placed = false;

  CappellaMessageState state = CappellaMessageState.idle;
  CappellaBubbleStyle? style;
  CappellaBubbleMetrics? metrics;
  bool timestampVisible = false;
  double timestampStart = double.negativeInfinity;

  // 本帧量好的值（退场时冻结沿用）。
  double w = 0;
  double h = 0;

  double get height =>
      (message.kind == CappellaMessageKind.emo ? kCappellaEmoTopPadding : 0) +
      margin.x +
      math.max(kCappellaAvatarSize, h);
}

/// 场景输入（随 [LyricVisualizerContext] 与参数变）。
@immutable
class CappellaSceneConfig {
  const CappellaSceneConfig({
    required this.lines,
    required this.messages,
    required this.intensity,
    required this.palette,
    required this.avatarSource,
    required this.seed,
    required this.fontScale,
    required this.motionEnabled,
    required this.initials,
  });

  final List<CappellaLine> lines;
  final List<CappellaMessage> messages;
  final CappellaIntensityConfig intensity;
  final LyricVisualizerPalette palette;
  final CappellaAvatarSource avatarSource;
  final int seed;
  final double fontScale;
  final bool motionEnabled;

  /// 演唱者发送者 → 头像首字母（有名字时）。
  final Map<CappellaSender, String> initials;
}

/// 整个聊天流的状态机 + 绘制。
class CappellaScene {
  CappellaScene(this._config);

  CappellaSceneConfig _config;
  CappellaSceneConfig get config => _config;

  /// 解码好的封面（cover 来源用；没有时回落生成头像）。
  ui.Image? cover;

  final CappellaMeasureCache _measure = CappellaMeasureCache();
  final Map<String, _Row> _rows = <String, _Row>{};
  final List<_Row> _exiting = <_Row>[];
  final Map<Object, TextPainter> _painters = <Object, TextPainter>{};
  final TextPainter _activePainter = TextPainter(
    textDirection: TextDirection.ltr,
    textWidthBasis: TextWidthBasis.longestLine,
  );
  double _lastElapsed = 0;
  bool _first = true;
  LyricVisualizerTick? _lastTick;
  Size? _lastSize;
  List<_Row> _visibleRows = <_Row>[];

  /// 换配置：消息表变了就清掉行状态与测量缓存（下一帧当首帧处理，不播进出场）。
  void update(CappellaSceneConfig next) {
    final bool reset =
        !identical(next.messages, _config.messages) ||
        !identical(next.lines, _config.lines) ||
        next.fontScale != _config.fontScale ||
        !identical(next.intensity, _config.intensity);
    _config = next;
    _lastTick = null;
    if (reset) {
      _rows.clear();
      _exiting.clear();
      _visibleRows = <_Row>[];
      _measure.clear();
      _disposePainters();
      _first = true;
    }
  }

  void _disposePainters() {
    for (final TextPainter p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }

  void dispose() {
    _disposePainters();
    _activePainter.dispose();
  }

  /// 当前可见消息的 id（测试 / 调试用）。
  List<String> get visibleIds => <String>[
    for (final _Row r in _visibleRows) r.message.id,
  ];

  // -------------------------------------------------------------------------
  // 推进
  // -------------------------------------------------------------------------

  /// 推进到 [tick]（同一帧重复调用是幂等的）。
  void advance(Size size, LyricVisualizerTick tick) {
    if (identical(tick, _lastTick) && size == _lastSize) return;
    _lastTick = tick;
    _lastSize = size;
    final CappellaSceneConfig c = _config;
    final CappellaMotion motion = c.intensity.motion;
    final bool snap = !c.motionEnabled;
    final double now = tick.elapsed;
    final double dt = _first ? 0 : (now - _lastElapsed).clamp(0.0, 0.1);
    _lastElapsed = now;
    final int t = tick.timeMs;
    final CappellaViewport vp = CappellaViewport.of(size, c.fontScale);

    final int activeIdx = cappellaActiveLineIndexAt(c.lines, t);
    final int visIdx = cappellaVisibleLineIndexAt(c.lines, t);
    final List<CappellaMessage> sent = cappellaSentMessages(
      c.messages,
      t,
      visIdx,
    );
    final List<CappellaMessage> visible = cappellaFitMessages(
      sent,
      size.height,
      (CappellaMessage m) => cappellaEstimatedHeight(
        message: m,
        active:
            cappellaMessageState(m, t, activeIdx) ==
            CappellaMessageState.active,
        motion: motion,
        viewport: vp,
        cache: _measure,
      ),
    );

    // 预热下一句的前缀尺寸表，切句那一帧不卡。
    if (visIdx + 1 < c.lines.length) {
      final CappellaLine next = c.lines[visIdx + 1];
      final int lead = next.startMs - t;
      if (lead >= kCappellaPreheatMinLeadMs &&
          lead <= kCappellaPreheatMaxLeadMs) {
        final CappellaMessage probe = CappellaMessage(
          id: '',
          kind: CappellaMessageKind.lyric,
          sender: const CappellaSender(right: true, avatarIndex: 0),
          line: next,
        );
        _measure.metricsFor(
          next,
          CappellaBubbleStyle.of(
            message: probe,
            active: true,
            baseFontSize: vp.baseFontSize,
            motion: motion,
          ),
          vp.maxTextWidth,
        );
      }
    }

    final Set<String> ids = <String>{
      for (final CappellaMessage m in visible) m.id,
    };
    for (final String id in _rows.keys.toList()) {
      if (ids.contains(id)) continue;
      final _Row gone = _rows.remove(id)!;
      if (!snap && !_first) {
        gone.exitStart = now;
        _exiting.add(gone);
      }
    }
    _exiting.removeWhere(
      (_Row r) => snap || now - r.exitStart! >= motion.rowExitDuration,
    );

    final List<_Row> rows = <_Row>[];
    for (final CappellaMessage m in visible) {
      final _Row row = _rows.putIfAbsent(
        m.id,
        () =>
            _Row(m, enterStart: (snap || _first) ? null : now, box: Size.zero),
      );
      _updateRow(row, t, activeIdx, now, dt, snap, vp, motion);
      rows.add(row);
    }

    // 自上而下排；行位置变化时平滑过去（framer `layout="position"`，0.32s easeOut 量级）。
    double y = vp.padTop;
    final double k = snap ? 1 : 1 - math.exp(-dt / 0.09);
    for (final _Row r in rows) {
      if (!r.placed || snap) {
        r.y = y;
        r.placed = true;
      } else {
        r.y += (y - r.y) * k;
        if ((y - r.y).abs() < 0.05) r.y = y;
      }
      y += r.height + kCappellaGap;
    }
    _visibleRows = rows;
    _first = false;
  }

  void _updateRow(
    _Row row,
    int t,
    int activeIdx,
    double now,
    double dt,
    bool snap,
    CappellaViewport vp,
    CappellaMotion motion,
  ) {
    final CappellaMessage m = row.message;
    final CappellaMessageState st = cappellaMessageState(m, t, activeIdx);
    row.state = st;
    final bool active = st == CappellaMessageState.active;
    final bool passed = st == CappellaMessageState.passed;

    double targetW;
    double targetH;
    double overflowBase;
    double tweenDuration = kCappellaBubbleSizeTweenSeconds;
    if (m.kind == CappellaMessageKind.emo) {
      final double s = active ? motion.emoActiveSize : motion.emoInactiveSize;
      targetW = s;
      targetH = s;
      overflowBase = s;
      tweenDuration = motion.emoSizeTransitionDuration;
      row.style = null;
      row.metrics = null;
    } else {
      final CappellaBubbleStyle style = CappellaBubbleStyle.of(
        message: m,
        active: active,
        baseFontSize: vp.baseFontSize,
        motion: motion,
      );
      row.style = style;
      if (m.kind == CappellaMessageKind.lyric && active) {
        final CappellaBubbleMetrics metrics = _measure.metricsFor(
          m.line!,
          style,
          vp.maxTextWidth,
        );
        row.metrics = metrics;
        final Size target = style.clamp(
          snap ? metrics.full : metrics.targetAt(t),
        );
        targetW = target.width;
        targetH = target.height;
        overflowBase = metrics.full.height;
      } else {
        row.metrics = null;
        final Size target = style.clamp(
          _measure.sizeFor(m.displayText, style, vp.maxTextWidth),
        );
        targetW = target.width;
        targetH = target.height;
        overflowBase = target.height;
      }
    }

    final double scaleTarget = active
        ? motion.activeScale
        : passed
        ? motion.passedScale
        : 1;
    final double opacityTarget = passed ? motion.passedOpacity : 1;
    final double marginTarget = active && motion.activeScale > 1
        ? (math.max(overflowBase, 40) * (motion.activeScale - 1)).ceilToDouble()
        : 0;

    if (!row.springsPrimed || snap) {
      // framer：组件挂上时直接处在 animate 值，之后变化才走弹簧 / 补间。
      row.scale.snap(scaleTarget);
      row.opacity.snap(opacityTarget);
      row.margin.snap(marginTarget);
      row.boxW.snap(targetW);
      row.boxH.snap(targetH);
      row.springsPrimed = true;
    } else {
      row.scale.step(scaleTarget, dt, motion.avatarSpring);
      row.opacity.step(opacityTarget, dt, motion.avatarSpring);
      row.margin.step(marginTarget, dt, motion.avatarSpring);
      row.boxW.retarget(targetW, now, tweenDuration);
      row.boxH.retarget(targetH, now, tweenDuration);
    }
    row.w = row.boxW.valueAt(now);
    row.h = row.boxH.valueAt(now);

    // 时间戳：表情在激活结束后、歌词在最后一个字淡入完（或已唱过）后出现。
    final bool tsVisible = switch (m.kind) {
      CappellaMessageKind.title => false,
      CappellaMessageKind.emo => t >= m.activationEndMs,
      CappellaMessageKind.lyric =>
        passed || t >= (row.metrics?.plan.timestampReadyMs ?? m.line!.endMs),
    };
    if (tsVisible && !row.timestampVisible) {
      row.timestampStart = (snap || _first || !row.placed)
          ? double.negativeInfinity
          : now;
    }
    row.timestampVisible = tsVisible;
  }

  // -------------------------------------------------------------------------
  // 绘制
  // -------------------------------------------------------------------------

  /// 推进并画一帧。
  void paint(Canvas canvas, Size size, LyricVisualizerTick tick) {
    advance(size, tick);
    final CappellaViewport vp = CappellaViewport.of(size, _config.fontScale);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final _Row r in _exiting) {
      _paintRow(canvas, r, tick, vp);
    }
    for (final _Row r in _visibleRows) {
      _paintRow(canvas, r, tick, vp);
    }
    canvas.restore();
  }

  void _paintRow(
    Canvas canvas,
    _Row r,
    LyricVisualizerTick tick,
    CappellaViewport vp,
  ) {
    final CappellaSceneConfig c = _config;
    final CappellaMotion motion = c.intensity.motion;
    final bool animate = c.motionEnabled;
    final double now = tick.elapsed;
    final CappellaMessage m = r.message;

    // 行级进 / 出场（opacity + y + scale，原点在行中心）。
    double rowOpacity = 1;
    double dy = 0;
    double rowScale = 1;
    double avatarFade = 1;
    double emoEnter = 1;
    if (animate && r.exitStart != null) {
      final double p = Curves.easeIn.transform(
        ((now - r.exitStart!) / motion.rowExitDuration).clamp(0.0, 1.0),
      );
      rowOpacity = 1 - p;
      dy = motion.rowExitY * p;
      rowScale = 1 + (motion.rowExitScale - 1) * p;
    } else if (animate && r.enterStart != null) {
      final double raw = ((now - r.enterStart!) / motion.rowEnterDuration)
          .clamp(0.0, 1.0);
      final double p = Curves.easeOut.transform(raw);
      rowOpacity = p;
      dy = motion.rowEnterY * (1 - p);
      rowScale = motion.rowEnterScale + (1 - motion.rowEnterScale) * p;
      emoEnter = p;
      avatarFade = Curves.easeOut.transform(
        ((now - r.enterStart!) / kCappellaAvatarFadeSeconds).clamp(0.0, 1.0),
      );
    }
    final double groupOpacity = (r.opacity.x * rowOpacity).clamp(0.0, 1.0);
    if (groupOpacity <= 0.001) return;

    final bool right = m.right;
    final double rowH = r.height;
    final double bottom = r.y + rowH;
    final Rect rowRect = Rect.fromLTRB(
      vp.panelLeft - 40,
      r.y - 80,
      vp.panelRight + 40,
      bottom + 40,
    );

    canvas.save();
    canvas.translate(0, dy);
    final Offset rowCenter = Offset(
      vp.panelLeft + vp.panelWidth / 2,
      r.y + rowH / 2,
    );
    canvas.translate(rowCenter.dx, rowCenter.dy);
    canvas.scale(rowScale);
    canvas.translate(-rowCenter.dx, -rowCenter.dy);
    // 气泡组：原点在面板外侧底角（右侧右下、左侧左下）。
    final Offset origin = Offset(right ? vp.panelRight : vp.panelLeft, bottom);
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(r.scale.x);
    canvas.translate(-origin.dx, -origin.dy);
    final bool layered = groupOpacity < 0.999;
    if (layered) {
      canvas.saveLayer(
        rowRect,
        Paint()..color = Colors.white.withValues(alpha: groupOpacity),
      );
    }

    final Rect avatar = Rect.fromLTWH(
      right ? vp.panelRight - kCappellaAvatarSize : vp.panelLeft,
      bottom - kCappellaAvatarSize,
      kCappellaAvatarSize,
      kCappellaAvatarSize,
    );
    paintCappellaAvatar(
      canvas,
      avatar,
      source: c.avatarSource,
      sender: m.sender,
      seed: c.seed,
      palette: c.palette,
      opacity: avatarFade,
      cover: cover,
      initial: c.initials[m.sender],
    );

    final double bubbleLeft = right
        ? avatar.left - kCappellaGap - r.w
        : avatar.right + kCappellaGap;
    final Rect box = Rect.fromLTWH(bubbleLeft, bottom - r.h, r.w, r.h);

    if (m.kind == CappellaMessageKind.emo) {
      _paintEmo(canvas, r, box, now, emoEnter, animate);
    } else {
      _paintBubble(canvas, r, box, tick, vp);
    }
    _paintTimestamp(canvas, r, box, now);

    if (layered) canvas.restore();
    canvas.restore();
  }

  void _paintEmo(
    Canvas canvas,
    _Row r,
    Rect box,
    double now,
    double enter,
    bool animate,
  ) {
    final CappellaMotion motion = _config.intensity.motion;
    double angle = 0;
    if (animate) {
      // cappella-emo-wiggle：-1.6° → 1.6° → -1.6°，每段 ease-in-out。
      final double p =
          (now % kCappellaEmoWiggleSeconds) / kCappellaEmoWiggleSeconds;
      final double half = p < 0.5 ? p * 2 : 2 - p * 2;
      angle =
          (-kCappellaEmoWiggleDegrees +
              2 *
                  kCappellaEmoWiggleDegrees *
                  Curves.easeInOut.transform(half)) *
          math.pi /
          180;
    }
    final double s = motion.emoEnterScale + (1 - motion.emoEnterScale) * enter;
    canvas.save();
    canvas.translate(box.center.dx, box.center.dy);
    canvas.rotate(angle);
    canvas.scale(s);
    canvas.translate(-box.center.dx, -box.center.dy);
    paintCappellaSticker(
      canvas,
      box,
      r.message.stickerIndex,
      _config.palette,
      enter,
    );
    canvas.restore();
  }

  void _paintBubble(
    Canvas canvas,
    _Row r,
    Rect box,
    LyricVisualizerTick tick,
    CappellaViewport vp,
  ) {
    final CappellaSceneConfig c = _config;
    final CappellaMotion motion = c.intensity.motion;
    final CappellaMessage m = r.message;
    final bool right = m.right;
    final bool active = r.state == CappellaMessageState.active;
    final CappellaBubbleColors colors = cappellaBubbleColors(
      m.sender,
      c.palette,
    );
    const Radius big = Radius.circular(kCappellaBubbleRadius);
    const Radius tail = Radius.circular(kCappellaBubbleTailRadius);
    final RRect rr = RRect.fromRectAndCorners(
      box,
      topLeft: big,
      topRight: big,
      bottomLeft: right ? big : tail,
      bottomRight: right ? tail : big,
    );

    // shadow-lg + 当前行的大投影（跟着弹簧缩放程度淡入淡出）。
    canvas.drawRRect(
      rr.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    final double activeAmount = motion.activeScale > 1
        ? ((r.scale.x - 1) / (motion.activeScale - 1)).clamp(0.0, 1.0)
        : (active ? 1.0 : 0.0);
    if (activeAmount > 0.01) {
      final Color shadow = Color.lerp(
        c.palette.background,
        c.palette.primary,
        0.2,
      )!.withValues(alpha: motion.activeShadowAlpha * activeAmount);
      canvas.drawRRect(
        rr.shift(const Offset(0, 18)),
        Paint()
          ..color = shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
      );
    }
    canvas.drawRRect(rr, Paint()..color = colors.background);

    canvas.save();
    canvas.clipRRect(rr);
    if (active && c.motionEnabled) {
      _paintGlow(canvas, box, right, tick.elapsed, motion);
    }
    final CappellaBubbleStyle style = r.style!;
    final Offset textOrigin = box.topLeft.translate(
      kCappellaBubbleBorder + style.padX,
      kCappellaBubbleBorder + style.padY,
    );
    if (r.metrics != null) {
      _paintActiveText(canvas, r, textOrigin, tick.timeMs, colors.text, vp);
    } else {
      final TextPainter tp = _staticPainter(
        m,
        style.fontSize,
        vp.maxTextWidth,
        colors.text,
      );
      tp.paint(canvas, textOrigin);
    }
    canvas.restore();

    canvas.drawRRect(
      rr.deflate(kCappellaBubbleBorder / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kCappellaBubbleBorder
        ..color = colors.border,
    );
  }

  /// cappella-bubble-glow-pan：两倍宽的 105° 斜向高光带，按 glowDuration 线性平移一个气泡宽。
  void _paintGlow(
    Canvas canvas,
    Rect box,
    bool right,
    double elapsed,
    CappellaMotion motion,
  ) {
    final double w = box.width;
    final double h = box.height;
    if (w <= 0 || h <= 0) return;
    final double shift =
        (elapsed % motion.glowDuration) / motion.glowDuration * w;
    final Rect band = Rect.fromLTWH(box.left - shift, box.top, w * 2, h);
    const double theta = 105 * math.pi / 180;
    final Offset dir = Offset(math.sin(theta), -math.cos(theta));
    final double len =
        (band.width * math.sin(theta)).abs() +
        (band.height * math.cos(theta)).abs();
    final Color glow = Colors.white.withValues(
      alpha:
          (right ? motion.glowRightAlpha : motion.glowLeftAlpha) *
          motion.glowOpacity,
    );
    const Color clear = Color(0x00FFFFFF);
    canvas.drawRect(
      band,
      Paint()
        ..shader = ui.Gradient.linear(
          band.center - dir * (len / 2),
          band.center + dir * (len / 2),
          <Color>[clear, glow, clear, clear, glow, clear, clear],
          <double>[0, 0.23, 0.34, 0.5, 0.73, 0.84, 1],
        ),
    );
  }

  /// 当前行：只排已出现的前缀，每个字按自己的时长 ease-out 淡入（folia `ActiveCappellaText`）。
  void _paintActiveText(
    Canvas canvas,
    _Row r,
    Offset origin,
    int timeMs,
    Color color,
    CappellaViewport vp,
  ) {
    final CappellaRevealPlan plan = r.metrics!.plan;
    final bool snap = !_config.motionEnabled;
    final int count = snap
        ? plan.characters.length
        : cappellaCharCountAt(plan.revealMs, timeMs);
    if (count == 0) return;
    final TextStyle base = cappellaBubbleTextStyle(r.style!.fontSize, color);
    final List<InlineSpan> spans = <InlineSpan>[];
    final StringBuffer run = StringBuffer();
    void flush() {
      if (run.isEmpty) return;
      spans.add(TextSpan(text: run.toString()));
      run.clear();
    }

    for (int i = 0; i < count; i++) {
      final double a = snap
          ? 1
          : Curves.easeOut.transform(
              ((timeMs - plan.revealMs[i]) / plan.fadeMs[i]).clamp(0.0, 1.0),
            );
      if (a >= 0.999) {
        run.write(plan.characters[i]);
      } else {
        flush();
        spans.add(
          TextSpan(
            text: plan.characters[i],
            style: TextStyle(color: color.withValues(alpha: color.a * a)),
          ),
        );
      }
    }
    flush();
    _activePainter.text = TextSpan(style: base, children: spans);
    _activePainter.layout(maxWidth: math.max(1, vp.maxTextWidth));
    _activePainter.paint(canvas, origin);
  }

  void _paintTimestamp(Canvas canvas, _Row r, Rect box, double now) {
    if (!r.timestampVisible) return;
    final CappellaLine? line = r.message.line;
    if (line == null) return;
    final double p = _config.motionEnabled
        ? Curves.easeOut.transform(
            ((now - r.timestampStart) / kCappellaTimestampFadeSeconds).clamp(
              0.0,
              1.0,
            ),
          )
        : 1;
    if (p <= 0) return;
    final Color color = _config.palette.secondary;
    final TextPainter tp = _timestampPainter(
      cappellaFormatTimestamp(line.endMs),
      color,
    );
    final bool emo = r.message.kind == CappellaMessageKind.emo;
    final double bottom = emo ? box.bottom + 2 : box.bottom - 4;
    final double x = r.message.right ? box.left - 8 - tp.width : box.right + 8;
    final Offset at = Offset(x, bottom - tp.height + 4 * (1 - p));
    canvas.saveLayer(
      at & tp.size,
      Paint()
        ..color = Colors.white.withValues(alpha: kCappellaTimestampOpacity * p),
    );
    tp.paint(canvas, at);
    canvas.restore();
  }

  TextPainter _staticPainter(
    CappellaMessage m,
    double fontSize,
    double maxTextWidth,
    Color color,
  ) {
    final Object key = ('msg', m.id, fontSize, maxTextWidth, color);
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;
    _evictPainters();
    return _painters[key] = cappellaLayoutText(
      m.displayText,
      fontSize,
      maxTextWidth,
      color,
    );
  }

  TextPainter _timestampPainter(String text, Color color) {
    final Object key = ('ts', text, color);
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;
    _evictPainters();
    return _painters[key] = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: kCappellaTimestampFontSize,
          fontWeight: FontWeight.w500,
          color: color,
          fontFeatures: const <ui.FontFeature>[ui.FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _evictPainters() {
    if (_painters.length < 96) return;
    // 超额时整批丢掉最早的一半（Map 保持插入顺序）。
    final List<Object> keys = _painters.keys.take(48).toList();
    for (final Object k in keys) {
      _painters.remove(k)!.dispose();
    }
  }
}

/// 把 [CappellaScene] 接到逐帧时间源上。
class CappellaPainter extends CustomPainter {
  CappellaPainter({
    required this.scene,
    required this.ticks,
    required this.revision,
  }) : super(repaint: ticks);

  final CappellaScene scene;
  final LyricVisualizerTicks ticks;

  /// 配置 / 封面变化时 +1，触发重画。
  final int revision;

  @override
  void paint(Canvas canvas, Size size) =>
      scene.paint(canvas, size, ticks.value);

  @override
  bool shouldRepaint(CappellaPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene) ||
      oldDelegate.revision != revision ||
      !identical(oldDelegate.ticks, ticks);
}

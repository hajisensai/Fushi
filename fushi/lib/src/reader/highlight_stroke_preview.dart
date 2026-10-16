/// 高亮条笔触样式的设置页预览（`HighlightStylePage`，四类高亮共用）。
///
/// 正文里的笔触由窄条层 `__fushiLanes`（reader_selection_scripts.dart）在 WebView 里画；
/// 这里用 Canvas 按**同一套参数与形状**画一段示意样文（带振假名，横排 / 竖排），让用户
/// 在设置页里拖滑块时立刻看到效果。改 JS 的形状要同步改这里（`_paint*` 与 JS 的
/// `MARKERS.*` 一一对应）。
///
/// 排版是逐字手排（Flutter 没有竖排与注音）：全角字按 1em 方格排，振假名按 0.5em 写在
/// over 侧（横排上方、竖排右侧），和正文的几何关系一致——这正是「盖住振假名」开关要
/// 让用户看清的东西。纯展示，不进焦点遍历。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/reader/highlight_stroke_style.dart';

/// 收藏五色的基色（与 highlight_bridge.dart 的 `BASE_COLORS` 相同）。
const Map<String, Color> kFavoriteHighlightColors = <String, Color>{
  'yellow': Color(0xFFFFDC00),
  'green': Color(0xFF00C853),
  'blue': Color(0xFF448AFF),
  'pink': Color(0xFFFF4081),
  'purple': Color(0xFFAA00FF),
};

/// 预览样文：`｜基字《注音》` 标注振假名，`⟦…⟧` 标出被收藏（高亮）的一段。
const String kHighlightPreviewSample =
    '｜放課後《ほうかご》の｜図書室《としょしつ》は｜静《しず》かだった。'
    '⟦｜窓際《まどぎわ》の｜席《せき》に｜座《すわ》ると、｜夕日《ゆうひ》がページの'
    '｜端《はし》を｜橙色《だいだいいろ》に｜染《そ》めていく。⟧｜外《そと》はもう｜暗《くら》い。';

/// 样式缩略图的样文（整句高亮、单行）。
const String kHighlightTileSample = '⟦｜夕日《ゆうひ》が｜染《そ》める⟧';

/// 解析后的一个字。
class HighlightPreviewGlyph {
  const HighlightPreviewGlyph(this.char, {required this.highlighted});
  final String char;
  final bool highlighted;
}

/// 一段振假名：覆盖 [start, end) 这几个字。
class HighlightPreviewRuby {
  const HighlightPreviewRuby(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

/// 解析样文标记（纯函数，供测试）。
({List<HighlightPreviewGlyph> glyphs, List<HighlightPreviewRuby> ruby})
parseHighlightPreviewSample(String source) {
  final List<HighlightPreviewGlyph> glyphs = <HighlightPreviewGlyph>[];
  final List<HighlightPreviewRuby> ruby = <HighlightPreviewRuby>[];
  bool highlighted = false;
  int? baseStart;
  final List<String> chars = source.runes
      .map((int r) => String.fromCharCode(r))
      .toList();
  for (int i = 0; i < chars.length; i++) {
    final String ch = chars[i];
    if (ch == '⟦') {
      highlighted = true;
    } else if (ch == '⟧') {
      highlighted = false;
    } else if (ch == '｜') {
      baseStart = glyphs.length;
    } else if (ch == '《') {
      final int close = chars.indexOf('》', i);
      if (close < 0) break;
      final String text = chars.sublist(i + 1, close).join();
      if (baseStart != null) {
        ruby.add(HighlightPreviewRuby(baseStart, glyphs.length, text));
      }
      baseStart = null;
      i = close;
    } else {
      glyphs.add(HighlightPreviewGlyph(ch, highlighted: highlighted));
    }
  }
  return (glyphs: glyphs, ruby: ruby);
}

/// 一行（列）里连续高亮的一段，在「沿行 u / 跨行 v」局部坐标里（与 JS 同义：横排 u=x、
/// v=y；竖排 u=y、v=-x；v 负方向 = 振假名所在的 over 侧）。
class HighlightPreviewLine {
  const HighlightPreviewLine({
    required this.u0,
    required this.u1,
    required this.vc,
    required this.em,
  });
  final double u0;
  final double u1;
  final double vc;
  final double em;
}

/// mulberry32 + FNV-1a（与 JS 的 `markRng` / `markHash` 同算法）。
class _Rng {
  _Rng(this._a);
  int _a;
  double next() {
    _a = (_a + 0x6D2B79F5) & 0xFFFFFFFF;
    int t = _a;
    t = _imul(t ^ (t >>> 15), t | 1);
    t ^= (t + _imul(t ^ (t >>> 7), t | 61)) & 0xFFFFFFFF;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296;
  }

  static int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

  static int hash(String s) {
    int h = 2166136261;
    for (final int c in s.codeUnits) {
      h ^= c;
      h = _imul(h, 16777619);
    }
    return h;
  }
}

/// 落笔扫过的长度（em）：行长两端各多 1em（与 JS 的 clip 矩形同义）。
double _sweepLengthEm(HighlightPreviewLine l) =>
    (l.u1 - l.u0 + l.em * 2) / l.em;

/// 逐字手排：每个字的方格中心（屏幕坐标）+ 高亮行段 + 每行字数。
({List<Offset> centers, List<HighlightPreviewLine> lines, int perLine})
_layoutPreview(
  ({List<HighlightPreviewGlyph> glyphs, List<HighlightPreviewRuby> ruby})
  parsed,
  Size size, {
  required double em,
  required double lineHeight,
  required bool vertical,
  required double padding,
}) {
  final double pitch = em * lineHeight.clamp(1.2, 3.2);
  final Rect box = Rect.fromLTRB(
    padding,
    padding,
    size.width - padding,
    size.height - padding,
  );
  final int perLine = math.max(
    1,
    ((vertical ? box.height : box.width) / em).floor(),
  );

  final List<Offset> centers = <Offset>[];
  for (int i = 0; i < parsed.glyphs.length; i++) {
    final int line = i ~/ perLine;
    final int col = i % perLine;
    centers.add(
      vertical
          ? Offset(box.right - pitch * (line + 0.5), box.top + em * (col + 0.5))
          : Offset(box.left + em * (col + 0.5), box.top + pitch * (line + 0.5)),
    );
  }

  final List<HighlightPreviewLine> lines = <HighlightPreviewLine>[];
  int? runStart;
  for (int i = 0; i <= parsed.glyphs.length; i++) {
    final bool on = i < parsed.glyphs.length && parsed.glyphs[i].highlighted;
    final bool sameLine =
        runStart != null &&
        i < parsed.glyphs.length &&
        i ~/ perLine == runStart ~/ perLine;
    if (runStart != null && (!on || !sameLine)) {
      final Offset a = centers[runStart];
      final Offset b = centers[i - 1];
      lines.add(
        vertical
            ? HighlightPreviewLine(
                u0: a.dy - em / 2,
                u1: b.dy + em / 2,
                vc: -a.dx,
                em: em,
              )
            : HighlightPreviewLine(
                u0: a.dx - em / 2,
                u1: b.dx + em / 2,
                vc: a.dy,
                em: em,
              ),
      );
      runStart = null;
    }
    if (on && runStart == null) runStart = i;
  }
  return (centers: centers, lines: lines, perLine: perLine);
}

/// 手排样文 + 笔触，画在给定尺寸里。
class HighlightStrokePreviewPainter extends CustomPainter {
  HighlightStrokePreviewPainter({
    required this.sample,
    required this.config,
    required this.color,
    required this.paper,
    required this.ink,
    required this.vertical,
    required this.fontSize,
    required this.lineHeight,
    this.progress = 1,
    this.padding = 14,
    this.seedSalt = 0,
    this.classicUnderline = true,
  });

  final String sample;
  final HighlightStrokeConfig config;
  final Color color;
  final Color paper;
  final Color ink;
  final bool vertical;
  final double fontSize;
  final double lineHeight;

  /// 落笔动画进度（0–1；1 = 画完）。逐行依次展开，与 JS 的 SMIL 时序同比例。
  final double progress;
  final double padding;
  final int seedSalt;

  /// 经典样式画不画下划线（只有收藏有下划线）。
  final bool classicUnderline;

  /// 在 [size] 里画完 [sample] 全部高亮行的落笔总时长（与正文同一公式：
  /// [highlightStrokeSweepLineDuration] 逐行 + [kHighlightStrokeSweepGap] 行间隔）。设置页
  /// 拿它当预览动画控制器的时长，预览里每一行的速度就与正文一致。
  static Duration sweepDurationFor({
    required String sample,
    required Size size,
    required double fontSize,
    required double lineHeight,
    required bool vertical,
    double padding = 14,
  }) {
    final List<HighlightPreviewLine> lines = _layoutPreview(
      parseHighlightPreviewSample(sample),
      size,
      em: fontSize,
      lineHeight: lineHeight,
      vertical: vertical,
      padding: padding,
    ).lines;
    Duration total = Duration.zero;
    for (final HighlightPreviewLine l in lines) {
      total +=
          highlightStrokeSweepLineDuration(_sweepLengthEm(l)) +
          kHighlightStrokeSweepGap;
    }
    return total;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ({
      List<HighlightPreviewGlyph> glyphs,
      List<HighlightPreviewRuby> ruby,
    })
    parsed = parseHighlightPreviewSample(sample);
    final double em = fontSize;
    final ({
      List<Offset> centers,
      List<HighlightPreviewLine> lines,
      int perLine,
    })
    layout = _layoutPreview(
      parsed,
      size,
      em: em,
      lineHeight: lineHeight,
      vertical: vertical,
      padding: padding,
    );
    final List<Offset> centers = layout.centers;
    final List<HighlightPreviewLine> lines = layout.lines;
    final int perLine = layout.perLine;

    // 笔触（在字下面）。
    if (config.style == HighlightStrokeStyle.classic) {
      _paintClassic(canvas, lines);
    } else {
      final double gap = kHighlightStrokeSweepGap.inMicroseconds / 1e6;
      double total = 0;
      final List<double> durations = <double>[
        for (final HighlightPreviewLine l in lines)
          highlightStrokeSweepLineDuration(_sweepLengthEm(l)).inMicroseconds /
              1e6,
      ];
      for (final double d in durations) {
        total += d + gap;
      }
      double start = 0;
      for (int i = 0; i < lines.length; i++) {
        final HighlightPreviewLine l = lines[i];
        final double f = progress >= 1 || total <= 0
            ? 1
            : ((progress * total - start) / durations[i]).clamp(0.0, 1.0);
        start += durations[i] + gap;
        if (f <= 0) continue;
        canvas.save();
        if (f < 1) {
          final double eased = 1 - math.pow(1 - f, 2.2).toDouble();
          final double reach = l.u0 - l.em + (l.u1 - l.u0 + l.em * 2) * eased;
          canvas.clipRect(
            vertical
                ? Rect.fromLTRB(
                    -l.vc - l.em * 3,
                    l.u0 - l.em,
                    -l.vc + l.em * 3,
                    reach,
                  )
                : Rect.fromLTRB(
                    l.u0 - l.em,
                    l.vc - l.em * 3,
                    reach,
                    l.vc + l.em * 3,
                  ),
          );
        }
        _paintStroke(
          canvas,
          l,
          _Rng(
            _Rng.hash(
              '${config.style.wireName}:${l.u0.round()}:${l.vc.round()}:$seedSalt',
            ),
          ),
        );
        canvas.restore();
      }
    }

    // 正文字。
    for (int i = 0; i < parsed.glyphs.length; i++) {
      _drawGlyph(canvas, parsed.glyphs[i].char, centers[i], em, ink);
    }
    // 振假名（over 侧，0.5em）。
    for (final HighlightPreviewRuby r in parsed.ruby) {
      if (r.start >= centers.length || r.end - 1 >= centers.length) continue;
      if (r.start ~/ perLine != (r.end - 1) ~/ perLine) continue;
      final Offset a = centers[r.start];
      final Offset b = centers[r.end - 1];
      final List<String> kana = r.text.runes
          .map((int c) => String.fromCharCode(c))
          .toList();
      final double rubyEm = em * 0.5;
      final double spanStart = vertical ? a.dy - em / 2 : a.dx - em / 2;
      final double spanLen = vertical ? b.dy - a.dy + em : b.dx - a.dx + em;
      final double step = math.min(rubyEm, spanLen / kana.length);
      final double first =
          spanStart + (spanLen - step * kana.length) / 2 + step / 2;
      for (int k = 0; k < kana.length; k++) {
        final Offset c = vertical
            ? Offset(a.dx + em * 0.5 + rubyEm * 0.5, first + step * k)
            : Offset(first + step * k, a.dy - em * 0.5 - rubyEm * 0.5);
        _drawGlyph(canvas, kana[k], c, rubyEm, ink.withValues(alpha: 0.72));
      }
    }
  }

  void _drawGlyph(
    Canvas canvas,
    String ch,
    Offset center,
    double size,
    Color c,
  ) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: ch,
        style: TextStyle(fontSize: size, color: c, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    Offset at = center - Offset(tp.width / 2, tp.height / 2);
    // 竖排句读点靠右上（与竖排正文的字形位置一致）。
    if (vertical && (ch == '、' || ch == '。')) {
      at += Offset(size * 0.32, -size * 0.32);
    }
    tp.paint(canvas, at);
    tp.dispose();
  }

  Offset _p(double u, double v) => vertical ? Offset(-v, u) : Offset(u, v);

  Path _poly(List<List<double>> pts) {
    final Path path = Path();
    for (int i = 0; i < pts.length; i++) {
      final Offset o = _p(pts[i][0], pts[i][1]);
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    return path..close();
  }

  List<List<double>> _wobble(
    double from,
    double to,
    double v,
    double amp,
    double step,
    _Rng r,
  ) {
    final int n = math.max(1, ((to - from).abs() / step).round());
    return <List<double>>[
      for (int i = 1; i < n; i++)
        <double>[from + (to - from) * i / n, v + (r.next() - 0.5) * 2 * amp],
    ];
  }

  ({double top, double bot}) _band(HighlightPreviewLine l, double k, _Rng r) {
    final double half = l.em * k * config.thickness / 2;
    final double j = (r.next() - 0.5) * l.em * 0.05 * config.roughness;
    final bool cover = config.coverRuby && config.style.supportsCoverRuby;
    return (
      top: l.vc - half - (cover ? l.em * 0.6 : 0) + j,
      bot: l.vc + half + j,
    );
  }

  /// 当前样式的自然粗细（em），与 JS `MARK_NATURAL_EM` 同表。
  double get _natural => kHighlightStrokeNaturalEm[config.style] ?? 1;

  Paint _fill(double opacity) => Paint()
    ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0))
    ..isAntiAlias = true;

  void _paintClassic(Canvas canvas, List<HighlightPreviewLine> lines) {
    final Paint lane = _fill(config.opacity);
    final Paint underline = Paint()
      ..color = Color.lerp(color, const Color(0xFF000000), 0.35)!
      ..strokeWidth = fontSize * 0.12;
    for (final HighlightPreviewLine l in lines) {
      final double half = l.em / 2;
      final Path p = _poly(<List<double>>[
        <double>[l.u0, l.vc - half],
        <double>[l.u1, l.vc - half],
        <double>[l.u1, l.vc + half],
        <double>[l.u0, l.vc + half],
      ]);
      canvas.drawPath(p, lane);
      final double v = l.vc + half + l.em * 0.18;
      if (classicUnderline) {
        canvas.drawLine(_p(l.u0, v), _p(l.u1, v), underline);
      }
    }
  }

  void _paintStroke(Canvas canvas, HighlightPreviewLine l, _Rng r) {
    final double rough = config.roughness;
    final double op = config.opacity;
    final double em = l.em;
    switch (config.style) {
      case HighlightStrokeStyle.classic:
        return;
      case HighlightStrokeStyle.marker:
        final ({double top, double bot}) b = _band(l, _natural, r);
        final double h = b.bot - b.top;
        final double s = h * (0.18 + 0.22 * rough);
        final double a = l.u0 - em * (0.06 + r.next() * 0.1 * rough);
        final double z = l.u1 + em * (0.04 + r.next() * 0.16 * rough);
        final double amp = h * 0.025 * rough;
        final List<List<double>> pts = <List<double>>[
          <double>[a + s / 2, b.top],
          ..._wobble(a + s / 2, z + s / 2, b.top, amp, em * 1.6, r),
          <double>[z + s / 2, b.top],
          <double>[
            z + s * 0.1 + (r.next() - 0.5) * em * 0.12 * rough,
            b.top + h * 0.45,
          ],
          <double>[z - s / 2, b.bot],
          ..._wobble(z - s / 2, a - s / 2, b.bot, amp, em * 1.6, r),
          <double>[a - s / 2, b.bot],
        ];
        canvas.drawPath(_poly(pts), _fill(op));
        final double p0 = math.max(a, z - em * 0.7);
        canvas.drawPath(
          _poly(<List<double>>[
            <double>[p0 + s / 2, b.top],
            <double>[z + s / 2, b.top],
            <double>[z - s / 2, b.bot],
            <double>[p0 - s / 2, b.bot],
          ]),
          _fill(op * 0.28),
        );
      case HighlightStrokeStyle.fluo:
        final ({double top, double bot}) b = _band(l, _natural, r);
        final double h = b.bot - b.top;
        final double s = h * 0.18;
        final double a = l.u0 - em * 0.1;
        final double z = l.u1 + em * (0.04 + r.next() * 0.14 * rough);
        final double amp = h * (0.02 + 0.05 * rough);
        final Path path = _poly(<List<double>>[
          <double>[a + s, b.top],
          ..._wobble(a + s, z, b.top, amp, em * 0.7, r),
          <double>[z, b.top],
          <double>[z - s, b.bot],
          ..._wobble(z - s, a, b.bot, amp, em * 0.7, r),
          <double>[a, b.bot],
        ]);
        final Offset g0 = _p(a, b.top);
        final Offset g1 = _p(z, b.top);
        final Paint paint = Paint()
          ..isAntiAlias = true
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.5 + 1.1 * rough)
          ..shader = ui.Gradient.linear(
            g0,
            g1,
            <Color>[
              for (final double k in <double>[1.55, 1, 0.82, 1, 1.7])
                color.withValues(alpha: math.min(1, op * k)),
            ],
            <double>[0, 0.06, 0.5, 0.94, 1],
          );
        canvas.drawPath(path, paint);
        final Paint streak = Paint()
          ..color = paper.withValues(alpha: 0.22)
          ..strokeWidth = 1.1
          ..strokeCap = StrokeCap.round;
        for (int k = 0; k < 2; k++) {
          final double v = b.top + h * (0.3 + r.next() * 0.45);
          final double u0 = a + (z - a) * r.next() * 0.3;
          final double u1 = math.min(
            u0 + (z - a) * (0.35 + r.next() * 0.4),
            z - s,
          );
          canvas.drawLine(
            _p(u0, v),
            _p(u1, v + (r.next() - 0.5) * 1.5),
            streak,
          );
        }
      case HighlightStrokeStyle.rough:
        final ({double top, double bot}) b = _band(l, _natural, r);
        final double w = b.bot - b.top;
        final double vc = (b.top + b.bot) / 2;
        for (int k = 0; k < 2; k++) {
          final double a = l.u0 - em * (0.04 + r.next() * 0.14 * rough);
          final double z = l.u1 + em * r.next() * 0.18 * rough;
          final double j = w * (0.08 + 0.2 * rough);
          final double v0 = vc + (r.next() - 0.5) * j;
          final double v1 = vc + (r.next() - 0.5) * j;
          final double bow = (r.next() - 0.5) * j * 1.3;
          final Offset start = _p(a, v0);
          final Offset ctrl = _p((a + z) / 2, (v0 + v1) / 2 + bow);
          final Offset end = _p(z, v1);
          canvas.drawPath(
            Path()
              ..moveTo(start.dx, start.dy)
              ..quadraticBezierTo(ctrl.dx, ctrl.dy, end.dx, end.dy),
            Paint()
              ..isAntiAlias = true
              ..style = PaintingStyle.stroke
              ..strokeWidth = w * (0.84 + r.next() * 0.1)
              ..color = color.withValues(alpha: op * 0.72),
          );
        }
      case HighlightStrokeStyle.under:
        final double top = l.vc + em * 0.02;
        final double bot = l.vc + em * 0.5 * config.thickness;
        final double s = (bot - top) * 0.4;
        final double a = l.u0 - em * 0.05;
        final double z = l.u1 + em * (0.03 + r.next() * 0.1 * rough);
        final double amp = 0.3 + 0.6 * rough;
        canvas.drawPath(
          _poly(<List<double>>[
            <double>[a + s / 2, top],
            ..._wobble(a, z, top, amp, em, r),
            <double>[z + s / 2, top],
            <double>[z - s / 2, bot],
            ..._wobble(z, a, bot, amp, em, r),
            <double>[a - s / 2, bot],
          ]),
          _fill(math.min(0.9, op * 1.35)),
        );
      case HighlightStrokeStyle.crayon:
        final ({double top, double bot}) b = _band(l, _natural, r);
        final double h = b.bot - b.top;
        final double a = l.u0 - em * 0.1;
        final double z = l.u1 + em * (0.05 + r.next() * 0.12 * rough);
        final double amp = h * (0.02 + 0.06 * rough);
        final Path path = _poly(<List<double>>[
          <double>[a, b.top + h * 0.08],
          ..._wobble(a, z, b.top, amp, em * 0.5, r),
          <double>[z, b.top + h * 0.1],
          <double>[z + em * 0.05, b.bot - h * 0.2],
          <double>[z - em * 0.1, b.bot],
          ..._wobble(z, a, b.bot, amp, em * 0.5, r),
          <double>[a - em * 0.04, b.bot - h * 0.1],
        ]);
        canvas.drawPath(path, _fill(math.min(1, op * 1.6)));
        // 颗粒：在笔划里撒纸色小点（对应 JS 的颗粒滤镜挖出的空白）。
        canvas.save();
        canvas.clipPath(path);
        final Paint grain = Paint()..color = paper.withValues(alpha: 0.42);
        final double dot = math.max(0.6, em * 0.035);
        final int count = (((z - a) * h) / (dot * dot * 9))
            .clamp(0, 900)
            .round();
        for (int k = 0; k < count; k++) {
          canvas.drawCircle(
            _p(a + (z - a) * r.next(), b.top + h * r.next()),
            dot * (0.5 + r.next()),
            grain,
          );
        }
        canvas.restore();
      case HighlightStrokeStyle.tape:
        final ({double top, double bot}) b = _band(l, _natural, r);
        final double h = b.bot - b.top;
        final double a = l.u0 - em * 0.16;
        final double z = l.u1 + em * 0.16;
        final double tilt = (r.next() - 0.5) * h * 0.2 * rough;
        List<List<double>> torn(double u, double top, double bot, double dir) =>
            <List<double>>[
              for (int i = 0; i <= 5; i++)
                <double>[
                  u +
                      dir * (i.isOdd ? em * 0.08 : 0) +
                      (r.next() - 0.5) * 1.2 * rough,
                  top + (bot - top) * i / 5,
                ],
            ];
        final Path path = _poly(<List<double>>[
          ...torn(z, b.top + tilt, b.bot + tilt, 1),
          ...torn(a, b.bot - tilt, b.top - tilt, -1),
        ]);
        canvas.drawPath(path, _fill(math.min(0.85, op * 1.05)));
        canvas.save();
        canvas.clipPath(path);
        final Rect bounds = path.getBounds();
        final Paint stripe = Paint()
          ..color = paper.withValues(alpha: 0.25)
          ..strokeWidth = 2;
        final double reach = bounds.width + bounds.height;
        for (double d = -reach; d < reach; d += 6) {
          final Offset o = bounds.topLeft + Offset(d, 0);
          canvas.drawLine(
            o,
            o + Offset(reach * math.cos(0.96), reach * math.sin(0.96)),
            stripe,
          );
        }
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(HighlightStrokePreviewPainter old) =>
      old.sample != sample ||
      old.config != config ||
      old.color != color ||
      old.paper != paper ||
      old.ink != ink ||
      old.vertical != vertical ||
      old.fontSize != fontSize ||
      old.lineHeight != lineHeight ||
      old.progress != progress ||
      old.seedSalt != seedSalt ||
      old.classicUnderline != classicUnderline;
}

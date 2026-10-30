/// 一行歌词的预排版 + 逐帧绘制（设计 §6.1）。
///
/// - **排版只做一次**：主文本按「未唱色 / 已唱色 / 描边 / 辉光」各排一份 [TextPainter]，
///   音节边界的字形框（可能跨折行）、ruby、翻译 / 罗马音副行都在 [KaraokeLineLayout.build]
///   里算好；字号 / 宽度 / 时间轴变了才重建（[debugLayoutCount] 供测试断言逐帧不重排）。
/// - **每帧只改裁剪与渐变 stop**：已唱完的音节并成一条裁剪路径画一次已唱色，未唱的并成一条画
///   一次未唱色（两条路径按「已唱完的音节数」缓存），只有正在唱（含刚唱完、回落中）的一两个
///   音节单独处理：硬边 / 羽化渐变 / 描边、上浮、辉光、长音呼吸。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_appearance.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_progress.dart';

/// 音节唱完后上浮回落的时长（毫秒，属于时间轴语义而非 UI 动效：跟着歌曲时间走，暂停即停）。
const int kKaraokeSettleMs = 180;

/// 一个音节的几何。
class KaraokeSyllableGeometry {
  KaraokeSyllableGeometry({
    required this.start,
    required this.end,
    required this.boxes,
    required this.totalWidth,
    this.rubyInactive,
    this.rubyActive,
    this.rubyOffset = Offset.zero,
  });

  /// 在整行文本里的 UTF-16 区间。
  final int start;
  final int end;

  /// 字形框（行布局坐标，已含注音预留的顶部偏移）。跨折行时多个。
  final List<Rect> boxes;
  final double totalWidth;
  final TextPainter? rubyInactive;
  final TextPainter? rubyActive;
  final Offset rubyOffset;

  Rect get bounds => boxes.isEmpty
      ? Rect.zero
      : boxes
            .skip(1)
            .fold(boxes.first, (Rect a, Rect b) => a.expandToInclude(b));
}

class KaraokeLineLayout {
  KaraokeLineLayout._({
    required this.line,
    required this.size,
    required this.textTop,
    required this.syllables,
    required TextPainter base,
    required TextPainter active,
    required TextPainter? outline,
    required TextPainter? glow,
    required List<(TextPainter, Offset)> subs,
    required List<(double, double)> lineBands,
    required this.feather,
    required this.lineLevel,
  }) : _base = base,
       _lineBands = lineBands,
       _active = active,
       _outline = outline,
       _glow = glow,
       _subs = subs;

  /// 排版次数（测试断言「逐帧不重排」用）。
  static int debugLayoutCount = 0;

  final LyricLine line;
  final Size size;

  /// 主文本相对行顶的纵向偏移（顶部为注音预留）。
  final double textTop;
  final List<KaraokeSyllableGeometry> syllables;
  final TextPainter _base;
  final TextPainter _active;
  final TextPainter? _outline;
  final TextPainter? _glow;
  final List<(TextPainter, Offset)> _subs;

  /// 主文本每一视觉行（折行后）独占的纵向带 (top, bottom)，行布局坐标。相邻两行以两者
  /// 行框间隙的中线为界，首行向上、末行向下不设界。逐字裁剪 / 辉光只在字形所在的带内画，
  /// 不越到同一句折出来的另一视觉行上（否则正在唱的字会把上下行的字也染成已唱色）。
  final List<(double, double)> _lineBands;

  /// 羽化边宽度。
  final double feather;

  /// 行级时间轴：整行当一个擦色区（[karaokeLineLevelProgress]）。
  final bool lineLevel;

  static KaraokeLineLayout build({
    required LyricLine line,
    required double width,
    required TextStyle style,
    required KaraokeResolvedStyle resolved,
    required TextAlign align,
    required bool lineLevel,
  }) {
    debugLayoutCount++;
    final TextScaler scaler = resolved.textScaler;
    final bool anyRuby =
        resolved.showRuby &&
        line.syllables.any((LyricSyllable s) => (s.ruby ?? '').isNotEmpty);
    final double fontSize = style.fontSize ?? 30;
    final TextStyle rubyStyle = resolved.ruby.copyWith(
      fontSize: fontSize * 0.42,
    );
    double rubyHeight = 0;
    if (anyRuby) {
      final TextPainter probe = TextPainter(
        text: TextSpan(text: 'あ', style: rubyStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      rubyHeight = probe.height;
      probe.dispose();
    }
    // 有注音时加大行高（偶数分布），折行后每一视觉行上方都留出注音空间。
    final double scaledFont = scaler.scale(fontSize);
    final TextStyle mainStyle = anyRuby
        ? style.copyWith(
            height: (style.height ?? 1.25) + rubyHeight / scaledFont,
            leadingDistribution: TextLeadingDistribution.even,
          )
        : style;
    final String text = line.text;
    TextPainter painter(TextStyle s) => TextPainter(
      text: TextSpan(text: text, style: s),
      textAlign: align,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(minWidth: width, maxWidth: width);

    final TextPainter base = painter(
      mainStyle.copyWith(color: resolved.inactive),
    );
    final TextPainter active = painter(
      mainStyle.copyWith(color: resolved.active),
    );
    final bool anyOutline = line.syllables.any(
      (LyricSyllable s) => s.fill == LyricFill.outline,
    );
    final TextPainter? outline = anyOutline
        ? painter(
            mainStyle.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = (fontSize / 22).clamp(1.0, 2.5)
                ..color = resolved.active,
            ),
          )
        : null;
    final TextPainter? glow = resolved.glow
        ? painter(
            mainStyle.copyWith(
              color: resolved.active,
              shadows: <Shadow>[
                Shadow(
                  color: resolved.active.withValues(alpha: 0.55),
                  blurRadius: fontSize * 0.45,
                ),
              ],
            ),
          )
        : null;
    final double textTop = anyRuby ? rubyHeight / 2 : 0;
    final List<(double, double)> lineBands = karaokeLineBands(
      base.computeLineMetrics(),
      textTop: textTop,
    );

    final List<KaraokeSyllableGeometry> geoms = <KaraokeSyllableGeometry>[];
    int at = 0;
    for (final LyricSyllable s in line.syllables) {
      final int end = at + s.text.length;
      final List<Rect> boxes = <Rect>[
        for (final TextBox b in base.getBoxesForSelection(
          TextSelection(baseOffset: at, extentOffset: end),
        ))
          if (b.right > b.left) b.toRect().shift(Offset(0, textTop)),
      ];
      final double total = boxes.fold(0.0, (double w, Rect r) => w + r.width);
      TextPainter? rIn;
      TextPainter? rAct;
      Offset rOff = Offset.zero;
      final String ruby = s.ruby ?? '';
      if (anyRuby && ruby.isNotEmpty && boxes.isNotEmpty) {
        TextPainter rp(Color c) => TextPainter(
          text: TextSpan(
            text: ruby,
            style: rubyStyle.copyWith(color: c),
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        rIn = rp(resolved.inactive);
        rAct = rp(resolved.active);
        final Rect first = boxes.first;
        final double top =
            first.top + (first.height - scaledFont * 1.2) / 2 - rIn.height + 1;
        rOff = Offset(first.center.dx - rIn.width / 2, top);
      }
      geoms.add(
        KaraokeSyllableGeometry(
          start: at,
          end: end,
          boxes: boxes,
          totalWidth: total,
          rubyInactive: rIn,
          rubyActive: rAct,
          rubyOffset: rOff,
        ),
      );
      at = end;
    }

    double y = textTop + base.height;
    final List<(TextPainter, Offset)> subs = <(TextPainter, Offset)>[];
    void addSub(String? s) {
      if (s == null || s.trim().isEmpty) return;
      final TextPainter p = TextPainter(
        text: TextSpan(text: s, style: resolved.sub),
        textAlign: align,
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(minWidth: width, maxWidth: width);
      // 副行紧贴主行（用户 2026-10-29 参考图：罗马音 / 翻译贴着主歌词，行与行
      // 之间才留空）。
      y += subs.isEmpty ? 2 : 0;
      subs.add((p, Offset(0, y)));
      y += p.height;
    }

    // 罗马音在上、翻译在下（读音紧挨着原文）。
    if (resolved.showRomanization) addSub(line.romanization);
    if (resolved.showTranslation) addSub(line.primaryTranslation);

    return KaraokeLineLayout._(
      line: line,
      size: Size(width, y),
      textTop: textTop,
      syllables: geoms,
      base: base,
      active: active,
      outline: outline,
      glow: glow,
      subs: subs,
      lineBands: lineBands,
      feather: scaledFont * 0.6,
      lineLevel: lineLevel,
    );
  }

  /// 音节级命中测试：[local] 是行布局坐标。命中返回（音节下标, 行内 UTF-16 下标），
  /// 落在字形框外（行间空白、副行、两侧留白）返回 null。
  ({int syllable, int charIndex})? hitTest(Offset local) {
    for (int i = 0; i < syllables.length; i++) {
      final KaraokeSyllableGeometry g = syllables[i];
      if (!g.boxes.any((Rect r) => _glyphClip(r).contains(local))) continue;
      // 逐字（按 UTF-16，代理对整对）找被点中的那个字；只在命中时算，不在逐帧路径上。
      final String text = line.text;
      int k = g.start;
      while (k < g.end) {
        final int next = (k + 1 < g.end && _isHighSurrogate(text.codeUnitAt(k)))
            ? k + 2
            : k + 1;
        for (final TextBox b in _base.getBoxesForSelection(
          TextSelection(baseOffset: k, extentOffset: next),
        )) {
          if (_glyphClip(
            b.toRect().shift(Offset(0, textTop)),
          ).contains(local)) {
            return (syllable: i, charIndex: k);
          }
        }
        k = next;
      }
      return (syllable: i, charIndex: g.start);
    }
    return null;
  }

  static bool _isHighSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;

  /// 已唱完 [count] 个音节时的裁剪路径缓存（已唱区 / 未唱区）。
  int _cachedDone = -1;
  int _cachedPending = -1;
  Path _donePath = Path();
  Path _futurePath = Path();

  void _ensurePaths(int doneUpTo, int futureFrom) {
    if (doneUpTo == _cachedDone && futureFrom == _cachedPending) return;
    _cachedDone = doneUpTo;
    _cachedPending = futureFrom;
    final Path done = Path();
    final Path future = Path();
    for (int i = 0; i < syllables.length; i++) {
      for (final Rect r in syllables[i].boxes) {
        if (i < doneUpTo) {
          done.addRect(_glyphClip(r));
        } else if (i >= futureFrom) {
          future.addRect(_glyphClip(r));
        }
      }
    }
    _donePath = done;
    _futurePath = future;
  }

  /// [box] 所在视觉行的纵向带。
  (double, double) _bandOf(Rect box) {
    final double y = box.center.dy;
    for (final (double top, double bottom) in _lineBands) {
      if (y < bottom) return (top, bottom);
    }
    return _lineBands.isEmpty
        ? (double.negativeInfinity, double.infinity)
        : _lineBands.last;
  }

  /// 字形框上下各放出一点，容纳超出 tight 框的笔画，但不越出本视觉行的带（折行时不碰
  /// 上下行的字）；左右不放（相邻音节共边，放了会叠画）。
  Rect _glyphClip(Rect r) {
    final (double top, double bottom) = _bandOf(r);
    return Rect.fromLTRB(
      r.left,
      math.max(r.top - r.height * 0.3, top),
      r.right,
      math.min(r.bottom + r.height * 0.3, bottom),
    );
  }

  /// 测试用：音节字形框 [box] 实际参与绘制的裁剪区（含辉光的纵向外扩）。
  @visibleForTesting
  Rect debugPaintClipOf(Rect box) => _glowClip(box, box.width);

  /// 辉光裁剪：横向只到已擦过的宽度，纵向给阴影留一个字高，但同样不越出本视觉行的带。
  Rect _glowClip(Rect box, double fillW) {
    final (double top, double bottom) = _bandOf(box);
    final Rect clip = _glyphClip(box);
    return Rect.fromLTRB(
      box.left,
      math.max(clip.top - box.height, top),
      box.left + fillW,
      math.min(clip.bottom + box.height, bottom),
    );
  }

  /// 静态（非当前行）绘制：整行未唱色 + 注音 + 副行。
  void paintStatic(Canvas canvas, {bool sung = false}) {
    (sung ? _active : _base).paint(canvas, Offset(0, textTop));
    for (final KaraokeSyllableGeometry g in syllables) {
      final TextPainter? r = sung ? g.rubyActive : g.rubyInactive;
      r?.paint(canvas, g.rubyOffset);
    }
    _paintSubs(canvas);
  }

  void _paintSubs(Canvas canvas) {
    for (final (TextPainter p, Offset o) in _subs) {
      p.paint(canvas, o);
    }
  }

  /// 当前行逐帧绘制。[timeMs] 是该行的显示时间；[motion] = false（减弱动态效果 / 墨水屏）
  /// 时不上浮、不呼吸、不辉光，只按进度变色。
  void paintActive(
    Canvas canvas, {
    required int timeMs,
    required bool motion,
    required bool lineLevelSweep,
    required double liftPx,
  }) {
    final List<LyricSyllable> syl = line.syllables;
    if (lineLevel) {
      final double p = karaokeLineLevelProgress(
        line,
        timeMs,
        sweep: lineLevelSweep,
      );
      _paintSweepAll(canvas, p);
      _paintSubs(canvas);
      return;
    }
    // 已唱完且回落结束的前缀、未开始的后缀各画一次；中间逐个处理。
    int doneUpTo = 0;
    while (doneUpTo < syl.length &&
        timeMs >= syl[doneUpTo].endMs + (motion ? kKaraokeSettleMs : 0)) {
      doneUpTo++;
    }
    int futureFrom = syl.length;
    while (futureFrom > doneUpTo && timeMs < syl[futureFrom - 1].startMs) {
      futureFrom--;
    }
    _ensurePaths(doneUpTo, futureFrom);
    final Offset textOrigin = Offset(0, textTop);
    if (doneUpTo > 0) {
      canvas
        ..save()
        ..clipPath(_donePath);
      _active.paint(canvas, textOrigin);
      canvas.restore();
    }
    if (futureFrom < syl.length) {
      canvas
        ..save()
        ..clipPath(_futurePath);
      _base.paint(canvas, textOrigin);
      canvas.restore();
    }
    for (int i = 0; i < syl.length; i++) {
      final KaraokeSyllableGeometry g = syllables[i];
      final LyricSyllable s = syl[i];
      final double p = karaokeSyllableProgress(s, timeMs);
      if (i >= doneUpTo && i < futureFrom) {
        double lift = 0;
        double scale = 1;
        if (motion) {
          if (p > 0 && p < 1) {
            lift = liftPx * karaokeLift(p);
          } else if (p >= 1) {
            final double settle =
                1 - ((timeMs - s.endMs) / kKaraokeSettleMs).clamp(0.0, 1.0);
            lift = liftPx * settle;
          }
          scale = karaokeBreathScale(s, p);
        }
        _paintSyllable(
          canvas,
          g,
          s.fill,
          p,
          lift: lift,
          scale: scale,
          glow: motion && p > 0 && p < 1,
        );
      }
      // 注音跟着本音节的进度擦色。
      final TextPainter? rIn = g.rubyInactive;
      final TextPainter? rAct = g.rubyActive;
      if (rIn != null && rAct != null) {
        if (p <= 0) {
          rIn.paint(canvas, g.rubyOffset);
        } else if (p >= 1) {
          rAct.paint(canvas, g.rubyOffset);
        } else {
          rIn.paint(canvas, g.rubyOffset);
          canvas
            ..save()
            ..clipRect(
              Rect.fromLTWH(
                g.rubyOffset.dx,
                g.rubyOffset.dy,
                rIn.width * p,
                rIn.height,
              ),
            );
          rAct.paint(canvas, g.rubyOffset);
          canvas.restore();
        }
      }
    }
    _paintSubs(canvas);
  }

  /// 行级：整行所有字形框按总宽度线性擦色。
  void _paintSweepAll(Canvas canvas, double p) {
    final KaraokeSyllableGeometry all = KaraokeSyllableGeometry(
      start: 0,
      end: line.text.length,
      boxes: <Rect>[
        for (final KaraokeSyllableGeometry g in syllables) ...g.boxes,
      ],
      totalWidth: syllables.fold(
        0.0,
        (double w, KaraokeSyllableGeometry g) => w + g.totalWidth,
      ),
    );
    _paintSyllable(
      canvas,
      all,
      LyricFill.sweep,
      p,
      lift: 0,
      scale: 1,
      glow: false,
    );
    for (final KaraokeSyllableGeometry g in syllables) {
      (p >= 1 ? g.rubyActive : g.rubyInactive)?.paint(canvas, g.rubyOffset);
    }
  }

  final Paint _featherPaint = Paint()..blendMode = BlendMode.dstIn;

  void _paintSyllable(
    Canvas canvas,
    KaraokeSyllableGeometry g,
    LyricFill fill,
    double p, {
    required double lift,
    required double scale,
    required bool glow,
  }) {
    final Offset textOrigin = Offset(0, textTop);
    double remaining = g.totalWidth * p;
    final Rect bounds = g.bounds;
    for (final Rect box in g.boxes) {
      final Rect clip = _glyphClip(box);
      final (double bandTop, double bandBottom) = _bandOf(box);
      final Rect outer = clip
          .shift(Offset(0, -lift))
          .inflate(scale > 1 ? box.height * 0.1 : 0);
      canvas.save();
      // 呼吸放大只往左右多给，纵向仍不出本视觉行的带（随上浮一起上移）。
      canvas.clipRect(
        Rect.fromLTRB(
          outer.left,
          math.max(outer.top, bandTop - lift),
          outer.right,
          math.min(outer.bottom, bandBottom - lift),
        ),
      );
      if (lift != 0) canvas.translate(0, -lift);
      if (scale != 1) {
        final Offset c = bounds.center;
        canvas
          ..translate(c.dx, c.dy)
          ..scale(scale)
          ..translate(-c.dx, -c.dy);
      }
      canvas
        ..save()
        ..clipRect(clip);
      _base.paint(canvas, textOrigin);
      final double fillW = remaining.clamp(0.0, box.width);
      remaining -= box.width;
      if (fillW > 0) {
        switch (fill) {
          case LyricFill.instant:
            _active.paint(canvas, textOrigin);
          case LyricFill.outline:
            // libass 的 `\ko`：到点填充换成高亮色，同时描边出现（之前不画描边）。
            _active.paint(canvas, textOrigin);
            _outline?.paint(canvas, textOrigin);
          case LyricFill.sweep:
            final double edge = box.left + fillW;
            final double f = fillW >= box.width ? 0 : feather;
            final Rect hard = Rect.fromLTRB(
              box.left,
              clip.top,
              edge - f / 2,
              clip.bottom,
            );
            if (hard.width > 0) {
              canvas
                ..save()
                ..clipRect(hard);
              _active.paint(canvas, textOrigin);
              canvas.restore();
            }
            if (f > 0) {
              final Rect soft = Rect.fromLTRB(
                (edge - f / 2).clamp(box.left, box.right),
                clip.top,
                (edge + f / 2).clamp(box.left, box.right),
                clip.bottom,
              );
              if (soft.width > 0) {
                canvas.saveLayer(soft, Paint());
                canvas.clipRect(soft);
                _active.paint(canvas, textOrigin);
                _featherPaint.shader = ui.Gradient.linear(
                  Offset(edge - f / 2, 0),
                  Offset(edge + f / 2, 0),
                  const <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)],
                );
                canvas.drawRect(soft, _featherPaint);
                canvas.restore();
              }
            }
        }
      }
      final TextPainter? glowPainter = _glow;
      if (glow && glowPainter != null && fillW > 0) {
        canvas.clipRect(_glowClip(box, fillW));
        glowPainter.paint(canvas, textOrigin);
      }
      canvas
        ..restore()
        ..restore();
    }
  }

  void dispose() {
    _base.dispose();
    _active.dispose();
    _outline?.dispose();
    _glow?.dispose();
    for (final (TextPainter p, Offset _) in _subs) {
      p.dispose();
    }
    for (final KaraokeSyllableGeometry g in syllables) {
      g.rubyInactive?.dispose();
      g.rubyActive?.dispose();
    }
  }
}

/// 主文本各视觉行的纵向带（见 [KaraokeLineLayout] 的 `_lineBands`）：相邻两行以「上一行
/// 行框底与下一行行框顶」的中线为界，首行顶为 -∞、末行底为 +∞。[textTop] 是主文本相对
/// 行顶的偏移（注音预留）。
List<(double, double)> karaokeLineBands(
  List<ui.LineMetrics> metrics, {
  required double textTop,
}) {
  final List<ui.LineMetrics> lines = List<ui.LineMetrics>.of(metrics)
    ..sort(
      (ui.LineMetrics a, ui.LineMetrics b) => a.baseline.compareTo(b.baseline),
    );
  final List<(double, double)> out = <(double, double)>[];
  for (int i = 0; i < lines.length; i++) {
    final double top = i == 0
        ? double.negativeInfinity
        : textTop +
              (lines[i - 1].baseline +
                      lines[i - 1].descent +
                      lines[i].baseline -
                      lines[i].ascent) /
                  2;
    final double bottom = i == lines.length - 1
        ? double.infinity
        : textTop +
              (lines[i].baseline +
                      lines[i].descent +
                      lines[i + 1].baseline -
                      lines[i + 1].ascent) /
                  2;
    out.add((top, bottom));
  }
  return out;
}

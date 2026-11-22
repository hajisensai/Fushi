/// 莫奈的歌词栏（移植 folia `MonetLyricsRail.tsx` / `MonetRailLine.tsx` / `MonetRailTokens.tsx`）：
/// 当前句前后各两句按固定轨道堆叠，换行时位置 / 缩放走弹簧、透明度 / 模糊走缓动，进出场
/// 上下滑入滑出；当前句逐词扫亮（字形级前沿 + 羽化），唱过的词带两层光晕，下面跟译文。
///
/// 每行的 TextPainter 量一次缓存（按行下标；字号 / 宽度 / 配色变了整体失效），逐帧只做
/// 弹簧求值与分层绘制。白字排版、上色用图层的 `srcIn` 色彩滤镜，同一份排版画出暗字 /
/// 亮字 / 光晕 / 投影，不为每种颜色各排一遍。
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_lyrics_model.dart';

/// folia `MONET_SCROLL_SPRING`。
const SpringDescription kMonetScrollSpring = SpringDescription(
  mass: 0.82,
  stiffness: 142,
  damping: 28,
);

/// folia `MONET_SCALE_SPRING`。
const SpringDescription kMonetScaleSpring = SpringDescription(
  mass: 0.78,
  stiffness: 150,
  damping: 30,
);

/// folia 透明度 / 模糊 / 退场的缓动 `[0.32, 0.72, 0, 1]`。
const Cubic kMonetFadeCurve = Cubic(0.32, 0.72, 0, 1);

// ---------------------------------------------------------------------------
// 动画通道
// ---------------------------------------------------------------------------

/// 一个数值的动画：要么弹簧（保速度换目标），要么定长缓动。时间单位秒。
class MonetChannel {
  MonetChannel(double value) : _target = value, _from = value;

  double _target;
  SpringSimulation? _sim;
  double _t0 = 0;
  double _from;
  double _duration = 0;
  Curve _curve = kMonetFadeCurve;

  double get target => _target;

  double value(double now) {
    final SpringSimulation? sim = _sim;
    if (sim != null) return sim.x(math.max(0, now - _t0));
    if (_duration <= 0) return _target;
    final double p = ((now - _t0) / _duration).clamp(0.0, 1.0);
    return _from + (_target - _from) * _curve.transform(p);
  }

  double _velocity(double now) => _sim?.dx(math.max(0, now - _t0)) ?? 0;

  /// 动画是否已停在目标上。
  bool settled(double now) {
    final SpringSimulation? sim = _sim;
    if (sim != null) return sim.isDone(math.max(0, now - _t0));
    return _duration <= 0 || now - _t0 >= _duration;
  }

  void snap(double v) {
    _target = v;
    _from = v;
    _sim = null;
    _duration = 0;
  }

  void springTo(double target, double now, SpringDescription spring) {
    if (_sim != null && target == _target) return;
    final double x = value(now);
    final double v = _velocity(now);
    _sim = SpringSimulation(spring, x, target, v);
    _t0 = now;
    _target = target;
  }

  void tweenTo(double target, double now, double duration, [Curve? curve]) {
    if (_sim == null && _duration == duration && target == _target) return;
    _from = value(now);
    _sim = null;
    _t0 = now;
    _duration = duration;
    _target = target;
    _curve = curve ?? kMonetFadeCurve;
  }
}

// ---------------------------------------------------------------------------
// 每行的排版缓存
// ---------------------------------------------------------------------------

/// 词内同一视觉行的一段连续字形（累计坐标 [c0, c1]）。
class MonetGlyphRun {
  const MonetGlyphRun(this.rect, this.c0, this.c1);
  final Rect rect;
  final double c0;
  final double c1;
}

/// 一个计时词的几何：字形累计宽度、字形时间、按行切好的段。
class MonetWordGeom {
  MonetWordGeom({
    required this.startMs,
    required this.endMs,
    required this.offsets,
    required this.timings,
    required this.runs,
  });

  final int startMs;
  final int endMs;

  /// 累计宽度，首项 0。
  final List<double> offsets;
  final List<(int, int)> timings;
  final List<MonetGlyphRun> runs;

  late final Rect bounds = runs.isEmpty
      ? Rect.zero
      : runs
            .map((MonetGlyphRun r) => r.rect)
            .reduce((Rect a, Rect b) => a.expandToInclude(b));
}

/// 一行排好的字：白字 TextPainter、各词几何、译文。
class MonetLineText {
  MonetLineText._({
    required this.painter,
    required this.words,
    required this.lineCount,
    required this.x0,
    required this.track,
    required this.lineEndMs,
  });

  /// 排版一行。[maxWidth] 为正文换行宽度，[contentWidth] 为栏宽（右对齐时用）。
  factory MonetLineText.layout({
    required LyricVisualizerLine line,
    required double fontPx,
    required double translationFontPx,
    required double contentWidth,
    required bool alignEnd,
    required Color trackColor,
  }) {
    final double maxW = math.max(contentWidth - 8, 60);
    List<LyricVisualizerGlyph> glyphs = line.glyphs;
    List<LyricVisualizerWord> words = line.words;
    if (glyphs.isEmpty) {
      glyphs = _evenGlyphs(line);
      words = buildLyricVisualizerWords(glyphs);
    }
    int first = 0;
    int last = glyphs.length - 1;
    while (first <= last && glyphs[first].isSpace) {
      first++;
    }
    while (last >= first && glyphs[last].isSpace) {
      last--;
    }
    final List<int> utf = List<int>.filled(glyphs.length + 1, 0);
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < glyphs.length; i++) {
      utf[i] = sb.length;
      if (i >= first && i <= last) sb.write(glyphs[i].text);
    }
    utf[glyphs.length] = sb.length;
    final String text = sb.isEmpty ? line.text : sb.toString();

    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFFFFFFFF),
          fontSize: fontPx,
          fontWeight: FontWeight.w600,
          height: kMonetLineHeightFactor,
          letterSpacing: 0,
        ),
      ),
      strutStyle: StrutStyle(
        fontSize: fontPx,
        height: kMonetLineHeightFactor,
        forceStrutHeight: true,
      ),
      textAlign: alignEnd ? TextAlign.right : TextAlign.left,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: maxW, maxWidth: maxW);

    final double inflate = fontPx * 0.08;
    final List<MonetWordGeom> geoms = <MonetWordGeom>[];
    if (sb.isNotEmpty) {
      for (final LyricVisualizerWord w in words) {
        final List<double> offsets = <double>[0];
        final List<(int, int)> timings = <(int, int)>[];
        final List<MonetGlyphRun> runs = <MonetGlyphRun>[];
        double c = 0;
        Rect? run;
        double runC0 = 0;
        for (int g = w.firstGlyph; g < w.firstGlyph + w.glyphCount; g++) {
          if (g < first || g > last) continue;
          final LyricVisualizerGlyph gl = glyphs[g];
          for (final TextBox b in painter.getBoxesForSelection(
            TextSelection(baseOffset: utf[g], extentOffset: utf[g + 1]),
          )) {
            final Rect r = Rect.fromLTRB(
              b.left,
              b.top - inflate,
              b.right,
              b.bottom + inflate,
            );
            if (run != null &&
                (r.top - run.top).abs() < 1 &&
                (r.left - run.right).abs() < 1.5) {
              run = run.expandToInclude(r);
            } else {
              if (run != null) runs.add(MonetGlyphRun(run, runC0, c));
              run = r;
              runC0 = c;
            }
            c += r.width;
          }
          offsets.add(c);
          timings.add((gl.startMs, gl.endMs));
        }
        if (run != null) runs.add(MonetGlyphRun(run, runC0, c));
        if (runs.isEmpty) continue;
        geoms.add(
          MonetWordGeom(
            startMs: w.startMs,
            endMs: w.endMs,
            offsets: offsets,
            timings: timings,
            runs: runs,
          ),
        );
      }
    }

    final String? sub = monetIsReadableSubtitle(line.translation)
        ? line.translation!.trim()
        : monetIsReadableSubtitle(line.romanization)
        ? line.romanization!.trim()
        : null;
    TextPainter? track;
    if (sub != null) {
      track = TextPainter(
        text: TextSpan(
          text: sub,
          style: TextStyle(
            color: trackColor,
            fontSize: translationFontPx,
            fontWeight: FontWeight.w500,
            height: kMonetTranslationLineHeightFactor,
            letterSpacing: 0,
          ),
        ),
        maxLines: kMonetTranslationLineLimit,
        ellipsis: '…',
        textAlign: alignEnd ? TextAlign.right : TextAlign.left,
        textDirection: TextDirection.ltr,
      )..layout(minWidth: maxW, maxWidth: maxW);
    }

    return MonetLineText._(
      painter: painter,
      words: geoms,
      lineCount: math.max(1, painter.computeLineMetrics().length),
      x0: alignEnd ? contentWidth - maxW : 0,
      track: track,
      lineEndMs: line.endMs,
    );
  }

  final TextPainter painter;
  final List<MonetWordGeom> words;
  final int lineCount;

  /// 正文在栏内的 x。
  final double x0;

  /// 译文（没有为 null）。
  final TextPainter? track;
  final int lineEndMs;

  int get trackLineCount =>
      track == null ? 0 : math.max(1, track!.computeLineMetrics().length);

  /// 整个盒子（正文 + 当前句的译文）的保留高度。
  double visualHeight(double fontPx, double translationFontPx, bool active) =>
      monetTextBoxHeight(fontPx: fontPx, lineCount: lineCount, active: active) +
      (active
          ? monetTranslationBoxHeight(translationFontPx, trackLineCount)
          : 0);

  void dispose() {
    painter.dispose();
    track?.dispose();
  }

  /// 没有字形时间（空音节）：按字形均分整行。
  static List<LyricVisualizerGlyph> _evenGlyphs(LyricVisualizerLine line) {
    final List<String> chars = line.text.characters.toList();
    final int voiced = chars.where((String c) => c.trim().isNotEmpty).length;
    final double step = voiced == 0 ? 0 : line.durationMs / voiced;
    int k = 0;
    return <LyricVisualizerGlyph>[
      for (final String c in chars)
        () {
          final bool space = c.trim().isEmpty;
          final int s = (line.startMs + step * k).round();
          final int e = space ? s : (line.startMs + step * (k + 1)).round();
          if (!space) k++;
          return LyricVisualizerGlyph(
            text: c,
            startMs: s,
            endMs: e,
            syllableIndex: 0,
            isSpace: space,
          );
        }(),
    ];
  }
}

// ---------------------------------------------------------------------------
// 歌词栏控制器
// ---------------------------------------------------------------------------

/// 一帧的输入。
class MonetRailFrame {
  const MonetRailFrame({
    required this.runtime,
    required this.timeMs,
    required this.now,
    required this.motion,
    required this.palette,
    required this.fontPx,
    required this.inactiveScale,
    required this.translationFontPx,
    required this.alignEnd,
  });

  final LyricVisualizerRuntime runtime;
  final int timeMs;

  /// 墙钟秒数（弹簧 / 缓动）。
  final double now;
  final bool motion;
  final LyricVisualizerPalette palette;
  final double fontPx;
  final double inactiveScale;
  final double translationFontPx;
  final bool alignEnd;
}

class _RailItem {
  _RailItem(this.index, this.status, this.offset)
    : y = MonetChannel(0),
      scale = MonetChannel(1),
      opacity = MonetChannel(0),
      blur = MonetChannel(0);

  final int index;
  MonetLineStatus status;
  int offset;
  final MonetChannel y;
  final MonetChannel scale;
  final MonetChannel opacity;
  final MonetChannel blur;
  int zIndex = 0;
  bool exiting = false;
  double exitEnd = 0;

  /// 变成当前句的时刻（译文淡入用）。
  double activeSince = -1e9;
}

/// 歌词栏的状态（跨帧：动画中的行、排版缓存）。由样式 State 持有、负责 [dispose]。
class MonetRailController {
  final LinkedHashMap<int, MonetLineText> _texts =
      LinkedHashMap<int, MonetLineText>();
  final Map<int, _RailItem> _items = <int, _RailItem>{};
  Object? _cacheKey;
  double? _lastNow;
  bool _fresh = true;

  static const int _cacheLimit = 40;

  /// 换歌：丢掉所有行与排版，下一帧直接就位（不播进场）。
  void reset() {
    _clearTexts();
    _items.clear();
    _fresh = true;
    _lastNow = null;
  }

  void dispose() => _clearTexts();

  void _clearTexts() {
    for (final MonetLineText t in _texts.values) {
      t.dispose();
    }
    _texts.clear();
  }

  MonetLineText _text(MonetRailFrame f, int index, double contentWidth) {
    final MonetLineText? hit = _texts.remove(index);
    if (hit != null) {
      _texts[index] = hit;
      return hit;
    }
    final MonetLineText made = MonetLineText.layout(
      line: f.runtime.lines[index],
      fontPx: f.fontPx,
      translationFontPx: f.translationFontPx,
      contentWidth: contentWidth,
      alignEnd: f.alignEnd,
      trackColor: f.palette.text.withValues(alpha: 0.68),
    );
    _texts[index] = made;
    while (_texts.length > _cacheLimit) {
      final int oldest = _texts.keys.first;
      _texts.remove(oldest)!.dispose();
    }
    return made;
  }

  /// 推进动画并画一帧。[size] 是歌词栏（正文列宽 × 栏高）。
  void paint(Canvas canvas, Size size, MonetRailFrame f) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) return;
    final Object key = Object.hash(
      f.runtime,
      f.fontPx,
      f.translationFontPx,
      w,
      f.alignEnd,
      f.palette,
    );
    if (key != _cacheKey) {
      if (_cacheKey != null && !identical(f.runtime, _lastRuntime)) {
        reset();
      } else {
        _clearTexts();
      }
      _cacheKey = key;
    }
    _lastRuntime = f.runtime;
    final double now = f.now;
    final bool snap =
        _fresh || !f.motion || (_lastNow != null && now < _lastNow!);
    _lastNow = now;
    _fresh = false;

    final List<MonetVisibleEntry> entries = buildMonetVisibleEntries(
      f.runtime,
      f.timeMs,
    );
    final List<MonetLineText> texts = <MonetLineText>[
      for (final MonetVisibleEntry e in entries) _text(f, e.index, w),
    ];
    final List<MonetLineTone> tones = <MonetLineTone>[
      for (final MonetVisibleEntry e in entries)
        monetLineTone(e.status, e.offset, f.inactiveScale),
    ];
    final List<double> scaled = <double>[
      for (int i = 0; i < entries.length; i++)
        texts[i].visualHeight(
              f.fontPx,
              f.translationFontPx,
              entries[i].status == MonetLineStatus.active,
            ) *
            tones[i].scale,
    ];
    final List<double> ys = monetStackPositions(entries, scaled, h, f.fontPx);

    final Set<int> seen = <int>{};
    for (int i = 0; i < entries.length; i++) {
      final MonetVisibleEntry e = entries[i];
      final MonetLineTone tone = tones[i];
      seen.add(e.index);
      _RailItem? item = _items[e.index];
      if (item == null) {
        item = _RailItem(e.index, e.status, e.offset);
        _items[e.index] = item;
        if (!snap) {
          item.y.snap(ys[i] + (e.offset >= 0 ? 34 : -34));
          item.scale.snap(tone.scale * 0.98);
          item.opacity.snap(0);
          item.blur.snap(5);
        }
      }
      if (e.status == MonetLineStatus.active &&
          item.status != MonetLineStatus.active) {
        item.activeSince = now;
      }
      if (snap && e.status == MonetLineStatus.active) {
        item.activeSince = now - 10;
      }
      item
        ..status = e.status
        ..offset = e.offset
        ..zIndex = tone.zIndex
        ..exiting = false;
      if (snap) {
        item.y.snap(ys[i]);
        item.scale.snap(tone.scale);
        item.opacity.snap(tone.opacity);
        item.blur.snap(tone.blurPx);
      } else {
        item.y.springTo(ys[i], now, kMonetScrollSpring);
        item.scale.springTo(tone.scale, now, kMonetScaleSpring);
        item.opacity.tweenTo(tone.opacity, now, 0.28);
        item.blur.tweenTo(tone.blurPx, now, 0.32);
      }
    }
    final List<int> gone = <int>[];
    for (final _RailItem item in _items.values) {
      if (seen.contains(item.index)) continue;
      if (snap || f.runtime.lines.length <= item.index) {
        gone.add(item.index);
        continue;
      }
      if (!item.exiting) {
        item.exiting = true;
        item.exitEnd = now + 0.2;
        final double dy =
            item.status == MonetLineStatus.passed || item.offset < 0 ? -38 : 38;
        item.y.tweenTo(item.y.value(now) + dy, now, 0.2);
        item.scale.tweenTo(item.scale.value(now) * 0.98, now, 0.2);
        item.opacity.tweenTo(0, now, 0.2);
        item.blur.tweenTo(6, now, 0.2);
      } else if (now >= item.exitEnd) {
        gone.add(item.index);
      }
    }
    gone.forEach(_items.remove);
    if (_items.isEmpty) return;

    final double glow = monetGlowBufferPx(f.fontPx);
    final Rect railRect = Rect.fromLTRB(-glow, 0, w + glow, h);
    canvas.saveLayer(railRect, Paint());
    canvas.clipRect(railRect);
    final List<_RailItem> order = _items.values.toList()
      ..sort((_RailItem a, _RailItem b) => a.zIndex.compareTo(b.zIndex));
    for (final _RailItem item in order) {
      _paintItem(canvas, item, _text(f, item.index, w), f, w, glow);
    }
    // 上下渐隐（folia 栏的 mask：0→11% 渐显，88%→100% 渐隐）。
    canvas.drawRect(
      railRect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          const <Color>[
            Color(0x00000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          const <double>[0, 0.11, 0.88, 1],
        ),
    );
    canvas.restore();
  }

  LyricVisualizerRuntime? _lastRuntime;

  /// 当前是否还有动画没停（测试 / 调试用）。
  bool get hasItems => _items.isNotEmpty;

  void _paintItem(
    Canvas canvas,
    _RailItem item,
    MonetLineText lt,
    MonetRailFrame f,
    double w,
    double glow,
  ) {
    final double now = f.now;
    final double fontPx = f.fontPx;
    final bool active = item.status == MonetLineStatus.active;
    final double opacity = item.opacity.value(now).clamp(0.0, 1.0);
    if (opacity <= 0.003) return;
    final double blur = math.max(0, item.blur.value(now));
    final double s = item.scale.value(now);
    final double visual = lt.visualHeight(fontPx, f.translationFontPx, active);
    final double padTop = monetTextPaddingTop(fontPx);
    final double lh = fontPx * kMonetLineHeightFactor;
    final bool clipped = !active && lt.lineCount > kMonetInactiveTextLineLimit;

    canvas.save();
    if (f.alignEnd) {
      canvas.translate(w, item.y.value(now));
      canvas.scale(s);
      canvas.translate(-w, 0);
    } else {
      canvas.translate(0, item.y.value(now));
      canvas.scale(s);
    }
    final Rect bounds = Rect.fromLTRB(-glow, -glow, w + glow, visual + glow);
    final bool layer = opacity < 0.999 || blur > 0.01 || clipped;
    if (layer) {
      final Paint lp = Paint()..color = Color.fromRGBO(0, 0, 0, opacity);
      if (blur > 0.01) {
        lp.imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
      }
      canvas.saveLayer(bounds, lp);
    }
    final double contentBottom =
        padTop + math.min(lt.lineCount, kMonetInactiveTextLineLimit) * lh;
    if (clipped) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(-glow, -glow, w + glow, contentBottom));
    }

    final Offset o = Offset(lt.x0, padTop);
    final Color primary = f.palette.text;
    _paintText(canvas, item, lt, f, o, primary, bounds);

    if (clipped) {
      canvas.restore();
      final double fade = math.max(fontPx * 0.55, 12);
      final Rect fr = Rect.fromLTRB(
        -glow,
        contentBottom - fade,
        w + glow,
        contentBottom,
      );
      canvas.drawRect(
        fr,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            fr.topCenter,
            fr.bottomCenter,
            const <Color>[Color(0xFF000000), Color(0x00000000)],
          ),
      );
    }

    final TextPainter? track = lt.track;
    if (active && track != null) {
      final double p = f.motion
          ? kMonetFadeCurve.transform(
              ((now - item.activeSince) / 0.28).clamp(0.0, 1.0),
            )
          : 1;
      if (p > 0) {
        final double ty =
            monetTextBoxHeight(
              fontPx: fontPx,
              lineCount: lt.lineCount,
              active: true,
            ) +
            monetTranslationPaddingTop(f.translationFontPx) +
            8 * (1 - p);
        if (p < 1) {
          canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, p));
        }
        track.paint(canvas, Offset(lt.x0, ty));
        if (p < 1) canvas.restore();
      }
    }
    if (layer) canvas.restore();
    canvas.restore();
  }

  void _paintText(
    Canvas canvas,
    _RailItem item,
    MonetLineText lt,
    MonetRailFrame f,
    Offset o,
    Color primary,
    Rect bounds,
  ) {
    final int t = f.timeMs;
    final double fontPx = f.fontPx;
    final MonetLineStatus status = item.status;
    final Color wordColor = primary.withValues(alpha: 0.98);

    if (status == MonetLineStatus.active) {
      // 当前句的投影：`0 14px 34px 背景色@0.22`。
      _tinted(
        canvas,
        lt.painter,
        o.translate(0, 14),
        f.palette.background.withValues(alpha: 0.22),
        bounds.inflate(40),
        filter: ui.ImageFilter.blur(sigmaX: 17, sigmaY: 17),
      );
    }

    // 光晕：唱过 / 正在唱的词，按亮度分组，每组两层（半径 0.28 / 0.65 倍字号）。
    if (status != MonetLineStatus.waiting) {
      final Map<int, Path> groups = <int, Path>{};
      final Map<int, Rect> groupBounds = <int, Rect>{};
      for (final MonetWordGeom w in lt.words) {
        final double g = monetGlow(t, w.startMs, w.endMs, lt.lineEndMs);
        if (g <= 0.02) continue;
        final int q = (g * 10).round().clamp(1, 10);
        final Path path = groups.putIfAbsent(q, Path.new);
        for (final MonetGlyphRun r in w.runs) {
          path.addRect(r.rect.shift(o));
        }
        groupBounds[q] =
            groupBounds[q]?.expandToInclude(w.bounds.shift(o)) ??
            w.bounds.shift(o);
      }
      final Color glowColor = primary.withValues(alpha: 0.88);
      for (final MapEntry<int, Path> g in groups.entries) {
        final double alpha = g.key / 10;
        for (final double radius in <double>[fontPx * 0.28, fontPx * 0.65]) {
          final double sigma = radius / 2;
          _tinted(
            canvas,
            lt.painter,
            o,
            glowColor.withValues(alpha: glowColor.a * alpha),
            groupBounds[g.key]!.inflate(sigma * 3),
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            clip: g.value,
          );
        }
      }
    }

    final double baseAlpha = switch (status) {
      MonetLineStatus.active => 0.34,
      MonetLineStatus.waiting => 0.46,
      MonetLineStatus.passed => 0.36,
    };
    if (status == MonetLineStatus.passed) {
      // 唱完的句子：计时词整句亮色。
      _tinted(canvas, lt.painter, o, wordColor, bounds);
      return;
    }
    _tinted(
      canvas,
      lt.painter,
      o,
      primary.withValues(alpha: baseAlpha),
      bounds,
    );
    if (status != MonetLineStatus.active) return;

    final Color base = primary.withValues(alpha: baseAlpha);
    final Path lit = Path();
    bool anyLit = false;
    for (final MonetWordGeom w in lt.words) {
      if (t >= w.endMs) {
        for (final MonetGlyphRun r in w.runs) {
          lit.addRect(r.rect.shift(o));
        }
        anyLit = true;
      }
    }
    if (anyLit) _tinted(canvas, lt.painter, o, wordColor, bounds, clip: lit);

    final double edge = monetSweepEdgeSoftness(fontPx);
    for (final MonetWordGeom w in lt.words) {
      if (t <= w.startMs || t >= w.endMs) continue;
      final double progress =
          (t - w.startMs) / math.max(1, w.endMs - w.startMs);
      final double full = w.offsets.last;
      final double fill = monetFillWidth(
        t,
        w.startMs,
        w.endMs,
        w.offsets,
        w.timings,
      );
      final double sweepEnd = monetSweepEnd(fill, full, edge);
      final Rect wb = w.bounds.shift(o);
      final Path clip = Path();
      for (final MonetGlyphRun r in w.runs) {
        clip.addRect(r.rect.shift(o));
      }
      canvas.saveLayer(wb, Paint());
      _tinted(
        canvas,
        lt.painter,
        o,
        Color.lerp(base, wordColor, progress)!,
        wb,
        clip: clip,
      );
      for (final MonetGlyphRun r in w.runs) {
        final Rect rr = r.rect.shift(o);
        final List<(double, double)> stops = monetSweepMaskStops(
          r.c0,
          r.c1,
          sweepEnd,
          edge,
          full,
        );
        canvas.drawRect(
          rr,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = ui.Gradient.linear(
              rr.centerLeft,
              rr.centerRight,
              <Color>[
                for (final (double, double) s in stops)
                  Color.fromRGBO(0, 0, 0, s.$2.clamp(0.0, 1.0)),
              ],
              <double>[for (final (double, double) s in stops) s.$1],
            ),
        );
      }
      canvas.restore();
    }
  }

  /// 把白字排版染成 [color] 画出（可带模糊 / 裁剪）。
  static void _tinted(
    Canvas canvas,
    TextPainter painter,
    Offset o,
    Color color,
    Rect bounds, {
    ui.ImageFilter? filter,
    Path? clip,
  }) {
    final Paint p = Paint()
      ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn);
    if (filter != null) p.imageFilter = filter;
    canvas.saveLayer(bounds, p);
    if (clip != null) canvas.clipPath(clip);
    painter.paint(canvas, o);
    canvas.restore();
  }
}

/// 歌词栏画家：每帧把 [frame] 交给 [controller]。
class MonetRailPainter extends CustomPainter {
  MonetRailPainter({required this.controller, required this.frame});

  final MonetRailController controller;
  final MonetRailFrame frame;

  @override
  void paint(Canvas canvas, Size size) => controller.paint(canvas, size, frame);

  @override
  bool shouldRepaint(covariant MonetRailPainter old) => true;
}

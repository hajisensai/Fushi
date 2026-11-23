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
    this.color,
  });

  final int startMs;
  final int endMs;

  /// 主题按词着色命中的颜色（folia `tokenColors`）；null = 用行的扫字色。
  final Color? color;

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

/// 当前句下面的一行副字幕（folia `MonetSubtitleTrackLayout`）：双行时第二行字号 0.88、上间距
/// 0.25em、透明度再乘 0.82。
class MonetSubtitleTrack {
  MonetSubtitleTrack._({
    required this.painter,
    required this.fontPx,
    required this.secondary,
  });

  final TextPainter painter;
  final double fontPx;
  final bool secondary;

  int get lineCount => math.max(1, painter.computeLineMetrics().length);

  double get paddingTop => secondary
      ? fontPx * kLyricVisualizerSecondarySubtitleGapEm
      : monetTranslationPaddingTop(fontPx);

  /// 这一行的保留高度（上下内边距 + 可见行）。
  double get height =>
      paddingTop +
      math.min(lineCount, kMonetTranslationLineLimit) *
          fontPx *
          kMonetTranslationLineHeightFactor +
      monetTranslationPaddingBottom(fontPx);
}

/// 一行排好的字：白字 TextPainter、各词几何、副字幕。
class MonetLineText {
  MonetLineText._({
    required this.painter,
    required this.words,
    required this.lineCount,
    required this.x0,
    required this.tracks,
    required this.lineEndMs,
    this.isChorus = false,
  });

  /// 排版一行。[maxWidth] 为正文换行宽度，[contentWidth] 为栏宽（右对齐时用）。[theme] 有按词着色
  /// 时给命中的词记上颜色；[textStyle] 带主题字体 / 字重。副字幕按 [subtitle]（全局字幕偏好：
  /// 译文 / 罗马音 / 两行 / 不要）取行，[trackStyle] 已套字幕字体。
  factory MonetLineText.layout({
    required LyricVisualizerLine line,
    required double fontPx,
    required double translationFontPx,
    required double contentWidth,
    required bool alignEnd,
    required Color trackColor,
    LyricVisualizerTheme? theme,
    TextStyle textStyle = const TextStyle(fontWeight: FontWeight.w600),
    TextStyle trackStyle = const TextStyle(fontWeight: FontWeight.w500),
    LyricVisualizerSubtitleSettings subtitle =
        LyricVisualizerSubtitleSettings.defaults,
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
    final List<LyricVisualizerWordColorRange> colorRanges =
        theme != null && theme.hasWordColors && sb.isNotEmpty
        ? theme.colorRangesFor(text)
        : const <LyricVisualizerWordColorRange>[];

    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: textStyle.copyWith(
          color: const Color(0xFFFFFFFF),
          fontSize: fontPx,
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
        final int wFirst = math.max(w.firstGlyph, first);
        final int wEnd = math.min(w.firstGlyph + w.glyphCount, last + 1);
        geoms.add(
          MonetWordGeom(
            startMs: w.startMs,
            endMs: w.endMs,
            offsets: offsets,
            timings: timings,
            runs: runs,
            color: colorRanges.isEmpty || wEnd <= wFirst
                ? null
                : LyricVisualizerTheme.colorForSpan(
                    colorRanges,
                    utf[wFirst],
                    utf[wEnd],
                  ),
          ),
        );
      }
    }

    final List<LyricVisualizerSubtitleRow> rows = subtitle.rowsFor(
      lineText: line.text,
      translation: line.translation,
      romanization: line.romanization,
    );
    final List<MonetSubtitleTrack> tracks = <MonetSubtitleTrack>[
      for (int r = 0; r < rows.length; r++)
        () {
          final bool secondary = r > 0;
          final double px = secondary
              ? translationFontPx * kLyricVisualizerSecondarySubtitleSize
              : translationFontPx;
          return MonetSubtitleTrack._(
            fontPx: px,
            secondary: secondary,
            painter: TextPainter(
              text: TextSpan(
                text: rows[r].text,
                style: trackStyle.copyWith(
                  color: secondary
                      ? trackColor.withValues(
                          alpha:
                              trackColor.a *
                              kLyricVisualizerSecondarySubtitleOpacity,
                        )
                      : trackColor,
                  fontSize: px,
                  fontWeight: secondary
                      ? theme?.fontWeight ??
                            kLyricVisualizerSecondarySubtitleWeight
                      : trackStyle.fontWeight,
                  height: kMonetTranslationLineHeightFactor,
                  letterSpacing: 0,
                ),
              ),
              maxLines: kMonetTranslationLineLimit,
              ellipsis: '…',
              textAlign: alignEnd ? TextAlign.right : TextAlign.left,
              textDirection: TextDirection.ltr,
            )..layout(minWidth: maxW, maxWidth: maxW),
          );
        }(),
    ];

    return MonetLineText._(
      painter: painter,
      words: geoms,
      lineCount: math.max(1, painter.computeLineMetrics().length),
      x0: alignEnd ? contentWidth - maxW : 0,
      tracks: tracks,
      // folia `getLineRenderEndTime`：光晕留到句尾离场窗口结束。
      lineEndMs: line.renderEndMs,
      isChorus: line.isChorus,
    );
  }

  final TextPainter painter;
  final List<MonetWordGeom> words;
  final int lineCount;

  /// 正文在栏内的 x。
  final double x0;

  /// 副字幕行（没有为空；只在当前句画）。
  final List<MonetSubtitleTrack> tracks;
  final int lineEndMs;

  /// 副歌行（folia `line.isChorus`）：强调色光晕、扫字色混强调色、光晕更大。
  final bool isChorus;

  /// 副字幕各行合计的保留高度。
  double get tracksHeight {
    double h = 0;
    for (final MonetSubtitleTrack t in tracks) {
      h += t.height;
    }
    return h;
  }

  /// 整个盒子（正文 + 当前句的副字幕）的保留高度。
  double visualHeight(double fontPx, bool active) =>
      monetTextBoxHeight(fontPx: fontPx, lineCount: lineCount, active: active) +
      (active ? tracksHeight : 0);

  void dispose() {
    painter.dispose();
    for (final MonetSubtitleTrack t in tracks) {
      t.painter.dispose();
    }
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
    this.theme,
    this.keywordColoring = true,
    this.textStyle = const TextStyle(fontWeight: FontWeight.w600),
    this.trackStyle = const TextStyle(fontWeight: FontWeight.w500),
    this.subtitle = LyricVisualizerSubtitleSettings.defaults,
  });

  /// 全局字幕偏好（取哪几行副字幕）。
  final LyricVisualizerSubtitleSettings subtitle;

  /// 本首的歌词动画主题（按词着色）。
  final LyricVisualizerTheme? theme;

  /// folia `keywordColoringEnabled`。
  final bool keywordColoring;

  /// 正文 / 译文的字体与字重（已套主题字体）。
  final TextStyle textStyle;
  final TextStyle trackStyle;

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
      blur = MonetChannel(0),
      chorusGlow = MonetChannel(0),
      chorusScale = MonetChannel(0.96);

  final int index;
  MonetLineStatus status;
  int offset;
  final MonetChannel y;
  final MonetChannel scale;
  final MonetChannel opacity;
  final MonetChannel blur;

  /// 副歌光晕的透明度 / 缩放（folia：当前句 1 / 1.02，否则 0 / 0.96，0.45 秒 easeOut）。
  final MonetChannel chorusGlow;
  final MonetChannel chorusScale;
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
      theme: f.keywordColoring ? f.theme : null,
      textStyle: f.textStyle,
      trackStyle: f.trackStyle,
      subtitle: f.subtitle,
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
      f.keywordColoring ? f.theme : null,
      f.textStyle,
      f.trackStyle,
      f.subtitle,
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
      final bool chorusOn = e.status == MonetLineStatus.active;
      if (snap) {
        item.y.snap(ys[i]);
        item.scale.snap(tone.scale);
        item.opacity.snap(tone.opacity);
        item.blur.snap(tone.blurPx);
        item.chorusGlow.snap(chorusOn ? 1 : 0);
        item.chorusScale.snap(chorusOn ? 1.02 : 0.96);
      } else {
        item.y.springTo(ys[i], now, kMonetScrollSpring);
        item.scale.springTo(tone.scale, now, kMonetScaleSpring);
        item.opacity.tweenTo(tone.opacity, now, 0.28);
        item.blur.tweenTo(tone.blurPx, now, 0.32);
        item.chorusGlow.tweenTo(chorusOn ? 1 : 0, now, 0.45, Curves.easeOut);
        item.chorusScale.tweenTo(
          chorusOn ? 1.02 : 0.96,
          now,
          0.45,
          Curves.easeOut,
        );
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
    final double visual = lt.visualHeight(fontPx, active);
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
    // 副歌光晕上下各伸出 56px，图层要包住它。
    final double haloPad = lt.isChorus ? 56 : 0;
    final Rect bounds = Rect.fromLTRB(
      -glow,
      -glow - haloPad,
      w + glow,
      visual + glow + haloPad,
    );
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

    if (lt.isChorus) _paintChorusHalo(canvas, item, f, w, visual);

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

    if (active && lt.tracks.isNotEmpty) {
      double top = monetTextBoxHeight(
        fontPx: fontPx,
        lineCount: lt.lineCount,
        active: true,
      );
      for (int r = 0; r < lt.tracks.length; r++) {
        final MonetSubtitleTrack track = lt.tracks[r];
        // 各行 0.28 秒淡入上移，第二行晚 0.04 秒（folia `MONET_SUBTITLE_TRACK_STAGGER_S`）。
        final double p = f.motion
            ? kMonetFadeCurve.transform(
                ((now - item.activeSince - r * 0.04) / 0.28).clamp(0.0, 1.0),
              )
            : 1;
        if (p > 0) {
          final double ty = top + track.paddingTop + 8 * (1 - p);
          if (p < 1) {
            canvas.saveLayer(
              bounds,
              Paint()..color = Color.fromRGBO(0, 0, 0, p),
            );
          }
          track.painter.paint(canvas, Offset(lt.x0, ty));
          if (p < 1) canvas.restore();
        }
        top += track.height;
      }
    }
    if (layer) canvas.restore();
    canvas.restore();
  }

  /// folia 副歌行背后的强调色椭圆光晕：贴着行盒左右、上下各伸出 56px，`closest-side` 径向渐变，
  /// 到边缘之前就淡没（不需要模糊）。
  static const List<(double, double)> _chorusGlowStops = <(double, double)>[
    (0.14, 0),
    (0.12, 0.15),
    (0.085, 0.35),
    (0.05, 0.55),
    (0.022, 0.72),
    (0.007, 0.87),
  ];

  void _paintChorusHalo(
    Canvas canvas,
    _RailItem item,
    MonetRailFrame f,
    double w,
    double visual,
  ) {
    final double a = item.chorusGlow.value(f.now).clamp(0.0, 1.0);
    if (a <= 0.003) return;
    final Rect box = Rect.fromLTRB(0, -56, w, visual + 56);
    final double rx = box.width / 2;
    final double ry = box.height / 2;
    if (rx <= 0 || ry <= 0) return;
    final double s = item.chorusScale.value(f.now);
    final Color accent = f.palette.accent;
    canvas.save();
    canvas.translate(box.center.dx, box.center.dy);
    canvas.scale(s * rx / ry, s);
    canvas.drawCircle(
      Offset.zero,
      ry,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          ry,
          <Color>[
            for (final (double, double) st in _chorusGlowStops)
              accent.withValues(alpha: st.$1 * a),
            accent.withValues(alpha: 0),
          ],
          <double>[
            for (final (double, double) st in _chorusGlowStops) st.$2,
            1,
          ],
        ),
    );
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
    // folia：扫字色是主色@0.98；副歌行混 48% 强调色。按词着色命中的词用主题色。
    final Color lineColor = primary.withValues(alpha: 0.98);
    final Color wordColor = lt.isChorus
        ? Color.lerp(lineColor, f.palette.accent, 0.48)!
        : lineColor;
    Color colorOf(MonetWordGeom w) => w.color ?? wordColor;
    final bool anyThemed = lt.words.any((MonetWordGeom w) => w.color != null);

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

    // 光晕：唱过 / 正在唱的词，按（亮度, 颜色）分组，每组两层（半径 0.28 / 0.65 倍字号；副歌
    // 0.45 / 0.90，不透明度 1 而非 0.88）。
    if (status != MonetLineStatus.waiting) {
      final Map<(int, int), Path> groups = <(int, int), Path>{};
      final Map<(int, int), Rect> groupBounds = <(int, int), Rect>{};
      for (final MonetWordGeom w in lt.words) {
        final double g = monetGlow(t, w.startMs, w.endMs, lt.lineEndMs);
        if (g <= 0.02) continue;
        final (int, int) k = (
          (g * 10).round().clamp(1, 10),
          colorOf(w).toARGB32(),
        );
        final Path path = groups.putIfAbsent(k, Path.new);
        for (final MonetGlyphRun r in w.runs) {
          path.addRect(r.rect.shift(o));
        }
        groupBounds[k] =
            groupBounds[k]?.expandToInclude(w.bounds.shift(o)) ??
            w.bounds.shift(o);
      }
      final double glowAlpha = lt.isChorus ? 1.0 : 0.88;
      final List<double> radii = lt.isChorus
          ? <double>[fontPx * 0.45, fontPx * 0.90]
          : <double>[fontPx * 0.28, fontPx * 0.65];
      for (final MapEntry<(int, int), Path> g in groups.entries) {
        final double alpha = g.key.$1 / 10;
        final Color glowColor = Color(g.key.$2).withValues(alpha: glowAlpha);
        for (final double radius in radii) {
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

    void paintThemed(bool Function(MonetWordGeom w) include) {
      if (!anyThemed) return;
      final Map<int, Path> byColor = <int, Path>{};
      for (final MonetWordGeom w in lt.words) {
        final Color? c = w.color;
        if (c == null || !include(w)) continue;
        final Path p = byColor.putIfAbsent(c.toARGB32(), Path.new);
        for (final MonetGlyphRun r in w.runs) {
          p.addRect(r.rect.shift(o));
        }
      }
      for (final MapEntry<int, Path> e in byColor.entries) {
        _tinted(canvas, lt.painter, o, Color(e.key), bounds, clip: e.value);
      }
    }

    final double baseAlpha = switch (status) {
      MonetLineStatus.active => 0.34,
      MonetLineStatus.waiting => 0.46,
      MonetLineStatus.passed => 0.36,
    };
    if (status == MonetLineStatus.passed) {
      // 唱完的句子：计时词整句亮色（着色词用主题色）。
      _tinted(canvas, lt.painter, o, wordColor, bounds);
      paintThemed((MonetWordGeom _) => true);
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
    paintThemed((MonetWordGeom w) => t >= w.endMs);

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
        Color.lerp(base, colorOf(w), progress)!,
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

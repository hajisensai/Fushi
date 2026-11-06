import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_core/fushi_core.dart';

import '../audiobook/audiobook_model.dart';
import 'subtitle_markup.dart';

/// 把 `ffc_parse_subtitle_*` 的结果字节块解码成 [AudioCue] / [SubtitleMarkup]。
///
/// 字段顺序与 native/fushi_compute/src/parse/subtitle.rs 的 `Out::write_*` 一一对应；
/// 对象形态（可变 / 不可变列表、`const []`、共享的样式对象）与旧 Dart 解析器保持一致。

const List<String?> _kModes = <String?>[null, 'k', 'kf', 'ko'];

SubtitleSpan _readSpan(
  SubtitleNativeReader r, {
  required int start,
  required int end,
  required bool withK,
}) {
  final int mask = r.u32();
  bool has(int bit) => mask & (1 << bit) != 0;
  final int? color = has(4) ? r.i64() : null;
  final double? fontSize = has(5) ? r.f64() : null;
  final String? fontName = has(6) ? r.string() : null;
  final int? outlineColor = has(7) ? r.i64() : null;
  final int? shadowColor = has(8) ? r.i64() : null;
  final double? outlineWidth = has(9) ? r.f64() : null;
  final double? shadowDepth = has(10) ? r.f64() : null;
  final double? blur = has(11) ? r.f64() : null;
  final double? fillOpacity = has(12) ? r.f64() : null;
  final double? letterSpacing = has(13) ? r.f64() : null;
  final double? scaleX = has(14) ? r.f64() : null;
  final double? scaleY = has(15) ? r.f64() : null;
  final String? kMode = withK && has(16) ? _kModes[r.u8()] : null;
  final int? kStart = withK && has(17) ? r.i64() : null;
  final int? kDur = withK && has(18) ? r.i64() : null;
  return SubtitleSpan(
    startGrapheme: start,
    endGrapheme: end,
    italic: has(0),
    bold: has(1),
    underline: has(2),
    strike: has(3),
    colorArgb: color,
    fontSizePx: fontSize,
    fontName: fontName,
    outlineColorArgb: outlineColor,
    shadowColorArgb: shadowColor,
    outlineWidthPx: outlineWidth,
    shadowDepthPx: shadowDepth,
    blur: blur,
    fillOpacity: fillOpacity,
    letterSpacingPx: letterSpacing,
    scaleX: scaleX,
    scaleY: scaleY,
    kMode: kMode,
    kStartCs: kStart,
    kDurCs: kDur,
  );
}

List<SubtitleClipSegment> _readSegments(SubtitleNativeReader r) {
  final int n = r.u32();
  final List<SubtitleClipSegment> out = <SubtitleClipSegment>[];
  for (int i = 0; i < n; i++) {
    final int op = r.u8();
    final double x1 = r.f64();
    final double y1 = r.f64();
    switch (op) {
      case 0:
        out.add(SubtitleClipSegment.move(x1, y1));
      case 1:
        out.add(SubtitleClipSegment.line(x1, y1));
      default:
        out.add(
          SubtitleClipSegment.cubic(x1, y1, r.f64(), r.f64(), r.f64(), r.f64()),
        );
    }
  }
  return out;
}

(int?, int?) _readOptPair(SubtitleNativeReader r) {
  final int m = r.u8();
  final int? a = m & 1 != 0 ? r.i64() : null;
  final int? b = m & 2 != 0 ? r.i64() : null;
  return (a, b);
}

/// 读一条 markup 记录。[cueStyle] 原样透传，行内无 `\an` 时回退它的 anchor。
SubtitleMarkup readSubtitleMarkup(
  SubtitleNativeReader r, {
  double? playResX,
  double? playResY,
  SubtitleCueStyle? cueStyle,
}) {
  final int mask = r.u32();
  bool has(int bit) => mask & (1 << bit) != 0;
  final String plainText = r.string();
  final int layer = r.i64();
  final List<SubtitleSpan> spans = <SubtitleSpan>[];
  if (has(0)) {
    final int n = r.u32();
    for (int i = 0; i < n; i++) {
      final int start = r.i64();
      final int end = r.i64();
      spans.add(_readSpan(r, start: start, end: end, withK: true));
    }
  }
  final SubtitleAnchor? anchor = has(1)
      ? SubtitleAnchor.fromAnCode(r.u8())
      : null;
  final SubtitlePos? pos = has(2) ? SubtitlePos(r.f64(), r.f64()) : null;
  List<int> breaks = const <int>[];
  if (has(3)) {
    final int n = r.u32();
    breaks = <int>[for (int i = 0; i < n; i++) r.i64()];
  }
  SubtitleFade? fade;
  if (has(4)) {
    if (r.u8() == 0) {
      fade = SubtitleFade.simple(r.i64(), r.i64());
    } else {
      fade = SubtitleFade.full(
        op1: r.f64(),
        op2: r.f64(),
        op3: r.f64(),
        t1: r.i64(),
        t2: r.i64(),
        t3: r.i64(),
        t4: r.i64(),
      );
    }
  }
  final double? rotation = has(5) ? r.f64() : null;
  SubtitleScale? scale;
  if (has(6)) {
    final double fromX = r.f64();
    final double fromY = r.f64();
    final double toX = r.f64();
    final double toY = r.f64();
    final (int? t1, int? t2) = _readOptPair(r);
    scale = SubtitleScale(
      fromX: fromX,
      fromY: fromY,
      toX: toX,
      toY: toY,
      t1Ms: t1,
      t2Ms: t2,
    );
  }
  SubtitleMove? move;
  if (has(7)) {
    final double x1 = r.f64();
    final double y1 = r.f64();
    final double x2 = r.f64();
    final double y2 = r.f64();
    final (int? t1, int? t2) = _readOptPair(r);
    move = SubtitleMove(x1, y1, x2, y2, t1Ms: t1, t2Ms: t2);
  }
  SubtitleClip? clip;
  if (has(8)) {
    final bool inverse = r.u8() != 0;
    clip = SubtitleClip(inverse: inverse, segments: _readSegments(r));
  }
  final List<SubtitleTransition> transitions = <SubtitleTransition>[];
  if (has(9)) {
    final int n = r.u32();
    for (int i = 0; i < n; i++) {
      final int tm = r.u8();
      bool t(int bit) => tm & (1 << bit) != 0;
      final int? t1 = t(0) ? r.i64() : null;
      final int? t2 = t(1) ? r.i64() : null;
      final double accel = r.f64();
      transitions.add(
        SubtitleTransition(
          t1Ms: t1,
          t2Ms: t2,
          accel: accel,
          alphaTo: t(2) ? r.f64() : null,
          colorToArgb: t(3) ? r.i64() : null,
          blurTo: t(4) ? r.f64() : null,
          bordTo: t(5) ? r.f64() : null,
          frzToDeg: t(6) ? r.f64() : null,
        ),
      );
    }
  }
  final double? frx = has(10) ? r.f64() : null;
  final double? fry = has(11) ? r.f64() : null;
  final double? fax = has(12) ? r.f64() : null;
  final double? fay = has(13) ? r.f64() : null;
  SubtitleDrawing? drawing;
  if (has(14)) {
    final List<SubtitleClipSegment> segments = _readSegments(r);
    drawing = SubtitleDrawing(
      segments: segments,
      minX: r.f64(),
      minY: r.f64(),
      maxX: r.f64(),
      maxY: r.f64(),
      baselineOffsetFraction: r.f64(),
    );
  }
  final SubtitleSpan? drawingStyle = has(15)
      ? _readSpan(r, start: 0, end: 0, withK: false)
      : null;
  return SubtitleMarkup(
    plainText: plainText,
    spans: spans,
    anchor: anchor ?? cueStyle?.anchor,
    posFraction: pos,
    cueStyle: cueStyle,
    playResY: playResY,
    playResX: playResX,
    lineBreakGraphemes: breaks,
    fade: fade,
    rotationDeg: rotation,
    scale: scale,
    move: move,
    layer: layer,
    clip: clip,
    transitions: List<SubtitleTransition>.unmodifiable(transitions),
    rotationXDeg: frx,
    rotationYDeg: fry,
    shearX: fax,
    shearY: fay,
    drawing: drawing,
    drawingStyle: drawingStyle,
  );
}

SubtitleCueStyle _readCueStyle(SubtitleNativeReader r) {
  final int mask = r.u32();
  bool has(int bit) => mask & (1 << bit) != 0;
  final String? fontName = has(0) ? r.string() : null;
  final int? primary = has(1) ? r.i64() : null;
  final int? outline = has(2) ? r.i64() : null;
  final int? shadow = has(3) ? r.i64() : null;
  final double? fontSize = has(4) ? r.f64() : null;
  final double? outlineWidth = has(5) ? r.f64() : null;
  final double? shadowDepth = has(6) ? r.f64() : null;
  final bool? bold = has(7) ? r.u8() != 0 : null;
  final bool? italic = has(8) ? r.u8() != 0 : null;
  final bool? underline = has(9) ? r.u8() != 0 : null;
  final bool? strikeOut = has(10) ? r.u8() != 0 : null;
  final SubtitleAnchor? anchor = has(11)
      ? SubtitleAnchor.fromAnCode(r.u8())
      : null;
  final double? marginV = has(12) ? r.f64() : null;
  final double? marginL = has(13) ? r.f64() : null;
  final double? marginR = has(14) ? r.f64() : null;
  final int? secondary = has(15) ? r.i64() : null;
  final double? spacing = has(16) ? r.f64() : null;
  final double? angle = has(17) ? r.f64() : null;
  final double? scaleX = has(18) ? r.f64() : null;
  final double? scaleY = has(19) ? r.f64() : null;
  return SubtitleCueStyle(
    fontName: fontName,
    primaryColorArgb: primary,
    outlineColorArgb: outline,
    shadowColorArgb: shadow,
    fontSizePx: fontSize,
    outlineWidthPx: outlineWidth,
    shadowDepthPx: shadowDepth,
    bold: bold,
    italic: italic,
    underline: underline,
    strikeOut: strikeOut,
    anchor: anchor,
    marginV: marginV,
    marginL: marginL,
    marginR: marginR,
    secondaryColorArgb: secondary,
    spacingPx: spacing,
    angleDeg: angle,
    scaleXPct: scaleX,
    scaleYPct: scaleY,
  );
}

AudioCue _cue({
  required String bookKey,
  required String chapterHref,
  required int audioFileIndex,
  required int index,
  required int startMs,
  required int endMs,
  required SubtitleMarkup markup,
}) {
  return AudioCue()
    ..bookKey = bookKey
    ..chapterHref = chapterHref
    ..sentenceIndex = index
    ..textFragmentId = '[data-cue-id="$index"]'
    ..text = markup.plainText
    ..markup = markup
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = audioFileIndex;
}

/// 解码 SRT / WebVTT 结果（并释放）。异常结果按原类型抛出。
List<AudioCue> decodeSubtitleCues(
  SubtitleNativeResult result, {
  required String bookKey,
  required String chapterHref,
  required int audioFileIndex,
}) {
  result.throwIfError();
  try {
    final SubtitleNativeReader r = result.reader();
    final int n = r.u32();
    final List<AudioCue> cues = <AudioCue>[];
    for (int i = 0; i < n; i++) {
      final int startMs = r.i64();
      final int endMs = r.i64();
      cues.add(
        _cue(
          bookKey: bookKey,
          chapterHref: chapterHref,
          audioFileIndex: audioFileIndex,
          index: i,
          startMs: startMs,
          endMs: endMs,
          markup: readSubtitleMarkup(r),
        ),
      );
    }
    return cues;
  } finally {
    result.free();
  }
}

/// 解码 ASS 结果（并释放）。样式表里的每个样式对象只建一次、被引用它的 cue 共享；
/// 有 Dialogue 行级 Margin 覆盖的 cue 走 `withEventMargins` 克隆（同旧实现）。
List<AudioCue> decodeAssCues(
  SubtitleNativeResult result, {
  required String bookKey,
  required String chapterHref,
  required int audioFileIndex,
}) {
  result.throwIfError();
  try {
    final SubtitleNativeReader r = result.reader();
    final int skipped = r.u32();
    final int styleCount = r.u32();
    final List<SubtitleCueStyle> styles = <SubtitleCueStyle>[
      for (int i = 0; i < styleCount; i++) _readCueStyle(r),
    ];
    final int n = r.u32();
    final List<AudioCue> cues = <AudioCue>[];
    for (int i = 0; i < n; i++) {
      final int startMs = r.i64();
      final int endMs = r.i64();
      final int styleId = r.i32();
      final int marginMask = r.u8();
      final double? evL = marginMask & 1 != 0 ? r.f64() : null;
      final double? evR = marginMask & 2 != 0 ? r.f64() : null;
      final double? evV = marginMask & 4 != 0 ? r.f64() : null;
      final double playResX = r.f64();
      final double playResY = r.f64();
      SubtitleCueStyle? cueStyle = styleId >= 0 ? styles[styleId] : null;
      if (evL != null || evR != null || evV != null) {
        cueStyle = (cueStyle ?? const SubtitleCueStyle()).withEventMargins(
          marginL: evL,
          marginR: evR,
          marginV: evV,
        );
      }
      cues.add(
        _cue(
          bookKey: bookKey,
          chapterHref: chapterHref,
          audioFileIndex: audioFileIndex,
          index: i,
          startMs: startMs,
          endMs: endMs,
          markup: readSubtitleMarkup(
            r,
            playResX: playResX,
            playResY: playResY,
            cueStyle: cueStyle,
          ),
        ),
      );
    }
    if (skipped > 0 && fushiDebugMode) {
      fushiDebugPrint('AssParser: skipped $skipped cue(s) with end<=start');
    }
    return cues;
  } finally {
    result.free();
  }
}

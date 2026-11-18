/// 漫画有声模式的时间表（纯函数，设计 §2）：时间轴由页段组成，台词放在页段内。
///
/// 句后停顿 = 转场基础值 + 该句的一拍；页有最短停留、无台词页有整页停留、翻页后先看
/// 画面（`lead`）。静音不烘焙进音频：成品是「每句一段音频 + 时间表」，同一份音频按
/// 播放形态得到两张表——边看边听插入页停留与 `lead`，纯听把它们压到 0、只留句间停顿。
library;

import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';

/// 播放形态。
enum MangaPlaybackMode {
  /// 边看边听：插入页停留与 `lead`。
  watchAndListen,

  /// 纯听（熄屏 / 后台 / 阅读器不可见；导出 m4b 也按它）：页停留与 `lead` 为 0。
  listenOnly,
}

/// 时间表的默认值（试做里所有者听过两轮后的取值，不是测量结果）。
class MangaTimingParams {
  const MangaTimingParams({
    this.sameSpeakerMs = 300,
    this.speakerChangeMs = 450,
    this.registerShiftMs = 900,
    this.pageTurnExtraMs = 450,
    this.finalGapMs = 600,
    this.silentPageHoldMs = 4000,
    this.spokenPageMinMs = 5000,
    this.pageLeadMs = 700,
  });

  /// 同一人接着下一个气泡。
  final int sameSpeakerMs;

  /// 换人说话。
  final int speakerChangeMs;

  /// 内心（独白 / 心声 / 嘟囔）与说出口之间切换（优先于换人）。
  final int registerShiftMs;

  /// 下一句在下一页时再加。
  final int pageTurnExtraMs;

  /// 最后一句之后的转场基础值（没有下一句可比；取值同试做）。
  final int finalGapMs;

  /// 无台词页停留（逐页 `hold` 可覆盖）。
  final int silentPageHoldMs;

  /// 有台词页最短停留，不足在页尾补静音。
  final int spokenPageMinMs;

  /// 翻到有台词页后、第一句之前先看画面（逐页 `lead` 可覆盖）。
  final int pageLeadMs;
}

/// 时间表的一句输入（只取算时间要用的字段）。
class MangaTimedLine {
  const MangaTimedLine({
    required this.page,
    required this.speaker,
    required this.kind,
    required this.durationMs,
    this.beatMs = 0,
    this.placeholder = false,
  });

  MangaTimedLine.fromScriptLine(
    MangaScriptLine line, {
    required int durationMs,
    bool placeholder = false,
  }) : this(
         page: line.page,
         speaker: line.speaker,
         kind: line.kind,
         durationMs: durationMs,
         beatMs: line.beatMs,
         placeholder: placeholder,
       );

  final int page;
  final String speaker;
  final CastLineKind kind;

  /// 这句音频的实际时长（裁掉首尾静音后）。
  final int durationMs;

  /// 该句的一拍（句后额外停顿）。
  final int beatMs;

  /// 没配上音（见 `cast_line_voicing.dart`）：[durationMs] 是占位静音的估计长度，
  /// 播放器在这段放静音、照常高亮；补回后换成真音频重算时间表。
  final bool placeholder;
}

/// 一个页段：`[startMs, endMs)`。纯听形态下无台词页的页段长度为 0，但仍会产出。
class MangaPageSegment {
  const MangaPageSegment({
    required this.page,
    required this.startMs,
    required this.endMs,
    required this.spoken,
  });

  final int page;
  final int startMs;
  final int endMs;

  /// 该页有台词。
  final bool spoken;

  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is MangaPageSegment &&
      other.page == page &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.spoken == spoken;

  @override
  int get hashCode => Object.hash(page, startMs, endMs, spoken);

  @override
  String toString() =>
      'MangaPageSegment(p$page $startMs-$endMs${spoken ? '' : ' silent'})';
}

/// 一句在时间轴上的位置：`[startMs, endMs)` 是音频本身，[gapAfterMs] 是句后停顿。
class MangaLineTiming {
  const MangaLineTiming({
    required this.startMs,
    required this.endMs,
    required this.gapAfterMs,
    this.placeholder = false,
  });

  final int startMs;
  final int endMs;
  final int gapAfterMs;

  /// 这段是占位静音（没配上音的句子）。
  final bool placeholder;

  @override
  bool operator ==(Object other) =>
      other is MangaLineTiming &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.gapAfterMs == gapAfterMs &&
      other.placeholder == placeholder;

  @override
  int get hashCode => Object.hash(startMs, endMs, gapAfterMs, placeholder);

  @override
  String toString() =>
      'MangaLineTiming($startMs-$endMs +$gapAfterMs${placeholder ? ' placeholder' : ''})';
}

class MangaTimeline {
  const MangaTimeline({
    required this.segments,
    required this.lines,
    required this.totalMs,
  });

  /// 从起始页到最后一页，每页恰好一个页段，首尾相接。
  final List<MangaPageSegment> segments;

  /// 与输入行一一对应。
  final List<MangaLineTiming> lines;

  final int totalMs;
}

/// 句后转场停顿 = 基础值 + 该句一拍。基础值按优先级：内心 ↔ 说出口切换 > 换人 > 同人；
/// 下一句在别的页时再加翻页值；没有下一句时用 [MangaTimingParams.finalGapMs]。
int mangaGapAfter(
  MangaTimedLine line,
  MangaTimedLine? next, {
  MangaTimingParams params = const MangaTimingParams(),
}) {
  int base;
  if (next == null) {
    base = params.finalGapMs;
  } else {
    if (line.kind.isInner != next.kind.isInner) {
      base = params.registerShiftMs;
    } else if (line.speaker != next.speaker) {
      base = params.speakerChangeMs;
    } else {
      base = params.sameSpeakerMs;
    }
    if (next.page != line.page) base += params.pageTurnExtraMs;
  }
  return base + line.beatMs;
}

/// 计算时间表。
///
/// - [lines]：排好序的会发声的行（页非降序；「不读」的行不要传进来，
///   用 `MangaAudioScript.audibleLines`）。
/// - [pageCount]：本卷页数；页段覆盖 `[startPage, pageCount)` 的每一页，中间、开头、
///   结尾没有任何行的页也各有一段。
/// - [pages]：逐页 `hold` / `lead`；没有条目用 [params] 的默认值。
/// - [pacing]：看图节奏倍率，只缩放页停留（无台词页停留、有台词页最短停留）与 `lead`，
///   不动句间停顿。
///
/// 页段内的顺序：`lead` → 各句（音频 + 句后停顿，含翻页加值）→ 不足页最短停留时补静音。
/// 输入不合约（页越界、乱序、负时长、负倍率）属于调用方的程序错误，抛 [ArgumentError]。
MangaTimeline computeMangaTimeline({
  required List<MangaTimedLine> lines,
  required int pageCount,
  int startPage = 0,
  Map<int, MangaPageDirective> pages = const <int, MangaPageDirective>{},
  MangaPlaybackMode mode = MangaPlaybackMode.watchAndListen,
  double pacing = 1.0,
  MangaTimingParams params = const MangaTimingParams(),
}) {
  if (!pacing.isFinite || pacing < 0) {
    throw ArgumentError.value(pacing, 'pacing', 'must be a finite value >= 0');
  }
  if (startPage < 0 || startPage > pageCount) {
    throw ArgumentError.value(startPage, 'startPage', 'outside [0, pageCount]');
  }
  int prevPage = startPage;
  for (final MangaTimedLine l in lines) {
    if (l.page < prevPage || l.page >= pageCount) {
      throw ArgumentError.value(
        l.page,
        'lines',
        'pages must be non-decreasing within [startPage, pageCount)',
      );
    }
    if (l.durationMs < 0 || l.beatMs < 0) {
      throw ArgumentError.value(l.durationMs, 'lines', 'negative duration');
    }
    if (!l.kind.isAudible) {
      throw ArgumentError.value(l.kind, 'lines', 'skip lines have no audio');
    }
    prevPage = l.page;
  }

  final bool watching = mode == MangaPlaybackMode.watchAndListen;
  int scaled(int ms) => watching ? (ms * pacing).round() : 0;
  int holdFor(int page) =>
      scaled(pages[page]?.holdMs ?? params.silentPageHoldMs);
  int leadFor(int page) => scaled(pages[page]?.leadMs ?? params.pageLeadMs);
  final int spokenFloor = scaled(params.spokenPageMinMs);

  final List<MangaPageSegment> segments = <MangaPageSegment>[];
  final List<MangaLineTiming> timings = <MangaLineTiming>[];
  int pos = 0;
  int i = 0;
  for (int page = startPage; page < pageCount; page++) {
    final int segStart = pos;
    if (i >= lines.length || lines[i].page != page) {
      pos += holdFor(page);
      segments.add(
        MangaPageSegment(
          page: page,
          startMs: segStart,
          endMs: pos,
          spoken: false,
        ),
      );
      continue;
    }
    pos += leadFor(page);
    while (i < lines.length && lines[i].page == page) {
      final MangaTimedLine line = lines[i];
      final int gap = mangaGapAfter(
        line,
        i + 1 < lines.length ? lines[i + 1] : null,
        params: params,
      );
      final int start = pos;
      pos += line.durationMs;
      timings.add(
        MangaLineTiming(
          startMs: start,
          endMs: pos,
          gapAfterMs: gap,
          placeholder: line.placeholder,
        ),
      );
      pos += gap;
      i++;
    }
    if (pos - segStart < spokenFloor) pos = segStart + spokenFloor;
    segments.add(
      MangaPageSegment(page: page, startMs: segStart, endMs: pos, spoken: true),
    );
  }
  return MangaTimeline(segments: segments, lines: timings, totalMs: pos);
}

/// 全屏歌词动画的共享运行时（纯 Dart，可单测）：当前行 / 上一句 / 下一句、逐字时间线、
/// 字进度与「歌词节拍」包络。对应 folia 的 `visualizer/runtime.ts` 与
/// `utils/lyrics/graphemeTiming.ts`。样式一律从这里取，不自己扫 `timeline.lines`。
///
/// 时间一律是**歌词显示时间**（毫秒）：显示时间 = 播放位置 + 整首偏移。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_segments.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_structure.dart';

export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart';
export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_segments.dart';
export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_structure.dart';

/// 一个字形（grapheme）的时间：逐字歌词按音节拆，行级歌词按行时长均分。
class LyricVisualizerGlyph {
  const LyricVisualizerGlyph({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.syllableIndex,
    required this.isSpace,
    this.ruby,
  });

  final String text;
  final int startMs;
  final int endMs;

  /// 所属音节在行内的下标（行级歌词恒为 0）。
  final int syllableIndex;
  final bool isSpace;

  /// 来源自带的注音（只在音节第一个字形上挂；不做自动注音）。
  final String? ruby;

  int get durationMs => endMs - startMs;

  /// 0–1：此刻唱到这个字的哪里。
  double progress(int timeMs) {
    if (timeMs <= startMs) return 0;
    if (timeMs >= endMs) return 1;
    final int d = endMs - startMs;
    return d <= 0 ? 1 : (timeMs - startMs) / d;
  }
}

/// 一个词（连续的非空白字形；CJK 每个字自成一词）。动画样式常按词做发光 / 弹跳。
class LyricVisualizerWord {
  const LyricVisualizerWord({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.firstGlyph,
    required this.glyphCount,
  });

  final String text;
  final int startMs;
  final int endMs;

  /// 在行的 [LyricVisualizerLine.glyphs] 里的起始下标。
  final int firstGlyph;
  final int glyphCount;

  int get durationMs => endMs - startMs;

  double progress(int timeMs) {
    if (timeMs <= startMs) return 0;
    if (timeMs >= endMs) return 1;
    final int d = endMs - startMs;
    return d <= 0 ? 1 : (timeMs - startMs) / d;
  }
}

/// 预处理过的一行。
class LyricVisualizerLine {
  const LyricVisualizerLine({
    required this.index,
    required this.source,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.glyphs,
    required this.words,
    required this.backgroundLines,
    this.isChorus = false,
    this.songPart = LyricVisualizerSongPart.unknown,
    this.blockIndex = 0,
    this.chorusEffect,
    LyricVisualizerRenderHints? renderHints,
    List<LyricVisualizerSegment>? segments,
  }) : _renderHints = renderHints,
       _segments = segments;

  /// 在 `timeline.lines` 里的下标（主行）。
  final int index;
  final LyricLine source;
  final String text;
  final int startMs;
  final int endMs;
  final List<LyricVisualizerGlyph> glyphs;
  final List<LyricVisualizerWord> words;

  /// 挂在这一行下的和声行（`isBackground`）。
  final List<LyricLine> backgroundLines;

  /// 副歌行（来源标注优先，否则 folia 文本启发式；见 `lyric_visualizer_structure.dart`）。
  final bool isChorus;

  /// 段落类别（来源没有标注时：副歌行为 chorus，其余 unknown）。原始标注字符串见 [songPartLabel]。
  final LyricVisualizerSongPart songPart;

  /// 段（stanza）编号：从 0 起，段落标注变化或空隙超过阈值时 +1。
  final int blockIndex;

  /// 副歌装饰（folia `chorusEffect`）；非副歌为 null。
  final LyricVisualizerChorusEffect? chorusEffect;

  final LyricVisualizerRenderHints? _renderHints;
  final List<LyricVisualizerSegment>? _segments;

  /// 来源的段落标注原文（`Verse` / `Chorus`…）；没有为 null。
  String? get songPartLabel => source.songPart;

  /// 渲染提示（行时长分级、句尾离场窗口、逐词显现）。runtime 建行时已算好。
  LyricVisualizerRenderHints get renderHints =>
      _renderHints ??
      LyricVisualizerRenderHints.of(
        startMs: startMs,
        endMs: endMs,
        lastWordEndMs: words.isEmpty ? null : words.last.endMs,
      );

  /// 词级分组（汉字 + 送假名、片假名连写、拉丁单词…，标点粘连；见 `lyric_visualizer_segments.dart`）。
  /// 与 [words]（CJK 逐字）并存：要「按词」动画的样式用这个。
  List<LyricVisualizerSegment> get segments =>
      _segments ?? buildLyricVisualizerSegments(glyphs);

  /// 这一行最晚可以留在屏上的时刻（含离场窗口）。
  int get renderEndMs => renderHints.renderEndMs;

  /// 首选译文（没有为 null）。
  String? get translation => source.primaryTranslation;
  String? get romanization => source.romanization;

  /// 演唱者下标（`timeline.agents`），没有为 null。
  int? get agent => source.agent;
  int get durationMs => endMs - startMs;

  double progress(int timeMs) {
    if (timeMs <= startMs) return 0;
    if (timeMs >= endMs) return 1;
    final int d = endMs - startMs;
    return d <= 0 ? 1 : (timeMs - startMs) / d;
  }

  bool isActiveAt(int timeMs) => timeMs >= startMs && timeMs < endMs;
}

/// CJK / 假名 / 谚文：每个字自成一词。
bool lyricVisualizerIsCjk(String ch) {
  if (ch.isEmpty) return false;
  final int c = ch.runes.first;
  return (c >= 0x3040 && c <= 0x30FF) || // 平假名 / 片假名
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xAC00 && c <= 0xD7AF) || // 谚文
      (c >= 0x20000 && c <= 0x2FA1F) ||
      (c >= 0xFF00 && c <= 0xFFEF); // 全角
}

bool _isSpace(String ch) => ch.trim().isEmpty;

/// 把一行拆成字形时间线（folia `buildLineGraphemeTimeline`）：每个音节内按字形数均分
/// 音节时长；行级歌词（单音节或没有音节时间）按整行均分。
List<LyricVisualizerGlyph> buildLyricVisualizerGlyphs(LyricLine line) {
  final List<LyricVisualizerGlyph> out = <LyricVisualizerGlyph>[];
  final List<LyricSyllable> syl = line.syllables;
  if (syl.isEmpty) return out;
  final bool lineLevel =
      syl.length == 1 &&
      syl.first.startMs <= line.startMs &&
      syl.first.endMs >= line.endMs;
  for (int si = 0; si < syl.length; si++) {
    final LyricSyllable s = syl[si];
    final List<String> chars = s.text.characters.toList();
    if (chars.isEmpty) continue;
    int start = s.startMs;
    int end = s.endMs;
    if (lineLevel) {
      start = line.startMs;
      end = line.endMs;
    }
    if (end < start) end = start;
    // 空白不占时长：只在非空白字形间均分。
    final int voiced = chars.where((String c) => !_isSpace(c)).length;
    final double step = voiced == 0 ? 0 : (end - start) / voiced;
    int k = 0;
    for (int ci = 0; ci < chars.length; ci++) {
      final String c = chars[ci];
      final bool space = _isSpace(c);
      final int gs = (start + step * k).round();
      final int ge = space ? gs : (start + step * (k + 1)).round();
      if (!space) k++;
      out.add(
        LyricVisualizerGlyph(
          text: c,
          startMs: gs,
          endMs: ge,
          syllableIndex: lineLevel ? 0 : si,
          isSpace: space,
          ruby: ci == 0 ? s.ruby : null,
        ),
      );
    }
  }
  return out;
}

/// 字形 → 词：空白断词，CJK 字自成一词，拉丁连写成一词。
List<LyricVisualizerWord> buildLyricVisualizerWords(
  List<LyricVisualizerGlyph> glyphs,
) {
  final List<LyricVisualizerWord> out = <LyricVisualizerWord>[];
  int i = 0;
  while (i < glyphs.length) {
    if (glyphs[i].isSpace) {
      i++;
      continue;
    }
    final int first = i;
    if (lyricVisualizerIsCjk(glyphs[i].text)) {
      i++;
    } else {
      while (i < glyphs.length &&
          !glyphs[i].isSpace &&
          !lyricVisualizerIsCjk(glyphs[i].text)) {
        i++;
      }
    }
    final List<LyricVisualizerGlyph> part = glyphs.sublist(first, i);
    out.add(
      LyricVisualizerWord(
        text: part.map((LyricVisualizerGlyph g) => g.text).join(),
        startMs: part.first.startMs,
        endMs: part.last.endMs,
        firstGlyph: first,
        glyphCount: part.length,
      ),
    );
  }
  return out;
}

/// 按时间轴缓存的运行时。行 = 主行（和声行并入前一主行的 [LyricVisualizerLine.backgroundLines]），
/// 空行（纯间奏标记）去掉。
class LyricVisualizerRuntime {
  LyricVisualizerRuntime(this.timeline) : lines = _build(timeline);

  final LyricTimeline timeline;
  final List<LyricVisualizerLine> lines;

  bool get isSynced => timeline.isSynced;

  static List<LyricVisualizerLine> _build(LyricTimeline t) {
    // 第一遍：主行 + 挂上的和声行。
    final List<(int, LyricLine, String, List<LyricLine>)> raw =
        <(int, LyricLine, String, List<LyricLine>)>[];
    for (int i = 0; i < t.lines.length; i++) {
      final LyricLine l = t.lines[i];
      if (l.isBackground && raw.isNotEmpty) {
        final (int, LyricLine, String, List<LyricLine>) prev = raw.last;
        raw[raw.length - 1] = (
          prev.$1,
          prev.$2,
          prev.$3,
          <LyricLine>[...prev.$4, l],
        );
        continue;
      }
      final String text = l.text.trim();
      if (text.isEmpty) continue;
      raw.add((i, l, text, const <LyricLine>[]));
    }
    // 第二遍：字形 / 词 / 渲染提示，再按整首算结构（副歌 / 段落 / 段编号）。
    final List<List<LyricVisualizerGlyph>> glyphs =
        <List<LyricVisualizerGlyph>>[
          for (final (int, LyricLine, String, List<LyricLine>) e in raw)
            buildLyricVisualizerGlyphs(e.$2),
        ];
    final List<List<LyricVisualizerWord>> words = <List<LyricVisualizerWord>>[
      for (final List<LyricVisualizerGlyph> g in glyphs)
        buildLyricVisualizerWords(g),
    ];
    final List<LyricVisualizerRenderHints> hints = <LyricVisualizerRenderHints>[
      for (int k = 0; k < raw.length; k++)
        LyricVisualizerRenderHints.of(
          startMs: raw[k].$2.startMs,
          endMs: math.max(raw[k].$2.endMs, raw[k].$2.startMs),
          lastWordEndMs: words[k].isEmpty ? null : words[k].last.endMs,
        ),
    ];
    final List<LyricVisualizerStructureOutput> structure =
        buildLyricVisualizerStructure(<LyricVisualizerStructureInput>[
          for (int k = 0; k < raw.length; k++)
            (
              text: raw[k].$3,
              startMs: raw[k].$2.startMs,
              renderEndMs: hints[k].renderEndMs,
              songPart: raw[k].$2.songPart,
            ),
        ]);
    return <LyricVisualizerLine>[
      for (int k = 0; k < raw.length; k++)
        LyricVisualizerLine(
          index: raw[k].$1,
          source: raw[k].$2,
          text: raw[k].$3,
          startMs: raw[k].$2.startMs,
          endMs: math.max(raw[k].$2.endMs, raw[k].$2.startMs),
          glyphs: glyphs[k],
          words: words[k],
          backgroundLines: raw[k].$4,
          isChorus: structure[k].isChorus,
          songPart: structure[k].part,
          blockIndex: structure[k].blockIndex,
          chorusEffect: structure[k].chorusEffect,
          renderHints: hints[k],
          segments: buildLyricVisualizerSegments(glyphs[k]),
        ),
    ];
  }

  /// 来源是否带段落标注（否则 [LyricVisualizerLine.isChorus] 来自文本启发式）。
  bool get hasSourceSongParts =>
      lines.any((LyricVisualizerLine l) => l.source.songPart != null);

  /// 画面上该显示的行（含句尾离场窗口，folia `renderEndTime`）：起点已到的最后一行，且还没过它的
  /// [LyricVisualizerLine.renderEndMs]；否则 -1。离场窗口里下一行还没开始，所以不会和下一行重叠。
  int displayedLineAt(int timeMs) {
    final int i = lastStartedLineAt(timeMs);
    if (i < 0) return -1;
    return timeMs < lines[i].renderEndMs ? i : -1;
  }

  /// 行的视觉结束（folia `buildStructureLines` 的 `renderEndTime`）：可超出行尾，但不越过下一行起点。
  int visualEndMsOf(int lineIndex) {
    final LyricVisualizerLine l = lines[lineIndex];
    final int next = lineIndex + 1 < lines.length
        ? lines[lineIndex + 1].startMs
        : 1 << 52;
    return math.max(l.startMs, math.min(l.renderEndMs, next));
  }

  /// [timeMs] 是否在副歌行上（含离场窗口）。
  bool isChorusAt(int timeMs) {
    final int i = displayedLineAt(timeMs);
    return i >= 0 && lines[i].isChorus;
  }

  /// 段 [blockIndex] 的行下标区间 [first, last]；没有该段为 null。
  (int, int)? blockRange(int blockIndex) {
    int first = -1;
    int last = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].blockIndex == blockIndex) {
        if (first < 0) first = i;
        last = i;
      } else if (first >= 0) {
        break;
      }
    }
    return first < 0 ? null : (first, last);
  }

  /// 正在唱的行（起止之间），间奏里为 -1（folia `currentLineIndex` 语义）。
  int activeLineAt(int timeMs) {
    final int i = lastStartedLineAt(timeMs);
    if (i < 0) return -1;
    return lines[i].isActiveAt(timeMs) ? i : -1;
  }

  /// 起点已到的最后一行（间奏里停在上一句；一句都没到为 -1）。
  int lastStartedLineAt(int timeMs) {
    int lo = 0;
    int hi = lines.length - 1;
    int found = -1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      if (lines[mid].startMs <= timeMs) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  /// 间奏里最近唱完的一句（有行在唱时为 null；folia `getRecentCompletedLine`）。
  LyricVisualizerLine? recentCompletedLineAt(int timeMs) {
    if (activeLineAt(timeMs) >= 0) return null;
    final int i = lastStartedLineAt(timeMs);
    return i >= 0 ? lines[i] : null;
  }

  /// 下一句尚未开始的行（folia `getUpcomingLine`）。
  LyricVisualizerLine? upcomingLineAt(int timeMs) {
    final int i = lastStartedLineAt(timeMs) + 1;
    return i < lines.length ? lines[i] : null;
  }

  /// 之后的 [count] 句。
  List<LyricVisualizerLine> upcomingLinesAt(int timeMs, {int count = 2}) {
    final int from = lastStartedLineAt(timeMs) + 1;
    if (from >= lines.length) return const <LyricVisualizerLine>[];
    return lines.sublist(from, math.min(lines.length, from + count));
  }

  /// 下一句是否该预热（离开唱还有 [minLeadMs]–[maxLeadMs]）。
  bool shouldPreheat(
    LyricVisualizerLine? line,
    int timeMs, {
    required int minLeadMs,
    required int maxLeadMs,
  }) {
    if (line == null) return false;
    final int lead = line.startMs - timeMs;
    return lead >= minLeadMs && lead <= maxLeadMs;
  }

  /// 「歌词节拍」包络（0–1）：每个字起唱时冲到 1，按 [decayMs] 指数回落。没有实时音频
  /// 分析时代替 folia 的 `audioPower`，让脉动跟着唱词走。
  double pulseAt(int timeMs, {int decayMs = 260}) {
    final int li = lastStartedLineAt(timeMs);
    if (li < 0) return 0;
    final LyricVisualizerLine line = lines[li];
    if (timeMs > line.endMs + decayMs * 4) return 0;
    int lastOnset = -1;
    for (final LyricVisualizerGlyph g in line.glyphs) {
      if (g.isSpace) continue;
      if (g.startMs <= timeMs) {
        lastOnset = g.startMs;
      } else {
        break;
      }
    }
    if (lastOnset < 0) return 0;
    final double dt = (timeMs - lastOnset).toDouble();
    return math.exp(-dt / decayMs);
  }

  /// 整首进度 0–1（按最后一行结束时间）。
  double songProgressAt(int timeMs) {
    if (lines.isEmpty) return 0;
    final int end = lines.last.endMs;
    if (end <= 0) return 0;
    return (timeMs / end).clamp(0.0, 1.0);
  }
}

/// 稳定的小随机数发生器（mulberry32，folia `visualizerSeedHash` 同类）：同一首同一布局。
class LyricVisualizerRandom {
  LyricVisualizerRandom(int seed) : _state = seed & 0xFFFFFFFF;

  int _state;

  /// [0, 1)。
  double next() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    int t = _state;
    t = ((t ^ (t >> 15)) * (t | 1)) & 0xFFFFFFFF;
    t ^= (t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0;
  }

  double range(double min, double max) => min + (max - min) * next();
}

/// 字符串 → 32 位种子（FNV-1a）。
int lyricVisualizerSeedOf(String s) {
  int h = 0x811C9DC5;
  for (final int u in s.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

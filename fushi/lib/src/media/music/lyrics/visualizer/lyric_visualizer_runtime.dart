/// 全屏歌词动画的共享运行时（纯 Dart，可单测）：当前行 / 上一句 / 下一句、逐字时间线、
/// 字进度与「歌词节拍」包络。对应 folia 的 `visualizer/runtime.ts` 与
/// `utils/lyrics/graphemeTiming.ts`。样式一律从这里取，不自己扫 `timeline.lines`。
///
/// 时间一律是**歌词显示时间**（毫秒）：显示时间 = 播放位置 + 整首偏移。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:fushi_music/fushi_music.dart';

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
  });

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
    final List<LyricVisualizerLine> out = <LyricVisualizerLine>[];
    for (int i = 0; i < t.lines.length; i++) {
      final LyricLine l = t.lines[i];
      if (l.isBackground && out.isNotEmpty) {
        final LyricVisualizerLine prev = out.removeLast();
        out.add(
          LyricVisualizerLine(
            index: prev.index,
            source: prev.source,
            text: prev.text,
            startMs: prev.startMs,
            endMs: prev.endMs,
            glyphs: prev.glyphs,
            words: prev.words,
            backgroundLines: <LyricLine>[...prev.backgroundLines, l],
          ),
        );
        continue;
      }
      final String text = l.text.trim();
      if (text.isEmpty) continue;
      final List<LyricVisualizerGlyph> glyphs = buildLyricVisualizerGlyphs(l);
      out.add(
        LyricVisualizerLine(
          index: i,
          source: l,
          text: text,
          startMs: l.startMs,
          endMs: math.max(l.endMs, l.startMs),
          glyphs: glyphs,
          words: buildLyricVisualizerWords(glyphs),
          backgroundLines: const <LyricLine>[],
        ),
      );
    }
    return out;
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

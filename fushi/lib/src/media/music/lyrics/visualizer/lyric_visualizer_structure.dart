/// 歌曲结构：段落（主歌 / 副歌 / 桥段…）、副歌判据、段（block）编号。
///
/// 来源带标注时用标注（Apple TTML `<div itunes:song-part>` → `LyricLine.songPart`，解析器原样保留
/// 字符串）；没有标注时副歌用 folia 的文本启发式（`src/utils/chorusDetector.ts`：重复次数最多的行文本
/// 算副歌，至少重复两次、至少两个字符、`......` 不算），段用 folia `paragraphStructure.ts` 的时间
/// 空隙切分（空隙中位数 × 2.5，钳在 1.25–3.5 秒）。样式一律读 `LyricVisualizerLine.isChorus` /
/// `songPart` / `blockIndex`，不再自己数重复句。
library;

import 'dart:math' as math;

/// 段落类别。
enum LyricVisualizerSongPart {
  intro,
  verse,
  preChorus,
  chorus,
  bridge,
  outro,
  unknown,
}

/// 副歌装饰（folia `chorusEffect`：bars / circles / beams）。
enum LyricVisualizerChorusEffect { bars, circles, beams }

/// 来源段落字符串 → 类别（大小写、空格、连字符不敏感）。`Chorus` / `Hook` / `Refrain` / `Drop` /
/// `PostChorus` 算副歌（folia diorama 的 `CHORUS_PART` 同一组词）。
LyricVisualizerSongPart lyricVisualizerSongPartOf(String? raw) {
  if (raw == null) return LyricVisualizerSongPart.unknown;
  final String k = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (k.isEmpty) return LyricVisualizerSongPart.unknown;
  if (k.startsWith('prechorus') || k == 'build' || k == 'buildup') {
    return LyricVisualizerSongPart.preChorus;
  }
  if (k.contains('chorus') ||
      k.startsWith('hook') ||
      k.startsWith('refrain') ||
      k.startsWith('drop')) {
    return LyricVisualizerSongPart.chorus;
  }
  if (k.startsWith('verse')) return LyricVisualizerSongPart.verse;
  if (k.startsWith('bridge') || k.startsWith('interlude')) {
    return LyricVisualizerSongPart.bridge;
  }
  if (k.startsWith('intro')) return LyricVisualizerSongPart.intro;
  if (k.startsWith('outro') || k.startsWith('ending') || k == 'coda') {
    return LyricVisualizerSongPart.outro;
  }
  return LyricVisualizerSongPart.unknown;
}

/// folia `detectChorusLines`：出现次数最多（且 ≥ 2）的行文本。
Set<String> lyricVisualizerDetectChorusTexts(Iterable<String> lineTexts) {
  final Map<String, int> counts = <String, int>{};
  for (final String raw in lineTexts) {
    final String text = raw.trim();
    if (text.isEmpty || text == '......' || text.length < 2) continue;
    counts[text] = (counts[text] ?? 0) + 1;
  }
  int maxCount = 0;
  for (final int c in counts.values) {
    maxCount = math.max(maxCount, c);
  }
  if (maxCount <= 1) return const <String>{};
  return <String>{
    for (final MapEntry<String, int> e in counts.entries)
      if (e.value == maxCount) e.key,
  };
}

/// 一行参与结构计算的输入。
typedef LyricVisualizerStructureInput = ({
  String text,
  int startMs,
  int renderEndMs,
  String? songPart,
});

/// 一行的结构结果。
typedef LyricVisualizerStructureOutput = ({
  LyricVisualizerSongPart part,
  bool isChorus,
  int blockIndex,
  LyricVisualizerChorusEffect? chorusEffect,
});

/// folia `resolveParagraphGapThreshold`（毫秒）：相邻行空隙（下一行起点 − 上一行离场，不越过下一行
/// 起点）的中位数 × 2.5，钳在 1250–3500。
int lyricVisualizerBlockGapThresholdMs(
  List<LyricVisualizerStructureInput> lines,
) {
  final List<int> gaps = <int>[
    for (int i = 1; i < lines.length; i++)
      lines[i].startMs - math.min(lines[i - 1].renderEndMs, lines[i].startMs),
  ]..removeWhere((int g) => g <= 0);
  double median = 500;
  if (gaps.isNotEmpty) {
    gaps.sort();
    final int mid = gaps.length ~/ 2;
    median = gaps.length.isEven
        ? (gaps[mid - 1] + gaps[mid]) / 2
        : gaps[mid].toDouble();
  }
  return (median * 2.5).clamp(1250, 3500).round();
}

/// 整首的结构：段落 / 副歌 / 段编号 / 副歌装饰。
List<LyricVisualizerStructureOutput> buildLyricVisualizerStructure(
  List<LyricVisualizerStructureInput> lines,
) {
  if (lines.isEmpty) return const <LyricVisualizerStructureOutput>[];
  final bool sourced = lines.any(
    (LyricVisualizerStructureInput l) => l.songPart != null,
  );
  final List<LyricVisualizerSongPart> parts = <LyricVisualizerSongPart>[
    for (final LyricVisualizerStructureInput l in lines)
      lyricVisualizerSongPartOf(l.songPart),
  ];
  // folia `resolveProviderLyricsChorus`：来源已标出副歌就用标注，否则退回文本启发式。
  final bool sourcedChorus = parts.contains(LyricVisualizerSongPart.chorus);
  final Set<String> chorusTexts = sourcedChorus
      ? const <String>{}
      : lyricVisualizerDetectChorusTexts(
          lines.map((LyricVisualizerStructureInput l) => l.text),
        );
  final int gapMs = lyricVisualizerBlockGapThresholdMs(lines);
  final List<LyricVisualizerStructureOutput> out =
      <LyricVisualizerStructureOutput>[];
  int block = 0;
  for (int i = 0; i < lines.length; i++) {
    final LyricVisualizerStructureInput l = lines[i];
    if (i > 0) {
      final LyricVisualizerStructureInput prev = lines[i - 1];
      final int gap = l.startMs - math.min(prev.renderEndMs, l.startMs);
      final bool metadataChanged =
          sourced &&
          prev.songPart != null &&
          l.songPart != null &&
          prev.songPart != l.songPart;
      if (metadataChanged || gap > gapMs) block++;
    }
    final bool chorus = sourcedChorus
        ? parts[i] == LyricVisualizerSongPart.chorus
        : chorusTexts.contains(l.text.trim());
    final LyricVisualizerSongPart part =
        chorus && parts[i] == LyricVisualizerSongPart.unknown
        ? LyricVisualizerSongPart.chorus
        : parts[i];
    out.add((
      part: part,
      isChorus: chorus,
      blockIndex: block,
      // folia 每个副歌文本随机挑一种装饰；这里按文本哈希挑，同一首每次一致。
      chorusEffect: chorus
          ? LyricVisualizerChorusEffect.values[_fnv(l.text.trim()) %
                LyricVisualizerChorusEffect.values.length]
          : null,
    ));
  }
  return out;
}

int _fnv(String s) {
  int h = 0x811C9DC5;
  for (final int u in s.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

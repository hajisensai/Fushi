/// 从中日双语字幕里**拆出日语轨**（纯函数，反馈 E1pq561P2q）。
///
/// 双语字幕的两种常见形态：
/// 1. 同一条 cue 里上下两行（`日文行\N中文行` 或反过来）；
/// 2. 两条时间完全相同的 cue（ASS 里日文样式一条、中文样式一条）。
///
/// 这里先把「起止时间完全相同」的 cue 合成一组（形态 2 归并成形态 1），再逐组挑出
/// 日语行。判据与正文语言检测（`subtitle_content_language.dart`）同一套假名 / 汉字
/// 口径：
/// - 含假名的行是日语；
/// - 只有汉字、没有假名的行在双语字幕里是中文——**除非**这一组里没有任何一行带
///   假名（「了解」「本当」这类纯汉字日语句）：此时按全片统计出的日语所在位置
///   （上 / 下，[BilingualJapanesePosition]）取那一半；
/// - 既无假名也无汉字的行（`♪～`、`……`、英文名）是中性行：单独成组时保留，
///   和日语行同组时跟着日语行一起保留，和中文行同组时丢掉。
///
/// 拆分只删行、不改字、不动时间轴：日语正文与顺序一个字都不动。
library;

import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';

/// 拆分的输入 / 输出单元：一条带时间的字幕文本。[text] 里的换行（`\n`，或 ASS 未展开
/// 的字面 `\N`）分隔同屏的多行。
class SubtitleTextCue {
  const SubtitleTextCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SubtitleTextCue &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.text == text;

  @override
  int get hashCode => Object.hash(startMs, endMs, text);

  @override
  String toString() => 'SubtitleTextCue($startMs-$endMs: $text)';
}

/// 日语行在双语 cue 里的位置（全片统计）。
enum BilingualJapanesePosition { first, last }

/// [extractJapaneseFromBilingual] 的结果。
class BilingualSplitResult {
  const BilingualSplitResult({
    required this.cues,
    required this.droppedCues,
    required this.japanesePosition,
  });

  /// 拆出的日语 cue（按原顺序）。
  final List<SubtitleTextCue> cues;

  /// 整组都是非日语、被整条去掉的组数（中文单行、中文样式的独立 cue）。
  final int droppedCues;

  /// 全片统计出的日语位置；没有任何多行组可供统计时为 null（此时纯汉字多行组
  /// 按 [BilingualJapanesePosition.first] 取）。
  final BilingualJapanesePosition? japanesePosition;
}

enum _LineKind { japanese, chinese, neutral }

_LineKind _classify(String line) {
  bool han = false;
  for (final int rune in line.runes) {
    if (isSubtitleKanaRune(rune)) return _LineKind.japanese;
    if (isSubtitleHanRune(rune)) han = true;
  }
  return han ? _LineKind.chinese : _LineKind.neutral;
}

/// 把一条 cue 文本拆成同屏的各行（`\n` / `\r\n` / 字面 `\N` `\n`），去空行。
List<String> splitSubtitleCueLines(String text) => <String>[
  for (final String line in text.split(RegExp(r'\r?\n|\\[Nn]')))
    if (line.trim().isNotEmpty) line.trim(),
];

/// 见 library doc。[cues] 按播放顺序给（同起止时间的 cue 只与**相邻**的合组，
/// 不跨越别的 cue 去找）。
BilingualSplitResult extractJapaneseFromBilingual(List<SubtitleTextCue> cues) {
  // 1) 合组：相邻且起止时间完全相同的 cue 视为同屏的一组。
  final List<({int startMs, int endMs, List<String> lines})> groups =
      <({int startMs, int endMs, List<String> lines})>[];
  for (final SubtitleTextCue cue in cues) {
    final List<String> lines = splitSubtitleCueLines(cue.text);
    if (groups.isNotEmpty &&
        groups.last.startMs == cue.startMs &&
        groups.last.endMs == cue.endMs) {
      groups.last.lines.addAll(lines);
    } else {
      groups.add((startMs: cue.startMs, endMs: cue.endMs, lines: lines));
    }
  }

  // 2) 全片统计日语在上还是在下：只看「首尾两行一日一中」的组。
  int jaFirst = 0;
  int jaLast = 0;
  for (final ({int startMs, int endMs, List<String> lines}) g in groups) {
    if (g.lines.length < 2) continue;
    final _LineKind head = _classify(g.lines.first);
    final _LineKind tail = _classify(g.lines.last);
    if (head == _LineKind.japanese && tail == _LineKind.chinese) jaFirst++;
    if (head == _LineKind.chinese && tail == _LineKind.japanese) jaLast++;
  }
  final BilingualJapanesePosition? position = jaFirst == 0 && jaLast == 0
      ? null
      : (jaLast > jaFirst
            ? BilingualJapanesePosition.last
            : BilingualJapanesePosition.first);

  // 3) 逐组挑日语行。
  final List<SubtitleTextCue> out = <SubtitleTextCue>[];
  int dropped = 0;
  for (final ({int startMs, int endMs, List<String> lines}) g in groups) {
    final List<String> kept = _japaneseLines(
      g.lines,
      position ?? BilingualJapanesePosition.first,
    );
    if (kept.isEmpty) {
      if (g.lines.isNotEmpty) dropped++;
      continue;
    }
    out.add(
      SubtitleTextCue(
        startMs: g.startMs,
        endMs: g.endMs,
        text: kept.join('\n'),
      ),
    );
  }
  return BilingualSplitResult(
    cues: out,
    droppedCues: dropped,
    japanesePosition: position,
  );
}

List<String> _japaneseLines(
  List<String> lines,
  BilingualJapanesePosition position,
) {
  if (lines.isEmpty) return const <String>[];
  final List<_LineKind> kinds = <_LineKind>[
    for (final String l in lines) _classify(l),
  ];
  final bool anyJapanese = kinds.contains(_LineKind.japanese);
  final bool anyChinese = kinds.contains(_LineKind.chinese);
  if (anyJapanese) {
    // 日语行 + 夹在日语那一侧的中性行；中文行一律去掉。中性行跟随离它最近的
    // 有字行：紧挨日语行（或在日语块内部）就留。
    final List<String> kept = <String>[];
    for (int i = 0; i < lines.length; i++) {
      switch (kinds[i]) {
        case _LineKind.japanese:
          kept.add(lines[i]);
        case _LineKind.chinese:
          break;
        case _LineKind.neutral:
          if (_nearestTextKind(kinds, i) != _LineKind.chinese) {
            kept.add(lines[i]);
          }
      }
    }
    return kept;
  }
  if (!anyChinese) {
    // 全是中性行（`♪～`）：不是哪一轨的翻译，原样保留。
    return lines;
  }
  if (lines.length == 1) return const <String>[];
  // 多行、没有假名、有汉字：纯汉字的日语句和它的中文译文。按全片位置取一半。
  final int take = lines.length ~/ 2;
  return position == BilingualJapanesePosition.first
      ? lines.sublist(0, take)
      : lines.sublist(lines.length - take);
}

/// 第 [i] 行（中性行）最近的非中性行的类别；前后等距时取前面的。都没有时 neutral。
_LineKind _nearestTextKind(List<_LineKind> kinds, int i) {
  for (int d = 1; d < kinds.length; d++) {
    if (i - d >= 0 && kinds[i - d] != _LineKind.neutral) return kinds[i - d];
    if (i + d < kinds.length && kinds[i + d] != _LineKind.neutral) {
      return kinds[i + d];
    }
  }
  return _LineKind.neutral;
}

/// 把 cue 写成 SRT（UTF-8 文本，`\n` 换行，编号从 1 起）。负时间按 0 写。
String subtitleTextCuesToSrt(List<SubtitleTextCue> cues) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < cues.length; i++) {
    final SubtitleTextCue cue = cues[i];
    out
      ..write('${i + 1}\n')
      ..write('${_srtTime(cue.startMs)} --> ${_srtTime(cue.endMs)}\n')
      ..write('${cue.text}\n\n');
  }
  return out.toString();
}

String _srtTime(int ms) {
  final int v = ms < 0 ? 0 : ms;
  final int h = v ~/ 3600000;
  final int m = (v ~/ 60000) % 60;
  final int s = (v ~/ 1000) % 60;
  final int milli = v % 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)},${milli.toString().padLeft(3, '0')}';
}

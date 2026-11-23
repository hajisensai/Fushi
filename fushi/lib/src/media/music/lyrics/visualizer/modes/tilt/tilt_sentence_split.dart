/// 按语义把一句歌词拆成若干行（folia `utils/lyrics/sentenceLayout.ts` 的
/// `SentenceLayout.splitIntoSentences`）。纯函数，按 UTF-16 下标工作（与 folia 一致，
/// 段的 `charOffset` 也按它算）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart' show StringCharacters;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

final RegExp _cjk = RegExp(r'[一-龥぀-ヿ가-힯]');
final RegExp _westernChar = RegExp(r'[a-zA-Z0-9]');
final RegExp _space = RegExp(r'\s');
final RegExp _allSpace = RegExp(r'^\s+$');

bool _hasCjk(String text) => _cjk.hasMatch(text);

/// 拆成至少 / 至多 [targetCount] 段（0–1 原样返回）。[timeSeed] 只在退回「随机对半切」时用。
///
/// [wordSpans] 是整句的词边界（[tiltWordSpans]）；缺省按 [text] 现算（[tiltWordSpansOfText]）。
List<String> tiltSplitIntoSentences(
  String text,
  int targetCount, {
  double timeSeed = 0,
  List<(int, int)>? wordSpans,
}) {
  if (targetCount <= 1 && targetCount >= 0) return <String>[text];
  final int maxLevel = switch (targetCount) {
    -1 => 1,
    -2 => 2,
    -3 => 3,
    -4 => 4,
    _ => 5,
  };
  List<String> sentences = <String>[text];
  for (int level = 1; level <= maxLevel; level++) {
    if (sentences.length >= targetCount.abs() && targetCount > 0) break;
    sentences = <String>[
      for (final String s in sentences) ..._splitByLevel(s, level),
    ];
  }
  if (targetCount > 0 && sentences.length < targetCount) {
    sentences = _secondarySplit(
      sentences,
      targetCount,
      timeSeed,
      wordSpans ?? tiltWordSpansOfText(text),
    );
  }
  if (sentences.length > 1 &&
      sentences.length > targetCount &&
      targetCount > 0) {
    sentences = _mergeSentences(sentences, targetCount);
  }
  return sentences;
}

List<String> _splitByLevel(String text, int level) => switch (level) {
  1 => _splitByPunctuation(text),
  2 => _splitByBracketsQuotes(text),
  3 => _splitByWesternWords(text),
  4 => _splitCjkBySpace(text),
  5 => _splitBySpecialChars(text),
  _ => <String>[text],
};

final RegExp _punct = RegExp(r'[，。；！？、…·.,;!?]+');
final RegExp _leadingSpaces = RegExp(r'^\s+');

List<String> _splitByPunctuation(String text) {
  final List<RegExpMatch> matches = _punct.allMatches(text).toList();
  if (matches.isEmpty) return <String>[text];
  final List<String> result = <String>[];
  int lastIndex = 0;
  for (final RegExpMatch m in matches) {
    final int punctStart = m.start;
    final int punctEnd = m.end;
    final RegExpMatch? sp = _leadingSpaces.firstMatch(text.substring(punctEnd));
    final String trailing = sp?.group(0) ?? '';
    final String before = text.substring(lastIndex, punctStart);
    final String punctWithSpaces = m.group(0)! + trailing;
    if (before.isNotEmpty) {
      result.add(before + punctWithSpaces);
    } else if (result.isNotEmpty) {
      result[result.length - 1] += punctWithSpaces;
    } else {
      result.add(punctWithSpaces);
    }
    lastIndex = punctEnd + trailing.length;
  }
  if (lastIndex < text.length) result.add(text.substring(lastIndex));
  return result.where((String r) => r.isNotEmpty).toList();
}

final RegExp _westernBlock = RegExp(
  "[a-zA-Z0-9]+(?:[a-zA-Z0-9'\\-]*[a-zA-Z0-9]+)?"
  "(?:\\s+[a-zA-Z0-9]+(?:[a-zA-Z0-9'\\-]*[a-zA-Z0-9]+)?)+"
  '[.,;:!?。，；：！？]?\\s*',
);
final RegExp _westernWord = RegExp(r'[a-zA-Z0-9]+');

List<String> _splitByWesternWords(String text) {
  if (!_hasCjk(text)) return <String>[text];
  final List<RegExpMatch> blocks = _westernBlock.allMatches(text).toList();
  final bool multi = blocks.any(
    (RegExpMatch m) => _westernWord.allMatches(m.group(0)!).length > 1,
  );
  if (!multi) return <String>[text];
  final List<String> parts = <String>[];
  int lastIndex = 0;
  for (final RegExpMatch m in blocks) {
    final String before = text.substring(lastIndex, m.start);
    if (_shouldSkipBoundary(text, before)) {
      parts.add(before + m.group(0)!);
    } else if (m.start > lastIndex) {
      parts
        ..add(before)
        ..add(m.group(0)!);
    } else {
      parts.add(m.group(0)!);
    }
    lastIndex = m.end;
  }
  if (lastIndex < text.length) parts.add(text.substring(lastIndex));
  return parts.length > 1 ? parts : <String>[text];
}

bool _shouldSkipBoundary(String fullText, String beforeBlock) {
  if (beforeBlock.isEmpty) return false;
  final String sep = beforeBlock[beforeBlock.length - 1];
  if (sep == '-') return true;
  if (sep == ':' ||
      sep == '：' ||
      sep == '/' ||
      sep == '／' ||
      sep == '|' ||
      sep == '｜') {
    return sep.allMatches(fullText).length >= 2;
  }
  return false;
}

/// 成对符号：开、合（引号的开合是同一个字符）。
const List<(String, String)> _pairs = <(String, String)>[
  ('「', '」'),
  ('『', '』'),
  ('《', '》'),
  ('【', '】'),
  ('｛', '｝'),
  ('［', '］'),
  ('[', ']'),
  ('（', '）'),
  ('(', ')'),
  ('"', '"'),
  ("'", "'"),
];

List<String> _splitByBracketsQuotes(String text) {
  final List<String> result = _extractOutermostPairs(text);
  return result.length > 1 ? result : <String>[text];
}

List<String> _extractOutermostPairs(String text) {
  final (int, int)? best = _findOutermostPair(text);
  if (best == null) return <String>[text];
  final (int openStart, int closeEnd) = best;
  final String before = text.substring(0, openStart);
  final String paired = text.substring(openStart, closeEnd);
  final String remainder = text.substring(closeEnd);
  return <String>[
    if (before.isNotEmpty) ..._extractOutermostPairs(before),
    paired,
    if (remainder.isNotEmpty) ..._extractOutermostPairs(remainder),
  ].where((String p) => p.isNotEmpty).toList();
}

(int, int)? _findOutermostPair(String text) {
  (int, int)? best;
  for (final (String open, String close) in _pairs) {
    final int o = text.indexOf(open);
    if (o < 0) continue;
    final int c = text.indexOf(close, o + open.length);
    if (c < 0) continue;
    final (int, int) cand = (o, c + close.length);
    if (best == null || cand.$1 < best.$1) {
      best = cand;
    } else if (cand.$1 == best.$1 && cand.$2 > best.$2) {
      best = cand;
    }
  }
  return best;
}

List<String> _splitCjkBySpace(String text) {
  if (!_hasCjk(text)) return <String>[text];
  final List<String> segments = <String>[];
  String current = '';
  bool inCjk = false;
  for (int i = 0; i < text.length; i++) {
    final String ch = text[i];
    final bool isCjk = _cjk.hasMatch(ch);
    final bool isWestern = _westernChar.hasMatch(ch);
    final bool isSpace = _space.hasMatch(ch);
    if (isCjk) {
      current += ch;
      inCjk = true;
    } else if (isWestern) {
      // 拉丁字符跟随当前块，不做边界。
      current += ch;
    } else if (isSpace) {
      // 全角空格总是断开；半角空格只在 CJK 字后断开。
      final bool fullWidth = ch == '　';
      if (fullWidth && current.isNotEmpty) {
        segments.add(current + ch);
        current = '';
        inCjk = false;
      } else if (inCjk && current.isNotEmpty) {
        if (_cjk.hasMatch(current[current.length - 1])) {
          segments.add(current + ch);
          current = '';
          inCjk = false;
        } else {
          current += ch;
        }
      } else if (current.isEmpty && segments.isNotEmpty) {
        segments[segments.length - 1] += ch;
      } else {
        current += ch;
      }
    } else {
      if (current.isEmpty && segments.isNotEmpty) {
        segments[segments.length - 1] += ch;
      } else {
        current += ch;
      }
    }
  }
  if (current.isNotEmpty) {
    if (segments.isNotEmpty && _allSpace.hasMatch(current)) {
      segments[segments.length - 1] += current;
    } else {
      segments.add(current);
    }
  }
  return segments.length > 1 ? segments : <String>[text];
}

final RegExp _special = RegExp(r'[：:/／\\|｜~～]+');

List<String> _splitBySpecialChars(String text) {
  final List<String> parts = text.split(_special);
  if (parts.where((String p) => p.isNotEmpty).length <= 1) {
    return <String>[text];
  }
  final List<String> result = <String>[];
  int lastIndex = 0;
  for (final String part in parts) {
    final int index = text.indexOf(part, lastIndex);
    if (index > lastIndex) {
      final String sep = text.substring(lastIndex, index);
      if (result.isNotEmpty) {
        result[result.length - 1] += sep;
      } else {
        result.add(sep);
      }
    }
    if (part.isNotEmpty) {
      result.add(part);
      lastIndex = index + part.length;
    } else if (index != -1) {
      lastIndex = index;
    }
  }
  if (lastIndex < text.length) {
    final String tail = text.substring(lastIndex);
    if (result.isNotEmpty) {
      result[result.length - 1] += tail;
    } else {
      result.add(tail);
    }
  }
  return result.where((String r) => r.isNotEmpty).toList();
}

/// 词边界（代替 folia 的 `Intl.Segmenter` word 粒度）：取框架共享的词级分组
/// （`LyricVisualizerLine.segments`，汉字 + 送假名、片假名 / 谚文 / 拉丁连写成词，标点粘连），换成
/// [glyphTexts] 拼起来的整句里的 UTF-16 区间 [start, end)。
List<(int, int)> tiltWordSpans(
  List<String> glyphTexts,
  List<LyricVisualizerSegment> segments,
) {
  final List<int> offsets = <int>[];
  int acc = 0;
  for (final String g in glyphTexts) {
    offsets.add(acc);
    acc += g.length;
  }
  offsets.add(acc);
  return <(int, int)>[
    for (final LyricVisualizerSegment s in segments)
      if (s.glyphCount > 0 && s.firstGlyph + s.glyphCount <= glyphTexts.length)
        (offsets[s.firstGlyph], offsets[s.firstGlyph + s.glyphCount]),
  ];
}

/// 一段纯文字的词边界（没有字形时间线时）：按字形拆开后走同一套共享分组。
List<(int, int)> tiltWordSpansOfText(String text) {
  final List<String> chars = text.characters.toList();
  final List<LyricVisualizerGlyph> glyphs = <LyricVisualizerGlyph>[
    for (final String c in chars)
      LyricVisualizerGlyph(
        text: c,
        startMs: 0,
        endMs: 0,
        syllableIndex: 0,
        isSpace: c.trim().isEmpty,
      ),
  ];
  return tiltWordSpans(chars, buildLyricVisualizerSegments(glyphs));
}

bool _isHighSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;

double _pseudoRandom(double seed) {
  final double x = math.sin(seed) * 10000;
  return x - x.floorToDouble();
}

List<String> _secondarySplit(
  List<String> input,
  int targetCount,
  double timeSeed,
  List<(int, int)> wordSpans,
) {
  final List<String> sentences = List<String>.of(input);
  // 各段在整句里的起点（各级拆分都保持「拼回去等于原文」）。
  final List<int> offsets = <int>[];
  int acc = 0;
  for (final String s in sentences) {
    offsets.add(acc);
    acc += s.length;
  }
  while (sentences.length < targetCount) {
    final List<int> candidates = <int>[
      for (int i = 0; i < sentences.length; i++)
        if (sentences[i].length > 2) i,
    ];
    if (candidates.isEmpty) break;

    int bestIndex = -1;
    int bestSplit = 0;
    double bestScore = double.negativeInfinity;
    for (final int ci in candidates) {
      final String s = sentences[ci];
      final List<(int, int)> words = _spansWithin(
        wordSpans,
        offsets[ci],
        s.length,
      );
      if (words.length < 2) continue;
      final double mid = s.length / 2;
      int bestGap = 1;
      double bestDist = double.infinity;
      for (int g = 1; g < words.length; g++) {
        final double dist = (words[g].$1 - mid).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestGap = g;
        }
      }
      final int splitPos = words[bestGap].$1;
      final double balance = 1 - (splitPos - mid).abs() / mid;
      final double score = balance * 10 + words.length;
      // 同分取靠前的（folia 稳定排序后取 [0]）。
      if (score > bestScore) {
        bestScore = score;
        bestIndex = ci;
        bestSplit = splitPos;
      }
    }
    if (bestIndex >= 0) {
      final String s = sentences[bestIndex];
      sentences.replaceRange(bestIndex, bestIndex + 1, <String>[
        s.substring(0, bestSplit),
        s.substring(bestSplit),
      ]);
      offsets.insert(bestIndex + 1, offsets[bestIndex] + bestSplit);
      continue;
    }

    int textHash = 0;
    for (final String s in sentences) {
      for (final int u in s.codeUnits) {
        textHash += u;
      }
    }
    final double seed = textHash + sentences.length + timeSeed;
    final int pick =
        candidates[(_pseudoRandom(seed) * candidates.length).floor()];
    final String s = sentences[pick];
    int midPoint = s.length ~/ 2;
    // 不把代理对切成两半。
    if (midPoint > 0 &&
        midPoint < s.length &&
        _isHighSurrogate(s.codeUnitAt(midPoint - 1))) {
      midPoint++;
    }
    sentences.replaceRange(pick, pick + 1, <String>[
      s.substring(0, midPoint),
      s.substring(midPoint),
    ]);
    offsets.insert(pick + 1, offsets[pick] + midPoint);
  }
  return sentences;
}

/// 整句词边界里落在 [from, from + length) 的部分，换成段内下标（跨段的词按段边界截开，与 folia
/// 对子串单独分词一致）。
List<(int, int)> _spansWithin(List<(int, int)> spans, int from, int length) {
  final int to = from + length;
  return <(int, int)>[
    for (final (int s, int e) in spans)
      if (s < to && e > from)
        (math.max(s, from) - from, math.min(e, to) - from),
  ];
}

List<String> _mergeSentences(List<String> input, int targetCount) {
  final List<String> sentences = List<String>.of(input);
  while (sentences.length > targetCount) {
    int bestMerge = 0;
    int shortest = 1 << 30;
    for (int i = 0; i < sentences.length - 1; i++) {
      final int combined = sentences[i].length + sentences[i + 1].length;
      if (combined < shortest) {
        shortest = combined;
        bestMerge = i;
      }
    }
    sentences.replaceRange(bestMerge, bestMerge + 2, <String>[
      sentences[bestMerge] + sentences[bestMerge + 1],
    ]);
  }
  return sentences;
}

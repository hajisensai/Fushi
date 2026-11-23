/// 词级分组（folia `src/utils/lyrics/wordSegmentation.ts` 的 `Intl.Segmenter` 词粒度）：把一行的字形
/// 按「文字类别连写」切成词，带时间。
///
/// 不接形态素分析（Sudachi / Lindera 等在功能黑名单里），也没有可同步调用的词典最长匹配，所以按
/// ICU 词断的无词典规则近似：
/// - 拉丁 / 数字连写成一词，词内的 `'` `’` `-` `.`（两侧都是字母数字时）不断；
/// - 片假名连写成一词（含长音 `ー` 与中点之外的片假名记号）；谚文连写成一词；
/// - 日文（行内出现假名）：汉字连写 + 紧跟的平假名送假名成一词，送假名尾部的常见助词
///   （を / が / は / に / で / と / も / へ / の / や / から / まで / より / けど / ので / のに）
///   单独成词；连写超过 4 个汉字时退回逐字（多半是没有词典就切不对的长复合词）；
///   纯平假名连写成一词；
/// - 中文（行内没有假名）：逐字（ICU 无词典时同样逐字）；
/// - 标点 / 符号粘到前一个词上（行首标点粘到后一个词），不单独成词；空白断词、不成词。
library;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 一个字形的文字类别。
enum LyricVisualizerScript {
  space,
  punctuation,
  latin,
  han,
  hiragana,
  katakana,
  hangul,
  other,
}

/// 字形 → 文字类别（看第一个码点）。
LyricVisualizerScript lyricVisualizerScriptOf(String glyph) {
  if (glyph.isEmpty || glyph.trim().isEmpty) return LyricVisualizerScript.space;
  final int c = glyph.runes.first;
  if (c == 0x30FC || c == 0xFF70) return LyricVisualizerScript.katakana; // ー
  if (c >= 0x3041 && c <= 0x309F) return LyricVisualizerScript.hiragana;
  if ((c >= 0x30A0 && c <= 0x30FF && c != 0x30FB) ||
      (c >= 0x31F0 && c <= 0x31FF) ||
      (c >= 0xFF66 && c <= 0xFF9F)) {
    return LyricVisualizerScript.katakana;
  }
  if ((c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x20000 && c <= 0x323AF) ||
      c == 0x3005 || // 々
      c == 0x3006 || // 〆
      c == 0x3007) {
    return LyricVisualizerScript.han;
  }
  if ((c >= 0xAC00 && c <= 0xD7AF) ||
      (c >= 0x1100 && c <= 0x11FF) ||
      (c >= 0x3130 && c <= 0x318F)) {
    return LyricVisualizerScript.hangul;
  }
  if (_isLetterOrDigit(c)) return LyricVisualizerScript.latin;
  if (_punctRe.hasMatch(glyph)) return LyricVisualizerScript.punctuation;
  return LyricVisualizerScript.other;
}

final RegExp _letterRe = RegExp(r'^[\p{L}\p{N}\p{M}]', unicode: true);
final RegExp _punctRe = RegExp(r'^[\p{P}\p{S}]', unicode: true);

bool _isLetterOrDigit(int c) {
  // 全角拉丁字母 / 数字归拉丁。
  if (c >= 0xFF10 && c <= 0xFF19) return true;
  if ((c >= 0xFF21 && c <= 0xFF3A) || (c >= 0xFF41 && c <= 0xFF5A)) {
    return true;
  }
  return _letterRe.hasMatch(String.fromCharCode(c));
}

/// 送假名尾部单独成词的助词（长的在前，最长匹配）。
const List<String> _particles = <String>[
  'から',
  'まで',
  'より',
  'けど',
  'ので',
  'のに',
  'を',
  'が',
  'は',
  'に',
  'で',
  'と',
  'も',
  'へ',
  'の',
  'や',
];

/// 紧跟汉字时开头就是助词（`光を` / `君の`）：不当送假名。不含「で」（`撫でる`）。
const List<String> _leadParticles = <String>[
  'から',
  'まで',
  'より',
  'けど',
  'ので',
  'のに',
  'を',
  'が',
  'は',
  'の',
  'へ',
  'や',
  'に',
  'と',
  'も',
];

/// 词内连接符（两侧都是字母数字时不断词）。
const Set<String> _latinJoiners = <String>{"'", '’', '-', '.'};

/// 一个词组（带时间）。
class LyricVisualizerSegment {
  const LyricVisualizerSegment({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.firstGlyph,
    required this.glyphCount,
    required this.script,
    this.spaceBefore = false,
  });

  /// 词组文本（含粘上的标点）。
  final String text;

  /// 第一个 / 最后一个**有声**字形的起止（粘上的标点不占时长）。
  final int startMs;
  final int endMs;

  /// 在行的 `glyphs` 里的起始下标与字形数（含粘上的标点）。
  final int firstGlyph;
  final int glyphCount;

  /// 主体文字类别。
  final LyricVisualizerScript script;

  /// 前面紧挨着空白（拉丁词间距；CJK 词边界为 false）。
  final bool spaceBefore;

  int get durationMs => endMs - startMs;

  double progress(int timeMs) {
    if (timeMs <= startMs) return 0;
    if (timeMs >= endMs) return 1;
    final int d = endMs - startMs;
    return d <= 0 ? 1 : (timeMs - startMs) / d;
  }

  @override
  String toString() => 'Segment($text $startMs-$endMs)';
}

/// 字形 → 词组（规则见库注释）。
List<LyricVisualizerSegment> buildLyricVisualizerSegments(
  List<LyricVisualizerGlyph> glyphs,
) {
  final int n = glyphs.length;
  if (n == 0) return const <LyricVisualizerSegment>[];
  final List<LyricVisualizerScript> sc = <LyricVisualizerScript>[
    for (final LyricVisualizerGlyph g in glyphs)
      lyricVisualizerScriptOf(g.text),
  ];
  final bool japanese = sc.any(
    (LyricVisualizerScript s) =>
        s == LyricVisualizerScript.hiragana ||
        s == LyricVisualizerScript.katakana,
  );

  // 第一步：只看有字的字形，切成核心区间 [start, end)。
  final List<(int, int, LyricVisualizerScript)> cores =
      <(int, int, LyricVisualizerScript)>[];
  int i = 0;
  while (i < n) {
    final LyricVisualizerScript s = sc[i];
    if (s == LyricVisualizerScript.space ||
        s == LyricVisualizerScript.punctuation) {
      i++;
      continue;
    }
    final int start = i;
    switch (s) {
      case LyricVisualizerScript.latin:
        i++;
        while (i < n) {
          if (sc[i] == LyricVisualizerScript.latin) {
            i++;
          } else if (_latinJoiners.contains(glyphs[i].text) &&
              i + 1 < n &&
              sc[i + 1] == LyricVisualizerScript.latin) {
            i += 2;
          } else {
            break;
          }
        }
        cores.add((start, i, s));
      case LyricVisualizerScript.katakana:
      case LyricVisualizerScript.hangul:
        while (i < n && sc[i] == s) {
          i++;
        }
        cores.add((start, i, s));
      case LyricVisualizerScript.hiragana:
        while (i < n && sc[i] == LyricVisualizerScript.hiragana) {
          i++;
        }
        for (final (int, int) r in _kanaRanges(glyphs, start, i, lead: false)) {
          cores.add((r.$1, r.$2, s));
        }
      case LyricVisualizerScript.han:
        while (i < n && sc[i] == LyricVisualizerScript.han) {
          i++;
        }
        final int hanEnd = i;
        if (!japanese) {
          // 中文：逐字（ICU 无词典时同样逐字）。
          for (int k = start; k < hanEnd; k++) {
            cores.add((k, k + 1, s));
          }
          break;
        }
        // 日文：过长的汉字连写退回逐字，送假名挂在最后一个字上。
        final int stemStart = hanEnd - start > 4 ? hanEnd - 1 : start;
        for (int k = start; k < stemStart; k++) {
          cores.add((k, k + 1, s));
        }
        int kanaEnd = hanEnd;
        while (kanaEnd < n && sc[kanaEnd] == LyricVisualizerScript.hiragana) {
          kanaEnd++;
        }
        final int stemEnd = _okuriganaStemEnd(glyphs, hanEnd, kanaEnd);
        cores.add((stemStart, stemEnd, s));
        for (final (int, int) r in _kanaRanges(
          glyphs,
          stemEnd,
          kanaEnd,
          lead: true,
        )) {
          cores.add((r.$1, r.$2, LyricVisualizerScript.hiragana));
        }
        i = kanaEnd;
      case LyricVisualizerScript.other:
        i++;
        cores.add((start, i, s));
      case LyricVisualizerScript.space:
      case LyricVisualizerScript.punctuation:
        i++;
    }
  }
  if (cores.isEmpty) return const <LyricVisualizerSegment>[];

  // 第二步：标点粘到前一个词（行首标点粘到第一个词）；空白不进词。
  final List<LyricVisualizerSegment> out = <LyricVisualizerSegment>[];
  for (int k = 0; k < cores.length; k++) {
    final (int cs, int ce, LyricVisualizerScript script) = cores[k];
    int from = cs;
    if (k == 0) {
      while (from > 0 && sc[from - 1] == LyricVisualizerScript.punctuation) {
        from--;
      }
    }
    int to = ce;
    final int limit = k + 1 < cores.length ? cores[k + 1].$1 : n;
    while (to < limit && sc[to] == LyricVisualizerScript.punctuation) {
      to++;
    }
    // 下一个词前的开引号 / 开括号归下一个词（「 ( “）：只在紧贴下一个词时。
    while (to > ce &&
        k + 1 < cores.length &&
        to == limit &&
        _isOpening(glyphs[to - 1].text)) {
      to--;
    }
    if (k > 0) {
      // 上一个词留下的开标点并到本词前面。
      final int prevTo = out.last.firstGlyph + out.last.glyphCount;
      while (from > prevTo &&
          sc[from - 1] == LyricVisualizerScript.punctuation) {
        from--;
      }
    }
    final bool spaceBefore =
        from > 0 && sc[from - 1] == LyricVisualizerScript.space;
    final StringBuffer text = StringBuffer();
    for (int g = from; g < to; g++) {
      text.write(glyphs[g].text);
    }
    out.add(
      LyricVisualizerSegment(
        text: text.toString(),
        startMs: glyphs[cs].startMs,
        endMs: glyphs[ce - 1].endMs,
        firstGlyph: from,
        glyphCount: to - from,
        script: script,
        spaceBefore: spaceBefore,
      ),
    );
  }
  return out;
}

bool _isOpening(String g) => const <String>{
  '「',
  '『',
  '（',
  '(',
  '[',
  '【',
  '“',
  '‘',
  '《',
  '〈',
  '{',
}.contains(g);

String _kanaText(List<LyricVisualizerGlyph> glyphs, int a, int b) {
  final StringBuffer t = StringBuffer();
  for (int k = a; k < b; k++) {
    t.write(glyphs[k].text);
  }
  return t.toString();
}

/// 紧跟汉字的平假名里，哪些算送假名：以助词开头（`光を`）则一个不算；以助词结尾（`探して…`
/// 不会，`君が` 会）则助词之前的算；否则整段都算（`見つめて` / `会おう`）。
int _okuriganaStemEnd(List<LyricVisualizerGlyph> glyphs, int from, int end) {
  if (end == from) return from;
  final String kana = _kanaText(glyphs, from, end);
  for (final String p in _leadParticles) {
    if (kana.startsWith(p)) return from;
  }
  for (final String p in _particles) {
    if (kana.endsWith(p)) return end - p.length;
  }
  return end;
}

/// 一段平假名切成词：[lead] 时先切出开头的助词；结尾的助词在剩下至少两个假名时单独成词。
List<(int, int)> _kanaRanges(
  List<LyricVisualizerGlyph> glyphs,
  int from,
  int end, {
  required bool lead,
}) {
  final List<(int, int)> out = <(int, int)>[];
  int a = from;
  if (a >= end) return out;
  if (lead) {
    final String kana = _kanaText(glyphs, a, end);
    for (final String p in _leadParticles) {
      if (kana.startsWith(p)) {
        out.add((a, a + p.length));
        a += p.length;
        break;
      }
    }
  }
  if (a >= end) return out;
  final String rest = _kanaText(glyphs, a, end);
  for (final String p in _particles) {
    if (rest.endsWith(p) && rest.length - p.length >= 2) {
      out.add((a, end - p.length));
      out.add((end - p.length, end));
      return out;
    }
  }
  out.add((a, end));
  return out;
}

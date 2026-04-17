import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

/// EPUB 一个章节，供 [EpubSrtMatcher] 使用。
///
/// `text` 必须是剥离 HTML 后的纯文本，一般通过 ttu IDB 的 `elementHtml`
/// 或原始 XHTML 抽取得到。
class EpubSection {
  const EpubSection({
    required this.index,
    required this.href,
    required this.text,
  });

  final int index;
  final String href;
  final String text;
}

/// 单条 cue 在 EPUB 里的匹配结果。
///
/// 偏移以**规范化后**（去掉空白与常见标点、ASCII 小写化）的字符位置给出。
/// S4 popup/高亮若需要 DOM 坐标，需在渲染时再做一次同规则的反向映射。
class CueMatch {
  const CueMatch({
    required this.cueSentenceIndex,
    required this.sectionIndex,
    required this.normCharStart,
    required this.normCharEnd,
    required this.score,
  });

  static const CueMatch unmatched = CueMatch(
    cueSentenceIndex: -1,
    sectionIndex: -1,
    normCharStart: -1,
    normCharEnd: -1,
    score: 0,
  );

  final int cueSentenceIndex;
  final int sectionIndex;
  final int normCharStart;
  final int normCharEnd;
  final double score;

  bool get matched => sectionIndex >= 0;
}

class MatchResult {
  const MatchResult({
    required this.matches,
    required this.totalCues,
    required this.matchedCues,
  });

  final List<CueMatch> matches;
  final int totalCues;
  final int matchedCues;

  double get matchRate => totalCues == 0 ? 0.0 : matchedCues / totalCues;
}

/// Sasayaki 风格 EPUB↔SRT 匹配器。
///
/// 算法：
/// 1. 章节文本线性化 + 规范化（去空白/标点、ASCII 小写）
/// 2. 按 cue 顺序向前滑窗：窗口 `[cursor, cursor + searchWindow)`
/// 3. 取与 cue 等长切片，用字符 bigram Jaccard 打分
/// 4. 粗扫（step = max(1, cueLen/10)）+ 命中后步长=1 精修
/// 5. 分数 ≥ `scoreThreshold` 视为命中，cursor 前进到命中末尾；
///    未命中则 cursor 不动，给下一条 cue 重新对齐的机会。
class EpubSrtMatcher {
  static const int defaultSearchWindow = 500;
  static const double defaultScoreThreshold = 0.4;

  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
    double scoreThreshold = defaultScoreThreshold,
  }) {
    if (cues.isEmpty) {
      return const MatchResult(
        matches: <CueMatch>[],
        totalCues: 0,
        matchedCues: 0,
      );
    }
    if (sections.isEmpty) {
      return MatchResult(
        matches: List<CueMatch>.filled(cues.length, CueMatch.unmatched),
        totalCues: cues.length,
        matchedCues: 0,
      );
    }

    final _Index idx = _buildIndex(sections);
    final String big = idx.normText;
    final int totalLen = big.length;

    final List<CueMatch> results = <CueMatch>[];
    int cursor = 0;
    int matched = 0;

    for (final AudioCue cue in cues) {
      final String nc = _normalize(cue.text);
      if (nc.length < 2) {
        results.add(CueMatch.unmatched);
        continue;
      }

      final Set<String> cueGrams = _bigrams(nc);
      if (cueGrams.isEmpty) {
        results.add(CueMatch.unmatched);
        continue;
      }

      final int windowEnd = (cursor + searchWindow).clamp(0, totalLen);
      final int searchEnd = (windowEnd - nc.length).clamp(cursor, totalLen);
      final int step = (nc.length ~/ 10).clamp(1, 3);

      double bestScore = 0;
      int bestStart = -1;

      for (int i = cursor; i <= searchEnd; i += step) {
        final double s = _scoreAt(big, i, nc.length, cueGrams);
        if (s > bestScore) {
          bestScore = s;
          bestStart = i;
        }
      }

      if (bestStart >= 0 && step > 1) {
        final int lo = (bestStart - step).clamp(cursor, totalLen);
        final int hi = (bestStart + step).clamp(0, searchEnd);
        for (int i = lo; i <= hi; i++) {
          final double s = _scoreAt(big, i, nc.length, cueGrams);
          if (s > bestScore) {
            bestScore = s;
            bestStart = i;
          }
        }
      }

      if (bestStart >= 0 && bestScore >= scoreThreshold) {
        final int endN = (bestStart + nc.length).clamp(0, totalLen);
        final int secIdx = _sectionForOffset(idx.sectionNormStarts, bestStart);
        results.add(CueMatch(
          cueSentenceIndex: cue.sentenceIndex,
          sectionIndex: secIdx,
          normCharStart: bestStart - idx.sectionNormStarts[secIdx],
          normCharEnd: endN - idx.sectionNormStarts[secIdx],
          score: bestScore,
        ));
        cursor = endN;
        matched++;
      } else {
        results.add(CueMatch.unmatched);
      }
    }

    return MatchResult(
      matches: results,
      totalCues: cues.length,
      matchedCues: matched,
    );
  }

  // ---------- internals ----------

  static double _scoreAt(String big, int start, int len, Set<String> grams) {
    final int end = start + len;
    if (end > big.length) {
      return 0;
    }
    final Set<String> sliceGrams = _bigramsRange(big, start, end);
    if (sliceGrams.isEmpty) {
      return 0;
    }
    return _jaccard(grams, sliceGrams);
  }

  static _Index _buildIndex(List<EpubSection> sections) {
    final StringBuffer buf = StringBuffer();
    final List<int> normStarts = <int>[];
    for (final EpubSection s in sections) {
      normStarts.add(buf.length);
      _appendNormalized(buf, s.text);
    }
    return _Index(buf.toString(), normStarts);
  }

  static String _normalize(String s) {
    final StringBuffer buf = StringBuffer();
    _appendNormalized(buf, s);
    return buf.toString();
  }

  static void _appendNormalized(StringBuffer buf, String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (_isSkippable(c)) {
        continue;
      }
      if (c >= 0x41 && c <= 0x5A) {
        buf.writeCharCode(c + 0x20);
      } else {
        buf.writeCharCode(c);
      }
    }
  }

  static const Set<int> _cjkPunct = <int>{
    0x3000, 0x3001, 0x3002, 0x300C, 0x300D, 0x300E, 0x300F,
    0x301C, 0x301D, 0x301E, 0x301F, 0x2026, 0x2014, 0x2015,
    0xFF01, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF08, 0xFF09,
    0xFF0D, 0xFF3B, 0xFF3D, 0xFF5B, 0xFF5D,
  };

  static bool _isSkippable(int c) {
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      return true;
    }
    if (c >= 0x21 && c <= 0x2F) {
      return true;
    }
    if (c >= 0x3A && c <= 0x40) {
      return true;
    }
    if (c >= 0x5B && c <= 0x60) {
      return true;
    }
    if (c >= 0x7B && c <= 0x7E) {
      return true;
    }
    return _cjkPunct.contains(c);
  }

  static Set<String> _bigrams(String s) {
    if (s.length < 2) {
      return <String>{};
    }
    final Set<String> out = <String>{};
    for (int i = 0; i < s.length - 1; i++) {
      out.add(s.substring(i, i + 2));
    }
    return out;
  }

  static Set<String> _bigramsRange(String s, int start, int end) {
    if (end - start < 2) {
      return <String>{};
    }
    final Set<String> out = <String>{};
    for (int i = start; i < end - 1; i++) {
      out.add(s.substring(i, i + 2));
    }
    return out;
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    final Set<String> small = a.length < b.length ? a : b;
    final Set<String> big = identical(small, a) ? b : a;
    int inter = 0;
    for (final String k in small) {
      if (big.contains(k)) {
        inter++;
      }
    }
    return inter / (a.length + b.length - inter);
  }

  static int _sectionForOffset(List<int> starts, int offset) {
    int lo = 0;
    int hi = starts.length - 1;
    int ans = 0;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      if (starts[mid] <= offset) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

class _Index {
  const _Index(this.normText, this.sectionNormStarts);

  final String normText;
  final List<int> sectionNormStarts;
}

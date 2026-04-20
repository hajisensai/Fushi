import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

/// EPUB 一个章节，供 [EpubSrtMatcher] 使用。
///
/// `text` 必须是剥离 HTML（含 ruby `<rt>/<rp>`）后的纯文本，一般通过 ttu IDB
/// 的 `elementHtml` 或原始 XHTML 抽取得到。
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
/// 偏移以**规范化后**（白名单保留假名/汉字/字母数字，其余剥掉）的字符位置
/// 给出。运行时高亮若需要 DOM 坐标，WebView 侧必须用**完全相同的规范化
/// 规则**（见 `audiobook_bridge.dart::__hoshiIsSkippable`）走 text node 数过来。
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

  /// 精确子串匹配命中 = 1.0，未命中 = 0.0。字段保留是为了给 UI / codec 留
  /// 一个可扩展口子，不再用于阈值判断。
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

/// Sasayaki 风格 EPUB↔SRT 匹配器（对齐 Hoshi-Reader iOS 实现）。
///
/// 算法：
/// 1. 章节文本拼成一串 `big`，同时记录每章在 `big` 里的起点。
/// 2. 规范化用**白名单**：只保留 假名 / 汉字 / CJK 扩展 A / ASCII & 全角字母
///    数字 / 半角假名。其它（句读、引号、`＊` 叙述标记、空白、ruby 注音
///    剥完后的残留空格等）一律扔掉。
/// 3. **起点检测**：取前 15 条 cue，跳过以 `＊` 开头的旁白 / 标题 cue，
///    跳过规范化后 < 6 字的短 cue，在全书做一次精确 `indexOf`，取最小命中
///    位置作为 cursor 起点。可以跳过音频前置的 OP 朗读。
/// 4. **精确主循环**：对每条 cue，在 `big[cursor, cursor + searchWindow]` 内做
///    精确子串 `indexOf`。命中则 cursor 推到子串末尾；未命中直接标记
///    unmatched，cursor 不动，下条 cue 重新找。
/// 5. **模糊兜底（gap-fill）**：对"夹在两条已精确匹配 cue 之间"的未匹配
///    cue，在已知的狭窄区间 `big[prev.end, next.start]` 内滑动固定长度窗口
///    跑有界 Levenshtein，相似度 ≥ [fuzzyThreshold] 就补一条 CueMatch。
///    只在两条锚点之间搜，不做全书漫搜，误配率可控。
class EpubSrtMatcher {
  /// 对齐官方 iOS Sasayaki `SasayakiMatchView` 的默认值（`searchWindow: Double = 200`）。
  /// 窗口越小越不容易被短 `＊` 噪声 cue 拉飞 cursor：当 SRT 是 Whisper 裸转写
  /// 把书名/作者/出版社朗读套了 `＊` 前缀时，1500 级别窗口会让 2 字 cue（`いつ`
  /// 之类）在 1500 字内蒙到一个假命中，后续长 cue 全部掉到 cursor 之后。
  static const int defaultSearchWindow = 200;

  /// 起点检测扫描的 cue 数量上限。
  static const int defaultProbeCount = 15;

  /// 起点检测 probe cue 的最小归一化长度，短于此忽略（避免短词在全书
  /// 命中偏前的歧义位置拉偏起点）。
  static const int defaultProbeMinLen = 6;

  /// 模糊兜底的相似度下限（1 - editDistance / len）。
  static const double fuzzyThreshold = 0.85;

  /// 模糊兜底对 cue 的最小归一化长度下限，太短不做模糊（假命中概率高）。
  static const int fuzzyMinLen = 6;

  /// 单个 gap 内最多扫多长（上限保险，防病态 cue 在一大段空白里拖时间）。
  static const int fuzzyMaxGapScan = 4000;

  /// 在后台 isolate 里跑 [match]。
  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
  }) {
    final _MatchRequest req = _MatchRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      searchWindow: searchWindow,
    );
    return compute(_matchEntrypoint, req);
  }

  /// 同一份 sections + cues 在 isolate 里顺序试多档 searchWindow，返回每档的
  /// matchRate（0..1）。数据只拷贝一次，明显快过 7 次 [matchInIsolate]。
  /// gap-fill 也走一遍，口径与正式匹配一致，用户看到的命中率≈真实导入后的
  /// 命中率。
  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required List<int> windows,
  }) {
    final _ProbeRequest req = _ProbeRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      windows: windows,
    );
    return compute(_probeEntrypoint, req);
  }

  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
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

    final int start = _findStart(big, cues);
    debugPrint('[sasayaki] matcher: sections=${sections.length} '
        'totalNormLen=$totalLen cues=${cues.length} startCursor=$start');
    // dump 每段累计起点 + 长度，方便和 JS __hoshiLoadSasayakiRefs 的
    // sasayakiRefsReady 日志对账（两侧累计 norm 长度必须一致，否则
    // sectionIndex 索引到的 base 会偏，命中率高也会高亮错位）。
    for (int si = 0; si < sections.length; si++) {
      final int s0 = idx.sectionNormStarts[si];
      final int s1 = (si + 1 < sections.length)
          ? idx.sectionNormStarts[si + 1]
          : totalLen;
      debugPrint('[sasayaki] matcher.section[$si] href="${sections[si].href}" '
          'normStart=$s0 normLen=${s1 - s0}');
    }

    final List<CueMatch> results = <CueMatch>[];
    int cursor = start;
    int matched = 0;

    for (final AudioCue cue in cues) {
      final String nc = _normalize(cue.text);
      if (nc.isEmpty) {
        results.add(CueMatch.unmatched);
        continue;
      }

      final int windowEnd = (cursor + searchWindow).clamp(0, totalLen);
      if (windowEnd - cursor < nc.length) {
        results.add(CueMatch.unmatched);
        continue;
      }

      final int found = big.indexOf(nc, cursor);
      if (found < 0 || found + nc.length > windowEnd) {
        results.add(CueMatch.unmatched);
        continue;
      }

      final int matchEnd = found + nc.length;
      final int secIdx = _sectionForOffset(idx.sectionNormStarts, found);
      results.add(CueMatch(
        cueSentenceIndex: cue.sentenceIndex,
        sectionIndex: secIdx,
        normCharStart: found - idx.sectionNormStarts[secIdx],
        normCharEnd: matchEnd - idx.sectionNormStarts[secIdx],
        score: 1.0,
      ));

      // 抽样打印前 5 / 最后 1 条命中：把 cue.text、normalize 后的串、以及 big
      // 串里实际命中的子串放在一起。三者应当是同一段（normalized cue == big
      // 子串），如果不一致说明 normalize 规则与 big 拼接逻辑不同步。
      if (matched < 5 || cue == cues.last) {
        final String snippet = big.substring(found, matchEnd);
        debugPrint('[sasayaki] matcher.hit#${matched} sid=${cue.sentenceIndex} '
            'sec=$secIdx ns=${found - idx.sectionNormStarts[secIdx]} '
            'cue="${_clip(cue.text, 24)}" '
            'norm="${_clip(nc, 24)}" '
            'big="${_clip(snippet, 24)}"');
      }

      cursor = matchEnd;
      matched++;
    }

    debugPrint('[sasayaki] matcher done (exact): matched=$matched/${cues.length} '
        'finalCursor=$cursor/$totalLen');

    final int filled = _gapFill(
      results: results,
      cues: cues,
      big: big,
      idx: idx,
      searchWindow: searchWindow,
    );
    if (filled > 0) {
      matched += filled;
      debugPrint('[sasayaki] matcher done (fuzzy gap-fill): +$filled '
          'final=$matched/${cues.length}');
    }

    return MatchResult(
      matches: results,
      totalCues: cues.length,
      matchedCues: matched,
    );
  }

  /// 第二遍：对"夹在两条已匹配 cue 之间"的未匹配 cue 做模糊兜底。
  ///
  /// 只在两条锚点之间的狭窄 gap（`big[prev.globalEnd, next.globalStart]`）里搜，
  /// 不漫搜全书。命中后推进 gap 内的局部 cursor，下一条未匹配 cue 继续从这里
  /// 往后搜，保证同一 gap 内多条 cue 的相对顺序。
  ///
  /// 返回本次补上的 cue 数。
  static int _gapFill({
    required List<CueMatch> results,
    required List<AudioCue> cues,
    required String big,
    required _Index idx,
    required int searchWindow,
  }) {
    int added = 0;
    int i = 0;
    while (i < results.length) {
      if (results[i].matched) {
        i++;
        continue;
      }
      int j = i;
      while (j < results.length && !results[j].matched) {
        j++;
      }

      // 三种锚点形态决定 gap 在 big 里的搜索范围（都尊重 searchWindow，
      // 避免漫搜全书）：
      // - 两端皆有锚：[prevEnd, min(prevEnd + searchWindow, nextStart)]。
      //   正常夹心场景。
      // - 仅后有锚（i==0）：[max(0, nextStart - searchWindow), nextStart]。
      //   首条 cue 因微差精确失败、但后续正常锚点到位时走这里；旧实现
      //   把 gapStart 钉在 probe 起点，等价于 nextStart，gap 为空错过首句。
      // - 仅前有锚（j==len）：[prevEnd, prevEnd + searchWindow]。尾段兜底。
      // - 全书无锚：跳过，避免误把完全不匹配的 SRT/EPUB 对靠模糊拼起来。
      final bool hasPrev = i > 0;
      final bool hasNext = j < results.length;
      int gapStart;
      int gapEnd;
      if (hasPrev && hasNext) {
        gapStart = _globalEnd(results[i - 1], idx);
        final int nextStart = _globalStart(results[j], idx);
        gapEnd = (gapStart + searchWindow).clamp(0, nextStart);
      } else if (hasNext) {
        final int nextStart = _globalStart(results[j], idx);
        gapEnd = nextStart;
        gapStart = (nextStart - searchWindow).clamp(0, nextStart);
      } else if (hasPrev) {
        gapStart = _globalEnd(results[i - 1], idx);
        gapEnd = (gapStart + searchWindow).clamp(0, big.length);
      } else {
        i = j;
        continue;
      }

      if (gapEnd > gapStart && (gapEnd - gapStart) <= fuzzyMaxGapScan) {
        int cursor = gapStart;
        for (int k = i; k < j; k++) {
          final String nc = _normalize(cues[k].text);
          if (nc.length < fuzzyMinLen) {
            continue;
          }
          if (gapEnd - cursor < nc.length) {
            break;
          }
          final _FuzzyHit? hit = _fuzzyFind(big, nc, cursor, gapEnd);
          if (hit == null) {
            continue;
          }
          final int secIdx =
              _sectionForOffset(idx.sectionNormStarts, hit.start);
          results[k] = CueMatch(
            cueSentenceIndex: cues[k].sentenceIndex,
            sectionIndex: secIdx,
            normCharStart: hit.start - idx.sectionNormStarts[secIdx],
            normCharEnd: hit.end - idx.sectionNormStarts[secIdx],
            score: hit.similarity,
          );
          added++;
          cursor = hit.end;
          if (added <= 5) {
            final String snippet = big.substring(hit.start, hit.end);
            debugPrint('[sasayaki] matcher.fuzzy#$added sid=${cues[k].sentenceIndex} '
                'sec=$secIdx sim=${hit.similarity.toStringAsFixed(2)} '
                'cue="${_clip(cues[k].text, 24)}" '
                'norm="${_clip(nc, 24)}" '
                'big="${_clip(snippet, 24)}"');
          }
        }
      }

      i = j;
    }
    return added;
  }

  /// 在 `big[start, end)` 内，以长度 L=nc.length 滑动窗口跑有界 Levenshtein，
  /// 取编辑距离最小的窗口；若 1 - d/L ≥ [fuzzyThreshold] 则返回该窗口。
  ///
  /// 注：保守使用等长窗口，让 Levenshtein 自己吞小的插入/删除；窗口长度
  /// 与 cue 差 1 字的情形，边界 1~2 的 edit cost 会被吸收，不影响阈值判断。
  static _FuzzyHit? _fuzzyFind(String big, String nc, int start, int end) {
    final int L = nc.length;
    final int scanEnd = end - L;
    if (scanEnd < start) {
      return null;
    }
    final int allowed = (L * (1 - fuzzyThreshold)).floor();
    int bestD = allowed + 1;
    int bestPos = -1;
    for (int p = start; p <= scanEnd; p++) {
      final int d = _levBounded(nc, big, p, L, bestD - 1);
      if (d < bestD) {
        bestD = d;
        bestPos = p;
        if (bestD == 0) {
          break;
        }
      }
    }
    if (bestPos < 0) {
      return null;
    }
    final double sim = 1.0 - bestD / L;
    if (sim < fuzzyThreshold) {
      return null;
    }
    return _FuzzyHit(bestPos, bestPos + L, sim);
  }

  /// Levenshtein(a, big[bStart, bStart+bLen])，超过 [maxDist] 提前终止。
  static int _levBounded(
      String a, String big, int bStart, int bLen, int maxDist) {
    final int n = a.length;
    final int m = bLen;
    if (maxDist < 0) {
      return (n == m) ? _levUnbounded(a, big, bStart, bLen) : 1;
    }
    if ((n - m).abs() > maxDist) {
      return maxDist + 1;
    }
    List<int> prev = List<int>.filled(m + 1, 0);
    List<int> curr = List<int>.filled(m + 1, 0);
    for (int j = 0; j <= m; j++) {
      prev[j] = j;
    }
    for (int i = 1; i <= n; i++) {
      curr[0] = i;
      int rowMin = i;
      final int ac = a.codeUnitAt(i - 1);
      for (int j = 1; j <= m; j++) {
        final int bc = big.codeUnitAt(bStart + j - 1);
        final int cost = (ac == bc) ? 0 : 1;
        int v = prev[j] + 1;
        final int left = curr[j - 1] + 1;
        if (left < v) {
          v = left;
        }
        final int diag = prev[j - 1] + cost;
        if (diag < v) {
          v = diag;
        }
        curr[j] = v;
        if (v < rowMin) {
          rowMin = v;
        }
      }
      if (rowMin > maxDist) {
        return maxDist + 1;
      }
      final List<int> tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[m];
  }

  // maxDist<0 的路径：只在 bestD 已经更新到 0 之后才会走到，这里给个保守
  // 兜底（逐字符比对），实测几乎不会被命中。
  static int _levUnbounded(String a, String big, int bStart, int bLen) {
    int d = 0;
    for (int i = 0; i < a.length && i < bLen; i++) {
      if (a.codeUnitAt(i) != big.codeUnitAt(bStart + i)) {
        d++;
      }
    }
    return d + (a.length - bLen).abs();
  }

  static int _globalStart(CueMatch m, _Index idx) =>
      idx.sectionNormStarts[m.sectionIndex] + m.normCharStart;

  static int _globalEnd(CueMatch m, _Index idx) =>
      idx.sectionNormStarts[m.sectionIndex] + m.normCharEnd;

  /// 取前 [defaultProbeCount] 条 cue，跳过 `＊` 开头 & 太短的，在全书做 indexOf，
  /// 返回最小命中偏移；全部 miss 则回到 0。
  static int _findStart(String big, List<AudioCue> cues) {
    int? minStart;
    final int limit =
        cues.length < defaultProbeCount ? cues.length : defaultProbeCount;
    for (int i = 0; i < limit; i++) {
      final String raw = cues[i].text;
      if (raw.startsWith('＊') || raw.startsWith('*')) {
        continue;
      }
      final String nc = _normalize(raw);
      if (nc.length < defaultProbeMinLen) {
        continue;
      }
      final int found = big.indexOf(nc);
      if (found >= 0) {
        if (minStart == null || found < minStart) {
          minStart = found;
        }
      }
    }
    return minStart ?? 0;
  }

  /// 截断中含日文字符串到 [n] 字符，给日志用，避免 30+ 字的句子刷屏。
  static String _clip(String s, int n) {
    final String r = s.replaceAll('\n', '\\n').replaceAll('\r', '\\r');
    return r.length <= n ? r : '${r.substring(0, n)}…';
  }

  // ---------- normalize ----------

  static String _normalize(String s) {
    final StringBuffer buf = StringBuffer();
    _appendNormalized(buf, s);
    return buf.toString();
  }

  static void _appendNormalized(StringBuffer buf, String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (!_isKeepable(c)) {
        continue;
      }
      if (c >= 0x41 && c <= 0x5A) {
        // ASCII uppercase → lowercase
        buf.writeCharCode(c + 0x20);
      } else if (c >= 0xFF21 && c <= 0xFF3A) {
        // Fullwidth uppercase → fullwidth lowercase
        buf.writeCharCode(c + 0x20);
      } else {
        buf.writeCharCode(c);
      }
    }
  }

  /// 白名单：只保留日文正文字符（假名 / 汉字 / CJK 扩展 A / 迭代符）+ 字母
  /// 数字（ASCII 与全角 / 半角）。
  ///
  /// 与 `audiobook_bridge.dart::__hoshiIsSkippable` 的 JS 镜像必须**严格一致**，
  /// 否则 matcher 写回的 normCharStart/End 与 WebView 运行期计数对不上，高亮
  /// 会漂。
  static bool _isKeepable(int c) {
    // ASCII 0-9
    if (c >= 0x30 && c <= 0x39) return true;
    // ASCII A-Z
    if (c >= 0x41 && c <= 0x5A) return true;
    // ASCII a-z
    if (c >= 0x61 && c <= 0x7A) return true;
    // 々 〆 〇
    if (c == 0x3005 || c == 0x3006 || c == 0x3007) return true;
    // Hiragana ぁ-ゖ
    if (c >= 0x3041 && c <= 0x3096) return true;
    // Hiragana ゝゞゟ
    if (c >= 0x309D && c <= 0x309F) return true;
    // Katakana ァ-ヺ
    if (c >= 0x30A1 && c <= 0x30FA) return true;
    // Katakana ー ヽ ヾ ヿ
    if (c >= 0x30FC && c <= 0x30FF) return true;
    // CJK Extension A
    if (c >= 0x3400 && c <= 0x4DBF) return true;
    // CJK Unified Ideographs
    if (c >= 0x4E00 && c <= 0x9FFF) return true;
    // Fullwidth ０-９
    if (c >= 0xFF10 && c <= 0xFF19) return true;
    // Fullwidth Ａ-Ｚ
    if (c >= 0xFF21 && c <= 0xFF3A) return true;
    // Fullwidth ａ-ｚ
    if (c >= 0xFF41 && c <= 0xFF5A) return true;
    // Halfwidth katakana ｦ-ﾝ
    if (c >= 0xFF66 && c <= 0xFF9D) return true;
    return false;
  }

  // ---------- index ----------

  static _Index _buildIndex(List<EpubSection> sections) {
    final StringBuffer buf = StringBuffer();
    final List<int> normStarts = <int>[];
    for (final EpubSection s in sections) {
      normStarts.add(buf.length);
      _appendNormalized(buf, s.text);
    }
    return _Index(buf.toString(), normStarts);
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

class _FuzzyHit {
  const _FuzzyHit(this.start, this.end, this.similarity);

  final int start;
  final int end;
  final double similarity;
}

class _MatchRequest {
  const _MatchRequest({
    required this.sections,
    required this.cueTexts,
    required this.cueIndexes,
    required this.searchWindow,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final int searchWindow;
}

MatchResult _matchEntrypoint(_MatchRequest req) {
  final List<AudioCue> cues = _rebuildCues(req.cueTexts, req.cueIndexes);
  return EpubSrtMatcher.match(
    sections: req.sections,
    cues: cues,
    searchWindow: req.searchWindow,
  );
}

/// [EpubSrtMatcher.probeInIsolate] 的结果。
class ProbeResult {
  const ProbeResult({required this.perWindow});

  /// window（字符数） → matchRate（0..1）。
  final Map<int, double> perWindow;

  /// 取命中率最高者；并列时取窗口较小的一档（更抗短 cue 噪声）。
  /// perWindow 为空返回 null。
  MapEntry<int, double>? get best {
    MapEntry<int, double>? top;
    for (final MapEntry<int, double> e in perWindow.entries) {
      if (top == null ||
          e.value > top.value + 1e-9 ||
          (e.value > top.value - 1e-9 && e.key < top.key)) {
        top = e;
      }
    }
    return top;
  }
}

class _ProbeRequest {
  const _ProbeRequest({
    required this.sections,
    required this.cueTexts,
    required this.cueIndexes,
    required this.windows,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final List<int> windows;
}

ProbeResult _probeEntrypoint(_ProbeRequest req) {
  final Map<int, double> map = <int, double>{};
  for (final int w in req.windows) {
    // 每档都用 fresh cues，避免 match() 内部可能对 cue 字段的一次性写入
    // 污染下一档的探测（目前 match 不写 cue，但新建更稳）。
    final List<AudioCue> cues = _rebuildCues(req.cueTexts, req.cueIndexes);
    final MatchResult r = EpubSrtMatcher.match(
      sections: req.sections,
      cues: cues,
      searchWindow: w,
    );
    map[w] = r.matchRate;
  }
  return ProbeResult(perWindow: map);
}

List<AudioCue> _rebuildCues(List<String> texts, List<int> indexes) {
  return <AudioCue>[
    for (int i = 0; i < texts.length; i++)
      (AudioCue()
        ..bookUid = ''
        ..chapterHref = ''
        ..sentenceIndex = indexes[i]
        ..textFragmentId = ''
        ..text = texts[i]
        ..startMs = 0
        ..endMs = 0
        ..audioFileIndex = 0),
  ];
}

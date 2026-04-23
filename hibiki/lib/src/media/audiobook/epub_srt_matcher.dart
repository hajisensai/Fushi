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

  /// 精确子串匹配命中 = 1.0，Dice 模糊命中 = 阈值..1.0，未命中 = 0.0。
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

/// EPUB↔字幕匹配器，移植自 ttu-whispersync 的 Dice 系数模糊匹配。
///
/// 算法：
/// 1. 章节文本拼成一串 `big`，同时记录每章在 `big` 里的起点。
/// 2. 规范化用**白名单**：只保留 假名 / 汉字 / CJK 扩展 A / ASCII & 全角字母
///    数字 / 半角假名。其它（句读、引号、`＊` 叙述标记、空白、ruby 注音
///    剥完后的残留空格等）一律扔掉。
/// 3. **起点检测**：取前 15 条 cue，跳过以 `＊` 开头的旁白 / 标题 cue，
///    跳过规范化后 < 6 字的短 cue，在全书做精确 `indexOf`（+ 模糊兜底），
///    取最小命中位置作为 cursor 起点。
/// 4. **主循环**（移植自 ttu-whispersync Match.svelte）：
///    a. 快速通道：精确 `indexOf` 命中 → score=1.0，cursor 推进。
///    b. 模糊兜底：在 `[cursor, cursor+searchWindow]` 内滑窗扫描，取 Dice
///       系数最高的位置；达到 [similarityThreshold] 则接受。
///    c. 重试机制：未命中时从上次命中位置向前偏移重试，最多
///       [maxMatchAttempts] 次，全部失败才标 unmatched。
class EpubSrtMatcher {
  static const int defaultSearchWindow = 200;
  static const int defaultProbeCount = 15;
  static const int defaultProbeMinLen = 6;
  static const double defaultSimilarityThreshold = 0.8;
  static const int defaultMaxMatchAttempts = 500;

  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxMatchAttempts = defaultMaxMatchAttempts,
  }) {
    final _MatchRequest req = _MatchRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxMatchAttempts: maxMatchAttempts,
    );
    return compute(_matchEntrypoint, req);
  }

  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required List<int> windows,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxMatchAttempts = defaultMaxMatchAttempts,
  }) {
    final _ProbeRequest req = _ProbeRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      windows: windows,
      similarityThreshold: similarityThreshold,
      maxMatchAttempts: maxMatchAttempts,
    );
    return compute(_probeEntrypoint, req);
  }

  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxMatchAttempts = defaultMaxMatchAttempts,
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

    final int start = _findStart(big, cues, similarityThreshold);
    debugPrint('[sasayaki] matcher: sections=${sections.length} '
        'totalNormLen=$totalLen cues=${cues.length} startCursor=$start '
        'threshold=$similarityThreshold');
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
    int cursorAfterLastMatch = start;
    int matched = 0;

    for (int ci = 0; ci < cues.length; ci++) {
      final AudioCue cue = cues[ci];
      final String nc = _normalize(cue.text);
      if (nc.isEmpty) {
        results.add(CueMatch.unmatched);
        continue;
      }

      // --- 快速通道：精确 indexOf ---
      final int windowEnd = (cursor + searchWindow).clamp(0, totalLen);
      if (windowEnd - cursor >= nc.length) {
        final int found = big.indexOf(nc, cursor);
        if (found >= 0 && found + nc.length <= windowEnd) {
          final int matchEnd = found + nc.length;
          final int secIdx =
              _sectionForOffset(idx.sectionNormStarts, found);
          results.add(CueMatch(
            cueSentenceIndex: cue.sentenceIndex,
            sectionIndex: secIdx,
            normCharStart: found - idx.sectionNormStarts[secIdx],
            normCharEnd: matchEnd - idx.sectionNormStarts[secIdx],
            score: 1.0,
          ));
          _logHit(matched, cue, nc, big, found, matchEnd, secIdx,
              idx.sectionNormStarts[secIdx], 1.0, ci == cues.length - 1);
          cursor = matchEnd;
          cursorAfterLastMatch = matchEnd;
          matched++;
          continue;
        }
      }

      // --- 模糊通道：Dice 系数滑窗 + 重试 ---
      bool didMatch = false;
      int attempt = 0;
      while (attempt < maxMatchAttempts) {
        final int tryCursor = cursorAfterLastMatch + attempt;
        if (tryCursor >= totalLen) break;
        final int tryWindowEnd =
            (tryCursor + searchWindow).clamp(0, totalLen);
        if (tryWindowEnd - tryCursor < nc.length) {
          attempt++;
          continue;
        }

        double bestSim = 0.0;
        int bestPos = -1;
        int bestLen = nc.length;

        // 重试偏移后再尝试精确 indexOf
        if (attempt > 0) {
          final int retryFound = big.indexOf(nc, tryCursor);
          if (retryFound >= 0 && retryFound + nc.length <= tryWindowEnd) {
            bestSim = 1.0;
            bestPos = retryFound;
          }
        }

        // 模糊扫描：固定长度滑窗
        if (bestSim < 1.0) {
          final int scanEnd = tryWindowEnd - nc.length + 1;
          for (int pos = tryCursor; pos < scanEnd; pos++) {
            final String candidate = big.substring(pos, pos + nc.length);
            final double sim = _diceSimilarity(nc, candidate);
            if (sim > bestSim) {
              bestSim = sim;
              bestPos = pos;
              bestLen = nc.length;
            }
          }
          // 也试 ±1~2 字符的长度变化，应对 SRT/EPUB 文本增减字
          for (final int delta in const <int>[-2, -1, 1, 2]) {
            final int tryLen = nc.length + delta;
            if (tryLen <= 0) continue;
            final int varScanEnd = tryWindowEnd - tryLen + 1;
            for (int pos = tryCursor; pos < varScanEnd; pos++) {
              final String candidate = big.substring(pos, pos + tryLen);
              final double sim = _diceSimilarity(nc, candidate);
              if (sim > bestSim) {
                bestSim = sim;
                bestPos = pos;
                bestLen = tryLen;
              }
            }
          }
        }

        if (bestSim >= similarityThreshold && bestPos >= 0) {
          final int matchEnd = bestPos + bestLen;
          final int secIdx =
              _sectionForOffset(idx.sectionNormStarts, bestPos);
          results.add(CueMatch(
            cueSentenceIndex: cue.sentenceIndex,
            sectionIndex: secIdx,
            normCharStart: bestPos - idx.sectionNormStarts[secIdx],
            normCharEnd: matchEnd - idx.sectionNormStarts[secIdx],
            score: bestSim,
          ));
          _logHit(matched, cue, nc, big, bestPos, matchEnd, secIdx,
              idx.sectionNormStarts[secIdx], bestSim,
              ci == cues.length - 1);
          cursor = matchEnd;
          cursorAfterLastMatch = matchEnd;
          matched++;
          didMatch = true;
          break;
        }

        attempt++;
      }

      if (!didMatch) {
        results.add(CueMatch.unmatched);
        debugPrint('[sasayaki] matcher.miss sid=${cue.sentenceIndex} '
            'cue="${_clip(cue.text, 24)}" attempts=$attempt');
      }
    }

    debugPrint('[sasayaki] matcher done: matched=$matched/${cues.length} '
        'rate=${(matched * 100 / cues.length).toStringAsFixed(1)}% '
        'finalCursor=$cursor/$totalLen');

    return MatchResult(
      matches: results,
      totalCues: cues.length,
      matchedCues: matched,
    );
  }

  static void _logHit(
    int hitIndex,
    AudioCue cue,
    String nc,
    String big,
    int found,
    int matchEnd,
    int secIdx,
    int secBase,
    double score,
    bool isLast,
  ) {
    if (hitIndex < 5 || isLast) {
      final String snippet = big.substring(found, matchEnd);
      debugPrint('[sasayaki] matcher.hit#$hitIndex sid=${cue.sentenceIndex} '
          'sec=$secIdx ns=${found - secBase} '
          'score=${score.toStringAsFixed(3)} '
          'cue="${_clip(cue.text, 24)}" '
          'norm="${_clip(nc, 24)}" '
          'big="${_clip(snippet, 24)}"');
    }
  }

  // ---------- Dice 系数（bigram similarity） ----------

  /// 移植自 ttu-whispersync `Match.svelte::getSimilarity`。
  /// 短串（< 5 字符）用 unigram，长串用 bigram，返回 0.0..1.0。
  static double _diceSimilarity(String a, String b) {
    if (a == b) return 1.0;
    final int aLen = a.length;
    final int bLen = b.length;
    if (aLen == 0 || bLen == 0) return 0.0;

    final int n = (aLen < 5 || bLen < 5) ? 1 : 2;
    if (aLen < n || bLen < n) return 0.0;

    final Map<String, int> grams = <String, int>{};
    for (int i = 0; i <= aLen - n; i++) {
      final String gram = a.substring(i, i + n);
      grams[gram] = (grams[gram] ?? 0) + 1;
    }

    int matches = 0;
    for (int i = 0; i <= bLen - n; i++) {
      final String gram = b.substring(i, i + n);
      final int count = grams[gram] ?? 0;
      if (count > 0) {
        grams[gram] = count - 1;
        matches++;
      }
    }

    final int aGrams = aLen - n + 1;
    final int bGrams = bLen - n + 1;
    return (matches * 2) / (aGrams + bGrams);
  }

  // ---------- 起点检测 ----------

  /// 取前 [defaultProbeCount] 条 cue，跳过 `＊` 开头 & 太短的，在全书做 indexOf
  /// （精确 + 模糊兜底），返回最小命中偏移；全部 miss 则回到 0。
  static int _findStart(
      String big, List<AudioCue> cues, double similarityThreshold) {
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
      // 精确
      final int found = big.indexOf(nc);
      if (found >= 0) {
        if (minStart == null || found < minStart) {
          minStart = found;
        }
        continue;
      }
      // 模糊兜底：在全书扫描找最佳相似位置
      double bestSim = 0.0;
      int bestPos = -1;
      final int scanEnd = big.length - nc.length + 1;
      for (int pos = 0; pos < scanEnd; pos++) {
        final String candidate = big.substring(pos, pos + nc.length);
        final double sim = _diceSimilarity(nc, candidate);
        if (sim > bestSim) {
          bestSim = sim;
          bestPos = pos;
        }
      }
      if (bestSim >= similarityThreshold && bestPos >= 0) {
        if (minStart == null || bestPos < minStart) {
          minStart = bestPos;
        }
      }
    }
    return minStart ?? 0;
  }

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
    for (final int cp in s.runes) {
      if (!_isKeepable(cp)) continue;
      if (cp >= 0x41 && cp <= 0x5A) {
        buf.writeCharCode(cp + 0x20);
      } else if (cp >= 0xFF21 && cp <= 0xFF3A) {
        buf.writeCharCode(cp + 0x20);
      } else {
        buf.writeCharCode(cp);
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
    if (c >= 0x30 && c <= 0x39) return true;
    if (c >= 0x41 && c <= 0x5A) return true;
    if (c >= 0x61 && c <= 0x7A) return true;
    if (c == 0x3005 || c == 0x3006 || c == 0x3007) return true;
    if (c >= 0x3041 && c <= 0x3096) return true;
    if (c >= 0x309D && c <= 0x309F) return true;
    if (c >= 0x30A1 && c <= 0x30FA) return true;
    if (c >= 0x30FC && c <= 0x30FF) return true;
    if (c >= 0x3400 && c <= 0x4DBF) return true;
    if (c >= 0x4E00 && c <= 0x9FFF) return true;
    if (c == 0x25CB || c == 0x25EF) return true;
    if (c == 0x303B) return true;
    if (c >= 0x2E80 && c <= 0x2EFF) return true;
    if (c >= 0x2F00 && c <= 0x2FDF) return true;
    if (c >= 0xF900 && c <= 0xFAFF) return true;
    if (c >= 0x20000 && c <= 0x2A6DF) return true;
    if (c >= 0x2A700 && c <= 0x2EBE0) return true;
    if (c >= 0x2F800 && c <= 0x2FA1F) return true;
    if (c >= 0x30000 && c <= 0x323AF) return true;
    if (c >= 0xFF10 && c <= 0xFF19) return true;
    if (c >= 0xFF21 && c <= 0xFF3A) return true;
    if (c >= 0xFF41 && c <= 0xFF5A) return true;
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

class _MatchRequest {
  const _MatchRequest({
    required this.sections,
    required this.cueTexts,
    required this.cueIndexes,
    required this.searchWindow,
    required this.similarityThreshold,
    required this.maxMatchAttempts,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final int searchWindow;
  final double similarityThreshold;
  final int maxMatchAttempts;
}

MatchResult _matchEntrypoint(_MatchRequest req) {
  final List<AudioCue> cues = _rebuildCues(req.cueTexts, req.cueIndexes);
  return EpubSrtMatcher.match(
    sections: req.sections,
    cues: cues,
    searchWindow: req.searchWindow,
    similarityThreshold: req.similarityThreshold,
    maxMatchAttempts: req.maxMatchAttempts,
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
    required this.similarityThreshold,
    required this.maxMatchAttempts,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final List<int> windows;
  final double similarityThreshold;
  final int maxMatchAttempts;
}

ProbeResult _probeEntrypoint(_ProbeRequest req) {
  final Map<int, double> map = <int, double>{};
  for (final int w in req.windows) {
    final List<AudioCue> cues = _rebuildCues(req.cueTexts, req.cueIndexes);
    final MatchResult r = EpubSrtMatcher.match(
      sections: req.sections,
      cues: cues,
      searchWindow: w,
      similarityThreshold: req.similarityThreshold,
      maxMatchAttempts: req.maxMatchAttempts,
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

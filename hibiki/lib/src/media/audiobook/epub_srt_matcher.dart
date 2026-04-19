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
/// 4. **主循环**：对每条 cue，在 `big[cursor, cursor + searchWindow]` 内做
///    精确子串 `indexOf`。命中则 cursor 推到子串末尾；未命中直接标记
///    unmatched，cursor 不动，下条 cue 重新找。
/// 5. 不做 bigram 模糊匹配、不做阈值、不做后向救援 —— 白名单 normalize 把
///    标点 / 叙述符号剥干净后，精确匹配对多数日文小说可达 95%+（见
///    Hoshi-Reader 经验值 98%）。
class EpubSrtMatcher {
  static const int defaultSearchWindow = 1500;

  /// 起点检测扫描的 cue 数量上限。
  static const int defaultProbeCount = 15;

  /// 起点检测 probe cue 的最小归一化长度，短于此忽略（避免短词在全书
  /// 命中偏前的歧义位置拉偏起点）。
  static const int defaultProbeMinLen = 6;

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

    debugPrint('[sasayaki] matcher done: matched=$matched/${cues.length} '
        'finalCursor=$cursor/$totalLen');

    return MatchResult(
      matches: results,
      totalCues: cues.length,
      matchedCues: matched,
    );
  }

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
  final List<AudioCue> cues = <AudioCue>[
    for (int i = 0; i < req.cueTexts.length; i++)
      (AudioCue()
        ..bookUid = ''
        ..chapterHref = ''
        ..sentenceIndex = req.cueIndexes[i]
        ..textFragmentId = ''
        ..text = req.cueTexts[i]
        ..startMs = 0
        ..endMs = 0
        ..audioFileIndex = 0),
  ];
  return EpubSrtMatcher.match(
    sections: req.sections,
    cues: cues,
    searchWindow: req.searchWindow,
  );
}

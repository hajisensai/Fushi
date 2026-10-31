/// 歌词模式导航侧板的「搜索字幕」：在整书音频 cue（没有整书 cue 的书用当前章
/// cue，与歌词层 `LyricsCueWindow.select` 同一来源）的文本里做子串搜索。
///
/// 匹配口径与库页搜索同一份归一化（[normalizeMediaSearchText] = `foldMediaTitle`：
/// 全角折半角、片假名折平假名、大小写、丢空白与常见标点），不另写一套近似实现。
/// 归一化会丢字符，命中区间要映射回原文才能高亮：逐码点折叠（`foldMediaTitle`
/// 本身就是逐码点的），记下每个折叠后码元来自原文哪个下标。
///
/// 整书 cue 动辄上万条（实测一本 10162 条），搜索放后台 isolate
/// （[searchLyricsCueTextsOffUi]），结果最多 [kLyricsCueSearchMaxResults] 条，
/// 同时报总命中数供「仅显示前 N 条」提示。
library;

import 'package:flutter/foundation.dart' show compute;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

import 'package:fushi/src/media/media_search_text.dart';

/// 结果列表最多显示的命中句数。
const int kLyricsCueSearchMaxResults = 200;

/// 一条命中：[cueIndex] 是传入列表的下标，[matchStart] / [matchEnd] 是命中在该
/// cue **原文**里的 UTF-16 区间（半开）。
class LyricsCueTextHit {
  const LyricsCueTextHit({
    required this.cueIndex,
    required this.matchStart,
    required this.matchEnd,
  });

  final int cueIndex;
  final int matchStart;
  final int matchEnd;
}

/// 一次搜索的结果：[hits] 按书内顺序（cue 下标升序）、至多 limit 条；[total] 是
/// 全部命中句数（含没列出的）。
class LyricsCueTextSearch {
  const LyricsCueTextSearch({required this.hits, required this.total});

  static const LyricsCueTextSearch empty = LyricsCueTextSearch(
    hits: <LyricsCueTextHit>[],
    total: 0,
  );

  final List<LyricsCueTextHit> hits;
  final int total;

  /// 命中超过上限、只列出了前 [hits] 条。
  bool get truncated => total > hits.length;
}

/// [query] 在 [text] 里第一次命中的原文区间（按 [normalizeMediaSearchText] 口径）；
/// 不命中或归一化后查询为空返回 null。纯函数。
({int start, int end})? mediaSearchMatchRange(String text, String query) {
  final String needle = normalizeMediaSearchText(query);
  if (needle.isEmpty) return null;
  return _matchRange(text, needle);
}

({int start, int end})? _matchRange(String text, String needle) {
  final StringBuffer folded = StringBuffer();
  // origin[k] = 折叠串第 k 个码元来自原文的起始下标；originEnd[k] = 该码点在原文
  // 的结束下标（代理对占两个码元）。
  final List<int> origin = <int>[];
  final List<int> originEnd = <int>[];
  int i = 0;
  while (i < text.length) {
    final int unit = text.codeUnitAt(i);
    final int width =
        (unit >= 0xD800 &&
            unit <= 0xDBFF &&
            i + 1 < text.length &&
            (text.codeUnitAt(i + 1) & 0xFC00) == 0xDC00)
        ? 2
        : 1;
    final String piece = normalizeMediaSearchText(text.substring(i, i + width));
    for (int k = 0; k < piece.length; k++) {
      origin.add(i);
      originEnd.add(i + width);
    }
    folded.write(piece);
    i += width;
  }
  final int at = folded.toString().indexOf(needle);
  if (at < 0) return null;
  return (start: origin[at], end: originEnd[at + needle.length - 1]);
}

/// 在 [texts]（cue 文本，书内顺序）里搜 [query]。归一化后为空的查询返回空结果。
/// 纯函数，便于单测；生产路径走 [searchLyricsCueTextsOffUi]。
LyricsCueTextSearch searchLyricsCueTexts(
  List<String> texts,
  String query, {
  int limit = kLyricsCueSearchMaxResults,
}) {
  final String needle = normalizeMediaSearchText(query);
  if (needle.isEmpty) return LyricsCueTextSearch.empty;
  final List<LyricsCueTextHit> hits = <LyricsCueTextHit>[];
  int total = 0;
  for (int i = 0; i < texts.length; i++) {
    final String text = texts[i];
    // 先整句折叠判命中（便宜），命中且还要列出时才做逐码点映射求高亮区间。
    if (!normalizeMediaSearchText(text).contains(needle)) continue;
    total++;
    if (hits.length >= limit) continue;
    final ({int start, int end})? range = _matchRange(text, needle);
    if (range == null) continue;
    hits.add(
      LyricsCueTextHit(
        cueIndex: i,
        matchStart: range.start,
        matchEnd: range.end,
      ),
    );
  }
  return LyricsCueTextSearch(hits: hits, total: total);
}

LyricsCueTextSearch _searchEntry(({List<String> texts, String query}) args) =>
    searchLyricsCueTexts(args.texts, args.query);

/// 后台 isolate 跑 [searchLyricsCueTexts]（上万条 cue 逐句归一化不放 UI isolate）。
Future<LyricsCueTextSearch> searchLyricsCueTextsOffUi(
  List<String> texts,
  String query,
) => compute(_searchEntry, (texts: texts, query: query));

/// 歌词模式导航侧板的字幕搜索接线（阅读器页面 → 面板）。
///
/// - [cues]：被搜的 cue 列表（整书 cue；没有整书 cue 时当前章 cue）；
/// - [search]：在 [cues] 的文本里搜（生产走 isolate，测试可注入同步实现），命中下标
///   指向 [cues]；
/// - [locationLabel]：结果行上标（所属章节 · 时间戳）；
/// - [onJump]：点结果——音频跳到该句并让歌词层定位到它（面板先关自己）。
class ReaderLyricsCueSearch {
  const ReaderLyricsCueSearch({
    required this.cues,
    required this.search,
    required this.locationLabel,
    required this.onJump,
  });

  final List<AudioCue> cues;
  final Future<LyricsCueTextSearch> Function(String query) search;
  final String Function(AudioCue cue) locationLabel;
  final Future<void> Function(AudioCue cue) onJump;
}

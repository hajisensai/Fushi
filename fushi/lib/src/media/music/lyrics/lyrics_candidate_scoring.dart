/// 歌词候选的评分与查询词构造（纯函数，不带任何平台客户端 / HTTP）。
///
/// 宿主统一裁决各来源（插件 / 非官方来源）返回的候选：标题 / 艺人相似度 + 宽松时长。
library;

/// 一条歌词搜索候选。[ref] 是来源自己的取词凭据。
class LyricsCandidate {
  const LyricsCandidate({
    required this.providerId,
    required this.title,
    required this.artist,
    this.durationMs,
    this.ref = const <String, String>{},
  });

  final String providerId;
  final String title;
  final String artist;
  final int? durationMs;
  final Map<String, String> ref;
}

/// 时长容差（各家同一首的版本 / 剪辑差几秒很常见）。
const int kOnlineLyricsDurationToleranceMs = 5000;

// TODO(lyrics-plugins): 本 worktree 的 lrclib_client.dart 还没有 lrclibStripBrackets /
// lrclibTitleParts（只在 samu 分支）；合并 samu 后改为复用并删掉下面两个私有副本。
String _stripBrackets(String s) {
  String out = s;
  const List<List<String>> pairs = <List<String>>[
    <String>['《', '》'],
    <String>['「', '」'],
    <String>['『', '』'],
    <String>['【', '】'],
    <String>['（', '）'],
    <String>['(', ')'],
    <String>['[', ']'],
  ];
  for (final List<String> p in pairs) {
    out = out.replaceAll(
      RegExp(
        '${RegExp.escape(p[0])}[^${RegExp.escape(p[1])}]*${RegExp.escape(p[1])}',
      ),
      ' ',
    );
    final int i = out.indexOf(p[0]);
    if (i >= 0) out = out.substring(0, i);
  }
  out = out.replaceAll(RegExp(r'(\.{2,}|…)+\s*$'), '');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<String> _titleParts(String title) {
  final List<String> out = <String>[];
  for (final String raw in title.split(RegExp(r'\s+[-–—―]\s+|\s*[|｜]\s*|_+'))) {
    final String c = _stripBrackets(raw);
    if (c.isNotEmpty && !out.contains(c)) out.add(c);
  }
  return out;
}

/// 搜索词：清括注 / 拆文件名式标题后，`首段 艺人` → `首段 次段` → 各单段。最多 [max] 条。
List<String> lyricsQueries(String title, String? artist, {int max = 4}) {
  final List<String> parts = _titleParts(title);
  final String a = _stripBrackets(artist ?? '');
  final List<String> qs = <String>[];
  void add(String q) {
    final String v = q.trim();
    if (v.isNotEmpty && !qs.contains(v)) qs.add(v);
  }

  final String first = parts.isNotEmpty ? parts.first : title.trim();
  if (a.isNotEmpty) add('$first $a');
  if (parts.length > 1) add(parts.take(2).join(' '));
  add(first);
  for (final String p in parts.skip(1)) {
    add(p);
  }
  return qs.take(max).toList();
}

/// 依次用 [lyricsQueries] 的查询词调 [run]，累计候选（按 `ref|title|artist` 去重），
/// 一旦 [pickBestLyricsCandidate] 能挑出像样的就停。
Future<List<LyricsCandidate>> searchWithFallbackQueries({
  required String title,
  String? artist,
  int? durationMs,
  required Future<List<LyricsCandidate>> Function(String query) run,
}) async {
  final List<LyricsCandidate> all = <LyricsCandidate>[];
  final Set<String> seen = <String>{};
  for (final String q in lyricsQueries(title, artist)) {
    for (final LyricsCandidate h in await run(q)) {
      if (seen.add('${h.ref}|${h.title}|${h.artist}')) all.add(h);
    }
    if (pickBestLyricsCandidate(
          all,
          title: title,
          artist: artist,
          durationMs: durationMs,
        ) !=
        null) {
      break;
    }
  }
  return all;
}

String _norm(String s) => _stripBrackets(
  s,
).toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

Set<String> _bigrams(String s) {
  if (s.length < 2) return <String>{s};
  return <String>{for (int i = 0; i < s.length - 1; i++) s.substring(i, i + 2)};
}

/// 0..1 的名称相似度：完全相等 1，互相包含 0.85，其余按字符二元组 Jaccard。
double lyricsNameSimilarity(String a, String b) {
  final String x = _norm(a);
  final String y = _norm(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  if (x.contains(y) || y.contains(x)) return 0.85;
  final Set<String> bx = _bigrams(x);
  final Set<String> by = _bigrams(y);
  final int inter = bx.intersection(by).length;
  final int union = bx.length + by.length - inter;
  return union == 0 ? 0 : inter / union;
}

double _titleScore(String trackTitle, String hitTitle) {
  double best = lyricsNameSimilarity(trackTitle, hitTitle);
  for (final String p in _titleParts(trackTitle)) {
    final double s = lyricsNameSimilarity(p, hitTitle);
    if (s > best) best = s;
  }
  return best;
}

/// 从候选里挑最像的一条；全都不像（标题相似度 < 0.6，或艺人已知却对不上，
/// 或时长两侧已知且差超过 [kOnlineLyricsDurationToleranceMs]）返回 null。
/// 得分 `标题×2 + 艺人`；同分时时长差小者优先，再保持来源给出的顺序。
LyricsCandidate? pickBestLyricsCandidate(
  List<LyricsCandidate> hits, {
  required String title,
  String? artist,
  int? durationMs,
}) {
  final String a = _stripBrackets(artist ?? '');
  LyricsCandidate? best;
  double bestScore = 0;
  int bestDiff = 1 << 30;
  for (final LyricsCandidate h in hits) {
    final double ts = _titleScore(title, h.title);
    if (ts < 0.6) continue;
    double artistScore = 0.5;
    if (a.isNotEmpty && h.artist.isNotEmpty) {
      artistScore = lyricsNameSimilarity(a, h.artist);
      for (final String seg in h.artist.split(RegExp(r'[/、,&;＆，]'))) {
        final double s = lyricsNameSimilarity(a, seg);
        if (s > artistScore) artistScore = s;
      }
      if (artistScore < 0.3 && !_norm(title).contains(_norm(h.artist))) {
        continue;
      }
    }
    int diff = 0;
    if (durationMs != null &&
        durationMs > 0 &&
        h.durationMs != null &&
        h.durationMs! > 0) {
      diff = (h.durationMs! - durationMs).abs();
      if (diff > kOnlineLyricsDurationToleranceMs) continue;
    }
    final double score = ts * 2 + artistScore;
    if (best == null ||
        score > bestScore + 1e-9 ||
        ((score - bestScore).abs() <= 1e-9 && diff < bestDiff)) {
      best = h;
      bestScore = score;
      bestDiff = diff;
    }
  }
  return best;
}

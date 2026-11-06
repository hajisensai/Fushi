/// 歌词候选的评分与查询词构造（纯函数，不带任何平台客户端 / HTTP）。
///
/// 宿主统一裁决各来源（插件 / 非官方来源）返回的候选：标题 / 艺人相似度 + 宽松时长，
/// 候选带歌词正文时再看书写系统是否与曲目元数据一致（原文版 vs 罗马音 / 翻译版）。
library;

/// 一条歌词搜索候选。[ref] 是来源自己的取词凭据。
class LyricsCandidate {
  const LyricsCandidate({
    required this.providerId,
    required this.title,
    required this.artist,
    this.durationMs,
    this.ref = const <String, String>{},
    this.lyricsText,
  });

  final String providerId;
  final String title;
  final String artist;
  final int? durationMs;
  final Map<String, String> ref;

  /// 候选自带的歌词正文（LRCLIB 搜索结果带；插件搜索结果只有元数据，为 null）。
  /// 非 null 时 [pickBestLyricsCandidate] 按 [lyricsScriptFit] 区分原文版与罗马音 / 翻译版。
  final String? lyricsText;
}

/// 书写系统（按字符所属文字统计，不是语言识别）。
enum LyricsScript {
  /// 有假名：日文。
  kana,

  /// 只有汉字：中文（或纯汉字标题的日文）。
  han,

  /// 谚文：韩文。
  hangul,

  /// 拉丁字母：英文 / 罗马音 / 拼音。
  latin,
}

/// 一段文字里各文字的字符数（标点、数字、空白、LRC 时间戳都不计）。
class LyricsScriptProfile {
  const LyricsScriptProfile({
    required this.kana,
    required this.han,
    required this.hangul,
    required this.latin,
  });

  final int kana;
  final int han;
  final int hangul;
  final int latin;

  /// 计入统计的字母总数。
  int get letters => kana + han + hangul + latin;

  double _ratio(int n) => letters == 0 ? 0 : n / letters;

  double get kanaRatio => _ratio(kana);
  double get hanRatio => _ratio(han);
  double get hangulRatio => _ratio(hangul);
  double get latinRatio => _ratio(latin);

  /// 主导文字；字母太少（< [kLyricsScriptMinLetters]）或混得分不出来时为 null。
  LyricsScript? get dominant {
    if (letters < kLyricsScriptMinLetters) return null;
    if (kana > 0 && _ratio(kana + han) >= kLyricsScriptMismatchFit) {
      return LyricsScript.kana;
    }
    if (_ratio(hangul) >= kLyricsScriptMismatchFit) return LyricsScript.hangul;
    if (_ratio(han) >= kLyricsScriptMismatchFit) return LyricsScript.han;
    if (latinRatio >= 0.5) return LyricsScript.latin;
    return null;
  }
}

/// 判书写系统至少要这么多个字母（太短的文本不下结论）。
const int kLyricsScriptMinLetters = 8;

/// [lyricsScriptFit] 低于它即「明显不是这种文字」（例如期望日文却几乎全是拉丁字母）。
const double kLyricsScriptMismatchFit = 0.2;

/// 统计 [text] 里各文字的字符数。
LyricsScriptProfile lyricsScriptProfile(String text) {
  int kana = 0;
  int han = 0;
  int hangul = 0;
  int latin = 0;
  for (final int r in text.runes) {
    if ((r >= 0x3041 && r <= 0x309F) ||
        (r >= 0x30A1 && r <= 0x30FA) ||
        (r >= 0x30FD && r <= 0x30FF) ||
        (r >= 0x31F0 && r <= 0x31FF) ||
        (r >= 0xFF66 && r <= 0xFF9D)) {
      kana++;
    } else if ((r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0xF900 && r <= 0xFAFF) ||
        (r >= 0x20000 && r <= 0x3134F) ||
        r == 0x3005) {
      han++;
    } else if ((r >= 0xAC00 && r <= 0xD7A3) ||
        (r >= 0x1100 && r <= 0x11FF) ||
        (r >= 0x3130 && r <= 0x318F)) {
      hangul++;
    } else if ((r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A) ||
        (r >= 0xC0 && r <= 0x24F && r != 0xD7 && r != 0xF7) ||
        (r >= 0x1E00 && r <= 0x1EFF) ||
        (r >= 0xFF21 && r <= 0xFF3A) ||
        (r >= 0xFF41 && r <= 0xFF5A)) {
      latin++;
    }
  }
  return LyricsScriptProfile(
    kana: kana,
    han: han,
    hangul: hangul,
    latin: latin,
  );
}

/// 由曲目元数据（标题 / 艺人 / 专辑）推断歌词原文应有的书写系统：出现假名即日文，
/// 否则谚文即韩文，否则汉字即汉字系；元数据全是拉丁字母时不推断（返回 null）——
/// 英文歌与罗马字标题的日文歌分不开，宁可不判也不误伤英文歌。
LyricsScript? expectedLyricsScript({
  required String title,
  String? artist,
  String? album,
}) {
  final LyricsScriptProfile p = lyricsScriptProfile(
    '$title ${artist ?? ''} ${album ?? ''}',
  );
  if (p.kana > 0) return LyricsScript.kana;
  if (p.hangul > 0) return LyricsScript.hangul;
  if (p.han > 0) return LyricsScript.han;
  return null;
}

/// 0..1：[text] 有多大比例是 [expected] 这种文字。日文要求真的有假名（只有汉字的
/// 多半是中文翻译版）；汉字系把假名也算进去（纯汉字标题的日文歌）。
double lyricsScriptFit(LyricsScript expected, LyricsScriptProfile p) {
  if (p.letters == 0) return 0;
  switch (expected) {
    case LyricsScript.kana:
      return p.kana == 0 ? 0 : (p.kana + p.han) / p.letters;
    case LyricsScript.han:
      return (p.han + p.kana) / p.letters;
    case LyricsScript.hangul:
      return (p.hangul + p.han) / p.letters;
    case LyricsScript.latin:
      return p.latinRatio;
  }
}

/// [text] 明显不是 [expected] 这种文字（字母够多且 [lyricsScriptFit] 低于阈值）。
/// [expected] 为 null（元数据推断不出）时永远 false。
bool lyricsScriptMismatches(LyricsScript? expected, String text) {
  if (expected == null) return false;
  final LyricsScriptProfile p = lyricsScriptProfile(text);
  if (p.letters < kLyricsScriptMinLetters) return false;
  return lyricsScriptFit(expected, p) < kLyricsScriptMismatchFit;
}

/// 书写系统一致时的加分（同名同艺人的候选之间由它分出原文版；名字差得多时盖不过名字分）。
const double kLyricsScriptMatchWeight = 0.5;

/// 时长容差（各家同一首的版本 / 剪辑差几秒很常见）。
const int kOnlineLyricsDurationToleranceMs = 5000;

/// 去掉标题 / 艺人里的括注（`(feat. X)`、`【MV】`、`「…」` 等）与尾部省略号，合并空白。
/// 只有候选评分与查询词构造用：LRCLIB 走服务端精确匹配（`/api/get`）与用户手挑的模糊搜索，
/// 宿主不对它的结果打分，所以没有第二份实现。
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
///
/// [expectedScript] 非 null 且 [requireScriptMatch] 为 true 时，只有书写系统对得上的
/// 候选才算「像样」（见 [pickBestLyricsCandidate]）。
Future<List<LyricsCandidate>> searchWithFallbackQueries({
  required String title,
  String? artist,
  int? durationMs,
  LyricsScript? expectedScript,
  bool requireScriptMatch = false,
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
          expectedScript: expectedScript,
          requireScriptMatch: requireScriptMatch,
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
/// 得分 `标题×2 + 艺人`，[expectedScript] 已知且候选带歌词正文时，书写系统对得上的再加
/// [kLyricsScriptMatchWeight]；同分时时长差小者优先，再保持来源给出的顺序。
/// [requireScriptMatch] 为 true 时剔除正文明显不是 [expectedScript] 的候选
/// （[lyricsScriptMismatches]）。
LyricsCandidate? pickBestLyricsCandidate(
  List<LyricsCandidate> hits, {
  required String title,
  String? artist,
  int? durationMs,
  LyricsScript? expectedScript,
  bool requireScriptMatch = false,
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
    // 只分「对得上 / 对不上」两档：吻合度的细小差别（多两句英文副歌）不该盖过时长裁决。
    double scriptScore = 0;
    final String? text = h.lyricsText;
    if (expectedScript != null && text != null) {
      final LyricsScriptProfile p = lyricsScriptProfile(text);
      if (p.letters >= kLyricsScriptMinLetters) {
        final bool fits =
            lyricsScriptFit(expectedScript, p) >= kLyricsScriptMismatchFit;
        if (!fits && requireScriptMatch) continue;
        if (fits) scriptScore = kLyricsScriptMatchWeight;
      }
    }
    final double score = ts * 2 + artistScore + scriptScore;
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

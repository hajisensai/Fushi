/// 一首歌的生词覆盖率（设计 §12「歌词生词统计」）。
///
/// - **词**：整首歌词（主唱行）一次批量分词（`fushidicts_tokenize_terms`，一次 FFI、后台
///   isolate），只数词典命中的段，按**词头**（词典形）归一——变形后的表层形在复习库里
///   查不到；
/// - **已知**：复习库（SRS）里这个词有卡、且卡已进入复习队列（学过、还记得）。新卡 /
///   学习中 / 重学不算已知；
/// - 不认识任何语言：哪种语言有词典就对哪种生效；没装词典 / 一个词都没命中时返回 null，
///   界面不显示覆盖率（不硬造 0%）；复习模块关着同理。
library;

import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiTermToken;
import 'package:fushi_music/fushi_music.dart';

/// 批量分词（真 app = `FushiDicts.instance.tokenizeTermsInBackground`）。
typedef MusicTermTokenizer =
    Future<List<List<FushiTermToken>>?> Function(List<String> texts);

/// 复习库里「已知」的词头集合（入参是去重后的词头 + 读音）。null = 判不了（复习模块
/// 关着）：覆盖率整体不显示，而不是显示成 0%。
typedef MusicKnownTermLookup =
    Future<Set<String>?> Function(
      List<({String expression, String reading})> terms,
    );

/// 覆盖率结果：按出现次数算（一首歌里重复出现的词每次都算）。
class MusicLyricsCoverage {
  const MusicLyricsCoverage({
    required this.knownTokens,
    required this.totalTokens,
    required this.uniqueTerms,
    required this.unknownTerms,
  });

  final int knownTokens;
  final int totalTokens;

  /// 去重后的词数。
  final int uniqueTerms;

  /// 去重后不认识的词头（按首次出现顺序）。
  final List<String> unknownTerms;

  /// 0–1。
  double get ratio => totalTokens == 0 ? 0 : knownTokens / totalTokens;

  /// 0–100 取整。
  int get percent => (ratio * 100).round();
}

/// 段文本里有没有字母类字符（标点 / 空白 / 数字段即使词典命中也不算词）。
bool musicTermIsWordLike(String s) {
  for (final int r in s.runes) {
    final bool punctOrSpace =
        r <= 0x40 ||
        (r >= 0x5B && r <= 0x60) ||
        (r >= 0x7B && r <= 0xBF) ||
        (r >= 0x2000 && r <= 0x206F) ||
        (r >= 0x3000 && r <= 0x303F) ||
        (r >= 0xFF00 && r <= 0xFF20) ||
        (r >= 0xFF3B && r <= 0xFF40) ||
        (r >= 0xFF5B && r <= 0xFF65);
    if (!punctOrSpace) return true;
  }
  return false;
}

/// 参与覆盖率统计的歌词文本：主唱行（和声 / 背景行不算），空行不算。
List<String> musicCoverageTextsOf(LyricTimeline timeline) => <String>[
  for (final LyricLine l in timeline.lines)
    if (!l.isBackground && l.text.trim().isNotEmpty) l.text,
];

/// 一首歌去重后的一个词：词头（词典形）+ 首次出现时的读音 + 出现次数。
typedef MusicCoverageTerm = ({String expression, String reading, int count});

/// 分词结果按词头归一：只数词典命中、且表层形像个词的段。返回按首次出现顺序的去重词；
/// 分词段数与文本数对不上的部分忽略。
List<MusicCoverageTerm> aggregateMusicCoverageTerms(
  List<String> texts,
  List<List<FushiTermToken>> tokens,
) {
  final Map<String, ({String reading, int count})> unique =
      <String, ({String reading, int count})>{};
  for (int i = 0; i < texts.length && i < tokens.length; i++) {
    int at = 0;
    for (final FushiTermToken t in tokens[i]) {
      final String surface = texts[i].substring(at, at + t.length);
      at += t.length;
      if (t.expression.isEmpty || !musicTermIsWordLike(surface)) continue;
      final ({String reading, int count})? prev = unique[t.expression];
      unique[t.expression] = (
        reading: prev?.reading ?? t.reading,
        count: (prev?.count ?? 0) + 1,
      );
    }
  }
  return <MusicCoverageTerm>[
    for (final MapEntry<String, ({String reading, int count})> e
        in unique.entries)
      (expression: e.key, reading: e.value.reading, count: e.value.count),
  ];
}

/// 由去重词与「已知词头」集合组装覆盖率；没有词时返回 null。
MusicLyricsCoverage? musicCoverageOf(
  List<MusicCoverageTerm> terms,
  Set<String> known,
) {
  if (terms.isEmpty) return null;
  int knownCount = 0;
  int total = 0;
  for (final MusicCoverageTerm term in terms) {
    total += term.count;
    if (known.contains(term.expression)) knownCount += term.count;
  }
  return MusicLyricsCoverage(
    knownTokens: knownCount,
    totalTokens: total,
    uniqueTerms: terms.length,
    unknownTerms: <String>[
      for (final MusicCoverageTerm term in terms)
        if (!known.contains(term.expression)) term.expression,
    ],
  );
}

/// 算一首歌的覆盖率。拿不到分词结果（没词典 / 原生失败）或一个词都没有时返回 null。
Future<MusicLyricsCoverage?> computeMusicLyricsCoverage(
  LyricTimeline timeline, {
  required MusicTermTokenizer tokenize,
  required MusicKnownTermLookup knownTerms,
}) async {
  final List<String> texts = musicCoverageTextsOf(timeline);
  if (texts.isEmpty) return null;
  final List<List<FushiTermToken>>? tokens = await tokenize(texts);
  if (tokens == null) return null;
  final List<MusicCoverageTerm> terms = aggregateMusicCoverageTerms(
    texts,
    tokens,
  );
  if (terms.isEmpty) return null;
  final Set<String>? known =
      await knownTerms(<({String expression, String reading})>[
        for (final MusicCoverageTerm term in terms)
          (expression: term.expression, reading: term.reading),
      ]);
  if (known == null) return null;
  return musicCoverageOf(terms, known);
}

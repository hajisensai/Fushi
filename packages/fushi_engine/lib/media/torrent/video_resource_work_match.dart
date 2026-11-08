/// 一条发布是不是**目标作品本身**（BUG-3065）。
///
/// 资源搜索只做模糊词匹配：长寿系列的剧场版之间、原作与重制版之间、正作与续作之间
/// 共用几乎全部标题词（《大雄的恐龙》1980 / 《大雄的新恐龙》2020，《日本诞生》1989 /
/// 《新·日本诞生》2016，《STAND BY ME 哆啦A梦》2014 / 《… 2》2020）。相关度排序
/// （`rankVideoResourcesByRelevance`）只给标题贴合度打分、不丢弃，于是一部作品的
/// 候选里混着兄弟作品的发布，做种更多的那条就被当成「这一部」下下来。
///
/// 这里给出**否定判据**：发布标题里出现了与目标作品身份矛盾的证据就判为别的作品。
/// 判据只认三种确定的矛盾，其余一律放行（宁可漏判也不误杀——误杀等于「没资源」）：
///
/// * [VideoResourceWorkMismatch.year]：标题写了年份且没有一个落在目标年份 ±1 内；
/// * [VideoResourceWorkMismatch.remake]：标题带重制记号（`新・` / 在目标标题里插入
///   `新` / `Shin` / `New`），而目标作品自己的任何标题都不带重制记号；
/// * [VideoResourceWorkMismatch.sequel]：标题里目标标题后面跟着的续作序号与目标不同
///   （目标无序号而发布写了 ` 2`，或目标是 ` 2` 而发布只写了基础标题），且没有一处
///   序号相符的写法；
/// * [VideoResourceWorkMismatch.collection]：标题写了跨多年的年份区间
///   （`Doraemon Movies 01-25 (1980-2004)`）——这是多部作品的合集包，不是这一部。
///   包内按部选文件尚未实现，整包给区间端点那一部只会把 25 部全下进一部的目录。
/// * [VideoResourceWorkMismatch.sibling]：标题点名了**同系列的另一部**（BUG-4241）。
///   「ガルパ☆ピコ」2018 的候选里混着续作《ガルパ☆ピコ ふぃーばー！》的逐集发布
///   （`Garupa Pico: Fever! - 01`）和第二季《～大盛り～》的 BD 包——续作标题是「基础
///   标题 + 副标题词」，后面没有数字，序号判据看不出来；判别必须知道兄弟作品叫什么。
///   做法见 [VideoResourceSiblingMarks]：兄弟作品某个标题写法里**目标没有的词**
///   （`fever` / `ohmori`）全部出现、且目标独有的词一个都没出现，才判为那一部。
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 发布与目标作品的身份矛盾种类。
enum VideoResourceWorkMismatch { year, remake, sequel, collection, sibling }

/// 目标作品的身份：归一化后的全部标题 + 年份 + 同系列兄弟作品的区分证据。
class VideoResourceWorkTarget {
  VideoResourceWorkTarget({
    required Iterable<String> titles,
    this.year,
    Iterable<Iterable<String>> siblings = const <Iterable<String>>[],
  }) : titles = _normalizedTitles(titles),
       remakeMarked = titles.any(_hasRemakeMarker),
       siblings = _siblingMarksOf(titles, siblings);

  /// 只按年份判（同名剧集：靠标题搜到的是同一批发布，标题证据没有区分力）。
  VideoResourceWorkTarget.yearOnly(this.year)
    : titles = const <String>[],
      remakeMarked = false,
      siblings = const <VideoResourceSiblingMarks>[];

  /// 剧集身份：只做兄弟作品判据（+ 可选年份）。
  ///
  /// 剧集不做续作序号 / 重制 / 合集判据：逐集发布的集号会冒充续作序号，长寿剧
  /// 的逐集标题常带播出年份区间——那几条是给电影设计的。兄弟判据只认「标题点名了
  /// 另一部」这一种证据，对剧集同样成立。
  VideoResourceWorkTarget.series({
    required Iterable<String> titles,
    Iterable<Iterable<String>> siblings = const <Iterable<String>>[],
    this.year,
  }) : titles = const <String>[],
       remakeMarked = false,
       siblings = _siblingMarksOf(titles, siblings);

  /// 电影作品的完整身份：展示标题、原名、别名（含详情补的罗马字 / 英文名）。
  /// [siblings] 是同系列的其它作品（同一次作品搜索的其它候选、整套下载清单里的
  /// 其它条目）；与目标可能是同一部的条目由 [videoResourceSiblingTitles] 排掉。
  factory VideoResourceWorkTarget.fromReference(
    VideoMediaReference reference, {
    Iterable<VideoMediaReference> siblings = const <VideoMediaReference>[],
  }) => VideoResourceWorkTarget(
    titles: videoResourceReferenceTitles(reference),
    year: reference.year,
    siblings: videoResourceSiblingTitles(reference, siblings),
  );

  /// 剧集作品的身份（[VideoResourceWorkTarget.series]）；[byYear] 时附带年份判据。
  factory VideoResourceWorkTarget.seriesFromReference(
    VideoMediaReference reference, {
    Iterable<VideoMediaReference> siblings = const <VideoMediaReference>[],
    bool byYear = false,
  }) => VideoResourceWorkTarget.series(
    titles: videoResourceReferenceTitles(reference),
    siblings: videoResourceSiblingTitles(reference, siblings),
    year: byYear ? reference.year : null,
  );

  /// [normalizeVideoResourceMatchText] 之后的标题，去重，过短的（< 3 字）丢掉——
  /// 太短的标题在发布名里随处可见，拿来判续作序号只会误判。为空时不做续作 /
  /// 重制 / 合集判据。
  final List<String> titles;
  final int? year;

  /// 目标自己就带重制记号（它本身是重制版 / 「新」字头作品）：不做重制判据。
  final bool remakeMarked;

  /// 每部兄弟作品的区分证据（没有区分词的兄弟不在其中）。
  final List<VideoResourceSiblingMarks> siblings;

  static List<String> _normalizedTitles(Iterable<String> raw) {
    final Set<String> seen = <String>{};
    return List<String>.unmodifiable(<String>[
      for (final String title in raw)
        if (normalizeVideoResourceMatchText(title) case final String normalized
            when normalized.length >= 3 && seen.add(normalized))
          normalized,
    ]);
  }
}

/// 一部作品的全部标题写法：展示标题、原名、别名。
List<String> videoResourceReferenceTitles(VideoMediaReference reference) =>
    <String>[
      reference.title,
      if (reference.originalTitle != null) reference.originalTitle!,
      ...reference.aliases,
    ];

/// [siblings] 里确定是**另一部**的作品的标题（每部一组）。
///
/// 排掉可能与 [target] 是同一部的条目：同一资料源同一 id、共享 AniList / AniDB /
/// Bangumi / TMDB id，以及同类型且同年（或任一方没有年份）的条目——多源合并前
/// 同一部作品可能以不同语言的标题各出一条（TMDB 中文名 + AniList 罗马字），把它
/// 当兄弟会让目标自己的中文发布被判成「另一部」。宁可漏判也不误杀。
List<List<String>> videoResourceSiblingTitles(
  VideoMediaReference target,
  Iterable<VideoMediaReference> siblings,
) => <List<String>>[
  for (final VideoMediaReference sibling in siblings)
    if (!_mayBeSameWork(target, sibling)) videoResourceReferenceTitles(sibling),
];

bool _mayBeSameWork(VideoMediaReference a, VideoMediaReference b) {
  if (a.providerId == b.providerId && a.mediaId == b.mediaId) return true;
  bool shared(int? x, int? y) => x != null && x == y;
  if (shared(a.anilistId, b.anilistId) ||
      shared(a.anidbId, b.anidbId) ||
      shared(a.bangumiId, b.bangumiId) ||
      (shared(a.tmdbId, b.tmdbId) && a.mediaKind == b.mediaKind)) {
    return true;
  }
  return a.mediaKind == b.mediaKind &&
      (a.year == null || b.year == null || a.year == b.year);
}

/// 一部兄弟作品的区分证据。
///
/// * [variants]：兄弟作品每个标题写法里、目标任何标题都没有的词。发布标题包含
///   **某一个写法的全部**区分词，才算点名了这一部。
/// * [targetOnly]：目标标题里有、这部兄弟任何标题都没有的词。发布里出现任一个
///   就说明它（也）在说目标——不判兄弟。挡的是语言覆盖不对称：兄弟带中文别名
///   「少女乐团派对」而目标没有，目标自己的中文发布会全中兄弟的区分词。
/// * [wholeVariants]：兄弟作品每个标题写法的全部有效词。反方向的情形——目标是
///   续作（《ふぃーばー！》），兄弟是**基础作**（《ガルパ☆ピコ》）——兄弟没有
///   区分词（它的词全在目标里），能用的证据是：发布写全了兄弟的某个标题、却一个
///   目标独有词（`fever`）都没写、也没写季号，那它说的就是基础作。[targetOnly]
///   为空（目标与兄弟只差季号 / 序数）时不用这一条，交给季号判据；发布里有
///   兄弟标题解释不了的 CJK 片段（[siblingCjk] 之外，可能是目标的中文译名
///   「迷途之子」）时也不用。
class VideoResourceSiblingMarks {
  const VideoResourceSiblingMarks({
    required this.variants,
    required this.targetOnly,
    required this.wholeVariants,
    required this.siblingCjk,
  });

  final List<VideoResourceMatchWords> variants;
  final VideoResourceMatchWords targetOnly;
  final List<VideoResourceMatchWords> wholeVariants;
  final Set<String> siblingCjk;
}

/// 一组比对用的词：拉丁词按整词比，CJK 片段按子串比（CJK 没有词边界）。
class VideoResourceMatchWords {
  const VideoResourceMatchWords({required this.latin, required this.cjk});

  final Set<String> latin;
  final Set<String> cjk;

  bool get isEmpty => latin.isEmpty && cjk.isEmpty;
}

List<VideoResourceSiblingMarks> _siblingMarksOf(
  Iterable<String> targetTitles,
  Iterable<Iterable<String>> siblings,
) {
  final _MatchTokens target = _MatchTokens.ofAll(targetTitles);
  if (target.isEmpty) return const <VideoResourceSiblingMarks>[];
  final List<_MatchTokens> targetVariants = <_MatchTokens>[
    for (final String title in targetTitles)
      if (_MatchTokens.ofAll(<String>[title]) case final _MatchTokens tokens
          when !tokens.isEmpty)
        tokens,
  ];
  return List<VideoResourceSiblingMarks>.unmodifiable(
    <VideoResourceSiblingMarks>[
      for (final Iterable<String> sibling in siblings)
        if (_siblingMarksOfOne(
              target,
              targetVariants,
              sibling.toList(growable: false),
            )
            case final VideoResourceSiblingMarks marks)
          marks,
    ],
  );
}

VideoResourceSiblingMarks? _siblingMarksOfOne(
  _MatchTokens target,
  List<_MatchTokens> targetVariants,
  List<String> titles,
) {
  final List<VideoResourceMatchWords> variants = <VideoResourceMatchWords>[
    for (final String title in titles)
      if (_MatchTokens.ofAll(<String>[title]).distinctFrom(target)
          case final VideoResourceMatchWords words when !words.isEmpty)
        words,
  ];
  final _MatchTokens siblingTokens = _MatchTokens.ofAll(titles);
  final VideoResourceMatchWords targetOnly = target.distinctFrom(siblingTokens);
  // 「基础作」判据只在目标的**每个**标题写法都有兄弟没有的词时成立：目标有一个
  // 写法被兄弟的标题整个盖住（《BanG Dream!》对《BanG Dream! 2nd Season》，差的
  // 只是季号；或者只是别名覆盖不对称），只写这个标题的发布同样可能就是目标。
  final bool targetIsMoreSpecific =
      !targetOnly.isEmpty &&
      targetVariants.every(
        (_MatchTokens variant) => !variant.distinctFrom(siblingTokens).isEmpty,
      );
  final List<VideoResourceMatchWords> wholeVariants = !targetIsMoreSpecific
      ? const <VideoResourceMatchWords>[]
      : <VideoResourceMatchWords>[
          for (final String title in titles)
            if (_MatchTokens.ofAll(<String>[
                  title,
                ]).distinctFrom(_MatchTokens.none)
                case final VideoResourceMatchWords words when !words.isEmpty)
              words,
        ];
  if (variants.isEmpty && wholeVariants.isEmpty) return null;
  return VideoResourceSiblingMarks(
    variants: List<VideoResourceMatchWords>.unmodifiable(variants),
    targetOnly: targetOnly,
    wholeVariants: List<VideoResourceMatchWords>.unmodifiable(wholeVariants),
    siblingCjk: Set<String>.unmodifiable(siblingTokens.cjk),
  );
}

/// 一组标题切出来的词（拉丁词 / CJK 片段分开）。
class _MatchTokens {
  _MatchTokens(this.latin, this.cjk);

  static final _MatchTokens none = _MatchTokens(<String>{}, <String>{});

  factory _MatchTokens.ofAll(Iterable<String> raws) {
    final Set<String> latin = <String>{};
    final Set<String> cjk = <String>{};
    for (final String raw in raws) {
      for (final String token in _matchWords(raw)) {
        (_cjkChar.hasMatch(token) ? cjk : latin).add(token);
      }
    }
    return _MatchTokens(latin, cjk);
  }

  final Set<String> latin;
  final Set<String> cjk;

  bool get isEmpty => latin.isEmpty && cjk.isEmpty;

  /// 本组里 [other] 没有的、有区分力的词。
  ///
  /// CJK 先把 [other] 的每个片段从本组片段里切掉，再按季号 / 剧场版这类通用片段
  /// 切开；剩下的片段若仍是 [other] 某个片段的一部分（「大雄的新恐龙」对「大雄的
  /// 恐龙」切出的「大雄的」）也不算——它说明不了是哪一部。
  VideoResourceMatchWords distinctFrom(_MatchTokens other) {
    final Set<String> latinOut = <String>{
      for (final String word in latin)
        if (!other.latin.contains(word) && _isDistinctiveLatin(word)) word,
    };
    final List<String> cuts = other.cjk.toList()
      ..sort((String a, String b) => b.length.compareTo(a.length));
    final Set<String> cjkOut = <String>{};
    for (final String token in cjk) {
      List<String> parts = <String>[token];
      for (final String cut in cuts) {
        parts = <String>[for (final String part in parts) ...part.split(cut)];
      }
      for (final String part in parts) {
        for (final String piece in part.split(_cjkGeneric)) {
          if (piece.length < 2) continue;
          if (other.cjk.any((String o) => o.contains(piece))) continue;
          cjkOut.add(piece);
        }
      }
    }
    return VideoResourceMatchWords(latin: latinOut, cjk: cjkOut);
  }
}

/// 比对用切词：[normalizeVideoResourceMatchText] 后按空格切，并在 CJK 与拉丁 /
/// 数字相邻处断开（`喵萌production` → `喵萌` `production`）。
List<String> _matchWords(String raw) => normalizeVideoResourceMatchText(raw)
    .replaceAllMapped(_scriptBoundary, (Match match) => '${match.group(0)} ')
    .split(' ')
    .where((String token) => token.isNotEmpty)
    .toList(growable: false);

/// 匹配「后面紧跟另一种文字」的那个字符（CJK → 拉丁 / 数字，或反过来）。
final RegExp _scriptBoundary = RegExp(
  r'[぀-ヿ㐀-鿿](?=[a-z0-9])|[a-z0-9](?=[぀-ヿ㐀-鿿])',
);

/// 拉丁区分词：≥3 字、不是数字 / 序数 / 季集号 / 罗马数字 / 技术标签、不在通用词表里。
bool _isDistinctiveLatin(String word) =>
    word.length >= 3 &&
    !_genericLatin.contains(word) &&
    !_genericLatinShape.hasMatch(word);

final RegExp _genericLatinShape = RegExp(
  r'^(?:\d+|\d+(?:st|nd|rd|th)|s\d+|s\d+e\d+|e\d+|ep\d+|\d+p|[xh]26[45]'
  r'|[ivx]+|\d+bits?|v\d+)$',
);

/// 系列标题里常见、却说明不了「是哪一部」的词。
const Set<String> _genericLatin = <String>{
  'the',
  'and',
  'with',
  'from',
  'for',
  'season',
  'seasons',
  'part',
  'cour',
  'movie',
  'movies',
  'film',
  'films',
  'ova',
  'oad',
  'ona',
  'special',
  'specials',
  'episode',
  'episodes',
  'live',
  'edition',
  'version',
  'ver',
  'final',
  'new',
  'shin',
  'series',
  'chapter',
  'vol',
  'volume',
  'collection',
  'complete',
  'batch',
  'end',
  'extra',
  'extras',
  'first',
  'second',
  'third',
  'fourth',
  'fifth',
  'sixth',
  'gekijouban',
  'gekijoban',
  'theatrical',
  'zoku',
  'kanketsuhen',
  'remake',
  'recap',
  'web',
};

/// CJK 通用片段：季 / 期 / 部序号、剧场版、前后篇、总集篇等。
final RegExp _cjkGeneric = RegExp(
  '第?[0-9一二三四五六七八九十百]+[季期部章话話集回]|'
  '劇場版|剧场版|特別編|特别篇|總集篇|总集篇|総集編|前編|後編|前篇|后篇|'
  '完結編|完结篇|続編|续篇|映画|电影|電影',
);

/// 发布标题点名了 [target] 的某部兄弟作品。
bool _namesSibling(String releaseTitle, VideoResourceWorkTarget target) {
  if (target.siblings.isEmpty) return false;
  final List<String> words = _matchWords(releaseTitle);
  final Set<String> latin = <String>{
    for (final String word in words)
      if (!_cjkChar.hasMatch(word)) word,
  };
  final String compact = words.join();
  bool hasAll(VideoResourceMatchWords w) =>
      w.latin.every(latin.contains) && w.cjk.every(compact.contains);
  bool hasAny(VideoResourceMatchWords w) =>
      w.latin.any(latin.contains) || w.cjk.any(compact.contains);
  final bool seasonMarked = _seasonMarker.hasMatch(words.join(' '));
  // 开头的发布组标签（`[喵萌Production&LoliHouse]`）不是作品名的一部分。
  final _MatchTokens releaseCjk = _MatchTokens(<String>{}, <String>{
    for (final String word in _matchWords(
      releaseTitle.replaceFirst(_leadingGroupTag, ''),
    ))
      if (_cjkChar.hasMatch(word)) word,
  });
  bool cjkExplainedBy(VideoResourceSiblingMarks sibling) => releaseCjk
      .distinctFrom(_MatchTokens(<String>{}, sibling.siblingCjk))
      .cjk
      .isEmpty;
  for (final VideoResourceSiblingMarks sibling in target.siblings) {
    if (hasAny(sibling.targetOnly)) continue;
    if (sibling.variants.any(hasAll)) return true;
    if (!seasonMarked &&
        sibling.wholeVariants.any(hasAll) &&
        cjkExplainedBy(sibling)) {
      return true;
    }
  }
  return false;
}

final RegExp _leadingGroupTag = RegExp(r'^\s*[\[【][^\]】]*[\]】]');

/// 发布自己写了季 / 期号（`S2`、`Season 2`、`2nd Season`、`第二季`）：它在跟基础作
/// 区分自己，不能按「写全了基础作标题」判成基础作。
final RegExp _seasonMarker = RegExp(
  r'(?:^| )(?:s\d{1,2}|season \d{1,2}|\d{1,2}(?:st|nd|rd|th) season)(?: |$)'
  r'|第 ?[0-9一二三四五六七八九十]+ ?[季期]',
);

/// 比对用归一化：[TitleNormalizer.normalize]（全角 / 繁简 / 小写）后把一切非字母
/// 数字压成单个空格。`Nobita's` → `nobita s`，`新・のび太` → `新 のび太`。
String normalizeVideoResourceMatchText(String raw) =>
    TitleNormalizer.normalize(raw).replaceAll(_nonWord, ' ').trim();

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// `新・` / `新･` / `新·`：日文与中文发布对重制版的固定写法（《新・のび太の日本誕生》
/// 《新·大雄的海底鬼岩城》）。单个「新」字太常见（「大雄的新恐龙」是片名一部分），
/// 不带间隔号的只走「插入」判据。
final RegExp _cjkRemakeMarker = RegExp(r'新\s*[・･·•]');

/// 目标标题里出现任一重制记号（含单个「新」、拉丁词 shin / new）→ 目标本身就是
/// 「新」字头作品，重制判据对它没有区分力。
bool _hasRemakeMarker(String raw) {
  if (raw.contains('新')) return true;
  final String normalized = normalizeVideoResourceMatchText(raw);
  return RegExp(r'(?:^| )(?:shin|new)(?: |$)').hasMatch(normalized);
}

const List<String> _latinRemakeWords = <String>['shin', 'new'];

final RegExp _cjkChar = RegExp(r'[぀-ヿ㐀-鿿]');

/// [releaseTitle] 与 [target] 的身份矛盾；无矛盾（含证据不足）返回 null。
VideoResourceWorkMismatch? videoResourceWorkMismatch(
  String releaseTitle,
  VideoResourceWorkTarget target,
) {
  final int? year = target.year;
  if (year != null && releaseYearConflicts(releaseTitle, year)) {
    return VideoResourceWorkMismatch.year;
  }
  if (target.titles.isNotEmpty) {
    if (_spansSeveralYears(releaseTitle)) {
      return VideoResourceWorkMismatch.collection;
    }
    final String release = normalizeVideoResourceMatchText(releaseTitle);
    if (!target.remakeMarked && _isRemake(releaseTitle, release, target)) {
      return VideoResourceWorkMismatch.remake;
    }
    if (_isOtherSequel(releaseTitle, release, target)) {
      return VideoResourceWorkMismatch.sequel;
    }
  }
  if (_namesSibling(releaseTitle, target)) {
    return VideoResourceWorkMismatch.sibling;
  }
  return null;
}

/// [title] 里出现了年份，且没有一个落在 [year] ±1 内（首映与上映跨年）。
bool releaseYearConflicts(String title, int year) {
  final List<int> years = <int>[
    for (final RegExpMatch match in RegExp(
      r'(?<![0-9])(19[3-9][0-9]|20[0-9][0-9])(?![0-9])',
    ).allMatches(title))
      int.parse(match.group(1)!),
  ];
  if (years.isEmpty) return false;
  return !years.any((int value) => (value - year).abs() <= 1);
}

final RegExp _yearRange = RegExp(
  r'(?<![0-9])((?:19|20)[0-9]{2})\s*[-~–—]\s*((?:19|20)[0-9]{2})(?![0-9])',
);

/// 标题里有跨 ≥2 年的年份区间（首映 / 上映跨年的 ±1 不算）。
bool _spansSeveralYears(String title) {
  for (final RegExpMatch match in _yearRange.allMatches(title)) {
    final int from = int.parse(match.group(1)!);
    final int to = int.parse(match.group(2)!);
    if ((to - from).abs() >= 2) return true;
  }
  return false;
}

/// 「新」前面紧挨着这些字时是另一个词（`最新` / `更新` / `重新` / `全新` / `崭新`…），
/// 不是重制修饰。
const String _newCompoundPrefixes = '最更重全崭嶄清革创創翻';

bool _isRemake(String raw, String release, VideoResourceWorkTarget target) {
  if (_cjkRemakeMarker.hasMatch(raw)) return true;
  final String padded = ' $release ';
  final String compact = release.replaceAll(' ', '');
  for (final String title in target.titles) {
    if (_cjkChar.hasMatch(title)) {
      final String plain = title.replaceAll(' ', '');
      // 「新」只作标题前缀修饰（`新大雄的恐龙`）或插在标题中间（`大雄的新恐龙`）
      // 才是重制记号；标题后面的「新」（`大雄的恐龙 新版`）是发布版本说明，不算。
      for (int i = 0; i < plain.length; i++) {
        final String inserted =
            '${plain.substring(0, i)}新${plain.substring(i)}';
        if (_containsRemakeInsertion(compact, inserted, i)) return true;
      }
      continue;
    }
    final List<String> words = title.split(' ');
    for (int i = 0; i <= words.length; i++) {
      for (final String marker in _latinRemakeWords) {
        final String inserted = <String>[
          ...words.take(i),
          marker,
          ...words.skip(i),
        ].join(' ');
        if (padded.contains(' $inserted ')) return true;
      }
    }
  }
  return false;
}

/// [compact] 里有没有一处 [inserted]（「新」在其中第 [newAt] 位），且那个「新」
/// 不是 `最新` / `更新` 这类复合词的后半。
bool _containsRemakeInsertion(String compact, String inserted, int newAt) {
  int from = 0;
  while (true) {
    final int at = compact.indexOf(inserted, from);
    if (at < 0) return false;
    from = at + 1;
    final int newIndex = at + newAt;
    if (newIndex > 0 && _newCompoundPrefixes.contains(compact[newIndex - 1])) {
      continue;
    }
    return true;
  }
}

/// 标题尾部的续作序号（`stand by me ドラえもん 2` → (`stand by me ドラえもん`, 2)）。
/// 只认 1–2 位：四位数是年份，不是续作。
(String, int?) _splitSequelNumber(String title) {
  final RegExpMatch? match = RegExp(r'^(.+) (\d{1,2})$').firstMatch(title);
  if (match == null) return (title, null);
  return (match.group(1)!, int.parse(match.group(2)!));
}

/// 紧跟在标题后面的续作序号；`10 bit` / `1080p` / 声道 `5.1`（归一化后是
/// `5 1`）这类技术标签不算。
final RegExp _followingNumber = RegExp(
  r'^ (\d{1,2})(?![0-9])(?! ?(?:bit|bits|p|fps|ch|x)(?: |$))(?! \d(?: |$))',
);

/// 标题后面跟着的数字是不是**集号**而不是续作序号：补零写法（`01`，续作序号没人
/// 补零）、或原标题里这个数字带着集号上下文（` - 12`、`[12]`、`【12】`、`EP12`、
/// `#12`、`第12话`、`12话` / `12集`、`12v2`、`12 END`）。
bool _looksLikeEpisodeNumber(String digits, String raw) {
  if (digits.length > 1 && digits.startsWith('0')) return true;
  final String n = '0*${int.parse(digits)}';
  return RegExp(
    '(?:\\s[-–—~]\\s*$n(?![0-9])'
    '|[\\[【(（]\\s*$n(?:v[0-9]+)?(?:\\s*(?:end|fin))?\\s*[\\]】)）]'
    '|(?<![a-z])(?:ep\\.?\\s*|e|#\\s*)$n(?![0-9])'
    '|第\\s*$n(?![0-9])'
    '|(?<![0-9])$n\\s*(?:话|話|集|回)'
    '|(?<![0-9])$n\\s*v[0-9]+(?![0-9])'
    '|(?<![0-9])$n\\s+(?:end|fin)(?![a-z]))',
    caseSensitive: false,
  ).hasMatch(raw);
}

bool _isOtherSequel(
  String raw,
  String release,
  VideoResourceWorkTarget target,
) {
  final String padded = ' $release ';
  bool matched = false;
  bool mismatched = false;
  for (final String title in target.titles) {
    final (String base, int? number) = _splitSequelNumber(title);
    if (base.length < 3) continue;
    final String needle = ' $base';
    int from = 0;
    while (true) {
      final int at = padded.indexOf(needle, from);
      if (at < 0) break;
      from = at + 1;
      final int end = at + needle.length;
      // 词边界：标题后面必须是空格（padded 末尾恒有一个）。
      if (end >= padded.length || padded[end] != ' ') continue;
      final String rest = padded.substring(end);
      final RegExpMatch? following = _followingNumber.firstMatch(rest);
      final String? digits = following?.group(1);
      // 集号（`Title 01`、`Title - 12 [1080p]`）不是续作序号：按没写序号算。
      final int? found = digits == null || _looksLikeEpisodeNumber(digits, raw)
          ? null
          : int.parse(digits);
      if (found == number) {
        matched = true;
      } else {
        mismatched = true;
      }
    }
  }
  return mismatched && !matched;
}

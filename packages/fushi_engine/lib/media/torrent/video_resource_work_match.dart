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
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 发布与目标作品的身份矛盾种类。
enum VideoResourceWorkMismatch { year, remake, sequel, collection }

/// 目标作品的身份：归一化后的全部标题 + 年份。
class VideoResourceWorkTarget {
  VideoResourceWorkTarget({required Iterable<String> titles, this.year})
    : titles = _normalizedTitles(titles),
      remakeMarked = titles.any(_hasRemakeMarker);

  /// 只按年份判（同名剧集：靠标题搜到的是同一批发布，标题证据没有区分力）。
  VideoResourceWorkTarget.yearOnly(this.year)
    : titles = const <String>[],
      remakeMarked = false;

  /// 电影作品的完整身份：展示标题、原名、别名（含详情补的罗马字 / 英文名）。
  factory VideoResourceWorkTarget.fromReference(
    VideoMediaReference reference,
  ) => VideoResourceWorkTarget(
    titles: <String>[
      reference.title,
      if (reference.originalTitle != null) reference.originalTitle!,
      ...reference.aliases,
    ],
    year: reference.year,
  );

  /// [normalizeVideoResourceMatchText] 之后的标题，去重，过短的（< 3 字）丢掉——
  /// 太短的标题在发布名里随处可见，拿来判续作序号只会误判。
  final List<String> titles;
  final int? year;

  /// 目标自己就带重制记号（它本身是重制版 / 「新」字头作品）：不做重制判据。
  final bool remakeMarked;

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
  if (target.titles.isEmpty) return null;
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

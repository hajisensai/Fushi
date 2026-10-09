/// 「这条字幕是**这部作品**的吗」——字幕候选的作品身份核对（BUG-3068）。
///
/// 自动补字幕此前对候选只做两件事：语言排序 + 下载后的时长校验。作品身份全靠
/// 「搜索词搜得到它」隐式担保，而三家来源的搜索都担保不了：
/// - Jimaku / AJATT 的标题搜索是模糊 / 子串匹配：搜「映画ドラえもん のび太と鉄人兵団」
///   命中 2011 年重制版「新・のび太と鉄人兵団 ～はばたけ 天使たち～」，搜一部电影
///   命中同名 TV 系列「Doraemon (2005)」；
/// - OpenSubtitles 的 moviehash 档会撞车：一部电影按哈希搜回过《Pinky and the Brain》；
/// - 时长校验抓不住重制版：1986 版 98 分钟、2011 版 108 分钟，落在容差之内。
///
/// 判据只比对**数据**：目标作品的身份（[VideoMediaReference]：外部 id、标题 / 原名
/// / 别名、年份、电影或剧集）对候选的身份（来源自述 [SubtitleWorkClaim] + 字幕发布名
/// 本身写着的标题 / 年份 / 集号）。不为「新・」「2021」这类具体写法开特例——它们只是
/// 让两个标题不相等的普通差异。
///
/// 证据强弱（高到低）：
/// 1. **种类**：来源说是剧集 / 发布名带 `S03E25`，而目标是电影（或反之）→ 拒；
/// 2. **外部 id**：两侧都有且相等 → 来源已确认；都有且全不等 → 拒；
/// 3. （以下只对电影）**年份**：来源或发布名的年份与目标差一年以上 → 拒；
/// 4. **标题**：发布名本身带标题时，它必须就是目标的某个标题（归一后相等）；来源
///    已确认时放宽：
///    - 外部 id（TMDB / IMDb / AniList）相等：发布名只要**不是目标标题的真子串**
///      就收。发布名在标题后多几个词（`Title.Extended.Cut`、`Title.Directors.Cut`）
///      是上传者的版本修饰，弱的标题证据推翻不了强的 id 证据（BUG-3082）；反过来，
///      目标标题比发布名多出一截（目标「のび太の恐竜2006」、发布名「のび太の恐竜」）
///      说明发布名指的是那个更短的原作，照拒；
///    - 只有来源条目名与目标相等：发布名还须「不是目标标题的变体」（两个方向的
///      包含都拒——重制版 / 续作常把原标题整个包含在内）。
///    发布名不带标题（`01.srt`）时看来源条目名。
///
/// 剧集只用 1、2：剧集字幕文件名是「系列名 + 集号」，系列名写法五花八门，季与季之间
/// 的 AniList id 也各不相同，拿标题 / AniList 硬卡只会把对的拒掉；剧集的错配由集号
/// 匹配和时长校验管。
library;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// 核对结论：[rejected] 为真时 [detail] 是可读原因（英文短语，进日志）。
class SubtitleWorkCheck {
  const SubtitleWorkCheck.accepted() : rejected = false, detail = null;

  const SubtitleWorkCheck.rejected(String this.detail) : rejected = true;

  final bool rejected;
  final String? detail;
}

/// 字幕发布名里能读出的作品信息（纯解析，不做判断）。
class SubtitleReleaseName {
  const SubtitleReleaseName({
    required this.title,
    this.year,
    this.namesEpisode = false,
  });

  /// 归一后的标题（[normalizeMediaSearchText]）；读不出标题为空串。
  final String title;

  /// 标题之后独立出现的年份（`Title.2021.WEBRip`）。
  final int? year;

  /// 发布名写明了是某一集（`S03E25` / `第12話`）。
  final bool namesEpisode;

  /// 发布名本身带不带标题：纯集号 / 纯语言标记（`01.srt` / `ja.srt`）不算。
  bool get hasTitle => title.isNotEmpty && !RegExp(r'^\d+$').hasMatch(title);
}

/// 解析字幕发布名：去扩展名与 `[...]` 块，按分隔符切词；标题 = 第一个年份 / 技术
/// 标记（`WEBRip`、`1080p`、`x264` …）/ 集号之前的词，尾部的语言标记（`ja`、`chs`
/// …）先剥掉。纯函数。
SubtitleReleaseName parseSubtitleReleaseName(String fileName) {
  String stem = fileName.trim();
  while (true) {
    final RegExpMatch? ext = _kSubtitleExtension.firstMatch(stem);
    if (ext == null) break;
    stem = stem.substring(0, ext.start);
  }
  stem = stem.replaceAll(_kBracketBlock, ' ');
  final List<String> tokens = stem
      .split(_kTokenSeparator)
      .where((String token) => token.isNotEmpty)
      .toList();
  while (tokens.isNotEmpty &&
      _kTrailingLanguageTokens.contains(tokens.last.toLowerCase())) {
    tokens.removeLast();
  }
  final List<String> title = <String>[];
  int? year;
  bool episode = false;
  for (final String token in tokens) {
    if (_kEpisodeToken.hasMatch(token)) {
      episode = true;
      break;
    }
    if (title.isNotEmpty && _kYearToken.hasMatch(token)) {
      year = int.parse(token);
      break;
    }
    if (_isTechnicalToken(token)) break;
    title.add(token);
  }
  return SubtitleReleaseName(
    title: normalizeMediaSearchText(title.join(' ')),
    year: year,
    namesEpisode: episode,
  );
}

/// 核对 [candidate] 是否属于 [target] 这部作品。见 library doc 的证据次序。
SubtitleWorkCheck checkSubtitleWork(
  VideoMediaReference target,
  VideoSubtitleCandidate candidate,
) {
  final SubtitleWorkClaim? claim = candidate.work;
  final SubtitleReleaseName release = parseSubtitleReleaseName(
    candidate.fileName,
  );
  final bool movie = target.mediaKind == VideoMetadataMediaKind.movie;

  final VideoMetadataMediaKind? claimedKind = claim?.kind;
  if (claimedKind != null && claimedKind != target.mediaKind) {
    return SubtitleWorkCheck.rejected(
      'source files it under a ${claimedKind.name} work, '
      'target is a ${target.mediaKind.name}',
    );
  }
  if (movie && release.namesEpisode) {
    return const SubtitleWorkCheck.rejected(
      'release names a TV episode, target is a movie',
    );
  }

  final _IdVerdict ids = _compareIds(target, claim, movie: movie);
  if (ids == _IdVerdict.contradicted) {
    return const SubtitleWorkCheck.rejected(
      'source work ids differ from the target',
    );
  }
  if (!movie) return const SubtitleWorkCheck.accepted();

  final int? targetYear = target.year;
  if (targetYear != null) {
    for (final int? year in <int?>[claim?.year, release.year]) {
      if (year != null && (year - targetYear).abs() > 1) {
        return SubtitleWorkCheck.rejected(
          'subtitle is for a $year work, target is from $targetYear',
        );
      }
    }
  }

  final Set<String> targetTitles = _titleForms(<String?>[
    target.title,
    target.originalTitle,
    ...target.aliases,
  ]);
  final bool idConfirmed = ids == _IdVerdict.confirmed;
  final bool confirmed =
      idConfirmed ||
      _titleForms(claim?.titles ?? const <String>[]).any(targetTitles.contains);
  if (release.hasTitle) {
    final Set<String> releaseTitles = _releaseForms(release);
    if (releaseTitles.any(targetTitles.contains)) {
      return const SubtitleWorkCheck.accepted();
    }
    final bool namesOtherWork = idConfirmed
        ? _targetExtends(releaseTitles, targetTitles)
        : _isVariantOf(releaseTitles, targetTitles);
    if (!confirmed || namesOtherWork) {
      return const SubtitleWorkCheck.rejected(
        'release title names a different work',
      );
    }
    return const SubtitleWorkCheck.accepted();
  }
  if (confirmed || (claim?.titles.isEmpty ?? true)) {
    return const SubtitleWorkCheck.accepted();
  }
  return const SubtitleWorkCheck.rejected(
    'source work title differs from the target',
  );
}

enum _IdVerdict { confirmed, contradicted, unknown }

/// 两侧都有的 id 才比：任一相等 → 确认；有可比的且全不等 → 矛盾。
///
/// AniList 只对电影算数：剧集每季一个 AniList id，而刮削身份（TMDB 剧集）可能跨季，
/// 「AniList 不等」证明不了是别的作品。TMDB 号段分电影 / 剧集，种类不明不可比。
_IdVerdict _compareIds(
  VideoMediaReference target,
  SubtitleWorkClaim? claim, {
  required bool movie,
}) {
  if (claim == null) return _IdVerdict.unknown;
  final List<bool> comparisons = <bool>[
    if (movie && target.anilistId != null && claim.anilistId != null)
      target.anilistId == claim.anilistId,
    if (target.tmdbId != null &&
        claim.tmdbId != null &&
        claim.kind == target.mediaKind)
      target.tmdbId == claim.tmdbId,
    if (_imdbNumber(target.imdbId) != null && _imdbNumber(claim.imdbId) != null)
      _imdbNumber(target.imdbId) == _imdbNumber(claim.imdbId),
  ];
  if (comparisons.contains(true)) return _IdVerdict.confirmed;
  if (comparisons.isNotEmpty) return _IdVerdict.contradicted;
  return _IdVerdict.unknown;
}

int? _imdbNumber(String? raw) => int.tryParse(
  (raw ?? '').trim().replaceFirst(RegExp('^tt', caseSensitive: false), ''),
);

/// 标题的比较形态：归一后的全文，外加去掉开头「映画 / 劇場版」标记的形态——
/// 「映画ドラえもん X」与「ドラえもん X」是同一部片的两种写法，两侧对称处理。
Set<String> _titleForms(Iterable<String?> titles) => <String>{
  for (final String? title in titles)
    if (title != null) ..._forms(normalizeMediaSearchText(title)),
};

/// 发布名的比较形态：「标题」与「标题 + 年份」（`のび太の恐竜.2006` 的年份可能是
/// 片名本身的一部分：「のび太の恐竜2006」）。
Set<String> _releaseForms(SubtitleReleaseName release) => <String>{
  ..._forms(release.title),
  if (release.year != null) ..._forms('${release.title}${release.year}'),
};

Iterable<String> _forms(String normalized) sync* {
  if (normalized.isEmpty) return;
  yield normalized;
  for (final String marker in _kMovieMarkers) {
    if (normalized.length > marker.length && normalized.startsWith(marker)) {
      yield normalized.substring(marker.length);
    }
  }
}

/// 发布名与目标标题互相包含但不相等：同一系列的重制版 / 续作 / 年份版（「新・
/// のび太と鉄人兵団 ～はばたけ 天使たち～」包含「のび太と鉄人兵団」，「のび太の
/// 恐竜」被「のび太の恐竜2006」包含）。
bool _isVariantOf(Set<String> release, Set<String> target) {
  for (final String r in release) {
    for (final String t in target) {
      if (r != t && (r.contains(t) || t.contains(r))) return true;
    }
  }
  return false;
}

/// 目标标题把发布名整个包含且更长：发布名指的是目标所在系列里那个标题更短的
/// 作品（原作 / 前作），即使来源 id 说是同一部也不收。发布名比目标长的方向不算
/// ——id 已确认时，多出来的词只是版本修饰。
bool _targetExtends(Set<String> release, Set<String> target) {
  for (final String r in release) {
    for (final String t in target) {
      if (r != t && t.contains(r)) return true;
    }
  }
  return false;
}

/// 归一后（片假名已折成平假名）的「剧场版」前缀。
const List<String> _kMovieMarkers = <String>['映画', '劇場版', '剧场版', 'gekijouban'];

final RegExp _kSubtitleExtension = RegExp(
  r'\.(srt|ass|ssa|vtt|sub|txt|zip|rar|7z)$',
  caseSensitive: false,
);

/// `[...]` / `【...】` / `{...}` 块：字幕组、画质、语言修饰（`ja[cc]`），不含标题。
final RegExp _kBracketBlock = RegExp(r'\[[^\]]*\]|【[^】]*】|\{[^}]*\}');

final RegExp _kTokenSeparator = RegExp(r'[.\s_()（）]+');

final RegExp _kYearToken = RegExp(r'^(19|20)\d\d$');

final RegExp _kEpisodeToken = RegExp(
  r'^(s\d{1,2}e\d{1,4}|第\d+[話话集])$',
  caseSensitive: false,
);

/// 发布名尾部的语言 / 字幕类型标记（只从尾部剥，标题中间的同形词不动）。
const Set<String> _kTrailingLanguageTokens = <String>{
  'ja', 'jp', 'jpn', 'jap', 'japanese', //
  'en', 'eng', 'english', //
  'zh', 'chs', 'cht', 'sc', 'tc', 'chi', 'zho', 'gb', 'big5', //
  'ko', 'kor', //
  'cc', 'sdh', 'forced',
};

/// 片源 / 编码 / 平台 / 分辨率：发布名里标题结束的标志。`x264-GROUP` 这种带发布组
/// 后缀的按 `-` 前一段判。
bool _isTechnicalToken(String token) {
  final String head = token.toLowerCase().split('-').first;
  final String lower = token.toLowerCase();
  return _kTechnicalTokens.contains(lower) ||
      _kTechnicalTokens.contains(head) ||
      RegExp(r'^\d{3,4}[pi]$').hasMatch(head) ||
      RegExp(r'^\d{3,4}x\d{3,4}$').hasMatch(head);
}

const Set<String> _kTechnicalTokens = <String>{
  'webrip', 'web-dl', 'webdl', 'web-rip', 'bdrip', 'brrip', 'bluray', //
  'blu-ray', 'bdremux', 'remux', 'dvdrip', 'dvd', 'bd', 'hdrip', 'hdtv', //
  'tvrip', 'vhsrip', 'ldrip', //
  'x264', 'x265', 'h264', 'h265', 'hevc', 'avc', 'xvid', 'divx', 'aac', //
  'ac3', 'eac3', 'dts', 'flac', 'opus', '10bit', '8bit', 'hi10p', //
  'netflix', 'amzn', 'hulu', 'abema', 'dsnp', 'unext', 'crunchyroll', //
  '4k', 'uhd', 'hdr', 'hdr10',
};

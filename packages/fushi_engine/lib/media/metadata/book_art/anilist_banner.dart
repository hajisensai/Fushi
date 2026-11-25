/// 「获取各卷封面与横幅」的 AniList 横幅回落（纯函数，无 IO）。
///
/// MangaBaka 没有横幅时（或系列只在 Bangumi 上认定，Bangumi 根本没有横幅）才用：
/// - 已认定的 MangaBaka 系列带 AniList id（`source.anilist.id`）→ 按 id 直取，不比标题；
/// - 否则按名搜 AniList，只收**唯一**一个「标题与已认定系列严格同名、种类一致、不是
///   成人向、作者不冲突」的条目；同名同种类的有两个以上（重名作品）就不取，宁可没有
///   横幅也不贴错图。
///
/// 横幅只是背景图，不影响系列匹配与卷封面：AniList 不进系列候选、不能被钉死。
library;

import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart';

/// AniList 条目形态 → 系列种类（[BookArtCandidateKind]）。
BookArtCandidateKind aniListBookKind(BookCatalogFormat? format) =>
    switch (format) {
      BookCatalogFormat.novel => BookArtCandidateKind.novel,
      BookCatalogFormat.manga ||
      BookCatalogFormat.manhwa ||
      BookCatalogFormat.manhua ||
      BookCatalogFormat.oneShot => BookArtCandidateKind.manga,
      null => BookArtCandidateKind.other,
    };

/// AniList 条目的全部可比较写法（日文原名在前，与 [bestTitleTier] 的「首项是原名」
/// 约定一致）。
List<String> aniListComparableTitles(BookCatalogRecord record) => <String>[
  record.title,
  if (record.originalTitle case final String alt when alt != record.title) alt,
];

/// AniList 条目的作者名（[BookCatalogRecord.author] 以 `, ` 连接）。
List<String> aniListAuthors(BookCatalogRecord record) => <String>[
  for (final String a in (record.author ?? '').split(', '))
    if (a.trim().isNotEmpty) a.trim(),
];

/// 条目自带的横幅 → 候选图；没有横幅或成人向为 null。AniList 不给横幅尺寸，下载后
/// 再量。
BookArtImageOption? aniListBannerOption(BookCatalogRecord record) {
  final String? url = record.bannerUrl;
  if (url == null || record.isAdult) return null;
  return BookArtImageOption(source: BookArtSource.anilist, url: url);
}

/// 按名搜到的 [records] 里挑与已认定系列是同一部作品的那条。
///
/// [seriesTitles] 是已认定系列的全部写法（MangaBaka `comparableTitles` / Bangumi
/// 的 `name` + `name_cn`），[kind] 是它的种类，[author] 是本地书的作者。
/// 只认严格同名（[BookArtTitleTier.strict]）、同种类、非成人向、作者不冲突的条目，
/// 且这样的条目必须恰好一个；返回它（它自己可能没有横幅，调用方再看
/// [aniListBannerOption]）。
BookCatalogRecord? pickAniListSameWork({
  required List<String> seriesTitles,
  required BookArtCandidateKind kind,
  required String? author,
  required Iterable<BookCatalogRecord> records,
}) {
  if (kind == BookArtCandidateKind.other) return null;
  final Map<String, BookCatalogRecord> matches = <String, BookCatalogRecord>{};
  for (final BookCatalogRecord r in records) {
    if (r.isAdult || aniListBookKind(r.format) != kind) continue;
    final List<String> titles = aniListComparableTitles(r);
    final bool sameTitle = seriesTitles.any(
      (String t) => bestTitleTier(t, titles) == BookArtTitleTier.strict,
    );
    if (!sameTitle) continue;
    if (compareBookAuthors(author, aniListAuthors(r)) ==
        BookArtAuthorEvidence.mismatch) {
      continue;
    }
    matches.putIfAbsent(r.id, () => r);
  }
  return matches.length == 1 ? matches.values.single : null;
}

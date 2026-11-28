import 'dart:convert';

import 'package:fushi_core/fushi_core.dart'
    show CollectionScrapeMetaRow, ItemScrapeMetaRow;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

// =============================================================================
// 系列色块（设计稿 `.vb`）：有刮削元数据的条目 / 合集在色块布局里的统一视觉——
// 2:3 海报斜放在起始侧、无字横版背景图铺满尾侧、艺术字 logo、概览行（「类型 /
// 类型 · ★ 8.8」）与信息 chip（「2014 · 3 卷」）。
//
// 视频库系列卡、书架 / 漫画库合集卡、游戏库色块卡共用这一份：元数据一律先折成
// 与媒体无关的 [FushiSeriesMeta]（各库只负责从自己的表里取数），再经
// [fushiSeriesCoverBlock] 落到 [FushiCoverBlock]——两边不会各写一遍拼串 /
// 取图逻辑而漂移（2026-11-16 所有者：「涉及到刮削的都应该复用」）。
// =============================================================================

/// 系列色块的元数据（与媒体类型无关）。没有的项为 null，色块上整项不画。
@immutable
class FushiSeriesMeta {
  const FushiSeriesMeta({
    this.backdrop,
    this.logo,
    this.poster,
    this.overview,
    this.chip,
    this.genres = const <String>[],
    this.rating,
    this.year,
    this.backdropHasText = false,
  });

  /// 由零散字段拼出概览 / chip：概览 =「类型前若干个（` / ` 连接）· ★ 评分」，
  /// chip = [chipParts] 用 ` · ` 连接（调用方按「类型 · 年份 · 数量」顺序给）。
  factory FushiSeriesMeta.fromParts({
    ImageProvider? backdrop,
    ImageProvider? logo,
    ImageProvider? poster,
    List<String> genres = const <String>[],
    int overviewGenres = 2,
    double? rating,
    int? year,
    List<String> chipParts = const <String>[],
    bool backdropHasText = false,
  }) => FushiSeriesMeta(
    backdrop: backdrop,
    backdropHasText: backdropHasText,
    logo: logo,
    poster: poster,
    overview: fushiSeriesOverview(
      genres: genres.take(overviewGenres).toList(growable: false),
      rating: rating,
    ),
    chip: chipParts.isEmpty ? null : chipParts.join(' · '),
    genres: genres,
    rating: rating != null && rating > 0 ? rating : null,
    year: year,
  );

  /// 无字横版背景图（[FushiCoverBlockArt.portrait] 下铺在尾侧）。
  final ImageProvider? backdrop;

  /// 标题艺术字。
  final ImageProvider? logo;

  /// [backdrop] 本身印着片名（只有带字的背景图可用：TMDB 语言标签非空的
  /// backdrop、title card 一类）。为 true 时原图里的字就是标题，色块不再叠一份
  /// [logo]（2026-11-20 用户拍板设计稿 #3：宁可少一份也不出现两份）。
  final bool backdropHasText;

  /// 色块上实际要画的 logo：背景图自带片名时为 null。
  ImageProvider? get displayLogo => backdropHasText ? null : logo;

  /// 2:3 作品海报（横版槽左侧斜放那张，调用方按需使用）。
  final ImageProvider? poster;

  /// 概览行（「日常 / 喜剧 · ★ 8.8」）。
  final String? overview;

  /// 信息 chip（「TV · 2014 · 12 集」/「2014 · 3 卷」）。
  final String? chip;

  /// 结构化的类型 / 评分（>0）/ 年份：详情页 hero 把它们画成分开的信息胶囊
  /// （[overview] / [chip] 是色块上拼好的一行字）。
  final List<String> genres;
  final double? rating;
  final int? year;

  /// 换一张背景图，其余字段原样；[backdropHasText] 跟着新图给（默认无字）。
  FushiSeriesMeta withBackdrop(
    ImageProvider backdrop, {
    bool backdropHasText = false,
  }) => FushiSeriesMeta(
    backdrop: backdrop,
    backdropHasText: backdropHasText,
    logo: logo,
    poster: poster,
    overview: overview,
    chip: chip,
    genres: genres,
    rating: rating,
    year: year,
  );

  /// 只补空位的背景图 / logo：已有的（本机刮削的）一律不换，[backdrop] / [logo]
  /// 只填进原本为 null 的槽。补进的背景图是外部来源的无字图（[backdropHasText] 为
  /// false）；原有背景图保留它自己的旗子。两项都补不了时原样返回。
  FushiSeriesMeta withMissingArt({
    ImageProvider? backdrop,
    ImageProvider? logo,
  }) {
    final bool addBackdrop = this.backdrop == null && backdrop != null;
    final bool addLogo = this.logo == null && logo != null;
    if (!addBackdrop && !addLogo) return this;
    return FushiSeriesMeta(
      backdrop: addBackdrop ? backdrop : this.backdrop,
      backdropHasText: addBackdrop ? false : backdropHasText,
      logo: addLogo ? logo : this.logo,
      poster: poster,
      overview: overview,
      chip: chip,
      genres: genres,
      rating: rating,
      year: year,
    );
  }

  /// 背景图 / logo / 概览 / chip 一项都没有（海报不算：没刮削的条目也有封面）。
  bool get isEmpty =>
      backdrop == null && logo == null && overview == null && chip == null;
}

/// 概览行：类型（` / ` 连接）· ★ 评分（一位小数，≤0 不画）；都没有为 null。
String? fushiSeriesOverview({
  List<String> genres = const <String>[],
  double? rating,
}) {
  final List<String> parts = <String>[
    if (genres.isNotEmpty) genres.join(' / '),
    if (rating != null && rating > 0) '★ ${rating.toStringAsFixed(1)}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 刮削标签 JSON（`[{"name":"日常","count":1234}]`，按热度降序）的前 [limit]
/// 个名字；解析失败 / 没有为空表。`CollectionScrapeMeta.tagsJson` 与
/// `VideoScrapeMeta.tagsJson` 同形。
List<String> fushiScrapeTagNames(String? json, {required int limit}) {
  if (json == null || json.isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! List<Object?>) return const <String>[];
    return <String>[
      for (final Object? tag in decoded)
        if (tag is Map<String, Object?> &&
            tag['name'] is String &&
            (tag['name']! as String).isNotEmpty)
          tag['name']! as String,
    ].take(limit).toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}

/// 刮削日期（`YYYY-MM-DD` / `YYYY-MM` / 裸年份 `YYYY`）→ 年份；解析不出或早于
/// 1900（脏数据）为 null。
int? fushiScrapeYear(String? date) {
  if (date == null) return null;
  final RegExpMatch? m = RegExp(r'^(\d{4})').firstMatch(date.trim());
  if (m == null) return null;
  final int year = int.parse(m.group(1)!);
  return year >= 1900 ? year : null;
}

/// 普通合集（书 / 漫画等，没有视频那套作品级资料）的系列元数据：合集有刮削资料
/// 行或横版背景图时非 null，否则 null（调用方保持原摆法）。概览 = 刮削标签前两个
/// · ★ 评分；chip = 年份 · [countLabel]（「3 卷」，调用方按媒体给）。
FushiSeriesMeta? collectionSeriesMeta({
  required CollectionScrapeMetaRow? scrape,
  required ImageProvider? backdrop,
  ImageProvider? logo,
  String? countLabel,
}) => _scrapeSeriesMeta(
  hasScrape: scrape != null,
  airDate: scrape?.airDate,
  rating: scrape?.rating,
  tagsJson: scrape?.tagsJson,
  backdrop: backdrop,
  logo: logo,
  countLabel: countLabel,
);

/// 单个条目（书 / 漫画 / 字幕书 / 游戏，`item_scrape_meta` + `item_images`）的
/// 系列元数据，与 [collectionSeriesMeta] 同一口径：有刮削资料行或横版背景图时
/// 非 null，否则 null（调用方保持原摆法）。
FushiSeriesMeta? itemSeriesMeta({
  required ItemScrapeMetaRow? scrape,
  required ImageProvider? backdrop,
  ImageProvider? logo,
  String? countLabel,
}) => _scrapeSeriesMeta(
  hasScrape: scrape != null,
  airDate: scrape?.airDate,
  rating: scrape?.rating,
  tagsJson: scrape?.tagsJson,
  backdrop: backdrop,
  logo: logo,
  countLabel: countLabel,
);

/// [collectionSeriesMeta] / [itemSeriesMeta] 的共同实现（两张刮削表同形字段）。
FushiSeriesMeta? _scrapeSeriesMeta({
  required bool hasScrape,
  required String? airDate,
  required double? rating,
  required String? tagsJson,
  required ImageProvider? backdrop,
  required ImageProvider? logo,
  required String? countLabel,
}) {
  if (!hasScrape && backdrop == null) return null;
  final int? year = fushiScrapeYear(airDate);
  return FushiSeriesMeta.fromParts(
    backdrop: backdrop,
    logo: logo,
    genres: fushiScrapeTagNames(tagsJson, limit: 4),
    rating: rating,
    year: year,
    chipParts: <String>[
      if (year != null) '$year',
      if (countLabel != null && countLabel.isNotEmpty) countLabel,
    ],
  );
}

/// 背景图槽的 widget：铺满、不进语义树，解码失败画空（色块底色兜底）。
Widget? fushiSeriesBackdrop(ImageProvider? image) => image == null
    ? null
    : Image(
        image: image,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
            const SizedBox.shrink(),
      );

/// 系列色块：[meta] 的 logo / 概览 / chip 落到 [FushiCoverBlock]，其余参数原样
/// 透传。[backdrop] 由调用方显式给（通常是 `fushiSeriesBackdrop(meta.backdrop)`；
/// 视频横版槽等摆法会换成别的图或 null）。[art] 默认竖版海报摆法。
///
/// [backdropHasText]：画出来的 [backdrop] 是否自带片名（自带时不叠 logo）；null =
/// 按 [FushiSeriesMeta.backdropHasText]（[backdrop] 就是 `meta.backdrop` 的常见
/// 情形）。[backdrop] 换成了别的图时调用方显式给。
Widget fushiSeriesCoverBlock({
  required FushiCoverBlockSize size,
  required String title,
  required List<Widget> covers,
  required FushiSeriesMeta? meta,
  required Widget? backdrop,
  FushiCoverBlockArt art = FushiCoverBlockArt.portrait,
  String? eyebrow,
  String? byline,
  FushiCoverBlockFigure? figure,
  FushiCoverBlockAction? action,
  ImageProvider? tintImage,
  Key? metaKey,
  String? subtitle,
  IconData? leadingIcon,
  ShelfMetaTone tone = ShelfMetaTone.normal,
  double? progress,
  bool completed = false,
  Widget? trailing,
  Widget? coverOverlay,
  bool? selectionMode,
  bool? selected,
  bool hoverEnabled = true,
  bool? backdropHasText,
}) => FushiCoverBlock(
  size: size,
  art: art,
  title: title,
  covers: covers,
  backdrop: backdrop,
  logo: (backdropHasText ?? meta?.backdropHasText ?? false) ? null : meta?.logo,
  eyebrow: eyebrow,
  byline: byline,
  overview: meta?.overview,
  chip: meta?.chip,
  figure: figure,
  action: action,
  tintImage: tintImage,
  metaKey: metaKey,
  subtitle: subtitle,
  leadingIcon: leadingIcon,
  tone: tone,
  progress: progress,
  completed: completed,
  trailing: trailing,
  coverOverlay: coverOverlay,
  selectionMode: selectionMode,
  selected: selected,
  hoverEnabled: hoverEnabled,
);

import 'dart:async';

import 'package:fushi_core/fushi_core.dart' show ItemScrapeMetaRow;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/item_scrape_detail.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart'
    show fushiScrapeTagNames, fushiScrapeYear;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 单本刮削资料（[ItemScrapeDetail]）在详情页上的展示派生：书详情页
/// （`BookDetailPage`）与漫画作品页（`MangaSeriesPage`）**同一份**——原名、评分 /
/// 年份 / 类型 chip、简介、资料行（作者 / 发行日期 / 评分(人数) / 来源）与「查看
/// 条目」外链按钮，两页渲染逐字一致。
///
/// [keyPrefix] 给各区块的测试 key 加前缀（书详情页 `book-detail`，漫画作品页
/// `manga-series`）：`<prefix>-rating` / `<prefix>-facts` / `<prefix>-source-link`。
@immutable
class ItemScrapeDetailView {
  ItemScrapeDetailView(
    this.detail, {
    required String title,
    String? author,
    this.keyPrefix = 'book-detail',
  }) : author = _nonEmpty(author),
       originalTitle = _distinct(detail.meta?.originalTitle, title);

  final ItemScrapeDetail detail;
  final String keyPrefix;

  /// 书架侧作者（导入时读出的）；资料行的「作者」。
  final String? author;

  /// 原名；与书名相同不重复占行。
  final String? originalTitle;

  ItemScrapeMetaRow? get meta => detail.meta;

  /// 有任一刮削数据（资料行 / 背景图 / 艺术字）。
  bool get scraped => !detail.isEmpty;

  ImageProvider? get backdrop => detail.backdrop;
  ImageProvider? get logo => detail.logo;

  String? get summary => _nonEmpty(meta?.summary);

  double? get rating {
    final double? r = meta?.rating;
    return r != null && r > 0 ? r : null;
  }

  int? get year => fushiScrapeYear(meta?.airDate);

  /// 类型标签（按热度取前 [limit] 个）。
  List<String> genres({int limit = 3}) =>
      fushiScrapeTagNames(meta?.tagsJson, limit: limit);

  String? get sourceLabel => itemScrapeSourceLabel(meta?.source);

  /// 条目详情页外链（只放行 http(s)）。
  Uri? get detailUri {
    final String? v = _nonEmpty(meta?.detailUrl);
    if (v == null) return null;
    final Uri? uri = Uri.tryParse(v);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  /// 标题下的信息 chip：评分、年份、类型。
  List<MediaDetailChip> metaPills({int genreLimit = 3}) {
    final double? rating = this.rating;
    final int? year = this.year;
    return <MediaDetailChip>[
      if (rating != null)
        MediaDetailChip(
          '★ ${rating.toStringAsFixed(1)}',
          tone: MediaDetailChipTone.primary,
          key: ValueKey<String>('$keyPrefix-rating'),
        ),
      if (year != null) MediaDetailChip('$year', icon: FushiIcons.calendar),
      for (final String genre in genres(limit: genreLimit))
        MediaDetailChip(genre),
    ];
  }

  /// 资料行：作者、发行日期、评分(人数)、[extra]（页面自己的事实，如漫画卷的
  /// 页数）、来源。不重复标题下 chip 已醒目显示的：发行日期只在比年份 chip 更精确
  /// （到月 / 日）时出；评分只在有评分人数时出（「7.9 · 1,234 人评分」）。
  List<(String, String)> facts({
    List<(String, String)> extra = const <(String, String)>[],
  }) {
    final double? rating = this.rating;
    final String? date = _nonEmpty(meta?.airDate);
    final int? votes = switch (meta?.ratingCount) {
      final int n when n > 0 => n,
      _ => null,
    };
    return <(String, String)>[
      if (author case final String a) (t.book_edit_author, a),
      if (date != null && (year == null || date.length > 4))
        (t.book_detail_field_release, date),
      if (rating != null && votes != null)
        (
          t.book_detail_field_rating,
          '${rating.toStringAsFixed(1)} · '
              '${t.book_detail_rating_votes(count: votes)}',
        ),
      ...extra,
      if (sourceLabel case final String label)
        (t.book_detail_field_source, label),
    ];
  }

  /// 「资料」区块（不含左右页边距与进场动效，调用方按版式补页边距、包
  /// `FushiStaggeredEntrance`）。[extra] 见 [facts]；资料行为空时 null。
  Widget? factsSection(
    BuildContext context, {
    List<(String, String)> extra = const <(String, String)>[],
  }) {
    final List<(String, String)> facts = this.facts(extra: extra);
    if (facts.isEmpty) return null;
    return Padding(
      padding: EdgeInsets.only(
        top: FushiDesignTokens.of(context).spacing.section,
      ),
      child: MediaPosterFactList(
        key: ValueKey<String>('$keyPrefix-facts'),
        heading: t.book_detail_info_heading,
        facts: facts,
      ),
    );
  }

  /// 「刮削资料 / 重新刮削」操作项（与「⋯」同一套图标钮，文字进 tooltip）。
  MediaDetailMenuItem scrapeAction({
    required bool enabled,
    required VoidCallback onSelected,
  }) => MediaDetailMenuItem(
    key: ValueKey<String>('$keyPrefix-scrape'),
    icon: FushiIcons.imageSearch,
    label: scraped
        ? t.book_detail_rescrape_action
        : t.book_detail_scrape_action,
    enabled: enabled,
    onSelected: onSelected,
  );

  /// 「查看条目 · 来源」操作项（图标钮，来源显示名进 tooltip）；没有外链为 null。
  MediaDetailMenuItem? sourceLinkAction({
    Future<void> Function(Uri uri)? launch,
  }) {
    final Uri? uri = detailUri;
    if (uri == null) return null;
    final String? label = sourceLabel;
    return MediaDetailMenuItem(
      key: ValueKey<String>('$keyPrefix-source-link'),
      icon: FushiIcons.openInNew,
      label: label == null
          ? t.book_detail_source_open
          : '${t.book_detail_source_open} · $label',
      onSelected: () => unawaited(openItemScrapeLink(uri, launch: launch)),
    );
  }

  static String? _nonEmpty(String? s) {
    final String? v = s?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static String? _distinct(String? s, String other) {
    final String? v = _nonEmpty(s);
    return v == null || v == other.trim() ? null : v;
  }
}

/// 打开刮削条目外链：[launch] 是测试接缝，null = 系统浏览器。
Future<void> openItemScrapeLink(
  Uri uri, {
  Future<void> Function(Uri uri)? launch,
}) async {
  if (launch != null) return launch(uri);
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object catch (e, st) {
    ErrorLogService.instance.log(
      'item_scrape_detail',
      'open link failed: $e',
      st,
    );
  }
}

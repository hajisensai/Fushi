/// 视频「条目信息」弹窗：展示自动刮削抄来的 Bangumi 条目资料。
///
/// 排版照抄 Bangumi 条目页的信息层级：标题（中文）+ 原名 → 评分 → 资料表
/// （放送/话数/导演/制作…）→ 简介 → 标签。资料本身由后台自动刮削落
/// `video_scrape_meta` 表（见 `scraper/auto_scrape_service.dart`），本弹窗**只读**，
/// 不发网络请求——「重新刮削」是把资料行删掉后交回自动流水线，不在 UI 线程里跑刮削。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/utils.dart';

/// 弹出条目信息面板。[metadata] 为 null = 还没刮到（展示空态说明）。
/// [onRescrape] 非空时显示「重新刮削」。
Future<void> showScrapeInfoDialog({
  required BuildContext context,
  required String fallbackTitle,
  required ScrapeMetadata? metadata,
  Future<void> Function()? onRescrape,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => ScrapeInfoDialog(
      fallbackTitle: fallbackTitle,
      metadata: metadata,
      onRescrape: onRescrape,
    ),
  );
}

/// 条目信息面板本体（纯展示，便于 widget 测试直接挂载）。
class ScrapeInfoDialog extends StatelessWidget {
  const ScrapeInfoDialog({
    required this.fallbackTitle,
    required this.metadata,
    this.onRescrape,
    super.key,
  });

  /// 未刮到资料时用视频自身标题当抬头。
  final String fallbackTitle;

  final ScrapeMetadata? metadata;
  final Future<void> Function()? onRescrape;

  /// 资料表最多展示的行数：Bangumi infobox 动辄二三十行（每个声优一行），全列会把
  /// 弹窗撑成长名单。取前若干条（源本身按重要度排：中文名/话数/放送/导演/制作…）。
  static const int _maxInfoboxRows = 8;

  /// 标签最多展示条数（源按热度降序，尾巴是长尾噪音）。
  static const int _maxTags = 12;

  @override
  Widget build(BuildContext context) {
    final ScrapeMetadata? meta = metadata;
    return AlertDialog(
      title: Text(
        meta?.title ?? fallbackTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 420,
        child: meta == null
            ? Text(t.video_scrape_info_empty)
            : SingleChildScrollView(
                child: _buildBody(context, meta),
              ),
      ),
      actions: <Widget>[
        if (onRescrape != null)
          TextButton(
            key: const ValueKey<String>('scrape_info_rescrape'),
            onPressed: () async {
              Navigator.of(context).pop();
              await onRescrape!();
            },
            child: Text(t.video_scrape_rescrape),
          ),
        if (meta?.detailUrl != null)
          TextButton(
            key: const ValueKey<String>('scrape_info_view_subject'),
            onPressed: () => _openSubject(meta!.detailUrl!),
            child: Text(t.video_scrape_view_subject),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.video_scrape_batch_close),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, ScrapeMetadata meta) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    final List<ScrapeInfoboxEntry> rows = <ScrapeInfoboxEntry>[
      // 放送/话数是刮削层的一等字段（不只在 infobox 里），单独置顶成行，缺失不占位。
      if (meta.airDate != null)
        ScrapeInfoboxEntry(key: t.video_scrape_air_date, value: meta.airDate!),
      if (meta.episodeCount != null)
        ScrapeInfoboxEntry(
          key: t.video_scrape_episodes,
          value: '${meta.episodeCount}',
        ),
      ...meta.infobox.take(_maxInfoboxRows),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (meta.originalTitle != null)
          Text(
            meta.originalTitle!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        if (meta.rating != null) ...<Widget>[
          const SizedBox(height: 12),
          _buildRating(theme, colors, meta),
        ],
        if (rows.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          for (final ScrapeInfoboxEntry row in rows) _buildInfoRow(theme, row),
        ],
        if (meta.summary != null) ...<Widget>[
          const SizedBox(height: 16),
          Text(t.video_scrape_summary, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(
            meta.summary!,
            style: theme.textTheme.bodyMedium,
          ),
        ],
        if (meta.tags.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Text(t.video_scrape_tags, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          // 标签走共享 MD3 [HibikiTag]（与词典条目标签同一视觉），不自造 Chip 密度。
          Wrap(
            children: <Widget>[
              for (final ScrapeTag tag in meta.tags.take(_maxTags))
                HibikiTag(
                  text: tag.name,
                  backgroundColor: colors.secondaryContainer,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildRating(
    ThemeData theme,
    ColorScheme colors,
    ScrapeMetadata meta,
  ) {
    return Row(
      children: <Widget>[
        Icon(Icons.star_rounded, size: 20, color: colors.primary),
        const SizedBox(width: 4),
        Text(
          meta.rating!.toStringAsFixed(1),
          style: theme.textTheme.titleMedium?.copyWith(
            color: colors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (meta.ratingCount != null) ...<Widget>[
          const SizedBox(width: 8),
          Text(
            t.video_scrape_rating_votes(count: meta.ratingCount!),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _buildInfoRow(ThemeData theme, ScrapeInfoboxEntry row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              row.key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(row.value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  /// 打开 Bangumi 条目页（外部浏览器）。失败只提示一句本地化文案，原始异常不进 UI。
  Future<void> _openSubject(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      HibikiToast.show(msg: t.video_scrape_apply_failed);
    }
  }
}

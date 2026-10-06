/// 资料源候选作品行。批次内确认与事后手动指定共用同一份呈现与点击语义，
/// 避免「选一个作品」这件事在两处各长一套 UI 而慢慢漂开。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider_label.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/utils.dart';

/// 候选卡封面框（2:3 竖封面，M3E 小件圆角 12）。
const double _kCandidateCoverWidth = 56;
const double _kCandidateCoverHeight = 84;

/// M3E 候选卡：封面（有图显示、无图占位）+ 标题 + 身份行 + 资料源 / 年份标签，
/// AI 倾向的那条额外带一块 tertiary 色块（建议文案 + 置信度小进度条）。
///
/// 传了 [groupIndex] / [groupCount] 时是分段列表里的一格（首尾大圆角、行间
/// 2px）；否则是一张独立卡片。整卡可点，点按 = 选中这条候选。
class VideoSourceScrapeCandidateTile extends StatelessWidget {
  const VideoSourceScrapeCandidateTile({
    required this.candidate,
    required this.onSelected,
    this.aiSuggestion,
    this.aiConfidencePercent,
    this.groupIndex,
    this.groupCount,
    super.key,
  });

  final VideoSourceScrapeConfirmationCandidate candidate;
  final ValueChanged<VideoSourceScrapeConfirmationCandidate> onSelected;

  /// AI 倾向于这一条时的说明（「AI 建议 · 60%」+ 理由）；null = 不是 AI 建议。
  /// 只作标注：AI 置信度没到自动采用门槛才会走到人工确认，选哪条仍由用户定。
  final String? aiSuggestion;

  /// AI 置信度（0..100），只用来画色块里的小进度条；null = 不画（不编造）。
  final int? aiConfidencePercent;

  /// 在分段列表里的位置与组内总数；任一为 null = 独立卡片。
  final int? groupIndex;
  final int? groupCount;

  /// 「TMDB · 65733 · 2005 · ドラえもん」——同名作品全靠这行区分，
  /// 所以 provider、外部 id、年份、原名一个都不能省。
  static String describe(VideoSourceScrapeConfirmationCandidate candidate) {
    final String? original = candidate.work.originalTitle;
    return <String>[
      if (candidate.lookup.provider == VideoMetadataProviderKind.tmdb)
        candidate.lookup.mediaKind == VideoMetadataMediaKind.movie
            ? t.video_source_scrape_manual_tmdb_movie
            : t.video_source_scrape_manual_tmdb_tv
      else
        candidate.lookup.provider.name.toUpperCase(),
      candidate.lookup.externalId,
      if (candidate.work.year != null) '${candidate.work.year}',
      if (original != null && original != candidate.work.title) original,
    ].join(' · ');
  }

  /// 候选自带的封面图（资料源搜索结果里有就用，没有返回 null 走占位）。
  static String? coverUrlOf(VideoSourceScrapeConfirmationCandidate candidate) {
    for (final VideoMetadataImage image in candidate.work.images) {
      if (image.kind == VideoMetadataImageKind.cover &&
          image.url.trim().isNotEmpty) {
        return image.url.trim();
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Key key = ValueKey<String>(
      'video-source-candidate-${candidate.lookup.provider.name}-'
      '${candidate.lookup.mediaKind.name}-${candidate.lookup.externalId}',
    );
    final Widget body = Padding(
      padding: const EdgeInsets.all(12),
      child: _buildBody(context),
    );
    void select() => onSelected(candidate);
    final int? index = groupIndex;
    final int? count = groupCount;
    if (index != null && count != null) {
      return FushiGroupedListItem(
        key: key,
        index: index,
        count: count,
        onTap: select,
        child: body,
      );
    }
    return FushiCard(
      key: key,
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(vertical: 4),
      onTap: select,
      child: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiTypography type = context.fushiType;
    final int? year = candidate.work.year;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _CandidateCover(url: coverUrlOf(candidate)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                candidate.work.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.titleMediumEmphasized,
              ),
              const SizedBox(height: 2),
              Text(
                describe(candidate),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  FushiTag(
                    dense: true,
                    tone: FushiTagTone.accent,
                    icon: FushiIcons.cloud,
                    text: videoMetadataProviderLabel(candidate.lookup.provider),
                  ),
                  if (year != null)
                    FushiTag(
                      dense: true,
                      tone: FushiTagTone.neutral,
                      icon: FushiIcons.calendar,
                      text: '$year',
                    ),
                ],
              ),
              if (aiSuggestion case final String suggestion) ...<Widget>[
                const SizedBox(height: 10),
                _AiSuggestionBlock(
                  text: suggestion,
                  percent: aiConfidencePercent,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 28),
          child: FushiIcon(FushiIcons.chevronRight, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 封面框：有图显示（加载失败回落占位），无图是 surfaceContainerHighest 底 +
/// 视频图标占位；两者同一个 12 圆角框，列表对齐不跳。
class _CandidateCover extends StatelessWidget {
  const _CandidateCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final String? url = this.url;
    return SizedBox(
      width: _kCandidateCoverWidth,
      height: _kCandidateCoverHeight,
      child: ClipRRect(
        borderRadius: FushiM3eShape.smallRadius,
        child: url == null
            ? const _CandidateCoverPlaceholder()
            : Image(
                image: AppHttpImage(url),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const _CandidateCoverPlaceholder(),
              ),
      ),
    );
  }
}

class _CandidateCoverPlaceholder extends StatelessWidget {
  const _CandidateCoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: FushiDesignTokens.of(context).surfaces.overlay,
      child: Center(
        child: FushiIcon(
          FushiIcons.video,
          size: 24,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// AI 建议色块：tertiary container 底 + AI 图标 + 建议文案（含理由），有置信度
/// 时底部一条小进度条。只作标注，不改变点按语义。
class _AiSuggestionBlock extends StatelessWidget {
  const _AiSuggestionBlock({required this.text, required this.percent});

  final String text;
  final int? percent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiCardColors colors =
        fushiCardToneColors(context, FushiCardTone.tertiary) ??
            FushiCardColors(
              container: FushiDesignTokens.of(context).surfaces.overlay,
              onContainer: cs.onSurface,
            );
    final int? percent = this.percent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.container,
        borderRadius: FushiM3eShape.smallRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiIcon(FushiIcons.ai, size: 18, color: colors.onContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodySmall.copyWith(
                      color: colors.onContainer,
                    ),
                  ),
                ),
              ],
            ),
            if (percent != null) ...<Widget>[
              const SizedBox(height: 8),
              FushiLinearProgressIndicator(
                value: (percent / 100).clamp(0.0, 1.0),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 资料源候选作品行。批次内确认与事后手动指定共用同一份呈现与点击语义，
/// 避免「选一个作品」这件事在两处各长一套 UI 而慢慢漂开。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/utils.dart';

class VideoSourceScrapeCandidateTile extends StatelessWidget {
  const VideoSourceScrapeCandidateTile({
    required this.candidate,
    required this.onSelected,
    this.aiSuggestion,
    super.key,
  });

  final VideoSourceScrapeConfirmationCandidate candidate;
  final ValueChanged<VideoSourceScrapeConfirmationCandidate> onSelected;

  /// AI 倾向于这一条时的说明（「AI 建议 · 60%」+ 理由）；null = 不是 AI 建议。
  /// 只作标注：AI 置信度没到自动采用门槛才会走到人工确认，选哪条仍由用户定。
  final String? aiSuggestion;

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

  @override
  Widget build(BuildContext context) => FushiListItem(
        key: ValueKey<String>(
          'video-source-candidate-${candidate.lookup.provider.name}-'
          '${candidate.lookup.mediaKind.name}-${candidate.lookup.externalId}',
        ),
        padding: EdgeInsets.zero,
        leading: aiSuggestion == null
            ? null
            : FushiIcon(
                Icons.auto_awesome,
                color: Theme.of(context).colorScheme.primary,
              ),
        title: Text(candidate.work.title),
        subtitle: Text(
          aiSuggestion == null
              ? describe(candidate)
              : '${describe(candidate)}\n$aiSuggestion',
        ),
        subtitleMaxLines: aiSuggestion == null ? 2 : 5,
        trailing: const FushiIcon(Icons.chevron_right),
        onTap: () => onSelected(candidate),
      );
}

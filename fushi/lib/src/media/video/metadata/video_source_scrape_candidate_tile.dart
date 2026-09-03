/// 资料源候选作品行。批次内确认与事后手动指定共用同一份呈现与点击语义，
/// 避免「选一个作品」这件事在两处各长一套 UI 而慢慢漂开。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/utils.dart';

class VideoSourceScrapeCandidateTile extends StatelessWidget {
  const VideoSourceScrapeCandidateTile({
    required this.candidate,
    required this.onSelected,
    super.key,
  });

  final VideoSourceScrapeConfirmationCandidate candidate;
  final ValueChanged<VideoSourceScrapeConfirmationCandidate> onSelected;

  /// 「TMDB · 65733 · 2005 · ドラえもん」——同名作品全靠这行区分，
  /// 所以 provider、外部 id、年份、原名一个都不能省。
  static String describe(VideoSourceScrapeConfirmationCandidate candidate) {
    final String? original = candidate.work.originalTitle;
    return <String>[
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
          '${candidate.lookup.externalId}',
        ),
        padding: EdgeInsets.zero,
        title: Text(candidate.work.title),
        subtitle: Text(describe(candidate)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onSelected(candidate),
      );
}

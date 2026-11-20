import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';

/// 作品页「本作下载队列」横幅（拍板台 7LwxAtJ6r0）：这本书有未结束的下载任务
/// （排队 / 下载中 / 暂停）时，在章节列表上方就地显示进度与整批动作——暂停全部、
/// 继续全部、取消全部，以及（浏览模块可达时）跳到下载中心只看本作的任务。
///
/// 之前队列只在浏览页的下载中心里，作品页只有「下载全部」，用户看不到也停不下
/// 已经排进去的章。纯展示：任务真相是 [MangaDownloadService] 的任务表，动作全部
/// 由宿主委托给服务。
class MangaSeriesDownloadBanner extends StatelessWidget {
  const MangaSeriesDownloadBanner({
    required this.jobs,
    required this.onPauseAll,
    required this.onResumeAll,
    required this.onCancelAll,
    super.key,
    this.onOpenTasks,
  });

  /// 这本书的任务行（任意状态；已结束的不计入）。
  final Iterable<MangaDownloadJobRow> jobs;
  final VoidCallback onPauseAll;
  final VoidCallback onResumeAll;
  final VoidCallback onCancelAll;

  /// 跳到下载中心（只看本作）；null = 不可达（浏览模块关着 / iOS 无下载中心），
  /// 不出现按钮——横幅本身照常显示，暂停 / 取消不依赖下载中心。
  final VoidCallback? onOpenTasks;

  /// 有没有需要横幅的任务（排队 / 下载中 / 暂停）。
  static bool shows(Iterable<MangaDownloadJobRow> jobs) => jobs.any(
    (MangaDownloadJobRow job) => isMangaDownloadJobUnfinished(job.status),
  );

  /// 未结束任务的整体页进度；页数都还不知道 = null（不定进度）。
  static double? progressOf(Iterable<MangaDownloadJobRow> jobs) {
    int done = 0;
    int total = 0;
    for (final MangaDownloadJobRow job in jobs) {
      if (!isMangaDownloadJobUnfinished(job.status)) continue;
      done += job.pagesDone;
      total += job.pagesTotal;
    }
    if (total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    MangaDownloadJobRow? running;
    int queued = 0;
    int paused = 0;
    for (final MangaDownloadJobRow job in jobs) {
      switch (job.status) {
        case MangaDownloadJobStatus.running:
          running = job;
        case MangaDownloadJobStatus.queued:
          queued++;
        case MangaDownloadJobStatus.paused:
          paused++;
      }
    }
    final bool inFlight = running != null || queued > 0;
    final List<String> lines = <String>[
      if (running != null)
        '${running.chapterTitle} · '
            '${t.manga_chapter_download_status_downloading(done: '${running.pagesDone}', total: '${running.pagesTotal}')}',
      if (queued > 0) t.manga_series_download_queued_count(count: queued),
      if (paused > 0) t.manga_series_download_paused_count(count: paused),
    ];
    final double? progress = progressOf(jobs);
    final VoidCallback? openTasks = onOpenTasks;
    return FushiCard(
      key: const ValueKey<String>('manga_series_download_banner'),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  lines.join(' · '),
                  key: const ValueKey<String>('manga_series_download_summary'),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                // 全部暂停时停在当前比例，不画不定进度的流动条（那表示「在动」）。
                FushiLinearProgressIndicator(
                  value: inFlight ? progress : (progress ?? 0),
                ),
              ],
            ),
          ),
          if (inFlight)
            FushiIconButtonControl(
              key: const ValueKey<String>('manga_series_download_pause_all'),
              tooltip: t.download_pause_all,
              onPressed: onPauseAll,
              icon: const FushiIcon(FushiIcons.pause),
            ),
          if (paused > 0)
            FushiIconButtonControl(
              key: const ValueKey<String>('manga_series_download_resume_all'),
              tooltip: t.download_resume_all,
              onPressed: onResumeAll,
              icon: const FushiIcon(FushiIcons.play),
            ),
          FushiIconButtonControl(
            key: const ValueKey<String>('manga_series_download_cancel_all'),
            tooltip: t.manga_series_download_cancel_all,
            onPressed: onCancelAll,
            icon: const FushiIcon(FushiIcons.close),
          ),
          if (openTasks != null)
            FushiIconButtonControl(
              key: const ValueKey<String>('manga_series_download_open_tasks'),
              tooltip: t.manga_series_download_open_tasks,
              onPressed: openTasks,
              icon: const FushiIcon(FushiIcons.openInNew),
            ),
        ],
      ),
    );
  }
}

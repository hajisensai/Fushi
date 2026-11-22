import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/audiobook/audiobook_transcribe_tasks_section.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/downloads/download_task_share.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart'
    show animeDownloadTaskSnapshot;
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart'
    show videoDownloadJobTaskEntry;
import 'package:fushi/src/sync/interconnect_download_manager.dart'
    show interconnectDownloadManagerProvider;
import 'package:fushi_core/fushi_core.dart' show VideoDownloadJobRow;
import 'package:material_ui/material_ui.dart';

/// 下载页「任务」列表里，持久视频任务（`VideoDownloadJobsPanel` 自己读的那张表）
/// 之外的全部任务来源，按页面嵌套顺序（外 → 内）。
///
/// 唯一清单：下载页（`BrowsePage._buildTasks` 经 [nestDownloadTaskSources] 逐个
/// 套上各来源段）与侧栏下载速览（[loadDownloadTaskSnapshot]）都按它枚举，两边都
/// 是穷尽 switch——新加一个来源，两处不接上就编不过，速览不会再漏掉页面上有的任务。
enum DownloadTaskSource {
  transcribe,
  legacy,
  direct,
  manga,
  remote,
  interconnect,
}

/// 一个来源段：把本来源此刻的条目交给 [tasks]（下游）混进统一列表。
typedef DownloadTaskSourceWrapper =
    Widget Function(DownloadTaskSource source, DownloadTasksBuilder tasks);

/// 按 [DownloadTaskSource] 清单把各来源段一层套一层，最内层 [leaf] 收到全部来源
/// 的条目（按清单顺序拼接）。
Widget nestDownloadTaskSources({
  required DownloadTaskSourceWrapper wrap,
  required DownloadTasksBuilder leaf,
}) {
  const List<DownloadTaskSource> sources = DownloadTaskSource.values;
  Widget level(BuildContext context, int i, List<DownloadTaskEntry> acc) {
    if (i == sources.length) return leaf(context, acc);
    return wrap(
      sources[i],
      (BuildContext context, List<DownloadTaskEntry> tasks) =>
          level(context, i + 1, <DownloadTaskEntry>[...acc, ...tasks]),
    );
  }

  return Builder(
    builder: (BuildContext context) =>
        level(context, 0, const <DownloadTaskEntry>[]),
  );
}

/// 把持久视频任务与清单上每个来源的条目合成一份，按 id 去重（与
/// `VideoDownloadJobsPanel` 统一列表同一口径：先放来源条目，视频任务同 id 覆盖）。
/// [source] 对清单上每一项各调一次。
Future<List<DownloadTaskEntry>> collectDownloadTaskSnapshot({
  required FutureOr<List<DownloadTaskEntry>> Function() videoJobs,
  required FutureOr<List<DownloadTaskEntry>> Function(DownloadTaskSource source)
  source,
}) async {
  final Map<String, DownloadTaskEntry> entries = <String, DownloadTaskEntry>{};
  for (final DownloadTaskSource s in DownloadTaskSource.values) {
    for (final DownloadTaskEntry task in await source(s)) {
      entries[task.id] = task;
    }
  }
  for (final DownloadTaskEntry task in await videoJobs()) {
    entries[task.id] = task;
  }
  return entries.values.toList();
}

/// 侧栏下载速览的数据：与下载页同一份来源清单、同一份逐来源映射，只读此刻的
/// 本地状态，悬停一次不打网络、不扫盘：
///
/// * 视频任务读任务表；后端实时观测（暂停 / 排队、速率）不在悬停时去问，进行中
///   的任务按持久生命周期算作「下载中」。
/// * 远端 host 的代下载任务与「可重新入库」的漫画只由下载页去取，这里读下载页
///   最近一次的结果（[DownloadTaskShare]；下载页还没打开过时这两部分为空）。
///
/// 条目只用于展示字段：速览不调 builder、不挂动作。
Future<List<DownloadTaskEntry>> loadDownloadTaskSnapshot({
  required AppModel appModel,
  required WidgetRef ref,
}) => collectDownloadTaskSnapshot(
  videoJobs: () async => <DownloadTaskEntry>[
    for (final VideoDownloadJobRow job
        in await appModel.database.getVideoDownloadJobs())
      videoDownloadJobTaskEntry(job, builder: _summaryOnlyTaskCard),
  ],
  source: (DownloadTaskSource source) => switch (source) {
    DownloadTaskSource.transcribe =>
      switch (AudiobookTranscribeTasksSection.appQueue(appModel)) {
        null => const <DownloadTaskEntry>[],
        final queue => AudiobookTranscribeTasksSection.entriesOf(queue),
      },
    DownloadTaskSource.legacy => animeDownloadTaskSnapshot(appModel),
    DownloadTaskSource.direct => switch (DiscoveryDownloadTasksSection.appQueue(
      appModel,
    )) {
      null => const <DownloadTaskEntry>[],
      final queue => const DiscoveryDownloadTasksSection().entriesOf(
        queue,
        external: DiscoveryDownloadTasksSection.externalSourceResolver(
          appModel,
        ),
      ),
    },
    DownloadTaskSource.manga => mangaDownloadTaskSnapshot(
      MangaDownloadTaskSources.ofApp(appModel),
    ),
    DownloadTaskSource.remote => DownloadTaskShare.instance.entriesOf(
      DownloadTaskSharedPart.remoteHosts,
    ),
    DownloadTaskSource.interconnect => interconnectDownloadTaskEntries(
      ref,
      ref.read(interconnectDownloadManagerProvider),
    ),
  },
);

Widget _summaryOnlyTaskCard(BuildContext _) => const SizedBox.shrink();

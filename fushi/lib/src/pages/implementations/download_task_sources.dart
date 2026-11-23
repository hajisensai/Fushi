import 'dart:async';

import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:material_ui/material_ui.dart';

/// 本文件是叶子：只放来源清单与两个与来源无关的组合器，不 import 各来源段 /
/// AppModel。按清单取各来源条目的 `loadDownloadTaskSnapshot` 住在侧栏速览
/// （`home_nav_peek.dart`），套各来源段的 switch 住在下载页（`browse_page.dart`）——
/// 两处都对 [DownloadTaskSource] 穷尽 switch，新加来源不接就编不过。

/// 下载页「任务」列表里，持久视频任务（`VideoDownloadJobsPanel` 自己读的那张表）
/// 之外的全部任务来源，按页面嵌套顺序（外 → 内）。
///
/// 唯一清单：下载页（`BrowsePage._buildTasks` 经 [nestDownloadTaskSources] 逐个
/// 套上各来源段）与侧栏下载速览（`loadDownloadTaskSnapshot`）都按它枚举，两边都
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

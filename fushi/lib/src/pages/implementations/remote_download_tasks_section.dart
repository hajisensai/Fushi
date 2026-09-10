/// 下载中心「任务」tab 里的互联 host 代下载任务段（设计 §3.3）。
///
/// 与 `DiscoveryDownloadTasksSection` / `MokuroMoeTasksSection` 同一链式注入形状：
/// 探测第一台宣告 downloads 能力的已配对 host，把它的 `/api/downloads` 任务映射成
/// [DownloadTaskEntry] 交给下游 `tasksBuilder` 混进统一列表。没有 host 就是空段，
/// 页面零变化。列表按固定周期轮询（远端没有 watch 流）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

class RemoteDownloadTasksSection extends ConsumerStatefulWidget {
  const RemoteDownloadTasksSection({
    required this.tasksBuilder,
    this.clientOverride,
    this.pollInterval = const Duration(seconds: 5),
    super.key,
  });

  final DownloadTasksBuilder tasksBuilder;
  final InterconnectDownloadClient? clientOverride;
  final Duration pollInterval;

  @override
  ConsumerState<RemoteDownloadTasksSection> createState() =>
      _RemoteDownloadTasksSectionState();
}

class _RemoteDownloadTasksSectionState
    extends ConsumerState<RemoteDownloadTasksSection> {
  InterconnectDownloadClient? _client;
  HostDownloadTarget? _target;
  List<HostDownloadJob> _jobs = const <HostDownloadJob>[];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    final AppModel appModel = ref.read(appProvider);
    final InterconnectDownloadClient client = widget.clientOverride ??
        InterconnectDownloadClient(repo: SyncRepository(appModel.database));
    _client = client;
    HostDownloadTarget? target;
    try {
      target = await client.probe();
    } catch (_) {
      target = null;
    }
    if (!mounted) return;
    setState(() => _target = target);
    if (target != null) {
      await _refresh();
      _timer = Timer.periodic(widget.pollInterval, (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    final InterconnectDownloadClient? client = _client;
    final HostDownloadTarget? target = _target;
    if (client == null || target == null) return;
    try {
      final List<HostDownloadJob> jobs = await client.listJobs(target);
      if (!mounted) return;
      setState(() => _jobs = jobs);
    } catch (_) {
      // 一次轮询失败不清列表，下一轮再试。
    }
  }

  Future<void> _action(Future<void> Function() run) async {
    try {
      await run();
    } catch (error) {
      if (!mounted) return;
      FushiToast.show(
        msg: t.download_task_action_failed(error: '$error'),
        severity: ToastSeverity.error,
      );
    }
    await _refresh();
  }

  DownloadTaskEntry _entry(HostDownloadTarget target, HostDownloadJob job) {
    final InterconnectDownloadClient client = _client!;
    final DownloadTaskStatus status = switch (job.lifecycle) {
      VideoDownloadJobLifecycle.active => DownloadTaskStatus.active,
      VideoDownloadJobLifecycle.needsAttention => DownloadTaskStatus.attention,
      VideoDownloadJobLifecycle.completed => DownloadTaskStatus.completed,
      VideoDownloadJobLifecycle.failed => DownloadTaskStatus.attention,
      VideoDownloadJobLifecycle.cancelled => DownloadTaskStatus.cancelled,
      _ => DownloadTaskStatus.queued,
    };
    final bool finished =
        job.lifecycle == VideoDownloadJobLifecycle.completed ||
            job.lifecycle == VideoDownloadJobLifecycle.cancelled ||
            job.lifecycle == VideoDownloadJobLifecycle.failed;
    return DownloadTaskEntry(
      id: 'remote:${target.baseUrl}:${job.jobId}',
      title: job.title,
      kind: DownloadTaskKind.video,
      status: status,
      createdAt: job.updatedAt,
      progress: job.stageProgress,
      collectionKey: 'remote:${target.baseUrl}',
      collectionTitle: t.download_remote_jobs_title(device: target.label),
      searchTerms: <String>[job.title, target.label],
      // develop 把裸回调收敛成了 [DownloadTaskActions] 槽位；远端三个动作按语义
      // 各就各位，不再把「中止」和「删除」挤进同一个 onClear。
      //
      // `deletesFiles: true` 是如实声明而非乐观假设：远端 DELETE
      // /api/downloads/<id> 落到 `download_host.dart` 的
      // `deleteJob(jobId, deleteFiles: true)`，**恒删磁盘文件且无法关闭**——
      // 协议上没有「只移出列表」这一路。所以它进 [delete] 槽而不是 [clear]
      // （放 clear 会让用户以为远端文件还在），且 deleteFiles 传 false 时也照删，
      // 这一点由 deletesFiles 如实告知 UI。
      actions: DownloadTaskActions(
        retry: job.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
                job.lifecycle == VideoDownloadJobLifecycle.failed
            ? () => _action(() => client.retry(target, job.jobId))
            : null,
        cancel: finished
            ? null
            : () => _action(() => client.cancel(target, job.jobId)),
        delete: finished
            ? ({required bool deleteFiles}) =>
                _action(() => client.delete(target, job.jobId))
            : null,
        deletesFiles: true,
      ),
      // 与本地任务同一张卡（DownloadTaskCard），不再另开 ListTile 决策。
      builder: (BuildContext context) => DownloadTaskCard(
        key: ValueKey<String>('remote:${target.baseUrl}:${job.jobId}'),
        taskId: 'remote:${target.baseUrl}:${job.jobId}',
        title: job.title,
        status: '${job.stage} · ${(job.stageProgress * 100).toStringAsFixed(0)}%',
        subtitle: target.label,
        progress: job.stageProgress,
        leading: const Icon(Icons.cloud_download_outlined),
        details: _details(context, target, job),
      ),
    );
  }

  Widget _details(
    BuildContext context,
    HostDownloadTarget target,
    HostDownloadJob job,
  ) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('${target.label} · ${target.baseUrl}', style: text.bodySmall),
        if (job.lastError != null)
          Text(
            job.lastError!,
            style: text.bodySmall?.copyWith(color: scheme.error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final HostDownloadTarget? target = _target;
    final List<DownloadTaskEntry> entries = target == null
        ? const <DownloadTaskEntry>[]
        : <DownloadTaskEntry>[
            for (final HostDownloadJob job in _jobs) _entry(target, job),
          ];
    return widget.tasksBuilder(context, entries);
  }
}

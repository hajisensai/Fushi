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
      onRetry: job.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
              job.lifecycle == VideoDownloadJobLifecycle.failed
          ? () => _action(() => client.retry(target, job.jobId))
          : null,
      onClear: finished
          ? () => _action(() => client.delete(target, job.jobId))
          : () => _action(() => client.cancel(target, job.jobId)),
      builder: (BuildContext context) => ListTile(
        dense: true,
        leading: const Icon(Icons.cloud_download_outlined),
        title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${target.label} · ${job.stage} · '
          '${(job.stageProgress * 100).toStringAsFixed(0)}%'
          '${job.lastError == null ? '' : ' · ${job.lastError}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
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

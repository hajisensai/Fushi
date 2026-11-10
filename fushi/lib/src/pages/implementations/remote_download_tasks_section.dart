/// 下载中心「任务」tab 里的互联 host 代下载任务段（设计 §3.3）。
///
/// 与 `DiscoveryDownloadTasksSection` / `MangaDownloadTasksSection` 同一链式注入形状：
/// 探测**每一台**已配对 host 的 downloads 能力，把各自 `/api/downloads` 的任务映射成
/// [DownloadTaskEntry] 交给下游 `tasksBuilder` 混进统一列表；没有已配对 host 就是
/// 空段，页面零变化。列表按固定周期轮询（远端没有 watch 流）。
///
/// 状态按 host 维护（BUG-R6）：轮询失败保留上次的任务并标「过期」；探不到 / 凭据
/// 失效的 host 产出一条 attention 条目说明原因（可点重试）；连不上的 host 每拍重探、
/// 永久性失败只在用户点重试时重探；同一台 host 上一拍的请求没回来时本拍不叠加。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_host_failure_text.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';

class RemoteDownloadTasksSection extends ConsumerStatefulWidget {
  const RemoteDownloadTasksSection({
    required this.tasksBuilder,
    this.clientOverride,
    this.pollInterval = const Duration(seconds: 5),
    super.key,
  });

  final DownloadTasksBuilder tasksBuilder;

  /// 外部持有的 client（测试缝）：本段不关它。
  final InterconnectDownloadClient? clientOverride;
  final Duration pollInterval;

  @override
  ConsumerState<RemoteDownloadTasksSection> createState() =>
      _RemoteDownloadTasksSectionState();
}

/// 一台 host 在本段里的状态。
class _RemoteHostState {
  _RemoteHostState(this.outcome);

  InterconnectCapabilityOutcome<HostDownloadTarget> outcome;

  /// 最近一次成功取到的任务；之后的轮询失败不清它（[stale] 标识）。
  List<HostDownloadJob> jobs = const <HostDownloadJob>[];

  /// 最近一次轮询失败，[jobs] 是上次取到的进度。
  bool stale = false;

  /// 这台 host 有请求在途：轮询本拍跳过，不叠加。
  bool inFlight = false;

  InterconnectHostRef get host => outcome.host;
}

/// 下一拍还值得自动重探的失败：连不上 / host 回了错误码，过一会儿可能就好；
/// 凭据 / 证书 / 未配对 / 不支持换时间也不会好，只在用户点重试时重探。
bool _transientProbeFailure(InterconnectHostFailure failure) =>
    switch (failure) {
      InterconnectHostFailure.unreachable ||
      InterconnectHostFailure.httpError => true,
      InterconnectHostFailure.notPaired ||
      InterconnectHostFailure.authRejected ||
      InterconnectHostFailure.certificateMismatch ||
      InterconnectHostFailure.unsupported => false,
    };

/// listJobs 的错误码 → 应降级成的探测失败（null = 瞬时失败，保留任务标过期）。
InterconnectHostFailure? _permanentListFailure(String code) => switch (code) {
  'auth_rejected' => InterconnectHostFailure.authRejected,
  'certificate_mismatch' => InterconnectHostFailure.certificateMismatch,
  'no_host' => InterconnectHostFailure.notPaired,
  _ => null,
};

/// host 任务的内容域（`HostDownloadJob.discoveryKind`）→ 任务种类；null = 视频。
DownloadTaskKind _taskKindOf(String? discoveryKind) => discoveryKind == null
    ? DownloadTaskKind.video
    : DownloadTaskKind.values.asNameMap()[discoveryKind] ??
          DownloadTaskKind.video;

class _RemoteDownloadTasksSectionState
    extends ConsumerState<RemoteDownloadTasksSection> {
  late final InterconnectDownloadClient _client;

  /// hostRef.key → 状态；顺序 = 「下载执行设备」那台在前，其余按配对清单组序。
  final Map<String, _RemoteHostState> _hosts = <String, _RemoteHostState>{};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _client =
        widget.clientOverride ??
        InterconnectDownloadClient(
          repo: SyncRepository(ref.read(appProvider).database),
        );
    unawaited(_probe());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.clientOverride == null) _client.close();
    super.dispose();
  }

  Future<void> _probe() async {
    final AppModel appModel = ref.read(appProvider);
    final List<InterconnectCapabilityOutcome<HostDownloadTarget>> outcomes;
    final List<FushiClientUrl> rows;
    try {
      rows = await SyncRepository(appModel.database).getFushiClientUrls();
      outcomes = await _client.probeAllOutcomes();
    } on InterconnectChannelException catch (e) {
      if (e.kind == InterconnectChannelFailure.cancelled) return;
      rethrow;
    }
    if (!mounted) return;
    final String preferredUrl = appModel.prefsRepo.downloadExecutionHostUrl;
    final InterconnectHostRef? preferred = preferredUrl.isEmpty
        ? null
        : interconnectHostRefForUrl(rows, preferredUrl);
    final List<InterconnectCapabilityOutcome<HostDownloadTarget>> ordered =
        <InterconnectCapabilityOutcome<HostDownloadTarget>>[
          ...outcomes.where(
            (InterconnectCapabilityOutcome<HostDownloadTarget> o) =>
                o.host == preferred,
          ),
          ...outcomes.where(
            (InterconnectCapabilityOutcome<HostDownloadTarget> o) =>
                o.host != preferred,
          ),
        ];
    setState(() {
      for (final InterconnectCapabilityOutcome<HostDownloadTarget> o
          in ordered) {
        _hosts[o.host.key] = _RemoteHostState(o);
      }
    });
    if (_hosts.isEmpty) return;
    _tick();
    _timer = Timer.periodic(widget.pollInterval, (_) => _tick());
  }

  /// 一拍：可用的 host 拉任务，瞬时失败的 host 重探；在途的跳过。
  void _tick() {
    for (final _RemoteHostState s in _hosts.values) {
      if (s.inFlight) continue;
      final InterconnectCapabilityOutcome<HostDownloadTarget> o = s.outcome;
      if (o is InterconnectCapabilityAvailable<HostDownloadTarget>) {
        unawaited(_refresh(s));
      } else if (o is InterconnectCapabilityUnavailable<HostDownloadTarget> &&
          _transientProbeFailure(o.failure)) {
        unawaited(_reprobe(s));
      }
    }
  }

  Future<void> _refresh(_RemoteHostState s) async {
    final InterconnectCapabilityOutcome<HostDownloadTarget> o = s.outcome;
    if (o is! InterconnectCapabilityAvailable<HostDownloadTarget>) return;
    s.inFlight = true;
    try {
      final List<HostDownloadJob> jobs = await _client.listJobs(o.target);
      if (!mounted) return;
      setState(() {
        s.jobs = jobs;
        s.stale = false;
      });
    } on HostDownloadException catch (e) {
      // dispose 之后在途请求被取消：不是失败，什么都不做。
      if (e.code == 'cancelled' || !mounted) return;
      final InterconnectHostFailure? permanent = _permanentListFailure(e.code);
      setState(() {
        if (permanent == null) {
          s.stale = true;
        } else {
          s.outcome = InterconnectCapabilityUnavailable<HostDownloadTarget>(
            host: o.host,
            label: o.label,
            failure: permanent,
          );
          s.jobs = const <HostDownloadJob>[];
          s.stale = false;
        }
      });
    } finally {
      s.inFlight = false;
    }
  }

  /// 重探这台 host 的能力；恢复可用就立刻拉一次任务。
  Future<void> _reprobe(_RemoteHostState s) async {
    s.inFlight = true;
    final InterconnectCapabilityOutcome<HostDownloadTarget> outcome;
    try {
      outcome = await _client.probeHost(s.host);
    } on InterconnectChannelException catch (e) {
      s.inFlight = false;
      if (e.kind == InterconnectChannelFailure.cancelled) return;
      rethrow;
    }
    s.inFlight = false;
    if (!mounted) return;
    setState(() => s.outcome = outcome);
    if (outcome is InterconnectCapabilityAvailable<HostDownloadTarget>) {
      await _refresh(s);
    }
  }

  /// 用户点「重试」：在途就交给那次请求，否则立刻重探。
  Future<void> _retryHost(String key) async {
    final _RemoteHostState? s = _hosts[key];
    if (s == null || s.inFlight) return;
    await _reprobe(s);
  }

  Future<void> _action(_RemoteHostState s, Future<void> Function() run) async {
    try {
      await run();
    } catch (error) {
      if (!mounted) return;
      FushiToast.show(
        msg: t.download_task_action_failed(error: '$error'),
        severity: ToastSeverity.error,
      );
    }
    if (!mounted || s.inFlight) return;
    await _refresh(s);
  }

  DownloadTaskEntry _entry(
    _RemoteHostState s,
    HostDownloadTarget target,
    HostDownloadJob job,
  ) {
    final InterconnectDownloadClient client = _client;
    final String hostKey = s.host.key;
    final String taskId = 'remote:$hostKey:${job.jobId}';
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
    final bool stale = s.stale;
    return DownloadTaskEntry(
      id: taskId,
      title: job.title,
      kind: _taskKindOf(job.discoveryKind),
      status: status,
      createdAt: job.createdAt,
      progress: job.stageProgress,
      collectionKey: 'remote:$hostKey',
      collectionTitle: t.download_remote_jobs_title(device: target.label),
      searchTerms: <String>[job.title, target.label],
      // develop 把裸回调收敛成了 [DownloadTaskActions] 槽位；远端三个动作按语义
      // 各就各位，不再把「中止」和「删除」挤进同一个 onClear。
      //
      // 删除与「同时删除已下载文件」（BUG-3437）：host 宣告 `deleteFilesParam` 时把
      // 勾选结果原样带给 `DELETE /api/downloads/<id>?deleteFiles=`，勾选框按字面
      // 生效。老 host 不认这个参数、删不删由它的历史缺省决定（app 当 host 保留，
      // 无头服务端连数据一起删，客户端分不出是哪种），所以不摆勾选框
      // （deletesFiles: false），改在卡片详情里如实提示。
      actions: DownloadTaskActions(
        retry:
            job.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
                job.lifecycle == VideoDownloadJobLifecycle.failed
            ? () => _action(s, () => client.retry(target, job.jobId))
            : null,
        cancel: finished
            ? null
            : () => _action(s, () => client.cancel(target, job.jobId)),
        delete: finished
            ? ({required bool deleteFiles}) => _action(
                s,
                () => client.delete(
                  target,
                  job.jobId,
                  deleteFiles: target.deleteFilesParam ? deleteFiles : null,
                ),
              )
            : null,
        deletesFiles: target.deleteFilesParam,
      ),
      // 与本地任务同一张卡（DownloadTaskCard），不再另开 ListTile 决策。
      builder: (BuildContext context) => DownloadTaskCard(
        key: ValueKey<String>(taskId),
        taskId: taskId,
        // host 代下载跑的是它自己的下载管线：BT（host_download_routes 只收磁链）。
        method: DownloadTransferMethod.torrent,
        externalSource: true,
        title: job.title,
        status:
            '${job.stage} · ${(job.stageProgress * 100).toStringAsFixed(0)}%',
        subtitle: target.label,
        progress: job.stageProgress,
        leading: const FushiIcon(Icons.cloud_download_outlined),
        // 过期标识放常显的 summary：详情默认收起，放那里用户看不到。
        summary: stale
            ? Text(
                t.download_remote_jobs_stale,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              )
            : null,
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
        if (!target.deleteFilesParam)
          Text(
            t.download_remote_delete_files_host_default,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
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

  /// 探不到 / 失效的 host：一条 attention 条目说出原因，点重试重探。
  DownloadTaskEntry _unavailableEntry(
    InterconnectCapabilityUnavailable<HostDownloadTarget> o,
  ) {
    final String hostKey = o.host.key;
    final String taskId = 'remote:$hostKey';
    final String reason = interconnectHostFailureText(
      o.failure,
      statusCode: o.statusCode,
    );
    return DownloadTaskEntry(
      id: taskId,
      title: o.label,
      kind: DownloadTaskKind.video,
      status: DownloadTaskStatus.attention,
      collectionKey: 'remote:$hostKey',
      collectionTitle: t.download_remote_jobs_title(device: o.label),
      searchTerms: <String>[o.label],
      actions: DownloadTaskActions(retry: () => _retryHost(hostKey)),
      builder: (BuildContext context) {
        final TextTheme text = Theme.of(context).textTheme;
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return DownloadTaskCard(
          key: ValueKey<String>(taskId),
          taskId: taskId,
          externalSource: true,
          title: o.label,
          status: reason,
          leading: const FushiIcon(FushiIcons.cloudOff),
          details: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('${o.label} · ${o.host.anchorUrl}', style: text.bodySmall),
              Text(
                reason,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DownloadTaskEntry> entries = <DownloadTaskEntry>[
      for (final _RemoteHostState s in _hosts.values)
        ...switch (s.outcome) {
          InterconnectCapabilityAvailable<HostDownloadTarget>(
            :final HostDownloadTarget target,
          ) =>
            <DownloadTaskEntry>[
              for (final HostDownloadJob job in s.jobs) _entry(s, target, job),
            ],
          final InterconnectCapabilityUnavailable<HostDownloadTarget> o =>
            <DownloadTaskEntry>[_unavailableEntry(o)],
        },
    ];
    return widget.tasksBuilder(context, entries);
  }
}

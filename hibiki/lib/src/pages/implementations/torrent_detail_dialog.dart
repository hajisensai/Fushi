import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/torrent/torrent_task_display.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/download_actions.dart';
import 'package:hibiki/utils.dart';

/// TODO-2482：下载任务详情对话框（qb/hayase 式四 tab：总览 / 文件 /
/// 节点 / Tracker）。入口 = 下载任务行点击。
///
/// 数据面走 [TorrentDetailBackend] 可选能力接口：`backend is` 探测 +
/// [TorrentDetailBackend.detailAvailable] 运行时能力位双重把关（内置引擎
/// 随包 DLL 过旧时类型探测过了符号也缺）；缺能力的 tab 显示「当前后端
/// 不支持」而不是空白。文件列表是 [TorrentBackend] 基础能力，不受降级
/// 影响；文件优先级下拉只在详情能力可用时出现。
///
/// 轮询：对话框自持一个后端实例（qb = 独立 http 客户端；内置 = 常驻
/// session 的短命视图，close 不连累会话），每 2s 刷当前 tab 需要的数据，
/// 切 tab 立即补一轮 —— 不给不可见的 tab 白拉数据。
class TorrentTaskDetailDialog extends ConsumerStatefulWidget {
  const TorrentTaskDetailDialog({
    required this.plan,
    super.key,
    @visibleForTesting this.backendOverride,
  });

  /// 详情对象（`plan.id` = infohash）。
  final AnimeDownloadPlan plan;

  /// 仅测试用：注入假后端，跳过 AppModel 的真实后端工厂（widget 测试
  /// 不必拉起整个应用模型）。注入的后端由**调用方**负责 close。
  final TorrentBackend? backendOverride;

  @override
  ConsumerState<TorrentTaskDetailDialog> createState() =>
      _TorrentTaskDetailDialogState();
}

class _TorrentTaskDetailDialogState
    extends ConsumerState<TorrentTaskDetailDialog>
    with SingleTickerProviderStateMixin {
  static const Duration _pollInterval = Duration(seconds: 2);

  late final TabController _tabController;
  TorrentBackend? _backend;

  /// 详情能力：类型探测 + 运行时能力位（见类 doc）。
  bool _detailCapable = false;

  /// 后端是否归本状态所有（注入的测试后端不 close）。
  bool _ownsBackend = true;
  Timer? _timer;
  bool _refreshing = false;

  /// 首轮快照是否已返回（区分「还在加载」与「后端里已没有该任务」）。
  bool _snapshotLoaded = false;
  TorrentSnapshot? _snapshot;
  TorrentSessionStatusInfo? _sessionStatus;
  TorrentPieceStates? _pieces;
  List<TorrentPeerDetail>? _peers;
  List<TorrentTrackerDetail>? _trackers;
  List<TorrentFileEntry>? _files;
  List<TorrentFilePriority>? _filePriorities;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // 切 tab 立即补一轮该 tab 的数据（等下一个 2s tick 会显得迟钝）。
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        unawaited(_refresh());
      }
    });
    final TorrentBackend? override = widget.backendOverride;
    if (override != null) {
      _backend = override;
      _ownsBackend = false;
      _detailCapable =
          override is TorrentDetailBackend && override.detailAvailable;
    } else {
      final AppModel appModel = ref.read(appProvider);
      if (torrentBackendReady(appModel)) {
        final TorrentBackend backend = appModel.createTorrentBackend(
          effectiveTorrentConfig(appModel.qbConnectionConfig),
        );
        _backend = backend;
        _detailCapable =
            backend is TorrentDetailBackend && backend.detailAvailable;
      }
    }
    unawaited(_refresh());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabController.dispose();
    if (_ownsBackend) _backend?.close();
    super.dispose();
  }

  /// 刷一轮：快照恒取（总览/状态行/文件进度都吃它），其余按当前 tab 取。
  Future<void> _refresh() async {
    final TorrentBackend? backend = _backend;
    if (backend == null || _refreshing || !mounted) return;
    _refreshing = true;
    try {
      final String wantedHash = widget.plan.id.toLowerCase();
      final List<TorrentSnapshot> torrents = await backend.listTorrents();
      TorrentSnapshot? snapshot;
      for (final TorrentSnapshot t in torrents) {
        if (t.hash.toLowerCase() == wantedHash) {
          snapshot = t;
          break;
        }
      }
      final TorrentDetailBackend? detail =
          _detailCapable && backend is TorrentDetailBackend ? backend : null;
      TorrentSessionStatusInfo? sessionStatus = _sessionStatus;
      TorrentPieceStates? pieces = _pieces;
      List<TorrentPeerDetail>? peers = _peers;
      List<TorrentTrackerDetail>? trackers = _trackers;
      List<TorrentFileEntry>? files = _files;
      List<TorrentFilePriority>? priorities = _filePriorities;
      switch (_tabController.index) {
        case 0:
          sessionStatus = await detail?.sessionStatus() ?? sessionStatus;
          pieces = await detail?.pieceStates(widget.plan.id) ?? pieces;
        case 1:
          files = await backend.listFiles(widget.plan.id);
          priorities =
              await detail?.filePriorities(widget.plan.id) ?? priorities;
        case 2:
          peers = await detail?.listPeers(widget.plan.id) ?? peers;
        case 3:
          trackers = await detail?.listTrackers(widget.plan.id) ?? trackers;
      }
      if (!mounted) return;
      setState(() {
        _snapshotLoaded = true;
        _snapshot = snapshot;
        _sessionStatus = sessionStatus;
        _pieces = pieces;
        _peers = peers;
        _trackers = trackers;
        _files = files;
        _filePriorities = priorities;
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _changeFilePriority(
    int fileIndex,
    TorrentFilePriority priority,
  ) async {
    final TorrentBackend? backend = _backend;
    if (backend is! TorrentDetailBackend || !_detailCapable) return;
    await backend.setFilePriority(widget.plan.id, fileIndex, priority);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return HibikiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.86,
      scrollable: false,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(widget.plan.seriesTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(
            widget.plan.torrentTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tabController,
            tabs: <Widget>[
              Tab(text: t.download_detail_tab_overview),
              Tab(text: t.download_detail_tab_files),
              Tab(text: t.download_detail_tab_peers),
              Tab(text: t.download_detail_tab_trackers),
            ],
          ),
          Flexible(
            child: TabBarView(
              controller: _tabController,
              children: <Widget>[
                _buildOverviewTab(theme),
                _buildFilesTab(theme),
                _buildPeersTab(theme),
                _buildTrackersTab(theme),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
          ),
        ],
      ),
    );
  }

  /// 缺详情能力时各 tab 的占位（「当前后端不支持」，绝不空白）。
  Widget _buildUnsupported(ThemeData theme) {
    return _buildEmptyNote(theme, t.download_detail_backend_unsupported);
  }

  Widget _buildEmptyNote(ThemeData theme, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// 「标签: 值」一行（总览区的单元）。
  Widget _statRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// 「已连接 (swarm 总量)」合成：`5 (32)`；无数据的段各自省略。
  static String _peerCountText(int connected, int swarm) {
    if (connected < 0 && swarm < 0) return '—';
    final String head = connected >= 0 ? '$connected' : '—';
    return swarm >= 0 ? '$head ($swarm)' : head;
  }

  String _statusLabelFor(TorrentSnapshot snapshot) {
    return switch (torrentDisplayStatusFor(snapshot.state)) {
      TorrentDisplayStatus.downloading => t.download_task_status_downloading,
      TorrentDisplayStatus.seeding => t.download_task_status_seeding,
      TorrentDisplayStatus.completed => t.download_task_status_completed,
      TorrentDisplayStatus.paused => t.download_task_status_paused,
      TorrentDisplayStatus.queued => t.download_task_status_queued,
      TorrentDisplayStatus.stalled => t.download_task_status_stalled,
      TorrentDisplayStatus.checking => t.download_task_status_checking,
      TorrentDisplayStatus.fetchingMetadata => t.download_task_status_metadata,
      TorrentDisplayStatus.moving => t.download_task_status_moving,
      TorrentDisplayStatus.error => t.download_task_status_error,
      TorrentDisplayStatus.unknown => snapshot.state,
    };
  }

  Widget _buildOverviewTab(ThemeData theme) {
    final TorrentSnapshot? snapshot = _snapshot;
    if (snapshot == null) {
      return _snapshotLoaded
          ? _buildEmptyNote(theme, t.download_detail_task_gone)
          : const Center(child: CircularProgressIndicator());
    }
    final String? eta = formatTorrentEta(
      amountLeft: snapshot.amountLeft,
      downRateBps: snapshot.downRateBps,
    );
    final String? ratio = formatShareRatio(
      uploadedBytes: snapshot.uploadedBytes,
      downloadedBytes: snapshot.downloadedBytes,
    );
    final TorrentSessionStatusInfo? session = _sessionStatus;
    final TorrentPieceStates? pieces = _pieces;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: LinearProgressIndicator(
                value: snapshot.progress.clamp(0.0, 1.0),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${(snapshot.progress * 100).toStringAsFixed(1)}% · '
              '${_statusLabelFor(snapshot)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        if (pieces != null && pieces.numPieces > 0) ...<Widget>[
          const SizedBox(height: 8),
          SizedBox(
            height: 10,
            child: CustomPaint(
              painter: TorrentPieceBarPainter(
                states: pieces.states,
                haveColor: theme.colorScheme.primary,
                downloadingColor: theme.colorScheme.tertiary,
                missingColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${t.download_detail_pieces_label}: '
            '${pieces.haveCount}/${pieces.numPieces}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Text(t.download_detail_section_transfer,
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        _statRow(
          theme,
          '↓ / ↑',
          '${HibikiByteFormat.speed(snapshot.downRateBps.toDouble())} / '
              '${HibikiByteFormat.speed(snapshot.upRateBps.toDouble())}',
        ),
        _statRow(
          theme,
          '↓ ${HibikiByteFormat.bytes(snapshot.downloadedBytes)}',
          '↑ ${HibikiByteFormat.bytes(snapshot.uploadedBytes)}',
        ),
        if (eta != null) _statRow(theme, t.download_task_eta, eta),
        if (ratio != null) _statRow(theme, t.download_task_ratio, ratio),
        _statRow(
          theme,
          t.download_detail_seeds_label,
          _peerCountText(snapshot.numSeeds, snapshot.swarmSeeds),
        ),
        _statRow(
          theme,
          t.download_detail_leechers_label,
          _peerCountText(snapshot.numLeechs, snapshot.swarmLeechs),
        ),
        _statRow(
          theme,
          t.download_detail_connections_label,
          snapshot.numConnections >= 0
              ? '${snapshot.numConnections}'
              : '${snapshot.numPeers}',
        ),
        if (snapshot.activeDurationSeconds >= 0)
          _statRow(
            theme,
            t.download_detail_time_active,
            formatCompactDuration(
              Duration(seconds: snapshot.activeDurationSeconds),
            ),
          ),
        if (snapshot.seedingDurationSeconds > 0)
          _statRow(
            theme,
            t.download_detail_time_seeding,
            formatCompactDuration(
              Duration(seconds: snapshot.seedingDurationSeconds),
            ),
          ),
        const SizedBox(height: 12),
        Text(t.download_detail_section_network,
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        ..._buildNetworkRows(theme, session),
      ],
    );
  }

  /// 总览的「网络」区行集（协议状态；缺能力时单行提示）。
  List<Widget> _buildNetworkRows(
    ThemeData theme,
    TorrentSessionStatusInfo? session,
  ) {
    if (!_detailCapable) {
      return <Widget>[
        Text(
          t.download_detail_backend_unsupported,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ];
    }
    if (session == null) {
      return <Widget>[Text('…', style: theme.textTheme.bodySmall)];
    }
    return <Widget>[
      if (session.dhtEnabled != null)
        _statRow(
          theme,
          'DHT',
          session.dhtEnabled!
              ? (session.dhtNodes >= 0
                  ? '${t.download_detail_dht_nodes}: ${session.dhtNodes}'
                  : '✓')
              : '✗',
        ),
      if (session.lsdEnabled != null)
        _statRow(theme, 'LSD', session.lsdEnabled! ? '✓' : '✗'),
      if (session.pexEnabled != null)
        _statRow(theme, 'PEX', session.pexEnabled! ? '✓' : '✗'),
      if (session.listenPort > 0)
        _statRow(
          theme,
          t.download_detail_listen_port,
          '${session.listenPort}',
        ),
      if (session.downRateBps >= 0 || session.upRateBps >= 0)
        _statRow(
          theme,
          t.download_detail_session_rates,
          '↓ ${HibikiByteFormat.speed(session.downRateBps.toDouble())} · '
          '↑ ${HibikiByteFormat.speed(session.upRateBps.toDouble())}',
        ),
      for (final TorrentPortMappingInfo mapping in session.portMappings)
        _statRow(
          theme,
          '${t.download_detail_port_mapping} '
          '(${mapping.transport}'
          '${mapping.protocol.isEmpty ? '' : '/${mapping.protocol}'})',
          mapping.ok ? '✓ ${mapping.externalPort}' : '✗ ${mapping.error}',
        ),
    ];
  }

  String _priorityLabel(TorrentFilePriority priority) {
    return switch (priority) {
      TorrentFilePriority.skip => t.download_detail_priority_skip,
      TorrentFilePriority.normal => t.download_detail_priority_normal,
      TorrentFilePriority.high => t.download_detail_priority_high,
    };
  }

  Widget _buildFilesTab(ThemeData theme) {
    final List<TorrentFileEntry>? files = _files;
    if (files == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (files.isEmpty) {
      return _buildEmptyNote(theme, t.download_task_status_metadata);
    }
    final List<TorrentFilePriority>? priorities = _filePriorities;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      itemBuilder: (BuildContext context, int index) {
        final TorrentFileEntry file = files[index];
        final TorrentFilePriority? priority = (priorities != null &&
                file.index >= 0 &&
                file.index < priorities.length)
            ? priorities[file.index]
            : null;
        return HibikiListItem(
          density: HibikiListDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          titleMaxLines: 2,
          title: Text(file.name),
          subtitle: Row(
            children: <Widget>[
              Expanded(
                child: LinearProgressIndicator(
                  value: file.progress.clamp(0.0, 1.0),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(file.progress * 100).toStringAsFixed(0)}% · '
                '${HibikiByteFormat.bytes(file.size)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          trailing: priority == null
              ? null
              : DropdownButton<TorrentFilePriority>(
                  value: priority,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurface),
                  items: <DropdownMenuItem<TorrentFilePriority>>[
                    for (final TorrentFilePriority p
                        in TorrentFilePriority.values)
                      DropdownMenuItem<TorrentFilePriority>(
                        value: p,
                        child: Text(_priorityLabel(p)),
                      ),
                  ],
                  onChanged: (TorrentFilePriority? next) {
                    if (next != null && next != priority) {
                      unawaited(_changeFilePriority(file.index, next));
                    }
                  },
                ),
        );
      },
    );
  }

  Widget _buildPeersTab(ThemeData theme) {
    if (!_detailCapable) return _buildUnsupported(theme);
    final List<TorrentPeerDetail>? peers = _peers;
    if (peers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (peers.isEmpty) {
      return _buildEmptyNote(theme, t.download_detail_no_peers);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: peers.length,
      itemBuilder: (BuildContext context, int index) {
        final TorrentPeerDetail peer = peers[index];
        return HibikiListItem(
          density: HibikiListDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          title: Text('${peer.address}:${peer.port}'),
          subtitle: Text(
            <String>[
              if (peer.client.isNotEmpty) peer.client,
              '${(peer.progress * 100).toStringAsFixed(0)}%',
              if (peer.flags.isNotEmpty) peer.flags,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '↓ ${HibikiByteFormat.speed(peer.downSpeedBps.toDouble())} '
                '↑ ${HibikiByteFormat.speed(peer.upSpeedBps.toDouble())}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                '↓ ${HibikiByteFormat.bytes(peer.downloadedBytes)} '
                '↑ ${HibikiByteFormat.bytes(peer.uploadedBytes)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }

  String _trackerStatusLabel(TorrentTrackerStatus status) {
    return switch (status) {
      TorrentTrackerStatus.working => t.download_detail_tracker_working,
      TorrentTrackerStatus.updating => t.download_detail_tracker_updating,
      TorrentTrackerStatus.notContacted =>
        t.download_detail_tracker_not_contacted,
      TorrentTrackerStatus.notWorking => t.download_detail_tracker_not_working,
      TorrentTrackerStatus.disabled => t.download_detail_tracker_disabled,
    };
  }

  Widget _buildTrackersTab(ThemeData theme) {
    if (!_detailCapable) return _buildUnsupported(theme);
    final List<TorrentTrackerDetail>? trackers = _trackers;
    if (trackers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (trackers.isEmpty) {
      return _buildEmptyNote(theme, t.download_detail_no_trackers);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: trackers.length,
      itemBuilder: (BuildContext context, int index) {
        final TorrentTrackerDetail tracker = trackers[index];
        final bool failing = tracker.status == TorrentTrackerStatus.notWorking;
        return HibikiListItem(
          density: HibikiListDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          titleMaxLines: 2,
          title: Text(tracker.url),
          subtitle: Text(
            <String>[
              _trackerStatusLabel(tracker.status),
              if (tracker.message.isNotEmpty) tracker.message,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: failing
                ? theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)
                : null,
          ),
          trailing: Text(
            '${t.download_detail_seeds_label} '
            '${tracker.seeds >= 0 ? tracker.seeds : '—'} · '
            '${t.download_detail_leechers_label} '
            '${tracker.leeches >= 0 ? tracker.leeches : '—'}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      },
    );
  }
}

/// piece 位图条：按可用宽度把 piece 折进桶里，桶色 = 缺→有 的插值
/// （下载中的 piece 记半权重）。公开类以便测试直接构造。
class TorrentPieceBarPainter extends CustomPainter {
  TorrentPieceBarPainter({
    required this.states,
    required this.haveColor,
    required this.downloadingColor,
    required this.missingColor,
  });

  /// 0 = 缺、1 = 下载中、2 = 已持有（[TorrentPieceStates.states] 同值域）。
  final List<int> states;
  final Color haveColor;
  final Color downloadingColor;
  final Color missingColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (states.isEmpty || size.width <= 0) return;
    // 每桶至少 2 逻辑像素，桶数不超过 piece 数。
    final int buckets = (size.width ~/ 2).clamp(1, states.length);
    final double bucketWidth = size.width / buckets;
    final Paint paint = Paint();
    for (int b = 0; b < buckets; b++) {
      final int start = (b * states.length) ~/ buckets;
      int end = ((b + 1) * states.length) ~/ buckets;
      if (end <= start) end = start + 1;
      double weight = 0;
      bool downloading = false;
      for (int i = start; i < end && i < states.length; i++) {
        if (states[i] == 2) {
          weight += 1;
        } else if (states[i] == 1) {
          weight += 0.5;
          downloading = true;
        }
      }
      final double fraction = weight / (end - start);
      final Color base =
          downloading && fraction < 1 ? downloadingColor : haveColor;
      paint.color = Color.lerp(missingColor, base, fraction) ?? missingColor;
      canvas.drawRect(
        Rect.fromLTWH(b * bucketWidth, 0, bucketWidth + 0.5, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(TorrentPieceBarPainter oldDelegate) =>
      oldDelegate.states != states ||
      oldDelegate.haveColor != haveColor ||
      oldDelegate.downloadingColor != downloadingColor ||
      oldDelegate.missingColor != missingColor;
}

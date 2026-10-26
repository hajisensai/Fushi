import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 数据：备份 / 同步 / 下载中心 / 媒体服务器 / 互联 / 存储的操作描述（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）。
///
/// 路由在 `ctl_data_routes.dart` 的 `buildDataCtlRoutes`。其中订阅
/// （`buildDownloadSubscriptionCtlRoutes`）归 `op_descriptions_downloads.dart`，这里不写。
///
/// 撤销口径：
/// - 恢复备份**不在恢复前做快照**（`runBackupImportFlowForFile` 直接关库导入并重启），
///   所以是 irreversible；
/// - 立即同步把本机改动推给已配对 / 已配置的后端并拉回对端改动，不可撤回；
/// - 配对 / 吊销 / 忘记 host 涉及对端持有的令牌，本机撤销不回去；
/// - 数据目录迁移会关库搬移并重启，撤销不了。
List<OpDescription> describeDataOps(OpDescribeKit kit) => <OpDescription>[
  // ── 备份 ──────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'backup.list',
    method: 'GET',
    pattern: '/api/admin/backups',
    summary:
        'List Fushi backup archives in a directory with their version and validity.',
    params: <OpParam>[
      OpParam.string(
        'dir',
        description: 'Absolute directory path to scan.',
        required: true,
      ),
    ],
  ),
  const OpDescription(
    id: 'backup.info',
    method: 'GET',
    pattern: '/api/admin/backups/info',
    summary:
        'Inspect one backup archive: app / schema version, whether it is newer '
        'than this app, and per-category item counts.',
    params: <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute path of the backup file (from backup.list).',
        required: true,
      ),
    ],
  ),
  OpDescription(
    id: 'backup.create',
    method: 'POST',
    pattern: '/api/admin/backups',
    summary:
        'Create a backup archive (same as Settings › Backup › Export). Never '
        'overwrites an existing file. Undo deletes the archive it created. '
        'With wait=false it packs in the background; poll backup.status.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'output',
        description:
            'Absolute output file path, or an existing directory (default '
            'file name is used).',
        required: true,
      ),
      OpParam.boolean(
        'all',
        description: 'Include every category (videos included; can be huge).',
      ),
      OpParam.stringList(
        'categories',
        description:
            'Categories to include instead of the default set: dictionary, '
            'books, audiobooks, fonts, videos, localAudio.',
      ),
      OpParam.stringList(
        'books',
        description:
            'Only back up these books (keys from library.book.list); needs the '
            'books category.',
      ),
      OpParam.stringList(
        'videos',
        description:
            'Only back up these videos (book uids from the video library).',
      ),
      OpParam.boolean(
        'wait',
        description:
            'true (default) = return when the archive is written; false = run '
            'in the background.',
      ),
    ],
    undo: _createdFileUndo(kit),
  ),
  const OpDescription(
    id: 'backup.status',
    method: 'GET',
    pattern: '/api/admin/backups/status',
    summary:
        'Progress of the running backup export and the result of the last '
        'background backup.create.',
  ),
  const OpDescription(
    id: 'backup.restore',
    method: 'POST',
    pattern: '/api/admin/backups/restore',
    summary:
        'Restore a backup archive. Replace overwrites local data; merge keeps '
        'local data and adds the archive content. No snapshot is taken before '
        'restoring, so this cannot be undone; the app restarts afterwards. '
        'Without mode the app shows its own merge / replace dialog.',
    risk: OpRisk.irreversible,
    needsUi: true,
    params: <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute path of the backup file (from backup.list).',
        required: true,
      ),
      OpParam.string(
        'mode',
        description:
            'merge or replace; omit to let the user choose in the app dialog.',
        enumValues: <String>['merge', 'replace'],
      ),
      OpParam.stringList(
        'categories',
        description:
            'Categories to restore (only with mode); default = all present.',
      ),
      OpParam.boolean(
        'importSettings',
        description: 'Also restore app settings (replace mode only).',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed restoring over local data.',
      ),
    ],
  ),

  // ── 同步 ──────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'sync.status',
    method: 'GET',
    pattern: '/api/admin/sync',
    summary:
        'Sync status: auto-sync switches, whether a sync is running, last full '
        'sweep result, enabled channels and configured backends (no credentials).',
  ),
  const OpDescription(
    id: 'sync.run',
    method: 'POST',
    pattern: '/api/admin/sync/run',
    summary:
        'Sync now (same as Settings › Sync › Sync now): pushes local changes to '
        'the configured cloud backend / paired hosts and pulls theirs. Cannot be '
        'undone. Conflicts and auth prompts appear in the app.',
    risk: OpRisk.irreversible,
    needsUi: true,
    params: <OpParam>[
      OpParam.stringList(
        'channels',
        description:
            'Only these channels (cloud, interconnect; from sync.status); '
            'default = all enabled.',
      ),
      OpParam.boolean(
        'wait',
        description: 'true = return the outcome; default returns immediately.',
      ),
    ],
  ),

  ..._downloadOps(kit),

  // ── 媒体服务器 ──────────────────────────────────────────────────────────
  const OpDescription(
    id: 'mediaserver.list',
    method: 'GET',
    pattern: '/api/admin/media-servers',
    summary:
        'List configured media servers (Jellyfin / Emby / Plex): id, kind, URL '
        'and account name (no tokens).',
  ),
  OpDescription(
    id: 'mediaserver.browse',
    method: 'GET',
    pattern: '/api/admin/media-servers/:id/items',
    summary:
        'Browse a media server: without parent lists its libraries, with parent '
        'lists that node\'s children (paged).',
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Server id or index from mediaserver.list.',
        required: true,
        inPath: true,
      ),
      OpParam.string(
        'parent',
        description: 'Library / folder / series id from a previous browse.',
      ),
      OpParam.integer('start', description: 'Page offset (default 0).'),
      OpParam.integer('limit', description: 'Page size.'),
    ],
    availability: kit.whenModule(ModuleId.video),
  ),
  OpDescription(
    id: 'mediaserver.search',
    method: 'GET',
    pattern: '/api/admin/media-servers/:id/search',
    summary: 'Search a media server by title.',
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Server id or index from mediaserver.list.',
        required: true,
        inPath: true,
      ),
      OpParam.string('q', description: 'Search text.', required: true),
      OpParam.integer('start', description: 'Page offset (default 0).'),
      OpParam.integer('limit', description: 'Page size.'),
    ],
    availability: kit.whenModule(ModuleId.video),
  ),

  // ── 互联 ──────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'peer.list',
    method: 'GET',
    pattern: '/api/admin/peers',
    summary:
        'List interconnect peers: hosts this device connects to as a client, '
        'and devices paired to this device\'s host (tokens only as yes/no).',
  ),
  const OpDescription(
    id: 'peer.host.status',
    method: 'GET',
    pattern: '/api/admin/peers/host',
    summary:
        'Status of this device\'s interconnect host server (running, enabled, '
        'port, paired device count).',
  ),
  OpDescription(
    id: 'peer.host.start',
    method: 'POST',
    pattern: '/api/admin/peers/host/start',
    summary:
        'Start this device\'s interconnect host server (same as the "Enable '
        'host" switch). Undo stops it again if it was not running before.',
    risk: OpRisk.write,
    undo: _hostRunningUndo(kit),
  ),
  OpDescription(
    id: 'peer.host.stop',
    method: 'POST',
    pattern: '/api/admin/peers/host/stop',
    summary:
        'Stop this device\'s interconnect host server and keep it disabled. '
        'Undo starts it again if it was running before.',
    risk: OpRisk.write,
    undo: _hostRunningUndo(kit),
  ),
  const OpDescription(
    id: 'peer.pair',
    method: 'POST',
    pattern: '/api/admin/peers/pair',
    summary:
        'Pair this device with an interconnect host from a fushi://pair link. '
        'The host gets a device token, so this cannot be undone from here. '
        'Links needing a PIN must be paired in the app.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'link',
        description: 'The fushi://pair link the user provided.',
        required: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User checked the link and approved pairing.',
      ),
    ],
  ),
  const OpDescription(
    id: 'peer.pair-link.create',
    method: 'POST',
    pattern: '/api/admin/peers/pair-link',
    summary:
        'Issue a one-time pairing link from this device\'s host (same as the '
        'pairing QR code). The link is a pairing credential; issuing a new one '
        'voids the previous one. The link itself is shown to the user only.',
    risk: OpRisk.irreversible,
    // 票据是一次性配对凭据：只给用户看，不进 LLM 上下文。
    sensitiveResult: true,
  ),
  const OpDescription(
    id: 'peer.pair-link.revoke',
    method: 'DELETE',
    pattern: '/api/admin/peers/pair-link',
    summary:
        'Void the current one-time pairing link and any pairing session '
        'opened with it.',
    risk: OpRisk.irreversible,
  ),
  const OpDescription(
    id: 'peer.client.revoke',
    method: 'DELETE',
    pattern: '/api/admin/peers/clients/:peerId',
    summary:
        'Revoke a device paired to this device\'s host (deletes its token; it '
        'must pair again).',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'peerId',
        description: 'peerId from peer.list clients.',
        required: true,
        inPath: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed revoking the device.',
      ),
    ],
  ),
  const OpDescription(
    id: 'peer.host.forget',
    method: 'DELETE',
    pattern: '/api/admin/peers/hosts/:host',
    summary:
        'Forget a host this device connects to (all its addresses and its '
        'pairing token); pairing again is needed.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'host',
        description: 'hostId or URL from peer.list hosts.',
        required: true,
        inPath: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed forgetting the host.',
      ),
    ],
  ),

  // ── 存储 ──────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'storage.migrate',
    method: 'POST',
    pattern: '/api/admin/storage/migrate',
    summary:
        'Move the app data directory to a new location (closes the database, '
        'moves every file, restarts the app). dryRun=true only shows the '
        'resolved target paths. Cannot be undone automatically.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute target directory.',
        required: true,
      ),
      OpParam.boolean(
        'dryRun',
        description: 'Only resolve and validate the target, change nothing.',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed moving the data directory.',
      ),
    ],
  ),
  const OpDescription(
    id: 'storage.migrate-status',
    method: 'GET',
    pattern: '/api/admin/storage/migrate',
    summary: 'Progress and last result of a data directory migration.',
  ),
  const OpDescription(
    id: 'storage.root',
    method: 'GET',
    pattern: '/api/admin/storage/root',
    summary:
        'Current data directories (documents, support, temp, database) and '
        'whether a custom data root is used.',
  ),
  const OpDescription(
    id: 'storage.usage',
    method: 'GET',
    pattern: '/api/admin/storage/usage',
    summary: 'Disk usage per storage category and the total.',
  ),
];

/// 撤销 = 删掉这次操作新写出的文件（路由本身拒绝覆盖已有文件）。文件已不在、或
/// 大小与写出时不同（之后被替换过）报 superseded；后台打包还没结束报失败。
OpUndo _createdFileUndo(OpDescribeKit kit) => OpUndo(
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> map = result is Map
        ? result
        : const <Object?, Object?>{};
    final Object? path = map['path'];
    return OpUndoRecord(
      payload: <String, Object?>{
        'path': path is String ? path : null,
        'bytes': map['bytes'] is int ? map['bytes'] : null,
      },
      after: path is String ? path : null,
    );
  },
  revert: (Map<String, Object?> payload) async {
    final Object? path = payload['path'];
    if (path is! String) return const OpUndoOutcome.failed('没有记录文件路径');
    final Object? status = await kit.callRoute(
      'GET',
      '/api/admin/backups/status',
    );
    if (status is Map && status['active'] == true) {
      final Object? last = status['last'];
      if (last is Map && last['path'] == path && last['state'] == 'running') {
        return const OpUndoOutcome.failed('备份还在打包，结束后再撤销');
      }
    }
    final File file = File(path);
    if (!await file.exists()) return const OpUndoOutcome.superseded('文件已不在');
    final Object? bytes = payload['bytes'];
    if (bytes is int && await file.length() != bytes) {
      return const OpUndoOutcome.superseded('文件之后被改过，不删');
    }
    await file.delete();
    return const OpUndoOutcome.done();
  },
);

/// 互联 host 起停的撤销：执行前记下是否在运行，撤销时回到那个状态；当前状态
/// 已不是这次执行的结果（之后又手动起停过）报 superseded。
OpUndo _hostRunningUndo(OpDescribeKit kit) => kit.snapshotUndo(
  read: (Map<String, String> params) => _hostRunning(kit),
  write: (Map<String, String> params, Object? old) async {
    // 执行前就已是这个状态（重复起 / 停）：什么都不用做。
    if (await _hostRunning(kit) == (old == true)) return;
    await kit.callRoute(
      'POST',
      old == true
          ? '/api/admin/peers/host/start'
          : '/api/admin/peers/host/stop',
    );
  },
  newValue: (CtlCall call, Object? result) =>
      result is Map ? result['running'] == true : null,
);

Future<bool> _hostRunning(OpDescribeKit kit) async {
  final Object? status = await kit.callRoute('GET', '/api/admin/peers/host');
  return status is Map && status['running'] == true;
}

// ── 下载中心 ─────────────────────────────────────────────────────────────

const OpParam _jobId = OpParam.string(
  'id',
  description:
      'Job id from downloads.job.list (direct-link jobs look like "direct:3").',
  required: true,
  inPath: true,
);

const OpParam _jobDevice = OpParam.string(
  'device',
  description:
      'Interconnect host that runs the job (from downloads.job.targets); '
      'omit or "local" for this device.',
);

List<OpDescription> _downloadOps(OpDescribeKit kit) {
  final OpAvailability Function() available = kit
      .all(<OpAvailability Function()>[
        kit.whenStoreAllows(StoreRestrictedCapability.downloads),
        kit.whenModule(ModuleId.browse),
      ]);
  return <OpDescription>[
    OpDescription(
      id: 'downloads.job.list',
      method: 'GET',
      pattern: '/api/admin/downloads',
      summary:
          'List download center jobs (magnet / torrent / http direct links) '
          'with progress, or the jobs of an interconnect host.',
      params: const <OpParam>[_jobDevice],
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.get',
      method: 'GET',
      pattern: '/api/admin/downloads/:id',
      summary: 'Read one download job.',
      params: const <OpParam>[_jobId, _jobDevice],
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.detail',
      method: 'GET',
      pattern: '/api/admin/downloads/:id/details',
      summary:
          'Torrent details of a local job: files, torrent snapshot and where '
          'it is saved.',
      params: const <OpParam>[_jobId],
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.targets',
      method: 'GET',
      pattern: '/api/admin/download-targets',
      summary:
          'Where a download can go: target video libraries (source ids) and '
          'devices (this device or online interconnect hosts).',
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.add',
      method: 'POST',
      pattern: '/api/admin/downloads',
      summary:
          'Queue a download: magnet link, absolute .torrent path, or http(s) '
          'direct link (needs mediaKind). Finished files are imported into the '
          'library. Undo cancels the job and deletes its downloaded files.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'target',
          description: 'Magnet link, absolute .torrent path, or http(s) URL.',
          required: true,
        ),
        OpParam.string(
          'mediaKind',
          description:
              'movie / tv for torrents (default movie), or a discovery kind '
              '(novel, manga, game, music…); required for http links.',
        ),
        OpParam.string('title', description: 'Job title (default from link).'),
        _jobDevice,
        OpParam.integer(
          'source',
          description:
              'Target video library source id (from downloads.job.targets).',
        ),
        OpParam.string(
          'subtitlePolicy',
          description: 'Subtitle handling for video torrents.',
        ),
        OpParam.stringList(
          'files',
          description: 'Torrent file indexes to download (default all).',
        ),
        OpParam.integer(
          'priority',
          description: 'Queue priority: 1 high, 0 normal, -1 low.',
        ),
        OpParam.integer('year', description: 'Work year (identity hint).'),
        OpParam.string(
          'metadataProvider',
          description: 'Metadata provider of externalId (tmdb, anidb…).',
        ),
        OpParam.string(
          'externalId',
          description: 'Work id at metadataProvider.',
        ),
      ],
      undo: _downloadAddUndo(kit),
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.cancel',
      method: 'POST',
      pattern: '/api/admin/downloads/:id/cancel',
      summary:
          'Pause / cancel a running job (downloaded data is kept). Undo '
          'resumes it.',
      risk: OpRisk.write,
      params: const <OpParam>[_jobId, _jobDevice],
      undo: _downloadInverseUndo(kit, resume: true),
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.retry',
      method: 'POST',
      pattern: '/api/admin/downloads/:id/retry',
      summary:
          'Retry a failed (or cancelled direct-link) job. Undo cancels it again.',
      risk: OpRisk.write,
      params: const <OpParam>[_jobId, _jobDevice],
      undo: _downloadInverseUndo(kit, resume: false),
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.resume',
      method: 'POST',
      pattern: '/api/admin/downloads/:id/resume',
      summary: 'Resume a paused local torrent job. Undo pauses it again.',
      risk: OpRisk.write,
      params: const <OpParam>[_jobId],
      undo: _downloadInverseUndo(kit, resume: false),
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.priority',
      method: 'POST',
      pattern: '/api/admin/downloads/:id/priority',
      summary:
          'Change the queue priority of a queued / running local torrent job. '
          'Undo restores the old priority.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _jobId,
        OpParam.integer(
          'priority',
          description: '1 high, 0 normal, -1 low.',
          required: true,
        ),
      ],
      undo: kit.snapshotUndo(
        read: (Map<String, String> params) async {
          final Object? job = await kit.callRoute(
            'GET',
            '/api/admin/downloads/:id',
            params: params,
          );
          return job is Map ? job['priority'] : null;
        },
        write: (Map<String, String> params, Object? old) async {
          await kit.callRoute(
            'POST',
            '/api/admin/downloads/:id/priority',
            params: params,
            body: <String, Object?>{'priority': old ?? 0},
          );
        },
        newValue: (CtlCall call, Object? result) =>
            result is Map ? result['priority'] : call.body['priority'],
      ),
      availability: available,
    ),
    OpDescription(
      id: 'downloads.job.remove',
      method: 'DELETE',
      pattern: '/api/admin/downloads/:id',
      summary:
          'Remove a download job; with deleteFiles also delete its downloaded '
          'files from disk. Cannot be undone.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _jobId,
        _jobDevice,
        OpParam.boolean(
          'deleteFiles',
          description: 'Also delete the downloaded files (default keep).',
        ),
        OpParam.userGate(
          'confirm',
          description: 'User confirmed removing the job.',
        ),
      ],
      availability: available,
    ),
  ];
}

/// 新入队任务的撤销：先取消（已结束的回 409，跳过），再连同已下数据一起删掉
/// （直链只摘队列行：那边没有删文件的语义）。任务已不在报 superseded。
OpUndo _downloadAddUndo(OpDescribeKit kit) => OpUndo(
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> map = result is Map
        ? result
        : const <Object?, Object?>{};
    final Object? device = map['device'] ?? call.body['device'];
    return OpUndoRecord(
      payload: <String, Object?>{
        'jobId': map['jobId'],
        'device': device == null || device == 'local' ? null : '$device',
      },
      after: map['title'] is String ? map['title'] as String : null,
    );
  },
  revert: (Map<String, Object?> payload) async {
    final Object? jobId = payload['jobId'];
    if (jobId == null) return const OpUndoOutcome.failed('入队结果里没有任务 id');
    final Map<String, String> params = <String, String>{'id': '$jobId'};
    final Object? device = payload['device'];
    final bool direct = '$jobId'.startsWith('direct:');
    try {
      try {
        await kit.callRoute(
          'POST',
          '/api/admin/downloads/:id/cancel',
          params: params,
          body: <String, Object?>{'device': ?device},
        );
      } on CtlFailure catch (failure) {
        // 409 = 已经结束（下完 / 失败 / 已取消）：直接删。
        if (failure.status != 409) rethrow;
      }
      await kit.callRoute(
        'DELETE',
        '/api/admin/downloads/:id',
        params: params,
        body: <String, Object?>{
          'confirm': true,
          'deleteFiles': !direct,
          'device': ?device,
        },
      );
      return const OpUndoOutcome.done();
    } on CtlFailure catch (failure) {
      return failure.status == 404
          ? OpUndoOutcome.superseded(failure.message)
          : OpUndoOutcome.failed(failure.message ?? failure.code);
    }
  },
);

/// 暂停 / 继续 / 重试互为反向。[resume]：撤销的是一次「暂停」——本机任务走
/// resume，直链与互联 host 的任务没有暂停态，走 retry（直链 `.part` 保留即续传）；
/// 否则撤销的是一次「继续 / 重试」，反向就是 cancel。
OpUndo _downloadInverseUndo(OpDescribeKit kit, {required bool resume}) =>
    kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => <String, Object?>{
        'id': call.params['id'],
        'device': call.body['device'],
      },
      inverse: (Map<String, Object?> payload) {
        final String id = '${payload['id']}';
        final Object? device = payload['device'];
        final bool remote = device != null && device != 'local';
        final String action = !resume
            ? 'cancel'
            : (remote || id.startsWith('direct:') ? 'retry' : 'resume');
        return kit.callRoute(
          'POST',
          '/api/admin/downloads/:id/$action',
          params: <String, String>{'id': id},
          body: <String, Object?>{'device': ?device},
        );
      },
    );

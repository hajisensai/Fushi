import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart'
    show kVideoSubscriptionTitleExcludeKey, kVideoSubscriptionTitleIncludeKey;

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart'
    show videoSubscriptionFilterValues;

/// 下载类操作描述（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §4、§5.2）：
///
/// - 在线源的两个下载队列（`ctl_online_routes.dart`）：漫画章节队列
///   （`MangaDownloadService`）、视频源剧集（app 级互联下载管理器），以及 CLI 发起
///   的小说整本下载任务；
/// - 视频下载订阅（`ctl_download_subscription_routes.dart`）；
/// - 「AI 下载」会话（`ctl_ai_download_routes.dart`）。
///
/// 下载中心本体（磁链 / 直链任务表，`/api/admin/downloads`）归 data 域描述。
List<OpDescription> describeDownloadOps(OpDescribeKit kit) {
  final OpAvailability Function() manga = kit.whenStoreAllows(
    StoreRestrictedCapability.onlineMangaSource,
  );
  final OpAvailability Function() novel = kit.whenStoreAllows(
    StoreRestrictedCapability.onlineNovelSource,
  );
  final OpAvailability Function() downloads = kit.whenStoreAllows(
    StoreRestrictedCapability.downloads,
  );
  // 与路由的 requireCtlDownloadCenter 同一判据：合规门 +「浏览」模块。
  final OpAvailability Function() center = kit.all(<OpAvailability Function()>[
    downloads,
    kit.whenModule(ModuleId.browse),
  ]);
  return <OpDescription>[
    // ── CLI 发起的小说整本下载任务 ────────────────────────────────────────
    OpDescription(
      id: 'online.task.list',
      method: 'GET',
      pattern: '/api/admin/online/tasks',
      summary:
          'List whole-book novel download tasks started by online.source.download '
          'or an AI download session (status, done / total chapters, resultKey).',
      availability: novel,
    ),
    OpDescription(
      id: 'online.task.get',
      method: 'GET',
      pattern: '/api/admin/online/tasks/:id',
      summary: 'Progress of one novel download task.',
      params: const <OpParam>[_taskId],
      availability: novel,
    ),
    OpDescription(
      id: 'online.task.cancel',
      method: 'POST',
      pattern: '/api/admin/online/tasks/:id/cancel',
      summary:
          'Cancel a running novel download task (stops between chapters). A '
          'cancelled download cannot be resumed, so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[_taskId],
      availability: novel,
    ),
    // ── 漫画章节下载队列 ──────────────────────────────────────────────────
    OpDescription(
      id: 'online.manga-download.list',
      method: 'GET',
      pattern: '/api/admin/online/manga-downloads',
      summary:
          'List manga chapter download jobs (status, pages done / total, error).',
      params: const <OpParam>[
        OpParam.stringList(
          'status',
          description:
              'Only these statuses: queued, running, done, failed, cancelled.',
        ),
        OpParam.string(
          'book',
          description: 'Only jobs of this bookKey (from online.source.add).',
        ),
      ],
      availability: manga,
    ),
    OpDescription(
      id: 'online.manga-download.clear',
      method: 'DELETE',
      pattern: '/api/admin/online/manga-downloads',
      summary:
          'Remove all finished (done / failed / cancelled) manga download job rows. '
          'Downloaded chapters stay; the rows cannot be restored, so the user '
          'confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        OpParam.boolean(
          'finished',
          description: 'Must be true (only finished jobs can be cleared).',
          required: true,
        ),
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
      availability: manga,
    ),
    OpDescription(
      id: 'online.manga-download.cancel',
      method: 'POST',
      pattern: '/api/admin/online/manga-downloads/:id/cancel',
      summary:
          'Cancel a queued or running manga chapter download (partial pages are '
          'discarded). Undo re-queues it (retry).',
      risk: OpRisk.write,
      params: const <OpParam>[_mangaJobId],
      availability: manga,
      undo: _inverseUndo(
        kit,
        method: 'POST',
        pattern: '/api/admin/online/manga-downloads/:id/retry',
        describe: 'cancelled',
      ),
    ),
    OpDescription(
      id: 'online.manga-download.retry',
      method: 'POST',
      pattern: '/api/admin/online/manga-downloads/:id/retry',
      summary:
          'Re-queue a failed or cancelled manga chapter download. Undo cancels it '
          'again while it has not finished.',
      risk: OpRisk.write,
      params: const <OpParam>[_mangaJobId],
      availability: manga,
      undo: _inverseUndo(
        kit,
        method: 'POST',
        pattern: '/api/admin/online/manga-downloads/:id/cancel',
        describe: 'queued',
      ),
    ),
    OpDescription(
      id: 'online.manga-download.remove',
      method: 'DELETE',
      pattern: '/api/admin/online/manga-downloads/:id',
      summary:
          'Delete one manga download job row (a running one is cancelled first; '
          'downloaded chapter content stays). Cannot be restored, so the user '
          'confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _mangaJobId,
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
      availability: manga,
    ),
    // ── 视频源剧集下载 ────────────────────────────────────────────────────
    OpDescription(
      id: 'online.episode-download.list',
      method: 'GET',
      pattern: '/api/admin/online/episode-downloads',
      summary:
          'List video-extension episode downloads (status, progress, canPause, '
          'canResume); all=true also lists peer / media-server pulls.',
      params: const <OpParam>[
        OpParam.boolean(
          'all',
          description: 'Include downloads from paired devices / media servers.',
        ),
      ],
      availability: downloads,
    ),
    OpDescription(
      id: 'online.episode-download.get',
      method: 'GET',
      pattern: '/api/admin/online/episode-downloads/:id',
      summary: 'One episode download task.',
      params: const <OpParam>[_episodeTaskId],
      availability: downloads,
    ),
    OpDescription(
      id: 'online.episode-download.pause',
      method: 'POST',
      pattern: '/api/admin/online/episode-downloads/:id/pause',
      summary:
          'Pause an episode download (keeps the partial file). Undo resumes it.',
      risk: OpRisk.write,
      params: const <OpParam>[_episodeTaskId],
      availability: downloads,
      undo: _inverseUndo(
        kit,
        method: 'POST',
        pattern: '/api/admin/online/episode-downloads/:id/resume',
        describe: 'paused',
      ),
    ),
    OpDescription(
      id: 'online.episode-download.resume',
      method: 'POST',
      pattern: '/api/admin/online/episode-downloads/:id/resume',
      summary:
          'Resume or retry a paused / failed episode download. Undo pauses it '
          'again while it is still running.',
      risk: OpRisk.write,
      params: const <OpParam>[_episodeTaskId],
      availability: downloads,
      undo: _inverseUndo(
        kit,
        method: 'POST',
        pattern: '/api/admin/online/episode-downloads/:id/pause',
        describe: 'resumed',
      ),
    ),
    OpDescription(
      id: 'online.episode-download.remove',
      method: 'DELETE',
      pattern: '/api/admin/online/episode-downloads/:id',
      summary:
          'Remove an episode download task (pause it first if running). '
          'deleteFiles=true also deletes the partial file, or for a finished '
          'video-extension episode the downloaded file and its library row. '
          'Cannot be undone, so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _episodeTaskId,
        OpParam.boolean(
          'deleteFiles',
          description: 'Also delete the partial / downloaded file.',
        ),
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
      availability: downloads,
    ),
    // ── 视频下载订阅 ──────────────────────────────────────────────────────
    OpDescription(
      id: 'downloads.subscription.list',
      method: 'GET',
      pattern: '/api/admin/subscriptions',
      summary:
          'List video download subscriptions (query, enabled, next check, per-'
          'episode counts) and whether the download backend supports them.',
      availability: center,
    ),
    OpDescription(
      id: 'downloads.subscription.get',
      method: 'GET',
      pattern: '/api/admin/subscriptions/:id',
      summary: 'One video download subscription with its rules.',
      params: const <OpParam>[_subscriptionId],
      availability: center,
    ),
    OpDescription(
      id: 'downloads.subscription.items',
      method: 'GET',
      pattern: '/api/admin/subscriptions/:id/items',
      summary:
          'Per-episode history of a subscription (status, download job id, error).',
      params: const <OpParam>[_subscriptionId],
      availability: center,
    ),
    OpDescription(
      id: 'downloads.subscription.check-all',
      method: 'POST',
      pattern: '/api/admin/subscriptions/check',
      summary:
          'Check every enabled subscription now; new matching episodes are queued '
          'as downloads (torrents announce to peers). The queued jobs are not '
          'reported, so this cannot be undone and the user confirms.',
      risk: OpRisk.irreversible,
      availability: center,
    ),
    OpDescription(
      id: 'downloads.subscription.check',
      method: 'POST',
      pattern: '/api/admin/subscriptions/:id/check',
      summary:
          'Check one subscription now; new matching episodes are queued as '
          'downloads. Cannot be undone, so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[_subscriptionId],
      availability: center,
    ),
    OpDescription(
      id: 'downloads.subscription.set-enabled',
      method: 'POST',
      pattern: '/api/admin/subscriptions/:id/enable',
      summary:
          'Enable or disable a subscription. Undo restores the previous state.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _subscriptionId,
        OpParam.boolean('enabled', description: 'true = on.', required: true),
      ],
      availability: center,
      undo: kit.readBackUndo(
        readMethod: 'GET',
        readPattern: '/api/admin/subscriptions/:id',
        writeMethod: 'POST',
        writePattern: '/api/admin/subscriptions/:id/enable',
        field: 'enabled',
      ),
    ),
    OpDescription(
      id: 'downloads.subscription.edit',
      method: 'PUT',
      pattern: '/api/admin/subscriptions/:id',
      summary:
          'Edit a subscription; only the given fields change (same whitelist as '
          'the edit dialog). Undo writes the previous values back.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _subscriptionId,
        OpParam.string('searchQuery', description: 'Resource search query.'),
        OpParam.integer(
          'startAfterEpisode',
          description: 'Only episodes after this number are downloaded.',
        ),
        OpParam.string(
          'subtitlePolicy',
          description: 'Subtitle policy token, as shown by subscription get.',
        ),
        OpParam.integer(
          'source',
          description: 'Target managed video source id (data dl targets).',
        ),
        OpParam.stringList(
          'releaseGroups',
          description: 'Preferred release groups (replaces the list).',
        ),
        OpParam.stringList(
          'resolutions',
          description: 'Allowed resolutions such as 1080p (replaces the list).',
        ),
        OpParam.stringList(
          'titleIncludes',
          description: 'Title must contain all of these (replaces the list).',
        ),
        OpParam.stringList(
          'titleExcludes',
          description: 'Title must contain none of these (replaces the list).',
        ),
      ],
      availability: center,
      undo: _subscriptionEditUndo(kit),
    ),
    OpDescription(
      id: 'downloads.subscription.remove',
      method: 'DELETE',
      pattern: '/api/admin/subscriptions/:id',
      summary:
          'Delete a subscription and its episode history (queued downloads and '
          'files stay). There is no route to recreate it, so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _subscriptionId,
        OpParam.userGate('confirm', description: 'Destructive-action consent.'),
      ],
      availability: center,
    ),
    // ── 「AI 下载」会话 ───────────────────────────────────────────────────
    OpDescription(
      id: 'downloads.ai-session.list',
      method: 'GET',
      pattern: '/api/admin/ai-download/sessions',
      summary: 'List open AI download sessions (id, domain, stage).',
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.start',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions',
      summary:
          'Open an AI download session from one sentence ("download Frieren '
          'episode 3", a novel title…). It parses and searches only; nothing is '
          'downloaded until downloads.ai-session.confirm. Returns the session id.',
      params: const <OpParam>[
        OpParam.string(
          'domain',
          description: 'video (anime / films), novel, manga or game.',
          required: true,
          enumValues: <String>['video', 'novel', 'manga', 'game'],
        ),
        OpParam.string(
          'text',
          description: 'What the user wants, in their words.',
          required: true,
        ),
        _wait,
      ],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.get',
      method: 'GET',
      pattern: '/api/admin/ai-download/sessions/:id',
      summary:
          'Current view of an AI download session: stage, pending question with '
          'options, candidates, statuses.',
      params: const <OpParam>[_sessionId, _wait],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.close',
      method: 'DELETE',
      pattern: '/api/admin/ai-download/sessions/:id',
      summary: 'Close an AI download session (started downloads keep running).',
      params: const <OpParam>[_sessionId],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.say',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions/:id/say',
      summary:
          'Send a free-text reply to an AI download session. In a video session a '
          'reply that means "yes, go ahead" submits the download / subscription, '
          'so the user confirms each reply.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _sessionId,
        OpParam.string('text', description: 'The reply.', required: true),
        _wait,
      ],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.choose',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions/:id/choose',
      summary:
          'Answer the pending question (video: option id / 1-based number / label; '
          'other domains: candidate ids). Picking the confirm option or a specific '
          'release in a video session submits it, so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        _sessionId,
        OpParam.stringList(
          'answers',
          description:
              'Video: exactly one answer; novel/manga/game: candidate ids.',
          required: true,
        ),
        _wait,
      ],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.confirm',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions/:id/confirm',
      summary:
          'Confirm the session\'s current selection: starts the downloads / '
          'creates the subscription (may show an in-app dialog). Cannot be undone, '
          'so the user confirms.',
      risk: OpRisk.irreversible,
      needsUi: true,
      params: const <OpParam>[_sessionId, _wait],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.cancel',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions/:id/cancel',
      summary:
          'Cancel the session\'s current flow; also cancels novel downloads it '
          'started (they cannot be resumed), so the user confirms.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[_sessionId],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.restart',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions/:id/restart',
      summary:
          'Reset the session to the start (forgets the current search; started '
          'downloads are not touched).',
      params: const <OpParam>[_sessionId],
      availability: downloads,
    ),
    OpDescription(
      id: 'downloads.ai-session.franchise-toggle',
      method: 'POST',
      pattern: '/api/admin/ai-download/sessions/:id/franchise',
      summary:
          'Video sessions: tick / untick one entry (1-based) of the "whole '
          'franchise" list before confirming.',
      params: const <OpParam>[
        _sessionId,
        OpParam.integer(
          'index',
          description: '1-based entry number in the franchise list.',
          required: true,
        ),
      ],
      availability: downloads,
    ),
  ];
}

// ── 共用参数 ──────────────────────────────────────────────────────────────

const OpParam _taskId = OpParam.string(
  'id',
  description:
      'Task id (t1, t2…) from online.task.list / online.source.download.',
  required: true,
  inPath: true,
);

const OpParam _mangaJobId = OpParam.string(
  'id',
  description: 'Job id from online.manga-download.list.',
  required: true,
  inPath: true,
);

const OpParam _episodeTaskId = OpParam.string(
  'id',
  description:
      'Task id from online.episode-download.list (taskIds of online.source.download).',
  required: true,
  inPath: true,
);

const OpParam _subscriptionId = OpParam.string(
  'id',
  description: 'subscriptionId from downloads.subscription.list.',
  required: true,
  inPath: true,
);

const OpParam _sessionId = OpParam.string(
  'id',
  description: 'Session id from downloads.ai-session.start / list.',
  required: true,
  inPath: true,
);

const OpParam _wait = OpParam.integer(
  'wait',
  description:
      'Seconds to wait until the session is idle before answering (searching '
      'takes seconds to tens of seconds); default 0.',
);

// ── 私有助手（可能值得提进 OpDescribeKit） ───────────────────────────────

Map<String, Object?> _map(Object? raw) =>
    raw is Map ? raw.cast<String, Object?>() : const <String, Object?>{};

/// 撤销 = 对同一个 `:id` 调反向路由。反向路由回 404（对象没了）或 409（状态已变，
/// 如任务已下完、已被手动重试）都算「执行后又被改过」→ superseded，而不是失败。
OpUndo _inverseUndo(
  OpDescribeKit kit, {
  required String method,
  required String pattern,
  required String describe,
}) => OpUndo(
  record: (CtlCall call, Map<String, Object?> before, Object? result) =>
      OpUndoRecord(
        payload: <String, Object?>{'id': call.params['id']},
        after: '${call.params['id']} $describe',
      ),
  revert: (Map<String, Object?> payload) async {
    try {
      await kit.callRoute(
        method,
        pattern,
        params: <String, String>{'id': '${payload['id']}'},
      );
      return const OpUndoOutcome.done();
    } on CtlFailure catch (failure) {
      return failure.status == 404 || failure.status == 409
          ? OpUndoOutcome.superseded(failure.message)
          : OpUndoOutcome.failed(failure.message ?? failure.code);
    }
  },
);

/// 订阅编辑的 body 字段 → 订阅出参里对应的列（四条版本规则都落在 filterJson）。
const Map<String, String> _subscriptionEditColumns = <String, String>{
  'searchQuery': 'searchQuery',
  'startAfterEpisode': 'startAfterEpisode',
  'subtitlePolicy': 'subtitlePolicy',
  'source': 'targetSourceId',
  'releaseGroups': 'filterJson',
  'resolutions': 'filterJson',
  'titleIncludes': 'filterJson',
  'titleExcludes': 'filterJson',
};

Map<String, Object?> _subscriptionColumns(
  Map<String, Object?> wire,
  Iterable<String> columns,
) => <String, Object?>{for (final String c in columns) c: wire[c]};

/// 订阅编辑的撤销：只写回这次改到的列。撤销前这些列已不是编辑结果 → superseded。
/// 版本规则按旧 filterJson 拆回四个列表整组写回（编辑路由只认这四个列表）。
OpUndo _subscriptionEditUndo(OpDescribeKit kit) {
  Future<Map<String, Object?>> read(String id) async => _map(
    await kit.callRoute(
      'GET',
      '/api/admin/subscriptions/:id',
      params: <String, String>{'id': id},
    ),
  );
  return OpUndo(
    capture: (CtlCall call) async {
      final List<String> columns = <String>{
        for (final String key in call.body.keys)
          if (_subscriptionEditColumns[key] case final String column) column,
      }.toList();
      return <String, Object?>{
        'id': call.params['id'],
        'columns': columns,
        'old': _subscriptionColumns(await read(call.params['id']!), columns),
      };
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final List<String> columns = <String>[
        for (final Object? c in before['columns'] as List? ?? const <Object?>[])
          '$c',
      ];
      final Map<String, Object?> after = _subscriptionColumns(
        _map(result),
        columns,
      );
      return OpUndoRecord(
        payload: <String, Object?>{...before, 'new': after},
        before: jsonEncode(before['old']),
        after: jsonEncode(after),
      );
    },
    revert: (Map<String, Object?> payload) async {
      final String id = '${payload['id']}';
      final List<String> columns = <String>[
        for (final Object? c
            in payload['columns'] as List? ?? const <Object?>[])
          '$c',
      ];
      final Map<String, Object?> old = _map(payload['old']);
      try {
        if (!OpDescribeKit.sameJson(
          _subscriptionColumns(await read(id), columns),
          payload['new'],
        )) {
          return const OpUndoOutcome.superseded();
        }
        final Map<String, Object?> body = <String, Object?>{
          if (columns.contains('searchQuery'))
            'searchQuery': old['searchQuery'],
          if (columns.contains('startAfterEpisode'))
            'startAfterEpisode': old['startAfterEpisode'],
          if (columns.contains('subtitlePolicy'))
            'subtitlePolicy': old['subtitlePolicy'],
          if (columns.contains('targetSourceId') &&
              old['targetSourceId'] != null)
            'source': old['targetSourceId'],
        };
        if (columns.contains('filterJson')) {
          final String filter = '${old['filterJson'] ?? '{}'}';
          body['releaseGroups'] = videoSubscriptionFilterValues(
            filter,
            'releaseGroup',
          );
          body['resolutions'] = videoSubscriptionFilterValues(
            filter,
            'resolution',
          );
          body['titleIncludes'] = videoSubscriptionFilterValues(
            filter,
            kVideoSubscriptionTitleIncludeKey,
          );
          body['titleExcludes'] = videoSubscriptionFilterValues(
            filter,
            kVideoSubscriptionTitleExcludeKey,
          );
        }
        if (body.isEmpty) {
          return const OpUndoOutcome.failed(
            'previous target library was unset and cannot be cleared',
          );
        }
        await kit.callRoute(
          'PUT',
          '/api/admin/subscriptions/:id',
          params: <String, String>{'id': id},
          body: body,
        );
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return failure.status == 404
            ? OpUndoOutcome.superseded(failure.message)
            : OpUndoOutcome.failed(failure.message ?? failure.code);
      }
    },
  );
}

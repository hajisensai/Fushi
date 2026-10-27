import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_describe_kit.dart';

/// 长任务（`longRunning`）的状态读数：各域按执行结果里的任务 id 读一次**现有**的
/// 状态路由，映射成 [OpTaskStatus]（AI 运行时据此轮询，结束后报告并续一轮，
/// spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §6.1）。
///
/// 只读现有路由、只认各任务自己的状态枚举，不另存任务状态。

Map<String, Object?> _map(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : const <String, Object?>{};

String? _text(Object? raw) {
  final String? value = raw?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

/// 结果顶层 `id` 即任务 id（视频页任务、有声书任务 / 转录任务、小说下载任务的
/// JSON 都是 `{id, status, …}`，不是默认的 `taskId` / `jobId`）。
String? opTaskIdFromId(Object? result) => _text(_map(result)['id']);

/// 一个「`status` 字段 + 已知终态集合」的任务 JSON → [OpTaskStatus]。
/// [failed] 之外的终态（[succeeded]）算成功；不在三个集合里的一律当还在跑。
OpTaskStatus _statusOf(
  Object? raw, {
  required String field,
  required Set<String> succeeded,
  required Set<String> failed,
  String? label,
  String? Function(Map<String, Object?> job)? successDetail,
  String errorField = 'error',
}) {
  final Map<String, Object?> job = _map(raw);
  final String status = '${job[field]}';
  final String name = label ?? '${job['kind'] ?? job['title'] ?? 'task'}';
  if (succeeded.contains(status)) {
    final String? detail = successDetail?.call(job);
    return OpTaskStatus(
      terminal: true,
      succeeded: true,
      summary: detail == null ? '$name $status' : '$name $status: $detail',
      data: raw,
    );
  }
  if (failed.contains(status)) {
    final String? error = _text(job[errorField]);
    return OpTaskStatus(
      terminal: true,
      summary: error == null ? '$name $status' : '$name $status: $error',
      data: raw,
    );
  }
  return OpTaskStatus(terminal: false, summary: '$name $status', data: raw);
}

String? _basename(Object? path) {
  final String? value = _text(path);
  if (value == null) return null;
  final List<String> parts = value.split(RegExp(r'[\\/]'));
  return parts.lastWhere((String s) => s.isNotEmpty, orElse: () => value);
}

// ── 视频页 / 字幕生成任务：GET /api/admin/video/jobs/:id ─────────────────────

/// `VideoRemoteJobStatus { running, succeeded, failed, cancelled }`。
Future<OpTaskStatus> opVideoJobTaskStatus(OpDescribeKit kit, String id) async {
  final Object? raw = await kit.callRoute(
    'GET',
    '/api/admin/video/jobs/:id',
    params: <String, String>{'id': id},
  );
  return _statusOf(
    raw,
    field: 'status',
    succeeded: const <String>{'succeeded'},
    failed: const <String>{'failed', 'cancelled'},
    successDetail: (Map<String, Object?> job) {
      final Map<String, Object?> result = _map(job['result']);
      return _text(result['label']) ??
          _basename(result['path']) ??
          _basename(result['subtitle']);
    },
  );
}

// ── 下载中心任务：GET /api/admin/downloads/:id ──────────────────────────────

/// 本机种子流水线任务的 `lifecycle`（`VideoDownloadJobLifecycle`：active /
/// needsAttention / completed / failed / cancelled）或直链任务（`direct:` 前缀，
/// `DiscoveryDownloadStatus`：queued / running / waitingRetry / done / failed /
/// cancelled）。`needsAttention` = 流水线停下等用户处理（不会自己再推进），对 AI
/// 的轮询而言是终点：报告未成功并带上 `lastError`。
Future<OpTaskStatus> opDownloadJobTaskStatus(
  OpDescribeKit kit,
  String id,
) async {
  final Object? raw = await kit.callRoute(
    'GET',
    '/api/admin/downloads/:id',
    params: <String, String>{'id': id},
  );
  return _statusOf(
    raw,
    field: 'lifecycle',
    succeeded: const <String>{'completed', 'done'},
    failed: const <String>{'needsAttention', 'failed', 'cancelled'},
    label: 'download ${_text(_map(raw)['title']) ?? id}',
    errorField: 'lastError',
    successDetail: (Map<String, Object?> job) =>
        _text(job['imported']) ?? _basename(job['filePath']),
  );
}

// ── 有声书附着 / 重匹配：GET /api/admin/library/audiobook/tasks/:id ─────────

/// `LibraryCtlTaskStatus { running, done, failed, cancelled }`。
Future<OpTaskStatus> opAudiobookTaskStatus(OpDescribeKit kit, String id) async {
  final Object? raw = await kit.callRoute(
    'GET',
    '/api/admin/library/audiobook/tasks/:id',
    params: <String, String>{'id': id},
  );
  return _statusOf(
    raw,
    field: 'status',
    succeeded: const <String>{'done'},
    failed: const <String>{'failed', 'cancelled'},
    label: '${_map(raw)['kind'] ?? 'audiobook'} ${_map(raw)['key'] ?? ''}'
        .trim(),
  );
}

// ── 有声书转录：GET /api/admin/library/audiobook/jobs/:id ───────────────────

/// `AudiobookTranscribeJobStatus { queued, running, done, failed, cancelled }`。
Future<OpTaskStatus> opAudiobookJobTaskStatus(
  OpDescribeKit kit,
  String id,
) async {
  final Object? raw = await kit.callRoute(
    'GET',
    '/api/admin/library/audiobook/jobs/:id',
    params: <String, String>{'id': id},
  );
  return _statusOf(
    raw,
    field: 'status',
    succeeded: const <String>{'done'},
    failed: const <String>{'failed', 'cancelled'},
    label: 'transcription ${_text(_map(raw)['title']) ?? id}',
    successDetail: (Map<String, Object?> job) => _text(job['resultKey']),
  );
}

// ── 在线源下载（online.source.download）────────────────────────────────────

const String _novelPrefix = 'novel:';
const String _mangaPrefix = 'manga:';

/// `online.source.download` 三个生态的结果形状不同：
/// - novel：小说整本下载任务 `{id, status, …}` → `novel:<id>`；
/// - manga：书架条目 + 入队章数 `{bookKey, queued, …}` → `manga:<queued>:<bookKey>`
///   （章节进了漫画下载队列，没有单一任务 id；状态按这本书最近入队的那些任务汇总）；
/// - anime：`taskIds`（剧集 id）→ **不追踪**（返回 null）：剧集由下载管理器逐集
///   顺序启动、已下完的那集直接跳过不建任务，现有的剧集任务路由区分不了「还没
///   开始」与「被跳过」，读不出可信的终态。
String? opOnlineDownloadTaskIdOf(Object? result) {
  final Map<String, Object?> map = _map(result);
  switch (map['kind']) {
    case 'novel':
      final String? id = _text(map['id']);
      return id == null ? null : '$_novelPrefix$id';
    case 'manga':
      final int queued = (map['queued'] as num?)?.toInt() ?? 0;
      final String? bookKey = _text(map['bookKey']);
      if (queued <= 0 || bookKey == null) return null;
      return '$_mangaPrefix$queued:$bookKey';
  }
  return null;
}

/// [opOnlineDownloadTaskIdOf] 产出的任务 id → 状态。
Future<OpTaskStatus> opOnlineDownloadTaskStatus(
  OpDescribeKit kit,
  String taskId,
) async {
  if (taskId.startsWith(_novelPrefix)) {
    final Object? raw = await kit.callRoute(
      'GET',
      '/api/admin/online/tasks/:id',
      params: <String, String>{'id': taskId.substring(_novelPrefix.length)},
    );
    // CtlOnlineTask.status：running / done / failed / cancelled。
    return _statusOf(
      raw,
      field: 'status',
      succeeded: const <String>{'done'},
      failed: const <String>{'failed', 'cancelled'},
      label: 'novel download ${_text(_map(raw)['title']) ?? ''}'.trim(),
      successDetail: (Map<String, Object?> job) =>
          '${job['done']}/${job['total']} chapters',
    );
  }
  if (taskId.startsWith(_mangaPrefix)) {
    return _mangaBatchStatus(kit, taskId.substring(_mangaPrefix.length));
  }
  throw CtlFailure.badRequest('unknown online download task id: $taskId');
}

/// 漫画章节批：这本书在漫画下载队列（`MangaDownloadJobStatus`：queued / running /
/// done / failed / cancelled）里最近入队的 `queued` 个任务。
Future<OpTaskStatus> _mangaBatchStatus(OpDescribeKit kit, String rest) async {
  final int colon = rest.indexOf(':');
  final int count = colon < 0 ? 0 : int.tryParse(rest.substring(0, colon)) ?? 0;
  final String bookKey = colon < 0 ? rest : rest.substring(colon + 1);
  final Object? raw = await kit.callRoute(
    'GET',
    '/api/admin/online/manga-downloads',
    body: <String, Object?>{'book': bookKey},
  );
  final List<Map<String, Object?>> jobs =
      <Map<String, Object?>>[
        for (final Object? row
            in _map(raw)['jobs'] as List<Object?>? ?? const <Object?>[])
          if (_map(row)['bookKey'] == bookKey) _map(row),
      ]..sort((Map<String, Object?> a, Map<String, Object?> b) {
        final int byTime = ((b['createdAt'] as num?) ?? 0).compareTo(
          (a['createdAt'] as num?) ?? 0,
        );
        return byTime != 0 ? byTime : '${b['id']}'.compareTo('${a['id']}');
      });
  final List<Map<String, Object?>> batch = jobs.take(count).toList();
  if (batch.isEmpty) {
    // 任务都被删了（用户清了队列）：如实报结束、不算成功。
    throw CtlFailure.notFound('manga download jobs of $bookKey are gone');
  }
  int pending = 0;
  int done = 0;
  final List<String> errors = <String>[];
  for (final Map<String, Object?> job in batch) {
    switch ('${job['status']}') {
      case 'done':
        done++;
      case 'failed' || 'cancelled':
        errors.add(
          '${job['chapter'] ?? job['id']}: '
          '${_text(job['error']) ?? job['status']}',
        );
      default:
        pending++;
    }
  }
  final Map<String, Object?> data = <String, Object?>{
    'bookKey': bookKey,
    'jobs': batch,
  };
  final String counts = '$done/${batch.length} chapters done';
  if (pending > 0) {
    return OpTaskStatus(
      terminal: false,
      summary: 'manga download: $counts',
      data: data,
    );
  }
  return OpTaskStatus(
    terminal: true,
    succeeded: errors.isEmpty,
    summary: errors.isEmpty
        ? 'manga download finished: $counts'
        : 'manga download finished: $counts; '
              '${errors.length} failed (${jsonEncode(errors.take(3).toList())})',
    data: data,
  );
}

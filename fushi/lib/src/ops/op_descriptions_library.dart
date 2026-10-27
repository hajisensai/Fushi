import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_task_status.dart';

/// 书库 / 漫画库管理、合集、阅读器、有声书、漫画 OCR、库整理的操作描述（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）。
///
/// 覆盖 `buildLibraryCtlRoutes` 返回的全部路由。撤销只拼现有路由：
/// - 改值（合集 / 标签 / 来源改名、读完标记、合集定序、阅读位置）= 执行前快照，撤销写回；
/// - 新建（合集、标签、书签、导入、加来源、转录任务）= 删掉 / 取消刚建的那个；
/// - 打 / 摘标签、加 / 移成员 = 反向路由；
/// - 库整理直接挂到它已有的 `organize-undo`（[spec §5.3]），不重写。
/// 真删除（条目、合集、标签、书签、收藏句）、重置进度、换封面、有声书换音频 / 字幕、
/// 重新匹配、可能上传给 Google Lens 的 OCR 都撤销不了，标 irreversible。
List<OpDescription> describeLibraryOps(OpDescribeKit kit) => <OpDescription>[
  ..._describeItemOps(kit),
  ..._describeCollectionOps(kit),
  ..._describeTagOps(kit),
  ..._describeShelfMiscOps(kit),
  ..._describeSourceOps(kit),
  ..._describeReaderOps(kit),
  ..._describeAudiobookOps(kit),
  ..._describeMangaOcrOps(kit),
  ..._describeOrganizeOps(kit),
];

// ─────────────────────────────────────────────────────────────────────────
// 通用撤销形态（视频域描述也用；可能值得提进 OpDescribeKit）
// ─────────────────────────────────────────────────────────────────────────

/// 撤销闭包看到的调用范围：路径参数 + 撤销关心的 body 字段（kit 的
/// [OpDescribeKit.snapshotUndo] 只带路径参数，读写要 body 里的定位字段时用这个）。
typedef OpUndoScope = ({Map<String, String> params, Map<String, Object?> body});

/// [opScopedSnapshotUndo] 的 `newValue` 返回它 = 这次执行什么也没改（如 dry-run），
/// 撤销直接算完成。
const String kOpUndoNoop = '__fushi_op_undo_noop__';

OpUndoScope _scopeOf(CtlCall call, List<String> bodyKeys) => (
  params: Map<String, String>.of(call.params),
  body: <String, Object?>{
    for (final String k in bodyKeys)
      if (call.body[k] != null) k: call.body[k],
  },
);

/// 从持久化的撤销载荷里还原 [OpUndoScope]（JSON 往返后类型会松）。
OpUndoScope opUndoScopeFromPayload(Map<String, Object?> payload) => (
  params: <String, String>{
    for (final MapEntry<Object?, Object?> e
        in (payload['params'] as Map? ?? const <Object?, Object?>{}).entries)
      '${e.key}': '${e.value}',
  },
  body: <String, Object?>{
    for (final MapEntry<Object?, Object?> e
        in (payload['body'] as Map? ?? const <Object?, Object?>{}).entries)
      '${e.key}': e.value,
  },
);

/// 把 [CtlFailure] 变成撤销结论（404 = 对象已不在 → superseded）。
Future<OpUndoOutcome> opUndoGuard(Future<OpUndoOutcome> Function() body) async {
  try {
    return await body();
  } on CtlFailure catch (failure) {
    return failure.status == 404
        ? OpUndoOutcome.superseded(failure.message)
        : OpUndoOutcome.failed(failure.message ?? failure.code);
  }
}

/// 给人看的「改前 / 改后」。
String? opUndoDisplay(Object? value) {
  if (value == null || value == kOpUndoNoop) return null;
  final String text = value is String ? value : jsonEncode(value);
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

/// 快照撤销（body 感知版 [OpDescribeKit.snapshotUndo]）：执行前 [read] 旧值，撤销
/// 前再读一次——当前值（经 [compareBy] 投影后）不等于这次执行的结果就报
/// superseded、不覆盖用户之后的修改；否则 [write] 写回旧值。
OpUndo opScopedSnapshotUndo({
  List<String> bodyKeys = const <String>[],
  required Future<Object?> Function(OpUndoScope scope) read,
  required Future<void> Function(OpUndoScope scope, Object? old) write,
  required Object? Function(CtlCall call, Object? result) newValue,
  Object? Function(Object? value)? compareBy,
}) {
  Object? project(Object? v) => compareBy == null ? v : compareBy(v);
  return OpUndo(
    capture: (CtlCall call) async {
      final OpUndoScope scope = _scopeOf(call, bodyKeys);
      return <String, Object?>{
        'params': scope.params,
        'body': scope.body,
        'old': await read(scope),
      };
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final Object? after = newValue(call, result);
      return OpUndoRecord(
        payload: <String, Object?>{...before, 'new': after},
        before: opUndoDisplay(project(before['old'])),
        after: after == kOpUndoNoop ? null : opUndoDisplay(project(after)),
      );
    },
    revert: (Map<String, Object?> payload) => opUndoGuard(() async {
      if (payload['new'] == kOpUndoNoop) return const OpUndoOutcome.done();
      final OpUndoScope scope = opUndoScopeFromPayload(payload);
      if (!OpDescribeKit.sameJson(
        project(await read(scope)),
        project(payload['new']),
      )) {
        return const OpUndoOutcome.superseded();
      }
      await write(scope, payload['old']);
      return const OpUndoOutcome.done();
    }),
  );
}

/// 自定义撤销：[capture]（可空）抓前态，[payloadOf] 用前态 + 结果拼载荷，
/// [revert] 自己判 done / superseded / failed（[CtlFailure] 统一兜成结论）。
OpUndo opCustomUndo({
  Future<Map<String, Object?>> Function(CtlCall call)? capture,
  required Map<String, Object?> Function(
    CtlCall call,
    Map<String, Object?> before,
    Object? result,
  )
  payloadOf,
  required Future<OpUndoOutcome> Function(Map<String, Object?> payload) revert,
  String? Function(Map<String, Object?> payload)? describe,
}) => OpUndo(
  capture: capture,
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<String, Object?> payload = payloadOf(call, before, result);
    return OpUndoRecord(payload: payload, after: describe?.call(payload));
  },
  revert: (Map<String, Object?> payload) => opUndoGuard(() => revert(payload)),
);

/// 字符串列表（JSON 往返后的 `List<dynamic>` 也认）。
List<String> opUndoStrings(Object? raw) => <String>[
  if (raw is List)
    for (final Object? item in raw)
      if (item != null) '$item',
];

Map<String, Object?> _map(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : const <String, Object?>{};

List<Map<String, Object?>> _rows(Object? raw) => <Map<String, Object?>>[
  if (raw is List)
    for (final Object? item in raw)
      if (item is Map) _map(item),
];

/// 结果里 `results` 数组中状态为 [status] 的那一列字段值。
List<String> _resultField(Object? result, String status, String field) =>
    <String>[
      for (final Map<String, Object?> row in _rows(_map(result)['results']))
        if (row['status'] == status && row[field] != null) '${row[field]}',
    ];

// ─────────────────────────────────────────────────────────────────────────
// 路径
// ─────────────────────────────────────────────────────────────────────────

const String _root = '/api/admin/library';
const String _items = '$_root/items';
const String _item = '$_items/:key';
const String _collections = '$_root/collections';
const String _collection = '$_collections/:id';
const String _tags = '$_root/tags';
const String _sources = '$_root/sources';
const String _reader = '$_root/reader';
const String _abTasks = '$_root/audiobook/tasks';
const String _abJobs = '$_root/audiobook/jobs';
const String _ocr = '$_root/ocr';
const String _organize = '$_root/organize';

const String _keyHelp =
    'Library item key "<store>:<id>" (book:/srt:/video:/game:) from library.item.list.';

const OpParam _keyParam = OpParam.string(
  'key',
  description: _keyHelp,
  required: true,
  inPath: true,
);

const OpParam _collectionIdParam = OpParam.string(
  'id',
  description: 'Collection id from library.collection.list.',
  required: true,
  inPath: true,
);

const OpParam _confirmGate = OpParam.userGate(
  'confirm',
  description: 'User confirmed this destructive step.',
);

// ─────────────────────────────────────────────────────────────────────────
// 条目：列 / 查 / 删 / 打开 / 导入 / 最近 / 扫描
// ─────────────────────────────────────────────────────────────────────────

/// 删掉一条刚导入 / 刚扫进来的条目（只删库里的行，不删磁盘文件、不传播删除）。
/// 已不在 = true（算「已经不在了」），删掉 = false。
Future<bool> _removeEntryKeepFiles(OpDescribeKit kit, String key) async {
  try {
    await kit.callRoute(
      'DELETE',
      _item,
      params: <String, String>{'key': key},
      body: const <String, Object?>{'confirm': true},
    );
    return false;
  } on CtlFailure catch (failure) {
    if (failure.status == 404) return true;
    rethrow;
  }
}

/// 撤销「加来源」：先删掉这个来源扫进来的条目（库里的行，不动磁盘），再移除来源。
/// 来源已不在 = superseded。
Future<OpUndoOutcome> _revertSourceAdd(OpDescribeKit kit, int sourceId) async {
  final Object? listed = await kit.callRoute('GET', _sources);
  final Map<String, Object?>? source = _rows(
    _map(listed)['sources'],
  ).where((Map<String, Object?> s) => '${s['id']}' == '$sourceId').firstOrNull;
  if (source == null) {
    return OpUndoOutcome.superseded('source $sourceId is already gone');
  }
  final String? kind = switch (source['kind']) {
    'book' => 'book,pdf,audiobook',
    'manga' => 'manga',
    'video' => 'video',
    _ => null,
  };
  if (kind != null) {
    final Object? items = await kit.callRoute(
      'GET',
      _items,
      body: <String, Object?>{'kind': kind},
    );
    for (final Map<String, Object?> row in _rows(_map(items)['items'])) {
      final String key = '${row['key']}';
      final Object? detail = await kit.callRoute(
        'GET',
        _item,
        params: <String, String>{'key': key},
      );
      if ('${_map(detail)['sourceId']}' == '$sourceId') {
        await _removeEntryKeepFiles(kit, key);
      }
    }
  }
  await kit.callRoute(
    'DELETE',
    '$_sources/:id',
    params: <String, String>{'id': '$sourceId'},
    body: const <String, Object?>{'confirm': true},
  );
  return const OpUndoOutcome.done();
}

final RegExp _sourceIdInMessage = RegExp(r'id=(\d+)');
final RegExp _jobIdInMessage = RegExp(r'（任务 ([^）\s]+)）');

List<OpDescription> _describeItemOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'library.item.list',
    method: 'GET',
    pattern: _items,
    summary:
        'List library items (books, PDFs, manga, audiobooks, videos, games) with '
        'key, kind, title, progress and completion. Hidden modules are skipped.',
    params: <OpParam>[
      OpParam.string(
        'kind',
        description:
            'Comma-separated kinds: book, pdf, manga, audiobook, video, game.',
      ),
      OpParam.string('search', description: 'Title / author search text.'),
      OpParam.integer('limit', description: 'Max items to return.'),
    ],
  ),
  const OpDescription(
    id: 'library.item.get',
    method: 'GET',
    pattern: _item,
    summary:
        'Read one library item: title, format, progress, completion, paths, '
        'source library id and the paired audiobook / book key.',
    params: <OpParam>[_keyParam],
  ),
  const OpDescription(
    id: 'library.item.remove',
    method: 'DELETE',
    pattern: _item,
    summary:
        'Delete a library item (hard delete, like the library page delete '
        'dialog). Optionally also deletes its local audio / video files, its '
        'statistics, and propagates the deletion to synced devices.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _keyParam,
      OpParam.boolean(
        'everywhere',
        description: 'Also delete on all synced devices.',
      ),
      OpParam.boolean(
        'deleteFiles',
        description:
            'Also delete the local media files on disk (audio / video).',
      ),
      OpParam.boolean(
        'deleteStatistics',
        description: 'Also delete the reading / watching statistics.',
      ),
      _confirmGate,
    ],
  ),
  const OpDescription(
    id: 'library.item.open',
    method: 'POST',
    pattern: '$_item/open',
    summary:
        'Open an item in the app (reader, manga series page, video player or '
        'game detail page) like tapping its card. Navigation only; brings the '
        'main window to the foreground.',
    params: <OpParam>[
      _keyParam,
      OpParam.string(
        'at',
        description:
            'Video: timestamp (seconds, m:ss, h:mm:ss). EPUB: legacy chapter number.',
      ),
      OpParam.integer(
        'chapter',
        description:
            'EPUB chapter / online manga episode to open at (1-based).',
      ),
      OpParam.integer(
        'page',
        description: 'PDF / manga page to open at (1-based).',
      ),
      OpParam.number(
        'progress',
        description: 'EPUB in-chapter percent 0-100 (with chapter).',
      ),
    ],
  ),
  OpDescription(
    id: 'library.item.import',
    method: 'POST',
    pattern: '$_root/import',
    summary:
        'Import files or folders into the library (EPUB / PDF / manga / audio / '
        'video / game exe). Folders of videos or books become source libraries. '
        'Undo removes the imported entries (files on disk are kept).',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.stringList(
        'paths',
        description: 'Absolute file or folder paths.',
        required: true,
      ),
      OpParam.string(
        'kind',
        description:
            'Force a kind: book, manga, audiobook, video, game (default: auto).',
      ),
      OpParam.string(
        'duplicate',
        description:
            'When a same-title item exists: skip (default) or suffix (keep both).',
        enumValues: <String>['skip', 'suffix'],
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'keys': <String>[
              for (final Map<String, Object?> row in _rows(
                _map(result)['results'],
              ))
                if (row['status'] == 'imported') ...opUndoStrings(row['keys']),
            ],
            'sources': <String>[
              for (final String message in _resultField(
                result,
                'source_added',
                'message',
              ))
                ?_sourceIdInMessage.firstMatch(message)?.group(1),
            ],
            'jobs': <String>[
              for (final String message in _resultField(
                result,
                'queued',
                'message',
              ))
                ?_jobIdInMessage.firstMatch(message)?.group(1),
            ],
          },
      describe: (Map<String, Object?> p) =>
          'imported ${opUndoStrings(p['keys']).length} item(s), '
          '${opUndoStrings(p['sources']).length} source(s), '
          '${opUndoStrings(p['jobs']).length} transcription job(s)',
      revert: (Map<String, Object?> payload) async {
        int gone = 0;
        int total = 0;
        for (final String key in opUndoStrings(payload['keys'])) {
          total++;
          if (await _removeEntryKeepFiles(kit, key)) gone++;
        }
        for (final String id in opUndoStrings(payload['sources'])) {
          total++;
          final OpUndoOutcome outcome = await _revertSourceAdd(
            kit,
            int.parse(id),
          );
          if (outcome.status == OpUndoStatus.superseded) gone++;
        }
        for (final String id in opUndoStrings(payload['jobs'])) {
          total++;
          await kit.callRoute(
            'POST',
            '$_abJobs/:id/cancel',
            params: <String, String>{'id': id},
          );
        }
        return total > 0 && gone == total
            ? const OpUndoOutcome.superseded('imported items are already gone')
            : const OpUndoOutcome.done();
      },
    ),
  ),
  const OpDescription(
    id: 'library.history',
    method: 'GET',
    pattern: '$_root/history',
    summary: 'Recently opened items (books, videos, games), newest first.',
    params: <OpParam>[
      OpParam.integer('limit', description: 'Max items (default 20).'),
    ],
  ),
  const OpDescription(
    id: 'library.scan',
    method: 'POST',
    pattern: '$_root/scan',
    summary:
        'Rescan source libraries (folders) for new / changed media, like the '
        'source page "Rescan" button. Does not auto-scrape videos.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.integer(
        'source',
        description: 'Only this source id (from library.source.list).',
      ),
      OpParam.string(
        'kind',
        description: 'Only sources of this kind: book, video, manga.',
        enumValues: <String>['book', 'video', 'manga'],
      ),
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 合集
// ─────────────────────────────────────────────────────────────────────────

/// 合集详情里成员的定序 token：条目键，未知种类退回 `<mediaType>|<entryKey>`
/// （与定序路由认的键同形）。
List<String> _memberTokens(Object? detail) => <String>[
  for (final Map<String, Object?> item in _rows(_map(detail)['items']))
    item['key'] == null
        ? '${item['mediaType']}|${item['entryKey']}'
        : '${item['key']}',
];

Future<Object?> _collectionDetail(OpDescribeKit kit, String id) =>
    kit.callRoute('GET', _collection, params: <String, String>{'id': id});

/// 合集定序的快照撤销：旧顺序整表写回（手动定序路由）。
OpUndo _collectionOrderUndo(
  OpDescribeKit kit,
  Object? Function(CtlCall call, Object? result) newOrder,
) => opScopedSnapshotUndo(
  read: (OpUndoScope scope) async =>
      _memberTokens(await _collectionDetail(kit, scope.params['id']!)),
  write: (OpUndoScope scope, Object? old) async {
    final List<String> tokens = opUndoStrings(old);
    if (tokens.length < 2) return;
    await kit.callRoute(
      'PUT',
      '$_collection/order',
      params: scope.params,
      body: <String, Object?>{'keys': tokens},
    );
  },
  newValue: newOrder,
);

/// 打标签的撤销：摘掉这次加上的，再删掉这次顺手新建、此后没被别处用上的标签。
OpUndo _tagAddUndo(OpDescribeKit kit, String pattern) => opCustomUndo(
  capture: (CtlCall call) async => <String, Object?>{
    'params': call.params,
    'tagIds': <String>[
      for (final Map<String, Object?> tag in _rows(
        _map(await kit.callRoute('GET', _tags))['tags'],
      ))
        '${tag['id']}',
    ],
  },
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      <String, Object?>{
        ...before,
        'added': _resultField(result, 'added', 'tag'),
      },
  describe: (Map<String, Object?> p) =>
      'tagged: ${opUndoStrings(p['added']).join(', ')}',
  revert: (Map<String, Object?> payload) async {
    final List<String> added = opUndoStrings(payload['added']);
    if (added.isEmpty) return const OpUndoOutcome.done();
    final OpUndoScope scope = opUndoScopeFromPayload(payload);
    final Object? removed = await kit.callRoute(
      'DELETE',
      pattern,
      params: scope.params,
      body: <String, Object?>{'tags': added},
    );
    final Set<String> before = opUndoStrings(payload['tagIds']).toSet();
    for (final Map<String, Object?> tag in _rows(
      _map(await kit.callRoute('GET', _tags))['tags'],
    )) {
      if (added.contains(tag['name']) &&
          !before.contains('${tag['id']}') &&
          tag['count'] == 0) {
        await kit.callRoute(
          'DELETE',
          '$_tags/:id',
          params: <String, String>{'id': '${tag['id']}'},
          body: const <String, Object?>{'confirm': true},
        );
      }
    }
    return _resultField(removed, 'removed', 'tag').isEmpty
        ? const OpUndoOutcome.superseded('tags were already removed')
        : const OpUndoOutcome.done();
  },
);

/// 摘标签的撤销：把这次摘掉的打回去（标签此后被删了就打不回，结果里报 missing）。
OpUndo _tagRemoveUndo(OpDescribeKit kit, String pattern) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      <String, Object?>{
        'params': call.params,
        'removed': _resultField(result, 'removed', 'tag'),
      },
  describe: (Map<String, Object?> p) =>
      'untagged: ${opUndoStrings(p['removed']).join(', ')}',
  revert: (Map<String, Object?> payload) async {
    final List<String> removed = opUndoStrings(payload['removed']);
    if (removed.isEmpty) return const OpUndoOutcome.done();
    final Object? result = await kit.callRoute(
      'POST',
      pattern,
      params: opUndoScopeFromPayload(payload).params,
      body: <String, Object?>{'tags': removed},
    );
    final List<String> missing = _resultField(result, 'missing', 'tag');
    if (missing.length == removed.length) {
      return const OpUndoOutcome.superseded('the tags no longer exist');
    }
    return missing.isEmpty
        ? const OpUndoOutcome.done()
        : OpUndoOutcome.failed('tags deleted since: ${missing.join(', ')}');
  },
);

const OpParam _tagsParam = OpParam.stringList(
  'tags',
  description: 'Tag names (or ids) from library.tag.list.',
  required: true,
);

List<OpDescription> _describeCollectionOps(
  OpDescribeKit kit,
) => <OpDescription>[
  const OpDescription(
    id: 'library.collection.list',
    method: 'GET',
    pattern: _collections,
    summary:
        'List collections / playlists (id, name, type, visible member count, '
        'whether manually ordered).',
    params: <OpParam>[
      OpParam.string(
        'key',
        description: 'Only collections containing this item key.',
      ),
    ],
  ),
  OpDescription(
    id: 'library.collection.create',
    method: 'POST',
    pattern: _collections,
    summary:
        'Create a collection (reuses an existing one with the same name and '
        'type; then existed=true). Undo deletes it if it is still empty.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string('name', description: 'Collection name.', required: true),
      OpParam.string(
        'type',
        description: 'collection (default) or playlist.',
        enumValues: <String>['collection', 'playlist'],
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'id': '${_map(result)['id']}',
            'existed': _map(result)['existed'] == true,
          },
      describe: (Map<String, Object?> p) => 'collection ${p['id']}',
      revert: (Map<String, Object?> payload) async {
        if (payload['existed'] == true) return const OpUndoOutcome.done();
        final String id = '${payload['id']}';
        final Object? detail = await _collectionDetail(kit, id);
        if (_rows(_map(detail)['items']).isNotEmpty) {
          return const OpUndoOutcome.superseded(
            'the collection has members now',
          );
        }
        await kit.callRoute(
          'DELETE',
          _collection,
          params: <String, String>{'id': id},
          body: const <String, Object?>{'confirm': true},
        );
        return const OpUndoOutcome.done();
      },
    ),
  ),
  const OpDescription(
    id: 'library.collection.get',
    method: 'GET',
    pattern: _collection,
    summary:
        'Collection detail: members in order (item key, title, visible), tags.',
    params: <OpParam>[_collectionIdParam],
  ),
  OpDescription(
    id: 'library.collection.rename',
    method: 'PUT',
    pattern: _collection,
    summary: 'Rename a collection.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _collectionIdParam,
      OpParam.string('name', description: 'New name.', required: true),
    ],
    undo: kit.readBackUndo(
      readMethod: 'GET',
      readPattern: _collection,
      writeMethod: 'PUT',
      writePattern: _collection,
      field: 'name',
    ),
  ),
  const OpDescription(
    id: 'library.collection.remove',
    method: 'DELETE',
    pattern: _collection,
    summary:
        'Delete a collection (its member references, tags and own cover file; '
        'the items themselves stay in the library).',
    risk: OpRisk.irreversible,
    params: <OpParam>[_collectionIdParam, _confirmGate],
  ),
  OpDescription(
    id: 'library.collection.add',
    method: 'POST',
    pattern: '$_collection/members',
    summary:
        'Add items to a collection (all members must belong to the same library '
        'page: books / manga / videos / games).',
    risk: OpRisk.write,
    params: const <OpParam>[
      _collectionIdParam,
      OpParam.stringList(
        'keys',
        description: 'Item keys from library.item.list.',
        required: true,
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'id': call.params['id'],
            'added': _resultField(result, 'added', 'key'),
          },
      describe: (Map<String, Object?> p) =>
          'added ${opUndoStrings(p['added']).length} member(s)',
      revert: (Map<String, Object?> payload) async {
        final List<String> added = opUndoStrings(payload['added']);
        if (added.isEmpty) return const OpUndoOutcome.done();
        final Object? result = await kit.callRoute(
          'DELETE',
          '$_collection/members',
          params: <String, String>{'id': '${payload['id']}'},
          body: <String, Object?>{'keys': added},
        );
        return _resultField(result, 'removed', 'key').isEmpty
            ? const OpUndoOutcome.superseded('members were already removed')
            : const OpUndoOutcome.done();
      },
    ),
  ),
  OpDescription(
    id: 'library.collection.remove-members',
    method: 'DELETE',
    pattern: '$_collection/members',
    summary:
        'Remove items from a collection (the items stay in the library). A '
        'collection emptied this way is deleted automatically.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _collectionIdParam,
      OpParam.stringList(
        'keys',
        description: 'Member item keys from library.collection.get.',
        required: true,
      ),
    ],
    undo: opCustomUndo(
      capture: (CtlCall call) async {
        final Object? detail = await _collectionDetail(kit, call.params['id']!);
        return <String, Object?>{
          'order': _memberTokens(detail),
          'manualOrder': _map(detail)['manualOrder'] == true,
        };
      },
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            ...before,
            'id': call.params['id'],
            'removed': _resultField(result, 'removed', 'key'),
            'collectionDeleted': _map(result)['collectionDeleted'] == true,
          },
      describe: (Map<String, Object?> p) =>
          'removed ${opUndoStrings(p['removed']).length} member(s)',
      revert: (Map<String, Object?> payload) async {
        final List<String> removed = opUndoStrings(payload['removed']);
        if (removed.isEmpty) return const OpUndoOutcome.done();
        if (payload['collectionDeleted'] == true) {
          return const OpUndoOutcome.failed(
            'the collection was deleted automatically when it became empty',
          );
        }
        final Map<String, String> params = <String, String>{
          'id': '${payload['id']}',
        };
        await kit.callRoute(
          'POST',
          '$_collection/members',
          params: params,
          body: <String, Object?>{'keys': removed},
        );
        if (payload['manualOrder'] == true) {
          final Set<String> present = _memberTokens(
            await _collectionDetail(kit, '${payload['id']}'),
          ).toSet();
          final List<String> order = <String>[
            for (final String token in opUndoStrings(payload['order']))
              if (present.contains(token)) token,
          ];
          if (order.length > 1) {
            await kit.callRoute(
              'PUT',
              '$_collection/order',
              params: params,
              body: <String, Object?>{'keys': order},
            );
          }
        }
        return const OpUndoOutcome.done();
      },
    ),
  ),
  const OpDescription(
    id: 'library.collection.cover',
    method: 'PUT',
    pattern: '$_collection/cover',
    summary:
        'Set a collection\'s own cover from a local image or an http(s) URL, or '
        'reset it (fall back to member covers). The previous own cover file is '
        'replaced.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _collectionIdParam,
      OpParam.string('path', description: 'Absolute local image path.'),
      OpParam.string('url', description: 'http(s) image URL.'),
      OpParam.boolean('reset', description: 'Clear the own cover.'),
    ],
  ),
  OpDescription(
    id: 'library.collection.tag',
    method: 'POST',
    pattern: '$_collection/tags',
    summary: 'Add tags to a collection.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _collectionIdParam,
      _tagsParam,
      OpParam.boolean(
        'create',
        description: 'Create tags that do not exist yet.',
      ),
    ],
    undo: _tagAddUndo(kit, '$_collection/tags'),
  ),
  OpDescription(
    id: 'library.collection.untag',
    method: 'DELETE',
    pattern: '$_collection/tags',
    summary: 'Remove tags from a collection.',
    risk: OpRisk.write,
    params: const <OpParam>[_collectionIdParam, _tagsParam],
    undo: _tagRemoveUndo(kit, '$_collection/tags'),
  ),
  OpDescription(
    id: 'library.collection.order',
    method: 'PUT',
    pattern: '$_collection/order',
    summary:
        'Manually reorder collection members: listed keys take the listed order, '
        'unlisted members keep their slots. Switches the collection to manual order.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _collectionIdParam,
      OpParam.stringList(
        'keys',
        description:
            'Member keys in the wanted order (library.collection.get).',
        required: true,
      ),
    ],
    undo: _collectionOrderUndo(
      kit,
      (CtlCall call, Object? result) => _memberTokens(result),
    ),
  ),
  OpDescription(
    id: 'library.collection.sort',
    method: 'POST',
    pattern: '$_collection/sort',
    summary:
        'One-key sort of collection members by title, import time, or AI (uses '
        'the LLM assigned to collection sorting). dryRun only previews.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _collectionIdParam,
      OpParam.string(
        'by',
        description: 'title, imported or ai.',
        required: true,
        enumValues: <String>['title', 'imported', 'ai'],
      ),
      OpParam.boolean('dryRun', description: 'Preview without saving.'),
    ],
    undo: _collectionOrderUndo(kit, (CtlCall call, Object? result) {
      final Map<String, Object?> r = _map(result);
      if (r['persisted'] != true) return kOpUndoNoop;
      return <String>[
        for (final Map<String, Object?> row in _rows(r['order']))
          '${row['key']}',
      ];
    }),
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 标签
// ─────────────────────────────────────────────────────────────────────────

const OpParam _tagIdParam = OpParam.string(
  'id',
  description: 'Tag id from library.tag.list.',
  required: true,
  inPath: true,
);

List<OpDescription> _describeTagOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'library.tag.list',
    method: 'GET',
    pattern: _tags,
    summary: 'List tags with id, name, color and usage count.',
  ),
  OpDescription(
    id: 'library.tag.create',
    method: 'POST',
    pattern: _tags,
    summary: 'Create a tag. Undo deletes it while it is still unused.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string('name', description: 'Tag name.', required: true),
      OpParam.string('color', description: 'Color #RRGGBB (optional).'),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{'id': '${_map(result)['id']}'},
      describe: (Map<String, Object?> p) => 'tag ${p['id']}',
      revert: (Map<String, Object?> payload) async {
        final String id = '${payload['id']}';
        final Map<String, Object?>? tag = _rows(
          _map(await kit.callRoute('GET', _tags))['tags'],
        ).where((Map<String, Object?> t) => '${t['id']}' == id).firstOrNull;
        if (tag == null) {
          return const OpUndoOutcome.superseded('the tag is already gone');
        }
        if (tag['count'] != 0) {
          return const OpUndoOutcome.superseded('the tag is in use now');
        }
        await kit.callRoute(
          'DELETE',
          '$_tags/:id',
          params: <String, String>{'id': id},
          body: const <String, Object?>{'confirm': true},
        );
        return const OpUndoOutcome.done();
      },
    ),
  ),
  OpDescription(
    id: 'library.tag.edit',
    method: 'PUT',
    pattern: '$_tags/:id',
    summary: 'Rename a tag and / or change its color.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _tagIdParam,
      OpParam.string('name', description: 'New name.'),
      OpParam.string('color', description: 'New color #RRGGBB.'),
    ],
    undo: opScopedSnapshotUndo(
      read: (OpUndoScope scope) async {
        final Map<String, Object?> tag =
            _rows(_map(await kit.callRoute('GET', _tags))['tags']).firstWhere(
              (Map<String, Object?> t) => '${t['id']}' == scope.params['id'],
              orElse: () => throw CtlFailure.notFound(
                'tag ${scope.params['id']} is gone',
              ),
            );
        return <String, Object?>{'name': tag['name'], 'color': tag['color']};
      },
      write: (OpUndoScope scope, Object? old) async {
        await kit.callRoute(
          'PUT',
          '$_tags/:id',
          params: scope.params,
          body: _map(old),
        );
      },
      newValue: (CtlCall call, Object? result) => <String, Object?>{
        'name': _map(result)['name'],
        'color': _map(result)['color'],
      },
    ),
  ),
  const OpDescription(
    id: 'library.tag.remove',
    method: 'DELETE',
    pattern: '$_tags/:id',
    summary: 'Delete a tag everywhere (all items and collections lose it).',
    risk: OpRisk.irreversible,
    params: <OpParam>[_tagIdParam, _confirmGate],
  ),
  const OpDescription(
    id: 'library.item.tags',
    method: 'GET',
    pattern: '$_item/tags',
    summary: 'Tags of one library item.',
    params: <OpParam>[_keyParam],
  ),
  OpDescription(
    id: 'library.item.tag',
    method: 'POST',
    pattern: '$_item/tags',
    summary: 'Add tags to a library item.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _keyParam,
      _tagsParam,
      OpParam.boolean(
        'create',
        description: 'Create tags that do not exist yet.',
      ),
    ],
    undo: _tagAddUndo(kit, '$_item/tags'),
  ),
  OpDescription(
    id: 'library.item.untag',
    method: 'DELETE',
    pattern: '$_item/tags',
    summary: 'Remove tags from a library item.',
    risk: OpRisk.write,
    params: const <OpParam>[_keyParam, _tagsParam],
    undo: _tagRemoveUndo(kit, '$_item/tags'),
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 书签 / 收藏句 / 改名 / 封面 / 读完 / 重置
// ─────────────────────────────────────────────────────────────────────────

Future<Map<String, Object?>> _itemDetail(OpDescribeKit kit, String key) async =>
    _map(
      await kit.callRoute('GET', _item, params: <String, String>{'key': key}),
    );

List<OpDescription> _describeShelfMiscOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'library.bookmark.list',
    method: 'GET',
    pattern: '$_item/bookmarks',
    summary: 'Bookmarks of a book / PDF / manga / audiobook.',
    params: <OpParam>[_keyParam],
  ),
  OpDescription(
    id: 'library.bookmark.add',
    method: 'POST',
    pattern: '$_item/bookmarks',
    summary:
        'Add a bookmark: EPUB by chapter (+ in-chapter progress), PDF / local '
        'manga by page.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _keyParam,
      OpParam.integer('chapter', description: 'EPUB chapter (1-based).'),
      OpParam.integer('page', description: 'PDF / manga page (1-based).'),
      OpParam.number('progress', description: 'EPUB in-chapter percent 0-100.'),
      OpParam.string('label', description: 'Bookmark label.'),
    ],
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => <String, Object?>{
        'id': '${_map(result)['id']}',
      },
      inverse: (Map<String, Object?> payload) => kit.callRoute(
        'DELETE',
        '$_root/bookmarks/:id',
        params: <String, String>{'id': '${payload['id']}'},
      ),
      describe: (Map<String, Object?> p) => 'bookmark ${p['id']}',
    ),
  ),
  const OpDescription(
    id: 'library.bookmark.remove',
    method: 'DELETE',
    pattern: '$_root/bookmarks/:id',
    summary: 'Delete a bookmark.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Bookmark id from library.bookmark.list.',
        required: true,
        inPath: true,
      ),
    ],
  ),
  const OpDescription(
    id: 'library.favorite.list',
    method: 'GET',
    pattern: '$_root/favorites',
    summary: 'Favorite sentences (optionally of one item).',
    params: <OpParam>[
      OpParam.string('key', description: 'Only favorites of this item key.'),
      OpParam.integer('limit', description: 'Max rows.'),
    ],
  ),
  const OpDescription(
    id: 'library.favorite.remove',
    method: 'DELETE',
    pattern: '$_root/favorites/:id',
    summary: 'Delete one favorite sentence.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Favorite id from library.favorite.list.',
        required: true,
        inPath: true,
      ),
    ],
  ),
  const OpDescription(
    id: 'library.favorite.clear',
    method: 'POST',
    pattern: '$_root/favorites/clear',
    summary: 'Delete all favorite sentences.',
    risk: OpRisk.irreversible,
    params: <OpParam>[_confirmGate],
  ),
  const OpDescription(
    id: 'library.favorite.export',
    method: 'POST',
    pattern: '$_root/favorites/export',
    summary:
        'Export favorite sentences to a file (markdown / txt / csv / json). '
        'Overwrites the target file.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute output file path.',
        required: true,
      ),
      OpParam.string(
        'format',
        description: 'markdown (default), md, txt, csv or json.',
        enumValues: <String>['markdown', 'md', 'txt', 'csv', 'json'],
      ),
      OpParam.string('key', description: 'Only favorites of this item key.'),
      OpParam.boolean('dedupe', description: 'Drop duplicate sentences.'),
    ],
  ),
  OpDescription(
    id: 'library.item.rename',
    method: 'PUT',
    pattern: '$_item/title',
    summary:
        'Rename a book / audiobook (display-name override; reset=true restores '
        'the original) or a video (changes its title).',
    risk: OpRisk.write,
    params: const <OpParam>[
      _keyParam,
      OpParam.string('title', description: 'New title.'),
      OpParam.boolean(
        'reset',
        description: 'Books only: clear the override, show the original title.',
      ),
    ],
    undo: opScopedSnapshotUndo(
      read: (OpUndoScope scope) async {
        final Map<String, Object?> detail = await _itemDetail(
          kit,
          scope.params['key']!,
        );
        return <String, Object?>{
          'title': detail['title'],
          'rawTitle': detail['rawTitle'],
        };
      },
      write: (OpUndoScope scope, Object? old) async {
        final Map<String, Object?> before = _map(old);
        final bool isVideo = scope.params['key']!.startsWith('video:');
        await kit.callRoute(
          'PUT',
          '$_item/title',
          params: scope.params,
          body: !isVideo && before['title'] == before['rawTitle']
              ? const <String, Object?>{'reset': true}
              : <String, Object?>{'title': before['title']},
        );
      },
      newValue: (CtlCall call, Object? result) => <String, Object?>{
        'title': _map(result)['title'],
      },
      compareBy: (Object? v) => _map(v)['title'],
    ),
  ),
  const OpDescription(
    id: 'library.item.cover',
    method: 'PUT',
    pattern: '$_item/cover',
    summary:
        'Replace an item\'s cover with a local image or an http(s) URL (books: '
        'reset=true clears the override). The previous override file is replaced.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _keyParam,
      OpParam.string('path', description: 'Absolute local image path.'),
      OpParam.string('url', description: 'http(s) image URL.'),
      OpParam.boolean('reset', description: 'Books only: clear the override.'),
    ],
  ),
  OpDescription(
    id: 'library.item.complete',
    method: 'PUT',
    pattern: '$_item/completed',
    summary:
        'Mark a book / audiobook as finished or not finished, or a video as '
        'watched (videos cannot be un-marked here).',
    risk: OpRisk.write,
    params: const <OpParam>[
      _keyParam,
      OpParam.boolean(
        'completed',
        description: 'true = finished.',
        required: true,
      ),
    ],
    undo: opScopedSnapshotUndo(
      read: (OpUndoScope scope) async =>
          (await _itemDetail(kit, scope.params['key']!))['completed'] == true,
      write: (OpUndoScope scope, Object? old) async {
        await kit.callRoute(
          'PUT',
          '$_item/completed',
          params: scope.params,
          body: <String, Object?>{'completed': old == true},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          _map(result)['completed'] == true,
    ),
  ),
  const OpDescription(
    id: 'library.item.reset',
    method: 'POST',
    pattern: '$_item/reset',
    summary:
        'Reset reading / watching progress to the start and clear "finished"; '
        'stats=last also removes the last session, stats=all all study records.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _keyParam,
      OpParam.string(
        'stats',
        description: 'keep (default), last or all.',
        enumValues: <String>['keep', 'last', 'all'],
      ),
      _confirmGate,
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 来源库
// ─────────────────────────────────────────────────────────────────────────

List<OpDescription> _describeSourceOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'library.source.list',
    method: 'GET',
    pattern: _sources,
    summary:
        'List source libraries (scanned folders): id, label, kind, path, media '
        'count, last scan.',
    params: <OpParam>[
      OpParam.string(
        'kind',
        description: 'book, video or manga.',
        enumValues: <String>['book', 'video', 'manga'],
      ),
    ],
  ),
  OpDescription(
    id: 'library.source.add',
    method: 'POST',
    pattern: _sources,
    summary:
        'Register a local folder as a source library and scan it. Undo removes '
        'the source and the entries it imported (files on disk are kept).',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute folder path.',
        required: true,
      ),
      OpParam.string(
        'kind',
        description: 'book, video or manga.',
        required: true,
        enumValues: <String>['book', 'video', 'manga'],
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'added': _map(result)['added'] == true,
            'id': _map(result)['id'],
          },
      describe: (Map<String, Object?> p) => 'source ${p['id']}',
      revert: (Map<String, Object?> payload) async {
        final int? id = int.tryParse('${payload['id']}');
        if (payload['added'] != true || id == null) {
          return const OpUndoOutcome.done();
        }
        return _revertSourceAdd(kit, id);
      },
    ),
  ),
  OpDescription(
    id: 'library.source.rename',
    method: 'PUT',
    pattern: '$_sources/:id',
    summary: 'Rename a source library.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Source id from library.source.list.',
        required: true,
        inPath: true,
      ),
      OpParam.string('label', description: 'New label.', required: true),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) => kit.readListField(
        pattern: _sources,
        listKey: 'sources',
        id: params['id']!,
        field: 'label',
      ),
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'PUT',
          '$_sources/:id',
          params: params,
          body: <String, Object?>{'label': old},
        );
      },
      newValue: (CtlCall call, Object? result) => _map(result)['label'],
    ),
  ),
  const OpDescription(
    id: 'library.source.remove',
    method: 'DELETE',
    pattern: '$_sources/:id',
    summary:
        'Remove a source library (its entries stay; video download '
        'subscriptions move to migrateTo or are disabled).',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Source id from library.source.list.',
        required: true,
        inPath: true,
      ),
      OpParam.integer(
        'migrateTo',
        description: 'Another video source id to move downloads to.',
      ),
      _confirmGate,
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 阅读会话遥控
// ─────────────────────────────────────────────────────────────────────────

/// 阅读位置的比较投影（同一本书 + 章 / 页 + 章内进度）。
Object? _readerPosition(Object? snapshot) {
  final Map<String, Object?> s = _map(snapshot);
  if (s['active'] != true) return null;
  return <String, Object?>{
    'key': s['key'],
    'chapter': s['chapter'],
    'page': s['page'],
    'chapterProgress': s['chapterProgress'],
  };
}

/// 翻页 / 跳转会覆盖续读位置：撤销把阅读器跳回执行前的位置。
OpUndo _readerPositionUndo(OpDescribeKit kit) => opScopedSnapshotUndo(
  read: (OpUndoScope scope) => kit.callRoute('GET', _reader),
  write: (OpUndoScope scope, Object? old) async {
    final Map<String, Object?> before = _map(old);
    final Map<String, Object?> now = _map(await kit.callRoute('GET', _reader));
    if (before['active'] != true) return;
    if (now['key'] != before['key']) {
      throw const CtlFailure.conflict('another book is open now');
    }
    Future<void> go(Map<String, Object?> body) async {
      await kit.callRoute('POST', '$_reader/goto', body: body);
    }

    switch (before['kind']) {
      case 'epub':
        if (before['chapter'] != null) {
          await go(<String, Object?>{
            'chapter': before['chapter'],
            'progress': before['chapterProgress'] ?? 0,
          });
        } else if (before['percent'] != null) {
          await go(<String, Object?>{'percent': before['percent']});
        }
      case 'manga':
        if (before['chapterCount'] != null &&
            before['chapter'] != null &&
            now['chapter'] != before['chapter']) {
          await go(<String, Object?>{'chapter': before['chapter']});
        }
        if (before['page'] != null) {
          await go(<String, Object?>{'page': before['page']});
        }
      default:
        if (before['page'] != null) {
          await go(<String, Object?>{'page': before['page']});
        }
    }
  },
  newValue: (CtlCall call, Object? result) => result,
  compareBy: _readerPosition,
);

List<OpDescription> _describeReaderOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'library.reader.status',
    method: 'GET',
    pattern: _reader,
    summary:
        'State of the open reader (EPUB / PDF / manga): book key, chapter, page, '
        'progress. active=false when no reader is open.',
  ),
  OpDescription(
    id: 'library.reader.turn',
    method: 'POST',
    pattern: '$_reader/turn',
    summary:
        'Turn pages in the open reader (moves the saved reading position). '
        'Needs a reader open in the app window.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'direction',
        description: 'next (default) or prev.',
        enumValues: <String>['next', 'prev'],
      ),
      OpParam.integer('count', description: 'Pages to turn, 1-50.'),
    ],
    undo: _readerPositionUndo(kit),
  ),
  OpDescription(
    id: 'library.reader.goto',
    method: 'POST',
    pattern: '$_reader/goto',
    summary:
        'Jump in the open reader: EPUB by chapter (+progress) or whole-book '
        'percent, PDF by page, manga by page (online works also by chapter). '
        'Moves the saved reading position. Give exactly one of chapter / page / percent.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.integer(
        'chapter',
        description: 'Chapter / episode number (1-based).',
      ),
      OpParam.integer('page', description: 'Page number (1-based).'),
      OpParam.number('percent', description: 'EPUB whole-book percent 0-100.'),
      OpParam.number(
        'progress',
        description: 'EPUB in-chapter percent 0-100 (with chapter).',
      ),
    ],
    undo: _readerPositionUndo(kit),
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 有声书
// ─────────────────────────────────────────────────────────────────────────

const OpParam _taskIdParam = OpParam.string(
  'id',
  description: 'Task id from library.audiobook.tasks.',
  required: true,
  inPath: true,
);

const OpParam _jobIdParam = OpParam.string(
  'id',
  description: 'Transcription job id from library.audiobook.jobs.',
  required: true,
  inPath: true,
);

List<OpDescription> _describeAudiobookOps(OpDescribeKit kit) {
  final OpAvailability Function() books = kit.whenModule(ModuleId.books);
  return <OpDescription>[
    OpDescription(
      id: 'library.audiobook.attach',
      method: 'POST',
      pattern: '$_item/audiobook',
      summary:
          'Attach or replace audiobook audio and / or subtitle on an EPUB book or '
          'subtitle book (replaces the stored audio / cues). Returns a task id.',
      risk: OpRisk.irreversible,
      longRunning: true,
      taskIdOf: opTaskIdFromId,
      taskStatus: (String id) => opAudiobookTaskStatus(kit, id),
      availability: books,
      params: const <OpParam>[
        _keyParam,
        OpParam.stringList('audio', description: 'Absolute audio file paths.'),
        OpParam.stringList(
          'subtitle',
          description:
              'One absolute subtitle file path (srt / vtt / ass / lrc…).',
        ),
        OpParam.boolean('wait', description: 'Wait until the task finishes.'),
      ],
    ),
    OpDescription(
      id: 'library.audiobook.rematch',
      method: 'POST',
      pattern: '$_item/audiobook/rematch',
      summary:
          'Re-match audiobook subtitle cues to the book text (rewrites the '
          'stored alignment). Returns a task id.',
      risk: OpRisk.irreversible,
      longRunning: true,
      taskIdOf: opTaskIdFromId,
      taskStatus: (String id) => opAudiobookTaskStatus(kit, id),
      availability: books,
      params: const <OpParam>[
        _keyParam,
        OpParam.integer('window', description: 'Search window (cues).'),
        OpParam.number(
          'threshold',
          description: 'Similarity threshold in (0, 1].',
        ),
        OpParam.boolean('wait', description: 'Wait until the task finishes.'),
      ],
    ),
    OpDescription(
      id: 'library.audiobook.tasks',
      method: 'GET',
      pattern: _abTasks,
      summary: 'Attach / rematch tasks of this app run.',
      availability: books,
    ),
    OpDescription(
      id: 'library.audiobook.task',
      method: 'GET',
      pattern: '$_abTasks/:id',
      summary: 'One attach / rematch task (wait=true waits until it ends).',
      availability: books,
      params: const <OpParam>[
        _taskIdParam,
        OpParam.boolean('wait', description: 'Wait until it finishes.'),
      ],
    ),
    OpDescription(
      id: 'library.audiobook.task-cancel',
      method: 'POST',
      pattern: '$_abTasks/:id/cancel',
      summary: 'Cancel an attach / rematch task before it starts writing.',
      risk: OpRisk.irreversible,
      availability: books,
      params: const <OpParam>[_taskIdParam],
    ),
    OpDescription(
      id: 'library.audiobook.jobs',
      method: 'GET',
      pattern: _abJobs,
      summary: 'On-device transcription jobs (queue persists across restarts).',
      availability: books,
    ),
    OpDescription(
      id: 'library.audiobook.transcribe',
      method: 'POST',
      pattern: _abJobs,
      summary:
          'Queue on-device transcription of audio files: with a text file the '
          'result is aligned to it, with into= it is attached to an existing '
          'book, otherwise it becomes a subtitle book. Undo cancels the job.',
      risk: OpRisk.write,
      longRunning: true,
      taskIdOf: opTaskIdFromId,
      taskStatus: (String id) => opAudiobookJobTaskStatus(kit, id),
      availability: books,
      params: const <OpParam>[
        OpParam.stringList(
          'audio',
          description: 'Absolute audio file paths, in order.',
          required: true,
        ),
        OpParam.stringList(
          'text',
          description: 'One absolute text / EPUB file to align to.',
        ),
        OpParam.string(
          'into',
          description: 'Attach to this existing book key (book: / srt:).',
        ),
        OpParam.string('title', description: 'Title for the new book.'),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async => <String, Object?>{
          'before': <String>[
            for (final Map<String, Object?> job in _rows(
              _map(await kit.callRoute('GET', _abJobs))['jobs'],
            ))
              '${job['id']}',
          ],
        },
        payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) {
          final String id = '${_map(result)['id']}';
          return <String, Object?>{
            'id': id,
            'preexisting': opUndoStrings(before['before']).contains(id),
          };
        },
        describe: (Map<String, Object?> p) => 'transcription job ${p['id']}',
        revert: (Map<String, Object?> payload) async {
          // 队列把同一组音频去重成已有任务：那就不是这次排的，撤销不碰它。
          if (payload['preexisting'] == true) {
            return const OpUndoOutcome.done();
          }
          final Map<String, String> params = <String, String>{
            'id': '${payload['id']}',
          };
          await kit.callRoute('POST', '$_abJobs/:id/cancel', params: params);
          try {
            await kit.callRoute('DELETE', '$_abJobs/:id', params: params);
          } on CtlFailure {
            // 取消还在落定：任务记录留着（已取消），不影响撤销结论。
          }
          return const OpUndoOutcome.done();
        },
      ),
    ),
    OpDescription(
      id: 'library.audiobook.job',
      method: 'GET',
      pattern: '$_abJobs/:id',
      summary: 'One transcription job.',
      availability: books,
      params: const <OpParam>[_jobIdParam],
    ),
    OpDescription(
      id: 'library.audiobook.job-cancel',
      method: 'POST',
      pattern: '$_abJobs/:id/cancel',
      summary: 'Cancel a transcription job. Undo retries it.',
      risk: OpRisk.write,
      availability: books,
      params: const <OpParam>[_jobIdParam],
      undo: kit.inverseRouteUndo(
        payloadOf: (CtlCall call, Object? result) => <String, Object?>{
          'id': call.params['id'],
        },
        inverse: (Map<String, Object?> payload) => kit.callRoute(
          'POST',
          '$_abJobs/:id/retry',
          params: <String, String>{'id': '${payload['id']}'},
        ),
      ),
    ),
    OpDescription(
      id: 'library.audiobook.job-retry',
      method: 'POST',
      pattern: '$_abJobs/:id/retry',
      summary: 'Retry a failed / cancelled transcription job. Undo cancels it.',
      risk: OpRisk.write,
      availability: books,
      params: const <OpParam>[_jobIdParam],
      undo: kit.inverseRouteUndo(
        payloadOf: (CtlCall call, Object? result) => <String, Object?>{
          'id': call.params['id'],
        },
        inverse: (Map<String, Object?> payload) => kit.callRoute(
          'POST',
          '$_abJobs/:id/cancel',
          params: <String, String>{'id': '${payload['id']}'},
        ),
      ),
    ),
    OpDescription(
      id: 'library.audiobook.job-remove',
      method: 'DELETE',
      pattern: '$_abJobs/:id',
      summary: 'Remove a finished transcription job record from the queue.',
      risk: OpRisk.irreversible,
      availability: books,
      params: const <OpParam>[_jobIdParam],
    ),
  ];
}

// ─────────────────────────────────────────────────────────────────────────
// 漫画 OCR
// ─────────────────────────────────────────────────────────────────────────

List<OpDescription> _describeMangaOcrOps(OpDescribeKit kit) {
  final OpAvailability Function() manga = kit.whenModule(ModuleId.manga);
  return <OpDescription>[
    OpDescription(
      id: 'library.ocr.status',
      method: 'GET',
      pattern: _ocr,
      summary:
          'Manga OCR jobs: all running / queued, or one manga (key) with its '
          'pending part count.',
      availability: manga,
      params: const <OpParam>[
        OpParam.string('key', description: 'Manga item key (book:...).'),
      ],
    ),
    OpDescription(
      id: 'library.ocr.start',
      method: 'POST',
      pattern: _ocr,
      summary:
          'Queue OCR for a manga (unrecognized volume / downloaded chapters; '
          'force re-runs the whole volume and drops cached page results). The '
          'engine may be Google Lens, which uploads pages to Google.',
      risk: OpRisk.irreversible,
      availability: manga,
      params: const <OpParam>[
        OpParam.string(
          'key',
          description: 'Manga item key (book:...).',
          required: true,
        ),
        OpParam.boolean(
          'force',
          description: 'Re-run the whole volume, discarding cached results.',
        ),
        OpParam.string(
          'engine',
          description:
              'Engine preference key for this run (default: user setting).',
        ),
        OpParam.userGate(
          'consentUpload',
          description: 'User agreed to upload pages to Google Lens.',
        ),
      ],
    ),
    OpDescription(
      id: 'library.ocr.cancel',
      method: 'POST',
      pattern: '$_ocr/cancel',
      summary: 'Cancel the OCR job of a manga (finished pages are kept).',
      risk: OpRisk.irreversible,
      availability: manga,
      params: const <OpParam>[
        OpParam.string(
          'key',
          description: 'Manga item key (book:...).',
          required: true,
        ),
      ],
    ),
  ];
}

// ─────────────────────────────────────────────────────────────────────────
// AI 整理库（已有撤销机制：直接挂到 organize-undo）
// ─────────────────────────────────────────────────────────────────────────

List<OpDescription> _describeOrganizeOps(OpDescribeKit kit) => <OpDescription>[
  OpDescription(
    id: 'library.organize.run',
    method: 'POST',
    pattern: _organize,
    summary:
        'AI-organize one library page into collections / series tags (sends '
        'titles, authors / brands, years and video folder names to the LLM '
        'assigned to library organizing). Undo reverts the whole run.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'domain',
        description: 'Library page to organize: books, manga, video or games.',
        required: true,
        enumValues: <String>['books', 'manga', 'video', 'games'],
      ),
      OpParam.userGate(
        'yes',
        description: 'User agreed to send library metadata to the AI provider.',
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{'runId': _map(result)['runId']},
      describe: (Map<String, Object?> p) => 'organize run ${p['runId']}',
      revert: (Map<String, Object?> payload) async {
        final Object? runId = payload['runId'];
        if (runId == null) return const OpUndoOutcome.done();
        final Object? undone = await kit.callRoute(
          'POST',
          '$_organize/runs/:id/undo',
          params: <String, String>{'id': '$runId'},
        );
        return _map(undone)['undone'] == 0
            ? const OpUndoOutcome.superseded('nothing left to undo in this run')
            : const OpUndoOutcome.done();
      },
    ),
  ),
  const OpDescription(
    id: 'library.organize.history',
    method: 'GET',
    pattern: '$_organize/runs',
    summary: 'Past AI-organize runs with their changes and undo state.',
    params: <OpParam>[
      OpParam.integer('limit', description: 'Max runs (1-200, default 20).'),
    ],
  ),
  const OpDescription(
    id: 'library.organize.undo',
    method: 'POST',
    pattern: '$_organize/runs/:id/undo',
    summary:
        'Undo an AI-organize run (removes the collections / tags it created). '
        'Cannot be redone.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Run id from library.organize.history.',
        required: true,
        inPath: true,
      ),
    ],
  ),
];

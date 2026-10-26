import 'dart:convert';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ops/op_describe_kit.dart';

/// 设置域其余路由：Profile、统计、快捷键、模块排序、设置记录列表、AI 提供商、
/// 模型文件、朗读声音、后台任务的操作描述（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）。
///
/// 凭据纪律（spec §4.3 / §10）：AI 提供商的 API Key（`apiKey` / `apiKeySource` /
/// `clearKeys` / `appendKey`）、记录列表与朗读声音的 `secrets` / `secretSource`
/// **一概不声明**——模型传不进来（`OpInvoker` 拒绝未声明参数），只能用户在设置页或
/// CLI 经 stdin / 环境变量填。读接口回的都是脱敏形态（key 只给尾号、secret 只给
/// 键名）。
List<OpDescription> describeSettingsMoreOps(OpDescribeKit kit) =>
    <OpDescription>[
      ..._moduleOrderOps(kit),
      ..._profileOps(kit),
      ..._statsOps(kit),
      ..._shortcutOps(kit),
      ..._settingItemOps(kit),
      ..._aiOps(kit),
      ..._modelOps(kit),
      ..._voiceOps(kit),
      ..._taskOps(),
    ];

// ── 模块排序 ─────────────────────────────────────────────────────────────

List<OpDescription> _moduleOrderOps(OpDescribeKit kit) => <OpDescription>[
  OpDescription(
    id: 'modules.order',
    method: 'POST',
    pattern: '/api/admin/modules/order',
    summary:
        'Reorder the bottom bar / sidebar modules: the given modules move to '
        'the front in that order, the rest keep their relative order.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.stringList(
        'order',
        description: 'Module ids from modules.list, in the wanted order.',
        required: true,
      ),
    ],
    undo: kit.readBackUndo(
      readMethod: 'GET',
      readPattern: '/api/admin/modules',
      writeMethod: 'POST',
      writePattern: '/api/admin/modules/order',
      field: 'order',
    ),
  ),
];

// ── Profile ──────────────────────────────────────────────────────────────

const OpParam _profileRef = OpParam.string(
  'id',
  description: 'Profile id (or exact name) from settings.profile.list.',
  required: true,
  inPath: true,
);

List<OpDescription> _profileOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.profile.list',
    method: 'GET',
    pattern: '/api/admin/profiles',
    summary:
        'List settings profiles, the active one, and the media type / '
        'language → profile auto-switch bindings.',
  ),
  OpDescription(
    id: 'settings.profile.create',
    method: 'POST',
    pattern: '/api/admin/profiles',
    summary:
        'Create a new profile and switch to it. Undo switches back and deletes '
        'the new profile.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string('name', description: 'Profile name.', required: true),
    ],
    undo: _createdProfileUndo(kit, switchesActive: true),
  ),
  OpDescription(
    id: 'settings.profile.import',
    method: 'POST',
    pattern: '/api/admin/profiles/import',
    summary:
        'Import a profile file as a new profile, or over an existing one '
        '(into). Undo deletes the new profile / restores the overwritten one.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute path of the profile JSON file.',
        required: true,
      ),
      OpParam.string(
        'into',
        description:
            'Profile id or name to overwrite; omit to import as a new profile.',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User approved overwriting an existing profile.',
      ),
    ],
    undo: _profileImportUndo(kit),
  ),
  OpDescription(
    id: 'settings.profile.activate',
    method: 'POST',
    pattern: '/api/admin/profiles/:id/activate',
    summary: 'Switch to another profile. Undo switches back.',
    risk: OpRisk.write,
    params: const <OpParam>[_profileRef],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) async =>
          (await _profiles(kit)).activeId,
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'POST',
          '/api/admin/profiles/:id/activate',
          params: <String, String>{'id': '$old'},
        );
      },
      newValue: (CtlCall call, Object? result) => _resultProfileId(result),
    ),
  ),
  OpDescription(
    id: 'settings.profile.rename',
    method: 'PUT',
    pattern: '/api/admin/profiles/:id',
    summary: 'Rename a profile. Undo restores the old name.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _profileRef,
      OpParam.string('name', description: 'New name.', required: true),
    ],
    undo: _resolvedSnapshotUndo(
      resolve: (CtlCall call) async =>
          '${(await _profiles(kit)).resolve(call.params['id']!)['id']}',
      read: (String id) async => (await _profiles(kit)).resolve(id)['name'],
      write: (String id, Object? old) async {
        await kit.callRoute(
          'PUT',
          '/api/admin/profiles/:id',
          params: <String, String>{'id': id},
          body: <String, Object?>{'name': old},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map && result['profile'] is Map
          ? (result['profile'] as Map)['name']
          : call.body['name'],
    ),
  ),
  OpDescription(
    id: 'settings.profile.copy',
    method: 'POST',
    pattern: '/api/admin/profiles/:id/copy',
    summary:
        'Copy a profile under a new name (the active profile stays). Undo '
        'deletes the copy.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _profileRef,
      OpParam.string('name', description: 'Name of the copy.', required: true),
    ],
    undo: _createdProfileUndo(kit, switchesActive: false),
  ),
  const OpDescription(
    id: 'settings.profile.delete',
    method: 'DELETE',
    pattern: '/api/admin/profiles/:id',
    summary:
        'Delete a profile and all its settings (at least one must remain). '
        'Cannot be undone.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _profileRef,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the profile.',
      ),
    ],
  ),
  OpDescription(
    id: 'settings.profile.export',
    method: 'POST',
    pattern: '/api/admin/profiles/:id/export',
    summary:
        'Export a profile to a JSON file (refuses to overwrite an existing '
        'file). Undo deletes the exported file.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _profileRef,
      OpParam.string(
        'path',
        description: 'Absolute path of the new file.',
        required: true,
      ),
    ],
    undo: _exportedFileUndo(),
  ),
  const OpDescription(
    id: 'settings.profile.binding.list',
    method: 'GET',
    pattern: '/api/admin/profiles/bindings',
    summary:
        'List the auto-switch bindings: media type → profile and content '
        'language → profile.',
  ),
  OpDescription(
    id: 'settings.profile.binding.set',
    method: 'PUT',
    pattern: '/api/admin/profiles/bindings/:scope/:key',
    summary:
        'Bind a media type or content language to a profile (opening such '
        'media switches to it), or unbind with profile=none. Undo restores the '
        'previous binding.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'scope',
        description: 'media or language.',
        required: true,
        inPath: true,
        enumValues: <String>['media', 'language'],
      ),
      OpParam.string(
        'key',
        description:
            'Media type (epub, srtbook, audiobook, lyrics, video, …) or '
            'BCP-47 language tag (ja, en, zh-Hant).',
        required: true,
        inPath: true,
      ),
      OpParam.string(
        'profile',
        description: 'Profile id or name, or none to unbind.',
        required: true,
      ),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) async => _bindingOf(
        await kit.callRoute('GET', '/api/admin/profiles/bindings'),
        params,
      ),
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'PUT',
          '/api/admin/profiles/bindings/:scope/:key',
          params: params,
          body: <String, Object?>{'profile': old == null ? 'none' : '$old'},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          _bindingOf(result, call.params),
    ),
  ),
];

/// `GET /api/admin/profiles` 的快照。
class _ProfileList {
  _ProfileList(this.activeId, this.rows);

  final Object? activeId;
  final List<Map<Object?, Object?>> rows;

  Set<String> get ids => <String>{
    for (final Map<Object?, Object?> row in rows) '${row['id']}',
  };

  /// 与路由同一口径：整数优先按 id，其次唯一名字。
  Map<Object?, Object?> resolve(String ref) {
    for (final Map<Object?, Object?> row in rows) {
      if ('${row['id']}' == ref.trim()) return row;
    }
    final List<Map<Object?, Object?>> byName = <Map<Object?, Object?>>[
      for (final Map<Object?, Object?> row in rows)
        if (row['name'] == ref.trim()) row,
    ];
    if (byName.length == 1) return byName.single;
    throw CtlFailure.notFound('没有 Profile「$ref」');
  }
}

Future<_ProfileList> _profiles(OpDescribeKit kit) async {
  final Object? listed = await kit.callRoute('GET', '/api/admin/profiles');
  final Map<Object?, Object?> map = listed is Map
      ? listed
      : const <Object?, Object?>{};
  return _ProfileList(map['activeProfileId'], <Map<Object?, Object?>>[
    for (final Object? row in (map['profiles'] as List? ?? const <Object?>[]))
      if (row is Map) row,
  ]);
}

Object? _resultProfileId(Object? result) =>
    result is Map && result['profile'] is Map
    ? (result['profile'] as Map)['id']
    : null;

/// 新建 / 复制出来的 Profile 的撤销：删掉它（新建会切过去，先切回原来的）。
/// 结果里的 id 执行前就存在（复制没真建出来）时拒绝撤销，绝不删原 Profile。
OpUndo _createdProfileUndo(OpDescribeKit kit, {required bool switchesActive}) =>
    OpUndo(
      capture: (CtlCall call) async {
        final _ProfileList list = await _profiles(kit);
        return <String, Object?>{
          'activeId': list.activeId,
          'ids': list.ids.toList(),
        };
      },
      record: (CtlCall call, Map<String, Object?> before, Object? result) {
        final Object? created = _resultProfileId(result);
        final bool isNew =
            created != null &&
            !((before['ids'] as List?) ?? const <Object?>[]).contains(
              '$created',
            );
        return OpUndoRecord(
          payload: <String, Object?>{
            'id': isNew ? '$created' : null,
            'activeId': switchesActive ? before['activeId'] : null,
          },
          after: created == null ? null : 'profile $created',
        );
      },
      revert: (Map<String, Object?> payload) => _guardUndo(() async {
        final Object? id = payload['id'];
        if (id == null) return const OpUndoOutcome.failed('这次没有建出新 Profile');
        final _ProfileList list = await _profiles(kit);
        if (!list.ids.contains(id)) {
          return const OpUndoOutcome.superseded('Profile 已被删除');
        }
        final Object? previous = payload['activeId'];
        if (previous != null &&
            '$previous' != '$id' &&
            list.ids.contains('$previous')) {
          await kit.callRoute(
            'POST',
            '/api/admin/profiles/:id/activate',
            params: <String, String>{'id': '$previous'},
          );
        }
        await kit.callRoute(
          'DELETE',
          '/api/admin/profiles/:id',
          params: <String, String>{'id': '$id'},
          body: const <String, Object?>{'confirm': true},
        );
        return const OpUndoOutcome.done();
      }),
    );

/// 导入 Profile 的撤销：新建的删掉；覆盖的执行前先经导出路由抓一份原内容，撤销时
/// 再经导入路由覆盖回去（与配置管理页导出 / 导入同一对方法）。
OpUndo _profileImportUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async {
    final _ProfileList list = await _profiles(kit);
    final Object? into = call.body['into'];
    String? targetId;
    String? content;
    if (into != null) {
      targetId = '${list.resolve('$into')['id']}';
      final Directory dir = await Directory.systemTemp.createTemp(
        'fushi_ai_undo_',
      );
      try {
        final String path = p.join(dir.path, 'profile.json');
        await kit.callRoute(
          'POST',
          '/api/admin/profiles/:id/export',
          params: <String, String>{'id': targetId},
          body: <String, Object?>{'path': path},
        );
        content = await File(path).readAsString();
      } finally {
        await dir.delete(recursive: true);
      }
    }
    return <String, Object?>{
      'ids': list.ids.toList(),
      'targetId': targetId,
      'content': content,
    };
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Object? written = _resultProfileId(result);
    return OpUndoRecord(
      payload: <String, Object?>{
        'writtenId': written == null ? null : '$written',
        'ids': before['ids'],
        'targetId': before['targetId'],
        'content': before['content'],
      },
      after: written == null ? null : 'profile $written',
    );
  },
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    final Object? targetId = payload['targetId'];
    final Object? content = payload['content'];
    if (targetId != null && content is String) {
      final Directory dir = await Directory.systemTemp.createTemp(
        'fushi_ai_undo_',
      );
      try {
        final String path = p.join(dir.path, 'profile.json');
        await File(path).writeAsString(content);
        await kit.callRoute(
          'POST',
          '/api/admin/profiles/import',
          body: <String, Object?>{
            'path': path,
            'into': '$targetId',
            'confirm': true,
          },
        );
      } finally {
        await dir.delete(recursive: true);
      }
      return const OpUndoOutcome.done();
    }
    final Object? written = payload['writtenId'];
    final List<Object?> before = (payload['ids'] as List?) ?? const <Object?>[];
    if (written == null || before.contains(written)) {
      return const OpUndoOutcome.failed('这次没有建出新 Profile');
    }
    if (!(await _profiles(kit)).ids.contains(written)) {
      return const OpUndoOutcome.superseded('Profile 已被删除');
    }
    await kit.callRoute(
      'DELETE',
      '/api/admin/profiles/:id',
      params: <String, String>{'id': '$written'},
      body: const <String, Object?>{'confirm': true},
    );
    return const OpUndoOutcome.done();
  }),
);

/// 绑定表（`GET /api/admin/profiles/bindings` 同形）里 [params] 指的那一行的 profileId。
Object? _bindingOf(Object? listed, Map<String, String> params) {
  if (listed is! Map) return null;
  final String scope = params['scope']!.trim().toLowerCase() == 'lang'
      ? 'language'
      : params['scope']!.trim().toLowerCase();
  final String key = params['key']!.trim().toLowerCase();
  for (final Object? row in (listed[scope] as List? ?? const <Object?>[])) {
    if (row is Map && '${row['key']}'.toLowerCase() == key) {
      return row['profileId'];
    }
  }
  return null;
}

// ── 学习统计 ─────────────────────────────────────────────────────────────

const List<OpParam> _statFilters = <OpParam>[
  OpParam.string(
    'window',
    description: 'Time window (default 7d).',
    enumValues: <String>['today', '7d', '30d', 'all'],
  ),
  OpParam.string(
    'kind',
    description: 'Media filter: read (books + listening), watch, game.',
    enumValues: <String>['read', 'watch', 'game'],
  ),
];

List<OpDescription> _statsOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'stats.summary',
    method: 'GET',
    pattern: '/api/admin/stats',
    summary:
        'Study statistics of the active profile for a time window: time, '
        'characters, pages and per-title totals.',
    params: _statFilters,
  ),
  const OpDescription(
    id: 'stats.sessions',
    method: 'GET',
    pattern: '/api/admin/stats/sessions',
    summary: 'Recent study sessions (newest first) for a time window.',
    params: <OpParam>[
      ..._statFilters,
      OpParam.integer('limit', description: 'Max sessions (default 20).'),
    ],
  ),
  OpDescription(
    id: 'stats.export',
    method: 'POST',
    pattern: '/api/admin/stats/export',
    summary:
        'Write the statistics diagnostic log to a file (same as Settings › '
        'Diagnostics). Refuses to overwrite. Undo deletes the file.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute path of the new file.',
        required: true,
      ),
    ],
    undo: _exportedFileUndo(),
  ),
];

/// 撤销 = 删掉这次写出的新文件（不声明 `confirm`，模型覆盖不了已有文件）。
/// 文件已不在或大小变了（之后被替换）报 superseded。
OpUndo _exportedFileUndo() => OpUndo(
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> map = result is Map
        ? result
        : const <Object?, Object?>{};
    return OpUndoRecord(
      payload: <String, Object?>{
        'path': map['path'] is String ? map['path'] : null,
        'bytes': map['bytes'] is int ? map['bytes'] : null,
      },
      after: map['path'] is String ? map['path'] as String : null,
    );
  },
  revert: (Map<String, Object?> payload) async {
    final Object? path = payload['path'];
    if (path is! String) return const OpUndoOutcome.failed('没有记录文件路径');
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

// ── 快捷键 ───────────────────────────────────────────────────────────────

const OpParam _shortcutAction = OpParam.string(
  'action',
  description: 'Action key from settings.shortcut.list (action column).',
  required: true,
  inPath: true,
);

List<OpDescription> _shortcutOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.shortcut.list',
    method: 'GET',
    pattern: '/api/admin/shortcuts',
    summary:
        'List keyboard / gamepad / mouse shortcuts per action, with tokens '
        'that settings.shortcut.set accepts.',
    params: <OpParam>[
      OpParam.string(
        'scope',
        description: 'Only one scope (reader, video, global, …).',
      ),
    ],
  ),
  OpDescription(
    id: 'settings.shortcut.set',
    method: 'PUT',
    pattern: '/api/admin/shortcuts/:action',
    summary:
        'Bind keys / buttons to an action. Undo restores the previous bindings '
        '(including bindings taken from other actions with conflict=steal).',
    risk: OpRisk.write,
    params: const <OpParam>[
      _shortcutAction,
      OpParam.stringList(
        'bindings',
        description:
            'Binding tokens, e.g. "Ctrl+F", "PageDown", gamepad / mouse tokens '
            'as shown by settings.shortcut.list.',
        required: true,
      ),
      OpParam.string(
        'mode',
        description:
            'replace (default: replaces the channels mentioned) or add.',
        enumValues: <String>['replace', 'add'],
      ),
      OpParam.string(
        'conflict',
        description:
            'When a binding is used by another action: fail (default), steal '
            '(remove it there) or keep (both keep it).',
        enumValues: <String>['fail', 'steal', 'keep'],
      ),
    ],
    undo: _shortcutsUndo(kit),
  ),
  OpDescription(
    id: 'settings.shortcut.unbind',
    method: 'POST',
    pattern: '/api/admin/shortcuts/:action/unbind',
    summary:
        'Remove bindings from an action (or all with all=true). Undo restores '
        'them.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _shortcutAction,
      OpParam.stringList(
        'bindings',
        description: 'Tokens to remove (from settings.shortcut.list).',
      ),
      OpParam.boolean(
        'all',
        description: 'Remove every binding of the action.',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User approved clearing every binding of the action.',
      ),
    ],
    undo: _shortcutsUndo(kit),
  ),
  OpDescription(
    id: 'settings.shortcut.reset',
    method: 'POST',
    pattern: '/api/admin/shortcuts/reset',
    summary:
        'Reset shortcuts to defaults: one action, one scope, or all (give '
        'exactly one). Undo restores the previous bindings.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string('action', description: 'One action key.'),
      OpParam.string('scope', description: 'One scope name.'),
      OpParam.boolean('all', description: 'The whole shortcut table.'),
      OpParam.userGate(
        'confirm',
        description: 'User approved resetting a scope / all shortcuts.',
      ),
    ],
    undo: _shortcutsUndo(kit),
  ),
];

Future<Map<String, List<String>>> _shortcutTable(OpDescribeKit kit) async {
  final Object? listed = await kit.callRoute('GET', '/api/admin/shortcuts');
  return _shortcutRows(listed is Map ? listed['shortcuts'] : null);
}

Map<String, List<String>> _shortcutRows(Object? rows) => <String, List<String>>{
  for (final Object? row in (rows is List ? rows : const <Object?>[]))
    if (row is Map)
      '${row['action']}': <String>[
        for (final Object? token
            in (row['tokens'] as List? ?? const <Object?>[]))
          '$token',
      ],
};

/// 快捷键撤销：执行前抓整张表；执行后从结果里取受影响的动作（被 steal 摘走绑定的
/// 动作也算），撤销时先清空它们再按原绑定加回（conflict=keep，避免互相拦）。
/// 结果里列出的动作当前绑定已不是这次执行的结果 → superseded。
OpUndo _shortcutsUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async => <String, Object?>{
    'table': await _shortcutTable(kit),
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> map = result is Map
        ? result
        : const <Object?, Object?>{};
    final Map<String, List<String>> after = <String, List<String>>{
      ..._shortcutRows(<Object?>[if (map['shortcut'] != null) map['shortcut']]),
      ..._shortcutRows(map['shortcuts']),
    };
    final Set<String> affected = <String>{
      ...after.keys,
      for (final Object? c in (map['conflicts'] as List? ?? const <Object?>[]))
        if (c is Map && c['resolution'] == 'removed') '${c['action']}',
    };
    final Map<Object?, Object?> table =
        before['table'] as Map? ?? const <Object?, Object?>{};
    final Map<String, Object?> old = <String, Object?>{
      for (final String action in affected) action: table[action],
    };
    return OpUndoRecord(
      payload: <String, Object?>{'before': old, 'after': after},
      before: _shortDisplay(old),
      after: _shortDisplay(after),
    );
  },
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    final Map<String, List<String>> current = await _shortcutTable(kit);
    final Map<Object?, Object?> after =
        payload['after'] as Map? ?? const <Object?, Object?>{};
    for (final MapEntry<Object?, Object?> e in after.entries) {
      if (!OpDescribeKit.sameJson(current['${e.key}'], e.value)) {
        return const OpUndoOutcome.superseded();
      }
    }
    final Map<Object?, Object?> old =
        payload['before'] as Map? ?? const <Object?, Object?>{};
    for (final Object? action in old.keys) {
      await kit.callRoute(
        'POST',
        '/api/admin/shortcuts/:action/unbind',
        params: <String, String>{'action': '$action'},
        body: const <String, Object?>{'all': true, 'confirm': true},
      );
    }
    for (final MapEntry<Object?, Object?> e in old.entries) {
      final List<Object?> tokens = e.value as List? ?? const <Object?>[];
      if (tokens.isEmpty) continue;
      await kit.callRoute(
        'PUT',
        '/api/admin/shortcuts/:action',
        params: <String, String>{'action': '${e.key}'},
        body: <String, Object?>{
          'bindings': <String>[for (final Object? t in tokens) '$t'],
          'mode': 'add',
          'conflict': 'keep',
        },
      );
    }
    return const OpUndoOutcome.done();
  }),
);

// ── 设置记录列表 ─────────────────────────────────────────────────────────

const OpParam _listKey = OpParam.string(
  'key',
  description: 'List setting key (settings.search with kind=list).',
  required: true,
  inPath: true,
);

const OpParam _itemId = OpParam.string(
  'id',
  description: 'Record id from settings.item.list.',
  required: true,
  inPath: true,
);

List<OpDescription> _settingItemOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.item.list',
    method: 'GET',
    pattern: '/api/admin/settings/:key/items',
    summary:
        'List the records of a list setting (media servers, audio sources, '
        'fonts, custom themes, discovery sources…). Secrets are redacted.',
    params: <OpParam>[_listKey],
  ),
  OpDescription(
    id: 'settings.item.add',
    method: 'POST',
    pattern: '/api/admin/settings/:key/items',
    summary:
        'Add a record to a list setting. Credential fields (passwords, tokens, '
        'API keys) cannot be set here: the user must enter secrets on the '
        'settings page. Undo deletes the new record.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _listKey,
      OpParam.object(
        'args',
        description:
            'Field values by name (fields are listed in "params" of '
            'settings.get for this key).',
      ),
    ],
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => <String, Object?>{
        'key': call.params['key'],
        'id': result is Map && result['item'] is Map
            ? '${(result['item'] as Map)['id']}'
            : null,
      },
      inverse: (Map<String, Object?> payload) async {
        if (payload['id'] == null) {
          throw const CtlFailure.conflict('新增结果里没有记录 id');
        }
        return kit.callRoute(
          'DELETE',
          '/api/admin/settings/:key/items/:id',
          params: <String, String>{
            'key': '${payload['key']}',
            'id': '${payload['id']}',
          },
          body: const <String, Object?>{'confirm': true},
        );
      },
      describe: (Map<String, Object?> payload) =>
          '${payload['key']} #${payload['id']}',
    ),
  ),
  OpDescription(
    id: 'settings.item.update',
    method: 'PUT',
    pattern: '/api/admin/settings/:key/items/:id',
    summary:
        'Change fields of one record in a list setting (credential fields '
        'cannot be set here). Undo restores the changed fields.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _listKey,
      _itemId,
      OpParam.object(
        'args',
        description: 'Only the fields to change, by name.',
        required: true,
      ),
    ],
    undo: _settingItemUpdateUndo(kit),
  ),
  const OpDescription(
    id: 'settings.item.remove',
    method: 'DELETE',
    pattern: '/api/admin/settings/:key/items/:id',
    summary:
        'Delete one record from a list setting. Cannot be undone (stored '
        'credentials of the record are lost).',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _listKey,
      _itemId,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the record.',
      ),
    ],
  ),
];

Future<Map<Object?, Object?>> _settingItem(
  OpDescribeKit kit,
  Map<String, String> params,
) async {
  final Object? listed = await kit.callRoute(
    'GET',
    '/api/admin/settings/:key/items',
    params: <String, String>{'key': params['key']!},
  );
  for (final Object? row
      in (listed is Map
          ? listed['items'] as List? ?? const <Object?>[]
          : const <Object?>[])) {
    if (row is Map && '${row['id']}' == params['id']) return row;
  }
  throw CtlFailure.notFound('没有记录「${params['id']}」');
}

/// 只回滚这次改过的字段：执行前读记录里这些字段的旧值，撤销时用 update 路由写回。
/// 列表输出里读不到的字段（只写字段）回不去，撤销报失败而不是瞎写。
OpUndo _settingItemUpdateUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async {
    final Map<Object?, Object?> item = await _settingItem(kit, call.params);
    final Object? args = call.body['args'];
    final List<String> keys = <String>[
      if (args is Map)
        for (final Object? k in args.keys) '$k',
    ];
    return <String, Object?>{
      'params': call.params,
      'old': <String, Object?>{
        for (final String k in keys)
          if (item.containsKey(k)) k: item[k],
      },
      'unreadable': <String>[
        for (final String k in keys)
          if (!item.containsKey(k)) k,
      ],
    };
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> item = result is Map && result['item'] is Map
        ? result['item'] as Map
        : const <Object?, Object?>{};
    final Map<Object?, Object?> old =
        before['old'] as Map? ?? const <Object?, Object?>{};
    final Map<String, Object?> after = <String, Object?>{
      for (final Object? k in old.keys) '$k': item[k],
    };
    return OpUndoRecord(
      payload: <String, Object?>{...before, 'new': after},
      before: _shortDisplay(old),
      after: _shortDisplay(after),
    );
  },
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    final List<Object?> unreadable =
        payload['unreadable'] as List? ?? const <Object?>[];
    if (unreadable.isNotEmpty) {
      return OpUndoOutcome.failed(
        '字段 ${unreadable.join(', ')} 读不回旧值，请在设置页手动改回',
      );
    }
    final Map<String, String> params = <String, String>{
      for (final MapEntry<Object?, Object?> e
          in (payload['params'] as Map? ?? const <Object?, Object?>{}).entries)
        '${e.key}': '${e.value}',
    };
    final Map<Object?, Object?> current = await _settingItem(kit, params);
    final Map<Object?, Object?> after =
        payload['new'] as Map? ?? const <Object?, Object?>{};
    for (final MapEntry<Object?, Object?> e in after.entries) {
      if (!OpDescribeKit.sameJson(current[e.key], e.value)) {
        return const OpUndoOutcome.superseded();
      }
    }
    final Map<Object?, Object?> old =
        payload['old'] as Map? ?? const <Object?, Object?>{};
    await kit.callRoute(
      'PUT',
      '/api/admin/settings/:key/items/:id',
      params: params,
      body: <String, Object?>{
        'args': <String, Object?>{
          for (final MapEntry<Object?, Object?> e in old.entries)
            '${e.key}': _fieldText(e.value),
        },
      },
    );
    return const OpUndoOutcome.done();
  }),
);

String _fieldText(Object? value) => switch (value) {
  null => '',
  String() => value,
  num() || bool() => '$value',
  _ => jsonEncode(value),
};

// ── AI 提供商 ────────────────────────────────────────────────────────────

const OpParam _providerRef = OpParam.string(
  'id',
  description: 'Provider id from settings.ai.provider.list.',
  required: true,
  inPath: true,
);

/// 提供商的可回滚字段（不含 key：key 不进撤销载荷，也不由模型写）。
const List<String> _providerFields = <String>[
  'name',
  'baseUrl',
  'model',
  'protocol',
  'reasoning',
  'enabled',
  'allowInsecureHttp',
  'rpm',
];

const List<OpParam> _providerEditable = <OpParam>[
  OpParam.string('name', description: 'Display name.'),
  OpParam.string('baseUrl', description: 'API base URL.'),
  OpParam.string('model', description: 'Model name.'),
  OpParam.string(
    'protocol',
    description: 'Wire protocol override.',
    enumValues: <String>['openai', 'anthropic', 'gemini'],
  ),
  OpParam.string(
    'reasoning',
    description: 'Reasoning effort.',
    enumValues: <String>['none', 'low', 'medium', 'high'],
  ),
  OpParam.boolean('enabled', description: 'Provider enabled.'),
  OpParam.integer('rpm', description: 'Max requests per minute (0 = no cap).'),
  // allowInsecureHttp（明文 http 发送 API Key）刻意不声明：userGate 对可逆操作会被
  // 运行时直接注入成 true，等于替用户放开明文；只能用户自己在设置页打开。
];

List<OpDescription> _aiOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.ai.preset.list',
    method: 'GET',
    pattern: '/api/admin/ai/presets',
    summary:
        'List built-in LLM provider presets (OpenAI, Anthropic, Gemini, '
        'Ollama, LM Studio…) with protocol, base URL and suggested model.',
  ),
  const OpDescription(
    id: 'settings.ai.provider.list',
    method: 'GET',
    pattern: '/api/admin/ai/providers',
    summary:
        'List configured LLM providers (API keys only as last characters) and '
        'the default provider.',
  ),
  OpDescription(
    id: 'settings.ai.provider.add',
    method: 'POST',
    pattern: '/api/admin/ai/providers',
    summary:
        'Add an LLM provider from a preset. The API key cannot be set here: '
        'the user must enter it on the Settings › Models › LLM page. Undo '
        'deletes the provider (and restores the previous default).',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'preset',
        description: 'Preset id from settings.ai.preset.list.',
        required: true,
      ),
      ..._providerEditable,
      OpParam.boolean(
        'makeDefault',
        description: 'Also make it the default provider.',
      ),
    ],
    undo: _providerAddUndo(kit),
  ),
  OpDescription(
    id: 'settings.ai.provider.update',
    method: 'PUT',
    pattern: '/api/admin/ai/providers/:id',
    summary:
        'Change an LLM provider\'s name, URL, model, protocol, reasoning, '
        'enabled or rate limit. API keys cannot be changed here. Undo restores '
        'the previous values.',
    risk: OpRisk.write,
    params: const <OpParam>[_providerRef, ..._providerEditable],
    undo: _resolvedSnapshotUndo(
      resolve: (CtlCall call) async =>
          '${(await _provider(kit, call.params['id']!))['id']}',
      read: (String id) async => _providerSnapshot(await _provider(kit, id)),
      write: (String id, Object? old) async {
        final Map<Object?, Object?> before =
            old as Map? ?? const <Object?, Object?>{};
        await kit.callRoute(
          'PUT',
          '/api/admin/ai/providers/:id',
          params: <String, String>{'id': id},
          body: <String, Object?>{
            for (final MapEntry<Object?, Object?> e in before.entries)
              '${e.key}': e.value,
          },
        );
        // 写回后再核一遍：路由没能还原的字段（显式空串之外的边界）如实报失败，
        // 让用户手动处理，不报「已撤销」。
        final Map<String, Object?> now = _providerSnapshot(
          await _provider(kit, id),
        );
        final List<String> stuck = <String>[
          for (final String f in _providerFields)
            if (!OpDescribeKit.sameJson(now[f], before[f])) f,
        ];
        if (stuck.isNotEmpty) {
          throw CtlFailure.conflict(
            '${stuck.join(', ')} 没能还原；其余字段已还原，请在设置页手动改回',
          );
        }
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map && result['provider'] is Map
          ? _providerSnapshot(result['provider'] as Map)
          : null,
    ),
  ),
  const OpDescription(
    id: 'settings.ai.provider.delete',
    method: 'DELETE',
    pattern: '/api/admin/ai/providers/:id',
    summary:
        'Delete an LLM provider, its stored API keys and every feature '
        'assignment pointing to it. Cannot be undone (keys only the user can '
        're-enter).',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _providerRef,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the provider.',
      ),
    ],
  ),
  const OpDescription(
    id: 'settings.ai.provider.probe',
    method: 'POST',
    pattern: '/api/admin/ai/providers/:id/probe',
    summary:
        'Test an LLM provider connection (one chat ping, or list models). '
        'Changes nothing.',
    params: <OpParam>[
      _providerRef,
      OpParam.boolean(
        'models',
        description: 'List available models instead of a chat ping.',
      ),
    ],
  ),
  const OpDescription(
    id: 'settings.ai.feature.list',
    method: 'GET',
    pattern: '/api/admin/ai/features',
    summary:
        'List AI features and which provider each uses (default / off / a '
        'provider) and whether it is usable.',
  ),
  OpDescription(
    id: 'settings.ai.feature.assign',
    method: 'PUT',
    pattern: '/api/admin/ai/features/:feature',
    summary:
        'Choose the provider for one AI feature: default, off, or a provider. '
        'Undo restores the previous choice.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'feature',
        description: 'Feature name from settings.ai.feature.list.',
        required: true,
        inPath: true,
      ),
      OpParam.string(
        'provider',
        description: 'default, off, or a provider id / name.',
        required: true,
      ),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) => kit.readListField(
        pattern: '/api/admin/ai/features',
        listKey: 'features',
        idField: 'feature',
        id: params['feature']!,
        field: 'assignment',
      ),
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'PUT',
          '/api/admin/ai/features/:feature',
          params: params,
          body: <String, Object?>{'provider': old ?? 'default'},
        );
      },
      newValue: (CtlCall call, Object? result) {
        for (final Object? row
            in (result is Map
                ? result['features'] as List? ?? const <Object?>[]
                : const <Object?>[])) {
          if (row is Map && row['feature'] == call.params['feature']) {
            return row['assignment'];
          }
        }
        return null;
      },
    ),
  ),
  OpDescription(
    id: 'settings.ai.default.set',
    method: 'PUT',
    pattern: '/api/admin/ai/default',
    summary:
        'Set the default LLM provider (used by features set to default), or '
        'none. Undo restores the previous default.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'provider',
        description: 'Provider id / name, or none.',
        required: true,
      ),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) async {
        final Object? listed = await kit.callRoute(
          'GET',
          '/api/admin/ai/features',
        );
        return listed is Map ? listed['defaultProviderId'] : null;
      },
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'PUT',
          '/api/admin/ai/default',
          body: <String, Object?>{'provider': old ?? 'none'},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map ? result['defaultProviderId'] : null,
    ),
  ),
];

Future<Map<Object?, Object?>> _provider(OpDescribeKit kit, String ref) async {
  final Object? listed = await kit.callRoute('GET', '/api/admin/ai/providers');
  final List<Object?> rows = listed is Map
      ? listed['providers'] as List? ?? const <Object?>[]
      : const <Object?>[];
  for (final Object? row in rows) {
    if (row is Map && row['id'] == ref.trim()) return row;
  }
  final List<Map<Object?, Object?>> byName = <Map<Object?, Object?>>[
    for (final Object? row in rows)
      if (row is Map && row['name'] == ref.trim()) row,
  ];
  if (byName.length == 1) return byName.single;
  throw CtlFailure.notFound('没有 AI 提供商「$ref」');
}

Map<String, Object?> _providerSnapshot(Map<Object?, Object?> row) =>
    <String, Object?>{for (final String f in _providerFields) f: row[f]};

/// 新增提供商的撤销：删掉它；若这次顺带设成了默认，删后把原默认设回去。
OpUndo _providerAddUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async {
    final Object? listed = await kit.callRoute(
      'GET',
      '/api/admin/ai/providers',
    );
    return <String, Object?>{
      'oldDefault': listed is Map ? listed['defaultProviderId'] : null,
    };
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Object? provider = result is Map ? result['provider'] : null;
    final Object? id = provider is Map ? provider['id'] : null;
    return OpUndoRecord(
      payload: <String, Object?>{
        'id': id,
        'madeDefault': call.body['makeDefault'] == true,
        'oldDefault': before['oldDefault'],
      },
      after: provider is Map ? '${provider['name']}' : null,
    );
  },
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    final Object? id = payload['id'];
    if (id == null) return const OpUndoOutcome.failed('没有记录提供商 id');
    await kit.callRoute(
      'DELETE',
      '/api/admin/ai/providers/:id',
      params: <String, String>{'id': '$id'},
      body: const <String, Object?>{'confirm': true},
    );
    final Object? oldDefault = payload['oldDefault'];
    if (payload['madeDefault'] == true && oldDefault != null) {
      await kit.callRoute(
        'PUT',
        '/api/admin/ai/default',
        body: <String, Object?>{'provider': '$oldDefault'},
      );
    }
    return const OpUndoOutcome.done();
  }),
);

// ── 模型文件 ─────────────────────────────────────────────────────────────

const List<OpParam> _modelRef = <OpParam>[
  OpParam.string(
    'kind',
    description: 'Model kind.',
    required: true,
    inPath: true,
    enumValues: <String>['asr', 'ocr', 'gpt-sovits', 'irodori'],
  ),
  OpParam.string(
    'id',
    description:
        'Model id from settings.model.list (ASR pack id or language tag, OCR '
        'model key, "local" for gpt-sovits / irodori).',
    required: true,
    inPath: true,
  ),
];

List<OpDescription> _modelOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.model.list',
    method: 'GET',
    pattern: '/api/admin/models',
    summary:
        'List local model files (speech-to-text ASR packs, manga OCR models, '
        'local GPT-SoVITS / Irodori TTS servers) with download / ready state.',
  ),
  const OpDescription(
    id: 'settings.model.get',
    method: 'GET',
    pattern: '/api/admin/models/:kind/:id',
    summary: 'Status and download progress of one model.',
    params: _modelRef,
  ),
  OpDescription(
    id: 'settings.model.download',
    method: 'POST',
    pattern: '/api/admin/models/:kind/:id/download',
    summary:
        'Start downloading / installing a model in the background; poll '
        'settings.model.get. Sizes: ASR packs and OCR models are hundreds of '
        'MB, Irodori-TTS several GB, GPT-SoVITS over 10 GB. Undo cancels the '
        'download and deletes the downloaded files.',
    risk: OpRisk.write,
    params: const <OpParam>[
      ..._modelRef,
      OpParam.string(
        'source',
        description:
            'gpt-sovits: hf / ms; irodori: hf / hf-mirror (download mirror).',
      ),
      OpParam.string(
        'variant',
        description: 'gpt-sovits package variant (default by GPU).',
      ),
      OpParam.string('model', description: 'irodori model: small / mf.'),
      OpParam.string(
        'backend',
        description: 'irodori torch backend (default by GPU).',
      ),
      OpParam.string(
        'dir',
        description: 'gpt-sovits / irodori absolute install directory.',
      ),
    ],
    undo: _modelDownloadUndo(kit),
  ),
  OpDescription(
    id: 'settings.model.cancel',
    method: 'POST',
    pattern: '/api/admin/models/:kind/:id/cancel',
    summary:
        'Cancel a running model download (partial files are kept and resumed '
        'next time). Undo restarts the download.',
    risk: OpRisk.write,
    params: _modelRef,
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => <String, Object?>{
        'kind': call.params['kind'],
        'id': call.params['id'],
      },
      inverse: (Map<String, Object?> payload) => kit.callRoute(
        'POST',
        '/api/admin/models/:kind/:id/download',
        params: <String, String>{
          'kind': '${payload['kind']}',
          'id': '${payload['id']}',
        },
      ),
    ),
  ),
  OpDescription(
    id: 'settings.model.link',
    method: 'POST',
    pattern: '/api/admin/models/:kind/:id/link',
    summary:
        'Point the local GPT-SoVITS engine at an existing package directory '
        '(gpt-sovits only; nothing is copied). Undo restores the previous '
        'directory.',
    risk: OpRisk.write,
    params: const <OpParam>[
      ..._modelRef,
      OpParam.string(
        'dir',
        description: 'Absolute path of the GPT-SoVITS package.',
        required: true,
      ),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) async {
        final Object? status = await kit.callRoute(
          'GET',
          '/api/admin/models/:kind/:id',
          params: params,
        );
        return status is Map ? status['dir'] : null;
      },
      write: (Map<String, String> params, Object? old) async {
        if (old == null) {
          // 原来没接入：忘掉这次接入的目录（用户自己的目录不删文件）。
          await kit.callRoute(
            'DELETE',
            '/api/admin/models/:kind/:id',
            params: params,
            body: const <String, Object?>{'confirm': true},
          );
          return;
        }
        await kit.callRoute(
          'POST',
          '/api/admin/models/:kind/:id/link',
          params: params,
          body: <String, Object?>{'dir': old},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map ? result['dir'] : call.body['dir'],
    ),
  ),
  OpDescription(
    id: 'settings.model.start',
    method: 'POST',
    pattern: '/api/admin/models/:kind/:id/start',
    summary:
        'Start the local GPT-SoVITS / Irodori TTS server. Undo stops it if it '
        'was not running.',
    risk: OpRisk.write,
    params: _modelRef,
    undo: _serverRunningUndo(kit),
  ),
  OpDescription(
    id: 'settings.model.stop',
    method: 'POST',
    pattern: '/api/admin/models/:kind/:id/stop',
    summary:
        'Stop the local GPT-SoVITS / Irodori TTS server. Undo starts it again '
        'if it was running.',
    risk: OpRisk.write,
    params: _modelRef,
    undo: _serverRunningUndo(kit),
  ),
  const OpDescription(
    id: 'settings.model.delete',
    method: 'DELETE',
    pattern: '/api/admin/models/:kind/:id',
    summary:
        'Delete a downloaded model\'s files (a user-linked directory is only '
        'forgotten, not deleted). Cannot be undone; re-downloading is large.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      ..._modelRef,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the model files.',
      ),
    ],
  ),
];

/// 下载 / 安装的撤销：取消进行中的下载，再删掉下好的文件。执行前已就绪
/// （ASR / OCR 直接回 alreadyReady，什么也没改）就什么都不做；本机 TTS 整合包
/// 执行前已装好、这次是重装的，删了会连原安装一起没，报失败不动。
OpUndo _modelDownloadUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async {
    final Object? status = await kit.callRoute(
      'GET',
      '/api/admin/models/:kind/:id',
      params: call.params,
    );
    return <String, Object?>{
      'params': call.params,
      'wasReady': status is Map && status['ready'] == true,
    };
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) =>
      OpUndoRecord(
        payload: <String, Object?>{
          ...before,
          'alreadyReady': result is Map && result['alreadyReady'] == true,
        },
        after: '${call.params['kind']}/${call.params['id']}',
      ),
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    if (payload['alreadyReady'] == true) return const OpUndoOutcome.done();
    if (payload['wasReady'] == true) {
      return const OpUndoOutcome.failed('执行前已安装，这次是重装；删除会连原安装一起删掉，未动');
    }
    final Map<String, String> params = <String, String>{
      for (final MapEntry<Object?, Object?> e
          in (payload['params'] as Map? ?? const <Object?, Object?>{}).entries)
        '${e.key}': '${e.value}',
    };
    try {
      await kit.callRoute(
        'POST',
        '/api/admin/models/:kind/:id/cancel',
        params: params,
      );
    } on CtlFailure catch (failure) {
      // 409 = 已经不在下载（下完了或失败了）：直接删。
      if (failure.status != 409) rethrow;
    }
    await kit.callRoute(
      'DELETE',
      '/api/admin/models/:kind/:id',
      params: params,
      body: const <String, Object?>{'confirm': true},
    );
    return const OpUndoOutcome.done();
  }),
);

/// 本机 TTS 服务起停的撤销：回到执行前是否在运行的状态。
OpUndo _serverRunningUndo(OpDescribeKit kit) {
  Future<bool> running(Map<String, String> params) async {
    final Object? status = await kit.callRoute(
      'GET',
      '/api/admin/models/:kind/:id',
      params: params,
    );
    return status is Map && status['server'] == 'running';
  }

  return kit.snapshotUndo(
    read: running,
    write: (Map<String, String> params, Object? old) async {
      if (await running(params) == (old == true)) return;
      await kit.callRoute(
        'POST',
        old == true
            ? '/api/admin/models/:kind/:id/start'
            : '/api/admin/models/:kind/:id/stop',
        params: params,
      );
    },
    newValue: (CtlCall call, Object? result) =>
        result is Map ? result['server'] == 'running' : null,
  );
}

// ── 朗读声音 ─────────────────────────────────────────────────────────────

const OpParam _voiceRef = OpParam.string(
  'id',
  description: 'Voice id (or exact name) from settings.voice.list.',
  required: true,
  inPath: true,
);

List<OpDescription> _voiceOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.voice.list',
    method: 'GET',
    pattern: '/api/admin/voices',
    summary:
        'List text-to-speech voice presets, the default voice and the speech '
        'speed (secret parameters only by name).',
  ),
  const OpDescription(
    id: 'settings.voice.engine.list',
    method: 'GET',
    pattern: '/api/admin/voices/engines',
    summary: 'List available TTS engines and the parameters each accepts.',
  ),
  OpDescription(
    id: 'settings.voice.add',
    method: 'POST',
    pattern: '/api/admin/voices',
    summary:
        'Add a TTS voice preset for an engine. Secret parameters (API keys) '
        'cannot be set here: the user must enter them on the voice settings '
        'page. Undo deletes the preset and restores the previous default.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'engine',
        description: 'Engine id from settings.voice.engine.list.',
        required: true,
      ),
      OpParam.string('name', description: 'Preset name.'),
      OpParam.object(
        'params',
        description:
            'Non-secret engine parameters by key (from settings.voice.engine.list).',
      ),
      OpParam.boolean('use', description: 'Make it the default voice.'),
    ],
    undo: _voiceAddUndo(kit),
  ),
  OpDescription(
    id: 'settings.voice.update',
    method: 'PUT',
    pattern: '/api/admin/voices/:id',
    summary:
        'Change a voice preset\'s name or non-secret parameters (empty value '
        'removes a parameter). Undo restores the previous name and parameters.',
    risk: OpRisk.write,
    params: const <OpParam>[
      _voiceRef,
      OpParam.string('name', description: 'New name.'),
      OpParam.object(
        'params',
        description: 'Non-secret engine parameters to change, by key.',
      ),
      OpParam.boolean(
        'regenerate',
        description: 'Invalidate cached audio of this voice.',
      ),
    ],
    undo: _resolvedSnapshotUndo(
      resolve: (CtlCall call) async =>
          '${(await _voice(kit, call.params['id']!))['id']}',
      read: (String id) async => _voiceSnapshot(await _voice(kit, id)),
      write: (String id, Object? old) async {
        final Map<Object?, Object?> before =
            old as Map? ?? const <Object?, Object?>{};
        final Map<Object?, Object?> oldParams =
            before['params'] as Map? ?? const <Object?, Object?>{};
        final Map<Object?, Object?> currentParams =
            (await _voice(kit, id))['params'] as Map? ??
            const <Object?, Object?>{};
        await kit.callRoute(
          'PUT',
          '/api/admin/voices/:id',
          params: <String, String>{'id': id},
          body: <String, Object?>{
            'name': before['name'],
            'params': <String, Object?>{
              for (final Object? k in currentParams.keys)
                if (!oldParams.containsKey(k)) '$k': '',
              for (final MapEntry<Object?, Object?> e in oldParams.entries)
                '${e.key}': e.value,
            },
          },
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map && result['voice'] is Map
          ? _voiceSnapshot(result['voice'] as Map)
          : null,
    ),
  ),
  OpDescription(
    id: 'settings.voice.activate',
    method: 'POST',
    pattern: '/api/admin/voices/:id/activate',
    summary: 'Make a voice preset the default. Undo restores the old default.',
    risk: OpRisk.write,
    params: const <OpParam>[_voiceRef],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) async {
        final Object? listed = await kit.callRoute('GET', '/api/admin/voices');
        return listed is Map ? listed['activeId'] : null;
      },
      write: (Map<String, String> params, Object? old) async {
        if (old == null) {
          throw const CtlFailure.conflict('执行前没有默认声音，无从恢复');
        }
        await kit.callRoute(
          'POST',
          '/api/admin/voices/:id/activate',
          params: <String, String>{'id': '$old'},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map && result['voice'] is Map
          ? (result['voice'] as Map)['id']
          : null,
    ),
  ),
  const OpDescription(
    id: 'settings.voice.delete',
    method: 'DELETE',
    pattern: '/api/admin/voices/:id',
    summary:
        'Delete a voice preset, its stored secrets and its imported reference '
        'audio. Cannot be undone.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      _voiceRef,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the voice.',
      ),
    ],
  ),
  const OpDescription(
    id: 'settings.voice.voices',
    method: 'GET',
    pattern: '/api/admin/voices/:id/voices',
    summary:
        'List the speaker voices the preset\'s engine offers (Edge, system '
        'voices…), to pick a value for its voice parameter.',
    params: <OpParam>[_voiceRef],
  ),
  OpDescription(
    id: 'settings.voice.speed',
    method: 'PUT',
    pattern: '/api/admin/tts/speed',
    summary:
        'Set the text-to-speech playback speed (same range as the audiobook '
        'speed slider). Undo restores the old speed.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.number(
        'speed',
        description: 'Speed multiplier, e.g. 1.25.',
        required: true,
      ),
    ],
    undo: kit.readBackUndo(
      readMethod: 'GET',
      readPattern: '/api/admin/voices',
      writeMethod: 'PUT',
      writePattern: '/api/admin/tts/speed',
      field: 'speed',
    ),
  ),
];

Future<Map<Object?, Object?>> _voice(OpDescribeKit kit, String ref) async {
  final Object? listed = await kit.callRoute('GET', '/api/admin/voices');
  final List<Object?> rows = listed is Map
      ? listed['voices'] as List? ?? const <Object?>[]
      : const <Object?>[];
  for (final Object? row in rows) {
    if (row is Map && row['id'] == ref.trim()) return row;
  }
  final List<Map<Object?, Object?>> byName = <Map<Object?, Object?>>[
    for (final Object? row in rows)
      if (row is Map && row['name'] == ref.trim()) row,
  ];
  if (byName.length == 1) return byName.single;
  throw CtlFailure.notFound('没有声音「$ref」');
}

Map<String, Object?> _voiceSnapshot(Map<Object?, Object?> row) =>
    <String, Object?>{'name': row['name'], 'params': row['params']};

/// 新增声音的撤销：删掉它，原默认声音还在就设回默认。
OpUndo _voiceAddUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async {
    final Object? listed = await kit.callRoute('GET', '/api/admin/voices');
    return <String, Object?>{
      'oldActive': listed is Map ? listed['activeId'] : null,
    };
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Object? voice = result is Map ? result['voice'] : null;
    return OpUndoRecord(
      payload: <String, Object?>{
        'id': voice is Map ? voice['id'] : null,
        'oldActive': before['oldActive'],
      },
      after: voice is Map ? '${voice['name']}' : null,
    );
  },
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    final Object? id = payload['id'];
    if (id == null) return const OpUndoOutcome.failed('没有记录声音 id');
    final Object? deleted = await kit.callRoute(
      'DELETE',
      '/api/admin/voices/:id',
      params: <String, String>{'id': '$id'},
      body: const <String, Object?>{'confirm': true},
    );
    final Object? oldActive = payload['oldActive'];
    if (oldActive != null &&
        deleted is Map &&
        deleted['activeId'] != oldActive) {
      await kit.callRoute(
        'POST',
        '/api/admin/voices/:id/activate',
        params: <String, String>{'id': '$oldActive'},
      );
    }
    return const OpUndoOutcome.done();
  }),
);

// ── 后台任务 ─────────────────────────────────────────────────────────────

List<OpDescription> _taskOps() => const <OpDescription>[
  OpDescription(
    id: 'task.list',
    method: 'GET',
    pattern: '/api/admin/tasks',
    summary:
        'List recent settings background tasks (app update download / install, '
        'Plex sign-in, backup import…) with their state.',
    params: <OpParam>[
      OpParam.string(
        'kind',
        description: 'Task kind or kind prefix, e.g. update.',
      ),
    ],
  ),
  OpDescription(
    id: 'task.get',
    method: 'GET',
    pattern: '/api/admin/tasks/:id',
    summary:
        'Read one background task; optionally wait up to N seconds for it to '
        'finish.',
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Task id from task.list or from the call that started it.',
        required: true,
        inPath: true,
      ),
      OpParam.integer(
        'wait',
        description: 'Seconds to wait for completion (0–600).',
      ),
    ],
  ),
  OpDescription(
    id: 'task.cancel',
    method: 'POST',
    pattern: '/api/admin/tasks/:id/cancel',
    summary:
        'Cancel a running background task (refused once it is committing). '
        'A cancelled task cannot be resumed.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Task id from task.list.',
        required: true,
        inPath: true,
      ),
    ],
  ),
];

// ── 通用私有形态 ─────────────────────────────────────────────────────────

/// [OpDescribeKit.snapshotUndo] 的变体：路径参数可能是名字（改名后就对不上），
/// 所以执行前先 [resolve] 出稳定 id，读写都按 id。当前值已不是这次执行的结果报
/// superseded。
OpUndo _resolvedSnapshotUndo({
  required Future<String> Function(CtlCall call) resolve,
  required Future<Object?> Function(String id) read,
  required Future<void> Function(String id, Object? old) write,
  required Object? Function(CtlCall call, Object? result) newValue,
}) => OpUndo(
  capture: (CtlCall call) async {
    final String id = await resolve(call);
    return <String, Object?>{'id': id, 'old': await read(id)};
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Object? after = newValue(call, result);
    return OpUndoRecord(
      payload: <String, Object?>{...before, 'new': after},
      before: _shortDisplay(before['old']),
      after: _shortDisplay(after),
    );
  },
  revert: (Map<String, Object?> payload) => _guardUndo(() async {
    final String id = '${payload['id']}';
    if (!OpDescribeKit.sameJson(await read(id), payload['new'])) {
      return const OpUndoOutcome.superseded();
    }
    await write(id, payload['old']);
    return const OpUndoOutcome.done();
  }),
);

/// 撤销体里的 [CtlFailure]：404（对象已不在）→ superseded，其余 → failed。
Future<OpUndoOutcome> _guardUndo(Future<OpUndoOutcome> Function() body) async {
  try {
    return await body();
  } on CtlFailure catch (failure) {
    return failure.status == 404
        ? OpUndoOutcome.superseded(failure.message)
        : OpUndoOutcome.failed(failure.message ?? failure.code);
  }
}

String? _shortDisplay(Object? value) {
  if (value == null) return null;
  final String text = value is String ? value : jsonEncode(value);
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

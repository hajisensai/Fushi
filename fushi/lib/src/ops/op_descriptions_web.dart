import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_web_routes.dart' show kWebCtlClearRanges;
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart' show opCustomUndo;

/// 内置浏览器（书签 / 历史 / 打开网址）与网页广告拦截的操作描述（spec §4）。
///
/// 撤销只拼现有路由：
/// - 加书签 / 文件夹 = 删掉刚建的那一项（之后被改过、或文件夹里又放了东西 = superseded）；
/// - 改书签（标题 / 网址 / 移动 / 排序）= 执行前快照写回（之后又被手改 = superseded）；
/// - 删书签 / 文件夹 = 按执行前抓的整棵子树重建回原父目录、原顺序（id 会变）；之后同一
///   网址又被加回书签 = superseded；
/// - 广告拦截总开关 / 订阅列表 / 白名单（整份设置、加一个、删一个站点）= 快照写回。
///
/// irreversible：清除浏览历史（按时间范围或按条）——store 没有恢复历史的入口，记一次
/// 访问只会把次数从 1 重新数起。
///
/// read：打开网址只导航（不读网页内容）；「立即更新」过滤列表只刷新列表缓存、重编引擎，
/// 不改开关 / 订阅 / 白名单这些用户设置。
List<OpDescription> describeWebOps(OpDescribeKit kit) {
  final OpAvailability Function() web = kit.whenModule(ModuleId.web);
  return <OpDescription>[
    ..._describeBrowserOps(kit, web),
    ..._describeBookmarkOps(kit, web),
    ..._describeAdblockOps(kit),
  ];
}

const String _root = '/api/admin/web';
const String _bookmarks = '$_root/bookmarks';
const String _adblock = '$_root/adblock';

List<OpDescription> _describeBrowserOps(
  OpDescribeKit kit,
  OpAvailability Function() web,
) => <OpDescription>[
  OpDescription(
    id: 'web.open',
    method: 'POST',
    pattern: '$_root/open',
    summary:
        'Open a web address in the built-in browser (full-screen page; brings '
        'the main window forward). Text that is not an address is searched '
        'with the current search engine. Navigation only: the page content is '
        'not returned.',
    availability: web,
    params: const <OpParam>[
      OpParam.string(
        'url',
        description: 'Address (https://…, example.com) or search words.',
        required: true,
      ),
    ],
  ),
  OpDescription(
    id: 'web.history.list',
    method: 'GET',
    pattern: '$_root/history',
    summary: 'Browsing history, most recent first.',
    availability: web,
    params: const <OpParam>[
      OpParam.string('search', description: 'Filter by title / address.'),
      OpParam.integer('limit', description: 'Max rows (default 50).'),
      OpParam.integer('offset', description: 'Skip this many rows.'),
    ],
  ),
  OpDescription(
    id: 'web.history.clear',
    method: 'POST',
    pattern: '$_root/history/clear',
    summary:
        'Delete browsing history: everything in a time range, or the given '
        'entries. Cannot be undone.',
    risk: OpRisk.irreversible,
    availability: web,
    params: <OpParam>[
      OpParam.string(
        'range',
        description: 'Time range to clear (give range or ids).',
        enumValues: kWebCtlClearRanges.keys.toList(growable: false),
      ),
      const OpParam.stringList(
        'ids',
        description: 'History entry ids from web.history.list.',
      ),
      const OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the history.',
      ),
    ],
  ),
];

// ── 书签 ──────────────────────────────────────────────────────────────────

const OpParam _bookmarkIdParam = OpParam.string(
  'id',
  description: 'Bookmark / folder id from web.bookmark.list.',
  required: true,
  inPath: true,
);

/// 全部书签与文件夹（扁平，带 parentId / 同级 index）。
Future<List<Map<String, Object?>>> _allBookmarks(OpDescribeKit kit) async {
  final Object? raw = await kit.callRoute(
    'GET',
    _bookmarks,
    body: const <String, Object?>{'recursive': true},
  );
  final Object? rows = raw is Map ? raw['bookmarks'] : null;
  return <Map<String, Object?>>[
    if (rows is List)
      for (final Object? row in rows)
        if (row is Map)
          <String, Object?>{
            for (final MapEntry<Object?, Object?> e in row.entries)
              '${e.key}': e.value,
          },
  ];
}

Map<String, Object?>? _byId(List<Map<String, Object?>> rows, Object? id) {
  for (final Map<String, Object?> row in rows) {
    if ('${row['id']}' == '$id') return row;
  }
  return null;
}

/// 撤销比对用的投影：标题、网址、父目录、同级顺序。
Map<String, Object?> _bookmarkState(Map<String, Object?>? row) => row == null
    ? const <String, Object?>{}
    : <String, Object?>{
        'title': row['title'],
        'url': row['url'],
        'parentId': row['parentId'] == null ? null : '${row['parentId']}',
        'index': row['index'] is num ? (row['index'] as num).toInt() : null,
      };

/// 按快照子树（[rows] 里 [rootId] 及其子孙，原顺序）在 [parentId] 下重建；返回新 id。
Future<int?> _recreate(
  OpDescribeKit kit,
  List<Map<String, Object?>> rows,
  Map<String, Object?> node,
  Object? parentId,
) async {
  final bool folder = node['folder'] == true;
  final Object? created = await kit.callRoute(
    'POST',
    _bookmarks,
    body: <String, Object?>{
      'type': folder ? 'folder' : 'bookmark',
      'title': node['title'],
      if (!folder) 'url': node['url'],
      'parent': ?parentId,
    },
  );
  final Object? newId = created is Map ? created['id'] : null;
  if (newId == null || !folder) return newId is num ? newId.toInt() : null;
  final List<Map<String, Object?>> children =
      rows
          .where(
            (Map<String, Object?> r) => '${r['parentId']}' == '${node['id']}',
          )
          .toList()
        ..sort(
          (Map<String, Object?> a, Map<String, Object?> b) =>
              ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0),
        );
  for (final Map<String, Object?> child in children) {
    await _recreate(kit, rows, child, newId);
  }
  return (newId as num).toInt();
}

List<OpDescription> _describeBookmarkOps(
  OpDescribeKit kit,
  OpAvailability Function() web,
) => <OpDescription>[
  OpDescription(
    id: 'web.bookmark.list',
    method: 'GET',
    pattern: _bookmarks,
    summary:
        'Bookmarks and folders of one folder (default: root), in their order; '
        'recursive=true lists the whole tree flat with parentId.',
    availability: web,
    params: const <OpParam>[
      OpParam.integer('folder', description: 'Folder id (omit for root).'),
      OpParam.boolean('recursive', description: 'Whole tree, flat.'),
    ],
  ),
  OpDescription(
    id: 'web.bookmark.add',
    method: 'POST',
    pattern: _bookmarks,
    summary:
        'Add a bookmark (or a folder with type=folder) at the end of a folder. '
        'Undo deletes it.',
    risk: OpRisk.write,
    availability: web,
    params: const <OpParam>[
      OpParam.string(
        'type',
        description: 'What to add (default bookmark).',
        enumValues: <String>['bookmark', 'folder'],
      ),
      OpParam.string(
        'url',
        description: 'Address (bookmark only; required for bookmarks).',
      ),
      OpParam.string(
        'title',
        description: 'Title (required for folders; bookmark default: host).',
      ),
      OpParam.integer('parent', description: 'Folder id (omit for root).'),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'id': result is Map ? result['id'] : null,
            'state': _bookmarkState(
              result is Map ? result.cast<String, Object?>() : null,
            ),
          },
      describe: (Map<String, Object?> p) => 'bookmark ${p['id']}',
      revert: (Map<String, Object?> payload) async {
        final Object? id = payload['id'];
        if (id == null) return const OpUndoOutcome.done();
        final List<Map<String, Object?>> rows = await _allBookmarks(kit);
        final Map<String, Object?>? row = _byId(rows, id);
        if (row == null) return const OpUndoOutcome.superseded();
        final Map<String, Object?> state = _bookmarkState(row)..remove('index');
        final Map<String, Object?> created = <String, Object?>{
          ...?(payload['state'] as Map?)?.cast<String, Object?>(),
        }..remove('index');
        final bool hasChildren = rows.any(
          (Map<String, Object?> r) => '${r['parentId']}' == '$id',
        );
        if (!OpDescribeKit.sameJson(state, created) || hasChildren) {
          return const OpUndoOutcome.superseded();
        }
        await kit.callRoute(
          'DELETE',
          '$_bookmarks/:id',
          params: <String, String>{'id': '$id'},
        );
        return const OpUndoOutcome.done();
      },
    ),
  ),
  OpDescription(
    id: 'web.bookmark.update',
    method: 'PUT',
    pattern: '$_bookmarks/:id',
    summary:
        'Edit a bookmark / folder: rename, change address, move to another '
        'folder (parent) or to root (root=true), or reorder (index in its '
        'folder, 0-based). Undo restores the previous values.',
    risk: OpRisk.write,
    availability: web,
    params: const <OpParam>[
      _bookmarkIdParam,
      OpParam.string('title', description: 'New title.'),
      OpParam.string('url', description: 'New address (bookmarks only).'),
      OpParam.integer('parent', description: 'Move into this folder id.'),
      OpParam.boolean('root', description: 'Move to the root folder.'),
      OpParam.integer(
        'index',
        description: 'New position among its siblings (0-based).',
      ),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) async =>
          _bookmarkState(_byId(await _allBookmarks(kit), params['id'])),
      write: (Map<String, String> params, Object? old) async {
        final Map<String, Object?> was = old is Map
            ? old.cast<String, Object?>()
            : const <String, Object?>{};
        final Map<String, Object?> now = _bookmarkState(
          _byId(await _allBookmarks(kit), params['id']),
        );
        final Object? oldParent = was['parentId'];
        await kit.callRoute(
          'PUT',
          '$_bookmarks/:id',
          params: params,
          body: <String, Object?>{
            if (was['title'] != now['title']) 'title': was['title'],
            if (was['url'] != now['url'] && was['url'] != null)
              'url': was['url'],
            if (oldParent != now['parentId'])
              if (oldParent == null) 'root': true else 'parent': oldParent,
            'index': ?was['index'],
          },
        );
      },
      newValue: (CtlCall call, Object? result) =>
          _bookmarkState(result is Map ? result.cast<String, Object?>() : null),
    ),
  ),
  OpDescription(
    id: 'web.bookmark.delete',
    method: 'DELETE',
    pattern: '$_bookmarks/:id',
    summary:
        'Delete a bookmark, or a folder with everything in it. Undo recreates '
        'it (and its contents) in the same place.',
    risk: OpRisk.write,
    availability: web,
    params: const <OpParam>[
      _bookmarkIdParam,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting a non-empty folder.',
      ),
    ],
    undo: opCustomUndo(
      capture: (CtlCall call) async {
        final List<Map<String, Object?>> rows = await _allBookmarks(kit);
        final String id = call.params['id'] ?? '';
        // 子树：自己 + 全部子孙（rows 是深度优先，按 parentId 链收集）。
        final Set<String> ids = <String>{id};
        final List<Map<String, Object?>> subtree = <Map<String, Object?>>[];
        for (final Map<String, Object?> row in rows) {
          if ('${row['id']}' == id || ids.contains('${row['parentId']}')) {
            ids.add('${row['id']}');
            subtree.add(row);
          }
        }
        return <String, Object?>{'id': id, 'subtree': subtree};
      },
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          before,
      describe: (Map<String, Object?> p) => 'bookmark ${p['id']}',
      revert: (Map<String, Object?> payload) async {
        final List<Map<String, Object?>> subtree = <Map<String, Object?>>[
          for (final Object? row in (payload['subtree'] as List? ?? const []))
            if (row is Map) row.cast<String, Object?>(),
        ];
        final Map<String, Object?>? node = _byId(subtree, payload['id']);
        if (node == null) return const OpUndoOutcome.failed('没有快照');
        final List<Map<String, Object?>> now = await _allBookmarks(kit);
        final Object? url = node['url'];
        if (url != null &&
            now.any((Map<String, Object?> r) => r['url'] == url)) {
          return const OpUndoOutcome.superseded('这个网址已经又加回书签');
        }
        final Object? parentId = node['parentId'];
        if (parentId != null && _byId(now, parentId) == null) {
          return const OpUndoOutcome.failed('原来的父文件夹已不存在');
        }
        final int? newId = await _recreate(kit, subtree, node, parentId);
        final Object? index = node['index'];
        if (newId != null && index is num) {
          await kit.callRoute(
            'PUT',
            '$_bookmarks/:id',
            params: <String, String>{'id': '$newId'},
            body: <String, Object?>{'index': index.toInt()},
          );
        }
        return const OpUndoOutcome.done();
      },
    ),
  ),
];

// ── 广告拦截 ──────────────────────────────────────────────────────────────

/// 白名单写操作的撤销：执行前的原文写回（之后被手改 = superseded）。
OpUndo _allowlistUndo(OpDescribeKit kit) => kit.readBackUndo(
  readMethod: 'GET',
  readPattern: _adblock,
  writeMethod: 'PUT',
  writePattern: '$_adblock/allowlist',
  field: 'allowlist',
);

List<OpDescription> _describeAdblockOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'web.adblock.status',
    method: 'GET',
    pattern: _adblock,
    summary:
        'Web ad blocking: master switch, engine status, the built-in filter '
        'lists (subscribed or not, last update) and the allowlisted sites.',
  ),
  OpDescription(
    id: 'web.adblock.enable',
    method: 'POST',
    pattern: '$_adblock/enabled',
    summary:
        'Turn web ad blocking on / off (turning on also syncs the filter '
        'lists). Undo restores the previous switch.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.boolean(
        'enabled',
        description: 'true = on, false = off.',
        required: true,
      ),
    ],
    undo: kit.readBackUndo(
      readMethod: 'GET',
      readPattern: _adblock,
      writeMethod: 'POST',
      writePattern: '$_adblock/enabled',
      field: 'enabled',
    ),
  ),
  OpDescription(
    id: 'web.adblock.list.set',
    method: 'POST',
    pattern: '$_adblock/lists/:id',
    summary:
        'Subscribe / unsubscribe a built-in filter list (ids from '
        'web.adblock.status). The engine catches up in the background. Undo '
        'restores the previous subscription.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Filter list id.',
        required: true,
        inPath: true,
      ),
      OpParam.boolean(
        'enabled',
        description: 'true = subscribe, false = unsubscribe.',
        required: true,
      ),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) => kit.readListField(
        pattern: _adblock,
        listKey: 'lists',
        id: params['id'] ?? '',
        field: 'enabled',
      ),
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'POST',
          '$_adblock/lists/:id',
          params: params,
          body: <String, Object?>{'enabled': old == true},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map ? result['enabled'] : null,
    ),
  ),
  const OpDescription(
    id: 'web.adblock.update',
    method: 'POST',
    pattern: '$_adblock/update',
    summary:
        'Update now: re-download / re-check every subscribed filter list and '
        'rebuild the engine. Refreshes cached lists only; changes no '
        'settings.',
  ),
  OpDescription(
    id: 'web.adblock.allowlist.set',
    method: 'PUT',
    pattern: '$_adblock/allowlist',
    summary:
        'Replace the whole allowlist text (sites where ads are not blocked; '
        'separated by commas / spaces). Undo restores the previous text.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'allowlist',
        description: 'Allowlist text, e.g. "example.com, example.org".',
        required: true,
      ),
    ],
    undo: _allowlistUndo(kit),
  ),
  OpDescription(
    id: 'web.adblock.allowlist.add',
    method: 'POST',
    pattern: '$_adblock/allowlist',
    summary:
        'Allow ads on one more site (and its subdomains). Undo restores the '
        'previous allowlist.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'host',
        description: 'Site, e.g. example.com.',
        required: true,
      ),
    ],
    undo: _allowlistUndo(kit),
  ),
  OpDescription(
    id: 'web.adblock.allowlist.remove',
    method: 'DELETE',
    pattern: '$_adblock/allowlist/:host',
    summary:
        'Stop allowing ads on a site (host as listed in allowlistHosts). Undo '
        'restores the previous allowlist.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'host',
        description: 'Allowlisted host from web.adblock.status.',
        required: true,
        inPath: true,
      ),
    ],
    undo: _allowlistUndo(kit),
  ),
];

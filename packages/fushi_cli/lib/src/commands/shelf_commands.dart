import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'collection_commands.dart' show collectionOrderCommandSpecs;
import 'library_commands.dart' show libraryItemPath;

/// 书架管理命令组：合集 / 标签 / 书签 / 收藏句（app 侧路由见
/// `fushi/lib/src/ops/ctl_library_manage_routes.dart`）。
///
/// 条目键与 `library` 组同一形状（`book:` / `srt:` / `video:` / `game:`，由
/// `library ls` 给出）；合集 id、标签 id 由各自的 `ls` 给出。
const List<CtlCommandGroup> shelfCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'collection',
    summary: '合集：列出、详情、新建、改名、删除、增删成员、封面、定序 / 一键排序（含 AI）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出合集',
        configure: _configureCollectionLs,
        build: _buildCollectionLs,
        render: _renderCollections,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '合集详情（成员与标签）',
        usage: '<id>',
        build: _buildCollectionGet,
        render: _renderCollectionDetail,
      ),
      CtlCommandSpec(
        name: 'create',
        summary: '新建合集（同名同类型已存在时复用）',
        usage: '<name...>',
        configure: _configureCollectionCreate,
        build: _buildCollectionCreate,
        render: _renderCollectionLine,
      ),
      CtlCommandSpec(
        name: 'rename',
        summary: '合集改名',
        usage: '<id> <name...>',
        build: _buildCollectionRename,
        render: _renderCollectionLine,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除合集（只删合集，不删条目；需 --yes）',
        usage: '<id>',
        configure: _configureYes,
        build: _buildCollectionRm,
        render: _renderDeleted,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '把条目加进合集',
        usage: '<id> <key...>',
        build: _buildCollectionAdd,
        render: _renderStatusResults,
      ),
      CtlCommandSpec(
        name: 'remove',
        summary: '把条目移出合集（移空后合集自动删除）',
        usage: '<id> <key...>',
        build: _buildCollectionRemove,
        render: _renderStatusResults,
      ),
      CtlCommandSpec(
        name: 'cover',
        summary: '设置合集自有封面（本地图片或 URL；--reset 清除）',
        usage: '<id> [<图片路径|URL>]',
        configure: _configureCover,
        build: _buildCollectionCover,
      ),
      // 定序：手动 order、一键 sort（名称 / 导入时间 / AI），见 collection_commands.dart。
      ...collectionOrderCommandSpecs,
    ],
  ),
  CtlCommandGroup(
    name: 'tag',
    summary: '标签：列出、新建、改名 / 改色、删除，给条目或合集打 / 摘标签',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出全部标签；给条目键则列这个条目的标签',
        usage: '[<key>]',
        build: _buildTagLs,
        render: _renderTags,
      ),
      CtlCommandSpec(
        name: 'create',
        summary: '新建标签',
        usage: '<name...>',
        configure: _configureTagColor,
        build: _buildTagCreate,
        render: _renderTagLine,
      ),
      CtlCommandSpec(
        name: 'edit',
        summary: '标签改名 / 改色',
        usage: '<id>',
        configure: _configureTagEdit,
        build: _buildTagEdit,
        render: _renderTagLine,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除标签（从所有条目上摘掉；需 --yes）',
        usage: '<id>',
        configure: _configureYes,
        build: _buildTagRm,
        render: _renderDeleted,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '给条目或合集（collection:<id>）打标签',
        usage: '<key|collection:id> <tag...>',
        configure: _configureTagAdd,
        build: _buildTagAdd,
        render: _renderStatusResults,
      ),
      CtlCommandSpec(
        name: 'remove',
        summary: '从条目或合集摘标签',
        usage: '<key|collection:id> <tag...>',
        build: _buildTagRemove,
        render: _renderStatusResults,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'bookmark',
    summary: '书签：列出、添加、删除（书 / PDF / 漫画 / 有声书）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出一本书的书签',
        usage: '<key>',
        build: _buildBookmarkLs,
        render: _renderBookmarks,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '加书签：EPUB 用 --chapter [--progress]，PDF / 漫画用 --page',
        usage: '<key>',
        configure: _configureBookmarkAdd,
        build: _buildBookmarkAdd,
        render: _renderBookmarkLine,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除书签',
        usage: '<id>',
        build: _buildBookmarkRm,
        render: _renderDeleted,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'favorite',
    summary: '收藏句：列出、删除、清空、导出',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出收藏句（可按条目筛）',
        usage: '[<key>]',
        configure: _configureFavoriteLs,
        build: _buildFavoriteLs,
        render: _renderFavorites,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除一条收藏句',
        usage: '<id>',
        build: _buildFavoriteRm,
        render: _renderDeleted,
      ),
      CtlCommandSpec(
        name: 'clear',
        summary: '清空全部收藏句（需 --yes）',
        configure: _configureYes,
        build: _buildFavoriteClear,
      ),
      CtlCommandSpec(
        name: 'export',
        summary: '导出收藏句到文件',
        usage: '<输出文件>',
        configure: _configureFavoriteExport,
        build: _buildFavoriteExport,
        render: _renderExported,
      ),
    ],
  ),
];

const String _root = '/api/admin/library';

// ── 公共 ───────────────────────────────────────────────────────────────

void _configureYes(ArgParser parser) =>
    parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认（必需）');

void _requireYes(CtlCommandContext context) {
  if (!context.flag('yes')) {
    throw const CtlUsageError('这一步不可撤销，确认请加 --yes');
  }
}

/// 正整数 id 位置参数。
int _idArg(CtlCommandContext context, int index, String name) {
  final String raw = context.positional(index, name);
  final int? id = int.tryParse(raw);
  if (id == null || id <= 0) throw CtlUsageError('<$name> 必须是正整数，收到「$raw」');
  return id;
}

/// 从第 [from] 个起的全部位置参数（非空）。
List<String> _restFrom(CtlCommandContext context, int from, String name) {
  final List<String> values = <String>[
    for (final String raw in context.rest.skip(from))
      if (raw.trim().isNotEmpty) raw.trim(),
  ];
  if (values.isEmpty) throw CtlUsageError('缺少参数 <$name>');
  return values;
}

String _deletedLabel(Map<Object?, Object?> data) =>
    '${data['name'] ?? data['label'] ?? data['text'] ?? ''}';

String _renderDeleted(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已删除：${_deletedLabel(data)}（id=${data['id']}）';
}

const Map<String, String> _statusLabels = <String, String>{
  'added': '已加入',
  'already': '已存在',
  'removed': '已移除',
  'absent': '本来就没有',
  'rejected': '拒绝',
  'missing': '没有这个标签',
};

String _renderStatusResults(Object? data) {
  if (data is! Map || data['results'] is! List) return renderCtlJson(data);
  final List<String> lines = <String>[];
  for (final Object? row in data['results'] as List) {
    if (row is! Map) continue;
    final String status =
        _statusLabels['${row['status']}'] ?? '${row['status']}';
    final String subject = '${row['key'] ?? row['tag']}';
    final Object? message = row['message'];
    lines.add(
      message == null ? '[$status] $subject' : '[$status] $subject：$message',
    );
  }
  if (data['collectionDeleted'] == true) lines.add('（合集已移空，自动删除）');
  return lines.isEmpty ? '（没有任何改动）' : lines.join('\n');
}

void _configureCover(ArgParser parser) =>
    parser.addFlag('reset', negatable: false, help: '清除自定义封面');

/// `<图片路径|URL>` → body：URL 原样走 `url`，本地路径转绝对路径走 `path`。
Map<String, Object?> _coverBody(CtlCommandContext context, int index) {
  if (context.flag('reset')) {
    if (context.optionalPositional(index) != null) {
      throw const CtlUsageError('--reset 不带图片参数');
    }
    return <String, Object?>{'reset': true};
  }
  final String source = context.positional(index, '图片路径|URL');
  final Uri? uri = Uri.tryParse(source);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return <String, Object?>{'url': source};
  }
  return <String, Object?>{'path': ctlAbsolutePath(source)};
}

// ── collection ─────────────────────────────────────────────────────────

String _collectionPath(int id) => '$_root/collections/$id';

void _configureCollectionLs(ArgParser parser) =>
    parser.addOption('item', help: '只列包含这个条目（键）的合集');

CtlRequestSpec _buildCollectionLs(CtlCommandContext context) {
  final String? item = context.option('item');
  return CtlRequestSpec.get(
    '$_root/collections',
    query: <String, String>{if (item != null) 'key': item},
  );
}

String _renderCollections(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('类型', 'type'),
    ('成员', 'members'),
    ('手动排过', 'manualOrder'),
    ('名称', 'name'),
  ],
  listKey: 'collections',
  empty: '（还没有合集）',
);

CtlRequestSpec _buildCollectionGet(CtlCommandContext context) =>
    CtlRequestSpec.get(_collectionPath(_idArg(context, 0, 'id')));

String _renderCollectionDetail(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer(
    '#${data['id']} ${data['name']}（${data['type']}，${data['members']} 项）',
  );
  final Object? tags = data['tags'];
  if (tags is List && tags.isNotEmpty) out.write('\n标签：${tags.join(', ')}');
  final String table = renderCtlTable(data, const <(String, String)>[
    ('键', 'key'),
    ('标题', 'title'),
    ('库页可见', 'visible'),
  ], listKey: 'items');
  out.write('\n$table');
  return out.toString();
}

void _configureCollectionCreate(ArgParser parser) => parser.addOption(
  'type',
  help: 'collection（无序合集）/ playlist（有序播放列表）',
  allowed: <String>['collection', 'playlist'],
  defaultsTo: 'collection',
);

CtlRequestSpec _buildCollectionCreate(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '$_root/collections',
      body: <String, Object?>{
        'name': context.joinedRest(0, 'name'),
        'type': context.option('type') ?? 'collection',
      },
    );

String _renderCollectionLine(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String head = '#${data['id']} ${data['name']}（${data['type']}）';
  return data['existed'] == true ? '$head 已存在，沿用' : head;
}

CtlRequestSpec _buildCollectionRename(CtlCommandContext context) =>
    CtlRequestSpec.put(
      _collectionPath(_idArg(context, 0, 'id')),
      body: <String, Object?>{'name': context.joinedRest(1, 'name')},
    );

CtlRequestSpec _buildCollectionRm(CtlCommandContext context) {
  final int id = _idArg(context, 0, 'id');
  _requireYes(context);
  return CtlRequestSpec(
    'DELETE',
    _collectionPath(id),
    body: const <String, Object?>{'confirm': true},
  );
}

CtlRequestSpec _buildCollectionAdd(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '${_collectionPath(_idArg(context, 0, 'id'))}/members',
      body: <String, Object?>{'keys': _restFrom(context, 1, 'key')},
    );

CtlRequestSpec _buildCollectionRemove(CtlCommandContext context) =>
    CtlRequestSpec(
      'DELETE',
      '${_collectionPath(_idArg(context, 0, 'id'))}/members',
      body: <String, Object?>{'keys': _restFrom(context, 1, 'key')},
    );

CtlRequestSpec _buildCollectionCover(CtlCommandContext context) =>
    CtlRequestSpec.put(
      '${_collectionPath(_idArg(context, 0, 'id'))}/cover',
      body: _coverBody(context, 1),
    );

// ── tag ────────────────────────────────────────────────────────────────

/// `collection:<id>` 目标 → 合集 id；否则 null（当条目键）。
int? _collectionTarget(String target) {
  if (!target.startsWith('collection:')) return null;
  final int? id = int.tryParse(target.substring('collection:'.length));
  if (id == null || id <= 0) {
    throw CtlUsageError('合集目标写成 collection:<id>，收到「$target」');
  }
  return id;
}

String _tagTargetPath(String target) {
  final int? collection = _collectionTarget(target);
  return collection != null
      ? '${_collectionPath(collection)}/tags'
      : '${libraryItemPath(target)}/tags';
}

CtlRequestSpec _buildTagLs(CtlCommandContext context) {
  final String? key = context.optionalPositional(0);
  if (key == null) return const CtlRequestSpec.get('$_root/tags');
  return CtlRequestSpec.get('${libraryItemPath(key)}/tags');
}

String _renderTags(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('颜色', 'color'),
      ('条目数', 'count'),
      ('名称', 'name'),
    ],
    listKey: 'tags',
    empty: '（没有标签）',
  );
  if (data is Map && data['key'] != null) return '${data['key']}：\n$table';
  return table;
}

void _configureTagColor(ArgParser parser) =>
    parser.addOption('color', help: '颜色 #RRGGBB（缺省按预设色轮换）');

CtlRequestSpec _buildTagCreate(CtlCommandContext context) {
  final String? color = context.option('color');
  return CtlRequestSpec.post(
    '$_root/tags',
    body: <String, Object?>{
      'name': context.joinedRest(0, 'name'),
      if (color != null) 'color': color,
    },
  );
}

String _renderTagLine(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '#${data['id']} ${data['name']}（${data['color']}）';
}

void _configureTagEdit(ArgParser parser) {
  parser.addOption('name', help: '新名字');
  _configureTagColor(parser);
}

CtlRequestSpec _buildTagEdit(CtlCommandContext context) {
  final int id = _idArg(context, 0, 'id');
  final String? name = context.option('name');
  final String? color = context.option('color');
  if (name == null && color == null) {
    throw const CtlUsageError('至少给 --name 或 --color');
  }
  return CtlRequestSpec.put(
    '$_root/tags/$id',
    body: <String, Object?>{
      if (name != null) 'name': name,
      if (color != null) 'color': color,
    },
  );
}

CtlRequestSpec _buildTagRm(CtlCommandContext context) {
  final int id = _idArg(context, 0, 'id');
  _requireYes(context);
  return CtlRequestSpec(
    'DELETE',
    '$_root/tags/$id',
    body: const <String, Object?>{'confirm': true},
  );
}

void _configureTagAdd(ArgParser parser) =>
    parser.addFlag('create', negatable: false, help: '标签不存在时自动新建');

CtlRequestSpec _buildTagAdd(CtlCommandContext context) => CtlRequestSpec.post(
  _tagTargetPath(context.positional(0, 'key|collection:id')),
  body: <String, Object?>{
    'tags': _restFrom(context, 1, 'tag'),
    'create': context.flag('create'),
  },
);

CtlRequestSpec _buildTagRemove(CtlCommandContext context) => CtlRequestSpec(
  'DELETE',
  _tagTargetPath(context.positional(0, 'key|collection:id')),
  body: <String, Object?>{'tags': _restFrom(context, 1, 'tag')},
);

// ── bookmark ───────────────────────────────────────────────────────────

CtlRequestSpec _buildBookmarkLs(CtlCommandContext context) =>
    CtlRequestSpec.get(
      '${libraryItemPath(context.positional(0, 'key'))}/bookmarks',
    );

String _bookmarkPosition(Map<Object?, Object?> row) => row['page'] != null
    ? 'P.${row['page']}'
    : '第 ${row['chapter']} 章 ${row['progress']}%';

String _renderBookmarks(Object? data) {
  if (data is! Map || data['bookmarks'] is! List) return renderCtlJson(data);
  final List<Object?> rows = data['bookmarks'] as List<Object?>;
  if (rows.isEmpty) return '（没有书签）';
  return <String>[
    for (final Object? row in rows)
      if (row is Map)
        '#${row['id']} ${_bookmarkPosition(row)}  ${row['label']}',
  ].join('\n');
}

void _configureBookmarkAdd(ArgParser parser) => parser
  ..addOption('chapter', help: 'EPUB：第几章（1 起计）')
  ..addOption('progress', help: 'EPUB：章内百分比 0–100（缺省 0）')
  ..addOption('page', help: 'PDF / 漫画：第几页（1 起计）')
  ..addOption('label', help: '书签名（缺省 Ch.N / P.N）');

CtlRequestSpec _buildBookmarkAdd(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final int? chapter = context.intOption('chapter');
  final int? page = context.intOption('page');
  final String? progress = context.option('progress');
  if (chapter == null && page == null) {
    throw const CtlUsageError('需要 --chapter（EPUB）或 --page（PDF / 漫画）');
  }
  if (chapter != null && page != null) {
    throw const CtlUsageError('--chapter 与 --page 只给一个');
  }
  double? progressValue;
  if (progress != null) {
    progressValue = double.tryParse(progress);
    if (progressValue == null) throw const CtlUsageError('--progress 必须是数字');
  }
  final String? label = context.option('label');
  return CtlRequestSpec.post(
    '${libraryItemPath(key)}/bookmarks',
    body: <String, Object?>{
      if (chapter != null) 'chapter': chapter,
      if (page != null) 'page': page,
      if (progressValue != null) 'progress': progressValue,
      if (label != null) 'label': label,
    },
  );
}

String _renderBookmarkLine(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已加书签 #${data['id']}：${_bookmarkPosition(data)}  ${data['label']}';
}

CtlRequestSpec _buildBookmarkRm(CtlCommandContext context) =>
    CtlRequestSpec.delete('$_root/bookmarks/${_idArg(context, 0, 'id')}');

// ── favorite ───────────────────────────────────────────────────────────

void _configureFavoriteLs(ArgParser parser) =>
    parser.addOption('limit', abbr: 'n', help: '最多列几条');

CtlRequestSpec _buildFavoriteLs(CtlCommandContext context) {
  final String? key = context.optionalPositional(0);
  final int? limit = context.intOption('limit');
  if (limit != null && limit <= 0) throw const CtlUsageError('--limit 必须大于 0');
  return CtlRequestSpec.get(
    '$_root/favorites',
    query: <String, String>{
      if (key != null) 'key': key,
      if (limit != null) 'limit': '$limit',
    },
  );
}

String _renderFavorites(Object? data) {
  if (data is! Map || data['favorites'] is! List) return renderCtlJson(data);
  final List<Object?> rows = data['favorites'] as List<Object?>;
  if (rows.isEmpty) return '（没有收藏句）';
  final List<String> lines = <String>[
    for (final Object? row in rows)
      if (row is Map) '${row['id']}  [${row['bookTitle']}] ${row['text']}',
  ];
  final Object? total = data['total'];
  if (total is int && total > rows.length) {
    lines.add('（共 $total 条，只显示前 ${rows.length} 条）');
  }
  return lines.join('\n');
}

CtlRequestSpec _buildFavoriteRm(CtlCommandContext context) =>
    CtlRequestSpec.delete(
      '$_root/favorites/${Uri.encodeComponent(context.positional(0, 'id'))}',
    );

CtlRequestSpec _buildFavoriteClear(CtlCommandContext context) {
  _requireYes(context);
  return const CtlRequestSpec.post(
    '$_root/favorites/clear',
    body: <String, Object?>{'confirm': true},
  );
}

void _configureFavoriteExport(ArgParser parser) => parser
  ..addOption(
    'format',
    help: '文件格式',
    allowed: <String>['markdown', 'txt', 'csv', 'json'],
    defaultsTo: 'markdown',
  )
  ..addOption('item', help: '只导出这个条目（键）的收藏句')
  ..addFlag('dedupe', negatable: false, help: '同一句只留一条');

CtlRequestSpec _buildFavoriteExport(CtlCommandContext context) {
  final String? item = context.option('item');
  return CtlRequestSpec.post(
    '$_root/favorites/export',
    body: <String, Object?>{
      'path': ctlAbsolutePath(context.positional(0, '输出文件')),
      'format': context.option('format') ?? 'markdown',
      if (item != null) 'key': item,
      'dedupe': context.flag('dedupe'),
    },
  );
}

String _renderExported(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已导出 ${data['count']} 条（${data['format']}）：${data['path']}';
}

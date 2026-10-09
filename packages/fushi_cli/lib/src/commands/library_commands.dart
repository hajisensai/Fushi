import 'package:args/args.dart';

import '../ctl_commands.dart';

/// library 域命令（app 侧路由见 `fushi/lib/src/platform/desktop/ctl/ctl_library_routes.dart`）。
///
/// 条目键形如 `book:<bookKey>` / `srt:<uid>` / `video:<bookUid>` / `game:<id>`，
/// 由 `library ls` 给出；拼进路径时整体 URI 编码（id 里可能有 `/`）。
const List<CtlCommandGroup> libraryCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'library',
    summary: '书架 / 媒体库：列出、详情、删除、导入、打开、最近打开、来源扫描',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出库里的条目',
        configure: _configureLs,
        build: _buildLs,
        render: _renderEntries,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '单个条目详情',
        usage: '<key>',
        build: _buildGet,
        render: _renderDetail,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '从库删除条目（需 --yes）',
        usage: '<key>',
        configure: _configureRm,
        build: _buildRm,
        render: _renderRemoved,
      ),
      CtlCommandSpec(
        name: 'import',
        summary: '导入本机文件 / 目录',
        usage: '<path...>',
        configure: _configureImport,
        build: _buildImport,
        render: _renderImport,
      ),
      CtlCommandSpec(
        name: 'open',
        summary: '在 app 里打开阅读器 / 播放器',
        usage: '<key>',
        configure: _configureOpen,
        build: _buildOpen,
        render: _renderOpened,
      ),
      CtlCommandSpec(
        name: 'history',
        summary: '最近打开',
        configure: _configureHistory,
        build: _buildHistory,
        render: _renderEntries,
      ),
      CtlCommandSpec(
        name: 'sources',
        summary: '列出来源库（扫描根）',
        configure: _configureSourceKind,
        build: _buildSources,
        render: _renderSources,
      ),
      CtlCommandSpec(
        name: 'scan',
        summary: '扫描来源库并入库新文件',
        configure: _configureScan,
        build: _buildScan,
        render: _renderScan,
      ),
    ],
  ),
];

const String _root = '/api/admin/library';

/// `--kind` 的值域（与 app 侧 `LibraryCtlKind` 同名）。
const List<String> kLibraryKinds = <String>[
  'book',
  'pdf',
  'manga',
  'audiobook',
  'video',
  'game',
];

/// 来源库种类（`MediaSources.mediaKind`）。
const List<String> kLibrarySourceKinds = <String>['book', 'video', 'manga'];

/// 条目路径：键整体编码成一段。
String libraryItemPath(String key) =>
    '$_root/items/${Uri.encodeComponent(key)}';

// ── ls ─────────────────────────────────────────────────────────────────

void _configureLs(ArgParser parser) => parser
  ..addOption('kind', help: '只列这些种类（逗号分隔）：${kLibraryKinds.join('/')}')
  ..addOption('search', abbr: 's', help: '按标题 / 作者搜索（全角半角、片假名平假名互通）')
  ..addOption('limit', help: '最多列几条');

CtlRequestSpec _buildLs(CtlCommandContext context) {
  final String? kind = _kindList(context.option('kind'));
  final int? limit = context.intOption('limit');
  if (limit != null && limit <= 0) throw const CtlUsageError('--limit 必须大于 0');
  final String? search = context.optionalPositional(0) == null
      ? context.option('search')
      : context.joinedRest(0, 'search');
  return CtlRequestSpec.get(
    '$_root/items',
    query: <String, String>{
      if (kind != null) 'kind': kind,
      if (search != null) 'search': search,
      if (limit != null) 'limit': '$limit',
    },
  );
}

/// 校验并规整 `--kind a,b`。
String? _kindList(String? raw) {
  if (raw == null) return null;
  final List<String> kinds = <String>[
    for (final String part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim().toLowerCase(),
  ];
  for (final String kind in kinds) {
    if (!kLibraryKinds.contains(kind)) {
      throw CtlUsageError('--kind 不认识「$kind」，可选：${kLibraryKinds.join('/')}');
    }
  }
  return kinds.isEmpty ? null : kinds.join(',');
}

String _renderEntries(Object? data) {
  final String table = renderCtlTable(data, const <(String, String)>[
    ('键', 'key'),
    ('种类', 'kind'),
    ('进度', 'progress'),
    ('标题', 'title'),
  ], listKey: 'items');
  if (data is! Map) return table;
  final List<String> footer = <String>[];
  final Object? total = data['total'];
  final Object? items = data['items'];
  if (total is int && items is List && total > items.length) {
    footer.add('（共 $total 条，只显示前 ${items.length} 条）');
  }
  final Object? hidden = data['hiddenKinds'];
  if (hidden is List && hidden.isNotEmpty) {
    footer.add('（${hidden.join('/')} 所属模块已关闭，未列出）');
  }
  return footer.isEmpty ? table : '$table\n${footer.join('\n')}';
}

// ── get ────────────────────────────────────────────────────────────────

CtlRequestSpec _buildGet(CtlCommandContext context) =>
    CtlRequestSpec.get(libraryItemPath(context.positional(0, 'key')));

String _renderDetail(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    for (final MapEntry<Object?, Object?> entry in data.entries)
      '${entry.key}: ${entry.value}',
  ].join('\n');
}

// ── rm ─────────────────────────────────────────────────────────────────

void _configureRm(ArgParser parser) => parser
  ..addFlag('yes', abbr: 'y', negatable: false, help: '确认删除（必需）')
  ..addFlag('everywhere', negatable: false, help: '同步删除到其他设备（记删除墓碑；缺省只删本机）')
  ..addFlag(
    'delete-files',
    negatable: false,
    help: '同时删除本地原件（有声书原始音频 / 视频原文件；游戏不支持）',
  )
  ..addFlag('delete-stats', negatable: false, help: '同时删除统计数据');

CtlRequestSpec _buildRm(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  if (!context.flag('yes')) {
    throw const CtlUsageError('删除不可撤销，确认请加 --yes');
  }
  return CtlRequestSpec(
    'DELETE',
    libraryItemPath(key),
    body: <String, Object?>{
      'confirm': true,
      'everywhere': context.flag('everywhere'),
      'deleteFiles': context.flag('delete-files'),
      'deleteStatistics': context.flag('delete-stats'),
    },
  );
}

String _renderRemoved(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer('已删除：${data['title']}（${data['key']}）');
  if (data['everywhere'] == true) out.write('，将同步删除到其他设备');
  final Object? removed = data['removedFiles'];
  if (removed is int) out.write('，删掉本地文件 $removed 个');
  final Object? failures = data['fileFailures'];
  if (failures is List && failures.isNotEmpty) {
    out.write('\n以下本地文件没删掉：\n  ${failures.join('\n  ')}');
  }
  return out.toString();
}

// ── import ─────────────────────────────────────────────────────────────

void _configureImport(ArgParser parser) => parser
  ..addOption(
    'kind',
    help:
        '按这个种类导入：book（文件；目录则登记成书来源）/ manga / '
        'audiobook（全部路径合成一本：正文+字幕+音频）/ video（目录登记成来源）/ game',
    allowed: <String>['book', 'manga', 'audiobook', 'video', 'game'],
  )
  ..addOption(
    'duplicate',
    help: '同名条目已在库时：skip 跳过 / suffix 加「 (2)」留副本',
    allowed: <String>['skip', 'suffix'],
    defaultsTo: 'skip',
  );

CtlRequestSpec _buildImport(CtlCommandContext context) {
  context.positional(0, 'path');
  return CtlRequestSpec.post(
    '$_root/import',
    body: <String, Object?>{
      'paths': <String>[
        for (final String raw in context.rest)
          if (raw.trim().isNotEmpty) ctlAbsolutePath(raw),
      ],
      if (context.option('kind') != null) 'kind': context.option('kind'),
      'duplicate': context.option('duplicate') ?? 'skip',
    },
  );
}

const Map<String, String> _importStatusLabels = <String, String>{
  'imported': '已导入',
  'skipped': '已在库，跳过',
  'source_added': '已登记来源',
  'source_exists': '已是来源',
  'unsupported': '不支持',
  'failed': '失败',
};

String _renderImport(Object? data) {
  if (data is! Map || data['results'] is! List) return renderCtlJson(data);
  final List<String> lines = <String>[];
  for (final Object? row in data['results'] as List) {
    if (row is! Map) continue;
    final String status =
        _importStatusLabels['${row['status']}'] ?? '${row['status']}';
    final StringBuffer line = StringBuffer('[$status] ${row['path']}');
    final Object? keys = row['keys'];
    if (keys is List && keys.isNotEmpty) line.write(' → ${keys.join(', ')}');
    final Object? message = row['message'];
    if (message != null) line.write('\n    $message');
    lines.add(line.toString());
  }
  return lines.isEmpty ? '（没有导入任何东西）' : lines.join('\n');
}

// ── open ───────────────────────────────────────────────────────────────

void _configureOpen(ArgParser parser) => parser.addOption(
  'at',
  help: '起始位置：EPUB 书是 1 起计的章号，视频是时间点（秒 / m:ss / h:mm:ss）',
);

CtlRequestSpec _buildOpen(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final String? at = context.option('at');
  return CtlRequestSpec.post(
    '${libraryItemPath(key)}/open',
    body: <String, Object?>{if (at != null) 'at': at},
  );
}

String _renderOpened(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已打开：${data['title']}（${data['key']}）';
}

// ── history ────────────────────────────────────────────────────────────

void _configureHistory(ArgParser parser) =>
    parser.addOption('limit', abbr: 'n', help: '条数（缺省 20）');

CtlRequestSpec _buildHistory(CtlCommandContext context) {
  final int? limit = context.intOption('limit');
  if (limit != null && limit <= 0) throw const CtlUsageError('--limit 必须大于 0');
  return CtlRequestSpec.get(
    '$_root/history',
    query: <String, String>{if (limit != null) 'limit': '$limit'},
  );
}

// ── sources / scan ─────────────────────────────────────────────────────

void _configureSourceKind(ArgParser parser) => parser.addOption(
  'kind',
  help: '只看这种来源：${kLibrarySourceKinds.join('/')}',
  allowed: kLibrarySourceKinds,
);

CtlRequestSpec _buildSources(CtlCommandContext context) {
  final String? kind = context.option('kind');
  return CtlRequestSpec.get(
    '$_root/sources',
    query: <String, String>{if (kind != null) 'kind': kind},
  );
}

String _renderSources(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('种类', 'kind'),
    ('条目数', 'mediaCount'),
    ('名称', 'label'),
    ('路径', 'path'),
  ],
  listKey: 'sources',
  empty: '（还没有来源库）',
);

void _configureScan(ArgParser parser) {
  _configureSourceKind(parser);
  parser.addOption('source', help: '只扫这个来源（id 见 library sources）');
}

CtlRequestSpec _buildScan(CtlCommandContext context) {
  final String? kind = context.option('kind');
  final int? source = context.intOption('source');
  return CtlRequestSpec.post(
    '$_root/scan',
    body: <String, Object?>{
      if (kind != null) 'kind': kind,
      if (source != null) 'source': source,
    },
  );
}

String _renderScan(Object? data) {
  if (data is! Map || data['results'] is! List) return renderCtlJson(data);
  final List<String> lines = <String>[];
  for (final Object? row in data['results'] as List) {
    if (row is! Map) continue;
    final String head =
        '#${row['id']} ${row['label']}：发现 ${row['discovered']} 个，入库 ${row['imported']} 个';
    lines.add(row['error'] == null ? head : '$head（出错：${row['error']}）');
  }
  return lines.isEmpty ? '（没有可扫描的来源）' : lines.join('\n');
}

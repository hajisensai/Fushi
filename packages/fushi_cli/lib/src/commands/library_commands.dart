import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'reader_commands.dart';
import 'shelf_commands.dart';

/// library 域命令（app 侧路由见 `fushi/lib/src/ops/ctl_library_routes.dart`）。
///
/// 条目键形如 `book:<bookKey>` / `srt:<uid>` / `video:<bookUid>` / `game:<id>`，
/// 由 `library ls` 给出；拼进路径时整体 URI 编码（id 里可能有 `/`）。
///
/// 同一个域的其余命令组（合集 / 标签 / 书签 / 收藏句见 `shelf_commands.dart`，
/// 阅读器 / 有声书 / 漫画 OCR 见 `reader_commands.dart`）也经这张表注册。
const List<CtlCommandGroup> libraryCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'library',
    summary: '书架 / 媒体库：列出、详情、删除、导入、打开、改名、封面、读完、重置、来源',
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
      CtlCommandSpec(
        name: 'organize',
        summary: 'AI 整理库：把该在一起的条目归进合集（直接改库，可用 organize-undo 撤销）',
        configure: _configureOrganize,
        build: _buildOrganize,
        render: _renderOrganize,
      ),
      CtlCommandSpec(
        name: 'organize-history',
        summary: '列出最近的 AI 整理记录与每处改动',
        configure: _configureOrganizeHistory,
        build: _buildOrganizeHistory,
        render: _renderOrganizeHistory,
      ),
      CtlCommandSpec(
        name: 'organize-undo',
        summary: '撤销一次 AI 整理里还没撤销的全部改动',
        usage: '<记录 id>',
        build: _buildOrganizeUndo,
        render: _renderOrganizeUndo,
      ),
      CtlCommandSpec(
        name: 'source-add',
        summary: '把本机目录登记成来源库并扫描',
        usage: '<目录>',
        configure: _configureSourceAdd,
        build: _buildSourceAdd,
        render: _renderSourceAdded,
      ),
      CtlCommandSpec(
        name: 'source-rename',
        summary: '来源库改名',
        usage: '<id> <name...>',
        build: _buildSourceRename,
      ),
      CtlCommandSpec(
        name: 'source-rm',
        summary: '移除来源库（条目保留；需 --yes）',
        usage: '<id>',
        configure: _configureSourceRm,
        build: _buildSourceRm,
      ),
      CtlCommandSpec(
        name: 'rename',
        summary: '条目改名（书 / 有声书是显示名覆盖，--reset 恢复原名）',
        usage: '<key> [<title...>]',
        configure: _configureReset,
        build: _buildRename,
        render: _renderRenamed,
      ),
      CtlCommandSpec(
        name: 'cover',
        summary: '换封面（本地图片或 URL；书 / 有声书可 --reset 恢复默认）',
        usage: '<key> [<图片路径|URL>]',
        configure: _configureReset,
        build: _buildCover,
      ),
      CtlCommandSpec(
        name: 'complete',
        summary: '标记读完 / 看完（--undo 取消读完）',
        usage: '<key>',
        configure: _configureComplete,
        build: _buildComplete,
      ),
      CtlCommandSpec(
        name: 'reset',
        summary: '重置阅读 / 观看进度（需 --yes）',
        usage: '<key>',
        configure: _configureResetProgress,
        build: _buildResetProgress,
      ),
    ],
  ),
  ...shelfCommandGroups,
  ...readerCommandGroups,
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
  'queued': '已排队',
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

void _configureOpen(ArgParser parser) => parser
  ..addOption('at', help: '起始位置：EPUB 书是 1 起计的章号，视频是时间点（秒 / m:ss / h:mm:ss）')
  ..addOption('chapter', help: 'EPUB：第几章；在线漫画：第几话（1 起计）')
  ..addOption('progress', help: 'EPUB：配合 --chapter 的章内百分比 0–100')
  ..addOption('page', help: 'PDF / 漫画：第几页（1 起计）');

CtlRequestSpec _buildOpen(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final String? at = context.option('at');
  final int? chapter = context.intOption('chapter');
  final int? page = context.intOption('page');
  final String? progressRaw = context.option('progress');
  double? progress;
  if (progressRaw != null) {
    progress = double.tryParse(progressRaw);
    if (progress == null) throw const CtlUsageError('--progress 必须是数字');
  }
  if (chapter != null && chapter < 1) {
    throw const CtlUsageError('--chapter 从 1 开始数');
  }
  if (page != null && page < 1) throw const CtlUsageError('--page 从 1 开始数');
  return CtlRequestSpec.post(
    '${libraryItemPath(key)}/open',
    body: <String, Object?>{
      if (at != null) 'at': at,
      if (chapter != null) 'chapter': chapter,
      if (page != null) 'page': page,
      if (progress != null) 'progress': progress,
    },
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

// ── AI 整理库（app 侧路由见 ctl_library_organize_routes.dart）────────────────

const String _organizeRoot = '/api/admin/library/organize';

/// `--domain` 的值域（与 `CollectionShelfDomain` 同名）。
const List<String> kLibraryOrganizeDomains = <String>[
  'books',
  'manga',
  'video',
  'games',
];

void _configureOrganize(ArgParser parser) {
  parser
    ..addOption(
      'domain',
      help: '哪个库：books（书架）| manga（漫画库）| video（媒体库）| games（游戏库）',
      allowed: kLibraryOrganizeDomains,
    )
    ..addFlag(
      'yes',
      negatable: false,
      help:
          '同意把标题、作者或品牌、年份和视频文件夹名发给 AI 提供商（可能计费）；'
          '界面里同意过就不必加',
    );
}

CtlRequestSpec _buildOrganize(CtlCommandContext context) {
  final String? domain = context.option('domain');
  if (domain == null) throw const CtlUsageError('缺少 --domain');
  return CtlRequestSpec.post(
    _organizeRoot,
    body: <String, Object?>{
      'domain': domain,
      if (context.flag('yes')) 'yes': true,
    },
  );
}

String _renderOrganize(Object? data) {
  if (data is! Map) return '$data';
  final String error = data['error'] == null ? '' : '（${data['error']}）';
  return '整理记录 #${data['runId']} · ${data['status']}$error · '
      '${data['changes']} 处改动 · ${data['requests']} 次请求';
}

void _configureOrganizeHistory(ArgParser parser) {
  parser.addOption('limit', help: '最多列几次（默认 20）');
}

CtlRequestSpec _buildOrganizeHistory(CtlCommandContext context) {
  final int? limit = context.intOption('limit');
  return CtlRequestSpec.get(
    '/api/admin/library/organize/runs',
    query: <String, String>{if (limit != null) 'limit': '$limit'},
  );
}

String _renderOrganizeHistory(Object? data) {
  final Object? runs = data is Map ? data['runs'] : null;
  if (runs is! List || runs.isEmpty) return '还没有整理过';
  final StringBuffer out = StringBuffer();
  for (final Object? raw in runs) {
    if (raw is! Map) continue;
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(
      (raw['startedAt'] as num?)?.toInt() ?? 0,
    );
    out.writeln(
      '#${raw['id']} ${at.toIso8601String().substring(0, 16)} '
      '${raw['domain']} · ${raw['trigger']} · ${raw['status']}'
      '${raw['error'] == null ? '' : '（${raw['error']}）'}',
    );
    for (final Object? c in (raw['changes'] as List?) ?? const <Object?>[]) {
      if (c is! Map) continue;
      out.writeln(
        '    ${c['kind']} 「${c['collection']}」 ${c['source']}/${c['confidence']}'
        '${c['undone'] == true ? ' · 已撤销' : ''}',
      );
    }
  }
  return out.toString().trimRight();
}

CtlRequestSpec _buildOrganizeUndo(CtlCommandContext context) {
  final String raw = context.positional(0, '记录 id');
  if (!RegExp(r'^[1-9]\d*$').hasMatch(raw)) {
    throw CtlUsageError('记录 id 必须是正整数：$raw');
  }
  return CtlRequestSpec.post('/api/admin/library/organize/runs/$raw/undo');
}

String _renderOrganizeUndo(Object? data) =>
    data is Map ? '已撤销 ${data['undone']} 处' : '$data';

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

// ── source-add / source-rename / source-rm ─────────────────────────────

void _configureSourceAdd(ArgParser parser) => parser.addOption(
  'kind',
  help: '来源种类（必需）：${kLibrarySourceKinds.join('/')}',
  allowed: kLibrarySourceKinds,
);

CtlRequestSpec _buildSourceAdd(CtlCommandContext context) {
  final String path = context.positional(0, '目录');
  final String? kind = context.option('kind');
  if (kind == null)
    throw const CtlUsageError('需要 --kind（book / video / manga）');
  return CtlRequestSpec.post(
    '$_root/sources',
    body: <String, Object?>{'path': ctlAbsolutePath(path), 'kind': kind},
  );
}

String _renderSourceAdded(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return data['added'] == true
      ? '已登记来源 #${data['id']} 并扫描：${data['path']}'
      : '已是来源库：${data['path']}（重扫用 library scan）';
}

int _sourceId(CtlCommandContext context) {
  final String raw = context.positional(0, 'id');
  final int? id = int.tryParse(raw);
  if (id == null || id <= 0) throw CtlUsageError('<id> 必须是正整数，收到「$raw」');
  return id;
}

CtlRequestSpec _buildSourceRename(CtlCommandContext context) =>
    CtlRequestSpec.put(
      '$_root/sources/${_sourceId(context)}',
      body: <String, Object?>{'label': context.joinedRest(1, 'name')},
    );

void _configureSourceRm(ArgParser parser) => parser
  ..addFlag('yes', abbr: 'y', negatable: false, help: '确认移除（必需）')
  ..addOption('migrate-to', help: '视频来源：把指向它的下载订阅 / 未整理任务迁到这个视频来源（缺省停用订阅）');

CtlRequestSpec _buildSourceRm(CtlCommandContext context) {
  final int id = _sourceId(context);
  if (!context.flag('yes')) throw const CtlUsageError('移除来源请加 --yes');
  final int? migrateTo = context.intOption('migrate-to');
  return CtlRequestSpec(
    'DELETE',
    '$_root/sources/$id',
    body: <String, Object?>{
      'confirm': true,
      if (migrateTo != null) 'migrateTo': migrateTo,
    },
  );
}

// ── rename / cover / complete / reset ──────────────────────────────────

void _configureReset(ArgParser parser) =>
    parser.addFlag('reset', negatable: false, help: '恢复默认（原名 / 默认封面）');

CtlRequestSpec _buildRename(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  if (context.flag('reset')) {
    if (context.optionalPositional(1) != null) {
      throw const CtlUsageError('--reset 不带新名字');
    }
    return CtlRequestSpec.put(
      '${libraryItemPath(key)}/title',
      body: const <String, Object?>{'reset': true},
    );
  }
  return CtlRequestSpec.put(
    '${libraryItemPath(key)}/title',
    body: <String, Object?>{'title': context.joinedRest(1, 'title')},
  );
}

String _renderRenamed(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['key']} → ${data['title']}';
}

CtlRequestSpec _buildCover(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final String path = '${libraryItemPath(key)}/cover';
  if (context.flag('reset')) {
    if (context.optionalPositional(1) != null) {
      throw const CtlUsageError('--reset 不带图片参数');
    }
    return CtlRequestSpec.put(
      path,
      body: const <String, Object?>{'reset': true},
    );
  }
  final String source = context.positional(1, '图片路径|URL');
  final Uri? uri = Uri.tryParse(source);
  final bool remote =
      uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  return CtlRequestSpec.put(
    path,
    body: <String, Object?>{
      if (remote) 'url': source else 'path': ctlAbsolutePath(source),
    },
  );
}

void _configureComplete(ArgParser parser) =>
    parser.addFlag('undo', negatable: false, help: '取消读完标记');

CtlRequestSpec _buildComplete(CtlCommandContext context) => CtlRequestSpec.put(
  '${libraryItemPath(context.positional(0, 'key'))}/completed',
  body: <String, Object?>{'completed': !context.flag('undo')},
);

void _configureResetProgress(ArgParser parser) => parser
  ..addFlag('yes', abbr: 'y', negatable: false, help: '确认重置（必需）')
  ..addOption(
    'stats',
    help: '学习记录：keep 不动 / last 撤销最近一次会话 / all 全部清除',
    allowed: <String>['keep', 'last', 'all'],
    defaultsTo: 'keep',
  );

CtlRequestSpec _buildResetProgress(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  if (!context.flag('yes')) throw const CtlUsageError('重置进度请加 --yes');
  return CtlRequestSpec.post(
    '${libraryItemPath(key)}/reset',
    body: <String, Object?>{
      'confirm': true,
      'stats': context.option('stats') ?? 'keep',
    },
  );
}

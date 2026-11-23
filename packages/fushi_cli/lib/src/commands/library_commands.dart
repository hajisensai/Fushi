import 'dart:convert';
import 'dart:io';

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
        name: 'organize-proposals',
        summary: '列出 AI 整理产出的待确认建议（合并 / 改名你自己的合集）',
        configure: _configureOrganizeProposals,
        build: _buildOrganizeProposals,
        render: _renderOrganizeProposals,
      ),
      CtlCommandSpec(
        name: 'organize-accept',
        summary: '接受一条待确认建议：以你的身份合并 / 改名合集（不进整理撤销）',
        usage: '<建议 id>',
        build: _buildOrganizeAccept,
        render: _renderOrganizeResolve,
      ),
      CtlCommandSpec(
        name: 'organize-reject',
        summary: '拒绝一条待确认建议（同样的建议以后不再提）',
        usage: '<建议 id>',
        build: _buildOrganizeReject,
        render: _renderOrganizeResolve,
      ),
      CtlCommandSpec(
        name: 'map',
        summary: '整库地图（AI 管库 v3 用的紧凑列式快照，分页；只读）',
        configure: _configureMap,
        build: _buildMap,
      ),
      CtlCommandSpec(
        name: 'apply-changes',
        summary: '提交一整份库变更集（JSON 文件，AI 身份落库、整份一条撤销记录；--dry-run 只预演）',
        usage: '<变更集.json>',
        configure: _configureApplyChanges,
        build: _buildApplyChanges,
      ),
      CtlCommandSpec(
        name: 'curate',
        summary:
            'AI 库管家：整库跑一趟（合集归属 → 认身份 → 作品关系 → 作品层；直接改库，可用 curate-undo 整趟撤销）',
        configure: _configureCurate,
        build: _buildCurate,
        render: _renderCurate,
      ),
      CtlCommandSpec(
        name: 'curate-status',
        summary: 'AI 库管家是否在跑、跑到哪一步、上一趟的结论',
        build: _buildCurateStatus,
        render: _renderCurateStatus,
      ),
      CtlCommandSpec(
        name: 'curate-runs',
        summary: '列出本机最近的 AI 库管家运行记录与各步结论',
        configure: _configureCurateRuns,
        build: _buildCurateRuns,
        render: _renderCurateRuns,
      ),
      CtlCommandSpec(
        name: 'curate-undo',
        summary: '整趟撤销一次 AI 库管家运行（之后被你改过的部分保留）',
        usage: '<运行 id>',
        build: _buildCurateUndo,
        render: _renderCurateUndo,
      ),
      CtlCommandSpec(
        name: 'curate-links',
        summary: '对几个条目做一次作品关系推断（库管家 ④ 步本身；可在 AI 操作记录里撤销）',
        usage: '<kind:key>...',
        configure: _configureCurateLinks,
        build: _buildCurateLinks,
        render: _renderCurateLinks,
      ),
      CtlCommandSpec(
        name: 'curate-music',
        summary: '全库推断音乐专辑 / 曲目属于哪部动画或游戏（库管家 ④ 步的音乐部分）',
        configure: _configureCurateMusic,
        build: _buildCurateMusic,
        render: _renderCurateLinks,
      ),
      CtlCommandSpec(
        name: 'curate-pending',
        summary: '列出 AI 库管家留给你处理的事（合集建议、没认出的作品、要确认的操作）',
        build: _buildCuratePending,
        render: _renderCuratePending,
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
      CtlCommandSpec(
        name: 'scrape-meta',
        summary:
            '书 / 漫画 / 有声书 / 游戏的刮削资料与横版背景：get 看、set 写（造测试数据 / '
            '手动补资料）、clear 清',
        usage: '<get|set|clear> <key>',
        configure: _configureScrapeMeta,
        build: _buildScrapeMeta,
        render: _renderScrapeMeta,
      ),
    ],
  ),
  ...shelfCommandGroups,
  ...readerCommandGroups,
];

const String _root = '/api/admin/library';

// ── scrape-meta ────────────────────────────────────────────────────────

void _configureScrapeMeta(ArgParser parser) => parser
  ..addOption('summary', help: '简介')
  ..addOption('title', help: '刮削到的条目标题（只记事实，不改书名）')
  ..addOption('original-title', help: '原名')
  ..addOption('date', help: '日期：YYYY / YYYY-MM / YYYY-MM-DD')
  ..addOption('year', help: '年份（没有 --date 时）')
  ..addOption('rating', help: '评分 0~10')
  ..addOption('rating-count', help: '评分人数')
  ..addOption('genres', help: '类型 / 标签，逗号分隔')
  ..addOption('detail-url', help: '条目页 URL')
  ..addOption('source', help: '来源名（默认 manual）')
  ..addOption('subject-id', help: '源内条目 id')
  ..addOption('backdrop', help: '横版背景图：本地路径或 http(s) URL')
  ..addOption('logo', help: '标题 logo：本地路径或 http(s) URL')
  ..addFlag('replace', negatable: false, help: '整行替换（默认只改给了的字段）')
  ..addFlag('yes', negatable: false, help: 'clear 会删图片文件，确认请加 --yes');

CtlRequestSpec _buildScrapeMeta(CtlCommandContext context) {
  final String action = context.positional(0, 'get|set|clear').toLowerCase();
  final String key = context.positional(1, 'key').trim();
  if (!RegExp(r'^(book|srt|game):.+').hasMatch(key)) {
    throw CtlUsageError('条目键要写成 book: / srt: / game:（见 library ls）：$key');
  }
  final String path = '${libraryItemPath(key)}/scrape-meta';
  switch (action) {
    case 'get':
      return CtlRequestSpec.get(path);
    case 'clear':
      if (!context.flag('yes')) {
        throw const CtlUsageError('clear 会删除背景 / logo 图片文件，确认请加 --yes');
      }
      return CtlRequestSpec.delete(path);
    case 'set':
      final Map<String, Object?> body = <String, Object?>{
        for (final (String option, String field) in const <(String, String)>[
          ('summary', 'summary'),
          ('title', 'title'),
          ('original-title', 'originalTitle'),
          ('date', 'date'),
          ('detail-url', 'detailUrl'),
          ('source', 'source'),
          ('subject-id', 'subjectId'),
        ])
          if (context.option(option) case final String value) field: value,
        if (_scrapeNumber(context, 'year', integer: true) case final num v)
          'year': v,
        if (_scrapeNumber(context, 'rating') case final num v) 'rating': v,
        if (_scrapeNumber(context, 'rating-count', integer: true)
            case final num v)
          'ratingCount': v,
        if (context.option('genres') case final String genres)
          'genres': <String>[
            for (final String g in genres.split(RegExp(r'[,，、]')))
              if (g.trim().isNotEmpty) g.trim(),
          ],
        ..._scrapeImage(context.option('backdrop'), 'backdrop'),
        ..._scrapeImage(context.option('logo'), 'logo'),
        if (context.flag('replace')) 'replace': true,
      };
      if (body.isEmpty) {
        throw const CtlUsageError(
          'set 至少要给一个字段（--summary / --rating / --backdrop …）',
        );
      }
      return CtlRequestSpec.put(path, body: body);
    default:
      throw CtlUsageError('动作只能是 get / set / clear：$action');
  }
}

num? _scrapeNumber(
  CtlCommandContext context,
  String option, {
  bool integer = false,
}) {
  final String? raw = context.option(option);
  if (raw == null) return null;
  final num? value = integer ? int.tryParse(raw) : num.tryParse(raw);
  if (value == null) {
    throw CtlUsageError('--$option 要是${integer ? '整数' : '数字'}：$raw');
  }
  return value;
}

/// `--backdrop` / `--logo`：http(s) 走 `<kind>Url`（app 下载），其余当本地路径转绝对。
Map<String, Object?> _scrapeImage(String? raw, String kind) {
  if (raw == null || raw.trim().isEmpty) return const <String, Object?>{};
  final Uri? uri = Uri.tryParse(raw);
  final bool remote =
      uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  return <String, Object?>{
    if (remote) '${kind}Url': raw else '${kind}Path': ctlAbsolutePath(raw),
  };
}

String _renderScrapeMeta(Object? data) {
  if (data is! Map) return '完成';
  if (data['cleared'] == true) {
    return '${data['key']} 的刮削资料已清除（删了 ${data['files'] ?? 0} 个图片文件）';
  }
  final StringBuffer out = StringBuffer()
    ..writeln('${data['key']}  [${data['mediaType']} ${data['entryKey']}]');
  final Object? meta = data['meta'];
  if (meta is Map) {
    for (final (String label, String field) in const <(String, String)>[
      ('来源', 'source'),
      ('条目', 'subjectId'),
      ('标题', 'title'),
      ('原名', 'originalTitle'),
      ('日期', 'airDate'),
      ('评分', 'rating'),
      ('评分人数', 'ratingCount'),
      ('类型', 'tags'),
      ('条目页', 'detailUrl'),
      ('简介', 'summary'),
    ]) {
      final Object? value = meta[field];
      if (value == null || (value is List && value.isEmpty)) continue;
      out.writeln('$label：${value is List ? value.join(' / ') : value}');
    }
  } else {
    out.writeln('（没有刮削资料）');
  }
  final Object? images = data['images'];
  if (images is List) {
    for (final Object? image in images) {
      if (image is Map) out.writeln('${image['kind']}：${image['path']}');
    }
  }
  return out.toString().trimRight();
}

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
      '${data['changes']} 处改动 · ${data['requests']} 次请求'
      '${(data['proposals'] as num? ?? 0) > 0 ? ' · ${data['proposals']} 条待确认建议（organize-proposals）' : ''}';
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

void _configureOrganizeProposals(ArgParser parser) {
  parser.addFlag('all', negatable: false, help: '连已接受 / 已拒绝 / 已失效的一起列');
}

CtlRequestSpec _buildOrganizeProposals(CtlCommandContext context) =>
    CtlRequestSpec.get(
      '$_organizeRoot/proposals',
      query: <String, String>{if (context.flag('all')) 'all': 'true'},
    );

String _renderOrganizeProposals(Object? data) {
  final Object? list = data is Map ? data['proposals'] : null;
  if (list is! List || list.isEmpty) return '没有待确认的建议';
  final StringBuffer out = StringBuffer();
  for (final Object? p in list) {
    if (p is! Map) continue;
    final String what = p['kind'] == 'rename'
        ? '改名「${p['collection']}」→「${p['newName']}」'
        : '把 ${((p['sources'] as List?) ?? const <Object?>[]).map((Object? s) => '「$s」').join('、')} '
              '并进「${p['collection']}」';
    out.writeln(
      '#${p['id']} ${p['state']} · $what · ${p['confidence']}'
      '${p['reason'] == null ? '' : '（${p['reason']}）'}',
    );
  }
  return out.toString().trimRight();
}

CtlRequestSpec _buildOrganizeResolve(CtlCommandContext context, String verb) {
  final String raw = context.positional(0, '建议 id');
  if (!RegExp(r'^[1-9]\d*$').hasMatch(raw)) {
    throw CtlUsageError('建议 id 必须是正整数：$raw');
  }
  return CtlRequestSpec.post('$_organizeRoot/proposals/$raw/$verb');
}

CtlRequestSpec _buildOrganizeAccept(CtlCommandContext context) =>
    _buildOrganizeResolve(context, 'accept');

CtlRequestSpec _buildOrganizeReject(CtlCommandContext context) =>
    _buildOrganizeResolve(context, 'reject');

String _renderOrganizeResolve(Object? data) =>
    data is Map ? '建议 #${data['id']}：${data['state']}' : '$data';

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

// ── AI 库管家（app 侧路由见 ctl_library_curate_routes.dart）─────────────────

const String _curateRoot = '/api/admin/library/curate';

void _configureCurate(ArgParser parser) {
  parser
    ..addFlag('full', negatable: false, help: '忽略水位，整个库都过一遍（默认只看上一趟之后的新条目）')
    ..addFlag(
      'estimate',
      negatable: false,
      help: '只估算这一趟要处理多少条目、大约发多少次 AI 请求，不执行',
    )
    ..addFlag(
      'no-wait',
      negatable: false,
      help: '后台开跑立即返回运行 id（用 curate-status 看进度）',
    )
    ..addFlag(
      'yes',
      negatable: false,
      help:
          '同意把标题、作者或品牌、年份、卷数 / 集数和视频文件夹名发给 AI 提供商'
          '（可能计费）；界面里同意过就不必加',
    );
}

CtlRequestSpec _buildCurate(CtlCommandContext context) {
  if (context.flag('estimate')) {
    return CtlRequestSpec.get(
      '$_curateRoot/estimate',
      query: <String, String>{if (context.flag('full')) 'full': 'true'},
    );
  }
  return CtlRequestSpec.post(
    _curateRoot,
    body: <String, Object?>{
      if (context.flag('full')) 'full': true,
      if (context.flag('no-wait')) 'wait': false,
      if (context.flag('yes')) 'yes': true,
    },
  );
}

String _renderCurateStage(Object? s) {
  if (s is! Map) return '$s';
  final String extra = <String>[
    if ((s['changes'] as num? ?? 0) > 0) '${s['changes']} 处改动',
    if ((s['pending'] as num? ?? 0) > 0) '${s['pending']} 条待确认',
    if ((s['requests'] as num? ?? 0) > 0) '${s['requests']} 次请求',
    if (s['error'] != null) '${s['error']}',
  ].join(' · ');
  return '    ${s['stage']}：${s['status']}${extra.isEmpty ? '' : '（$extra）'}';
}

String _renderCurateRun(Map<Object?, Object?> run) {
  final StringBuffer out = StringBuffer(
    '运行 #${run['id']} · ${run['trigger']} · ${run['status']}'
    '${run['undoneAt'] == null ? '' : ' · 已撤销'} · '
    '${run['changes']} 处改动 · ${run['pending']} 条待确认 · '
    '${run['requests']} 次请求',
  );
  for (final Object? s in (run['stages'] as List?) ?? const <Object?>[]) {
    out.write('\n${_renderCurateStage(s)}');
  }
  return out.toString();
}

String _renderCurate(Object? data) {
  if (data is! Map) return '$data';
  if (data.containsKey('stages') && data.containsKey('items')) {
    // --estimate
    final StringBuffer out = StringBuffer(
      '估算：${data['items']} 个条目 · 约 ${data['requests']} 次 AI 请求'
      '${data['full'] == true ? '（全量）' : ''}',
    );
    for (final Object? s in (data['stages'] as List?) ?? const <Object?>[]) {
      if (s is! Map) continue;
      out.write('\n    ${s['stage']}：${s['items']} 个 · 约 ${s['requests']} 次');
    }
    return out.toString();
  }
  if (data['status'] == 'running' && !data.containsKey('stages')) {
    return '已在后台开跑：运行 #${data['runId']}（curate-status 看进度）';
  }
  return _renderCurateRun(data);
}

String _renderCurateStatus(Object? data) {
  if (data is! Map) return '$data';
  final String auto = data['auto'] == true ? '自动路径：开' : '自动路径：关';
  final Object? run = data['run'];
  if (data['running'] == true && run is Map) {
    return '正在跑：${data['stage'] ?? ''}（$auto）\n${_renderCurateRun(run)}';
  }
  final Object? last = data['last'];
  if (last is Map) return '空闲（$auto）。上一趟：\n${_renderCurateRun(last)}';
  return '空闲（$auto），还没跑过';
}

void _configureCurateRuns(ArgParser parser) {
  parser.addOption('limit', help: '最多列几趟（默认 20）');
}

CtlRequestSpec _buildCurateRuns(CtlCommandContext context) {
  final int? limit = context.intOption('limit');
  return CtlRequestSpec.get(
    '$_curateRoot/runs',
    query: <String, String>{if (limit != null) 'limit': '$limit'},
  );
}

String _renderCurateRuns(Object? data) {
  final Object? runs = data is Map ? data['runs'] : null;
  if (runs is! List || runs.isEmpty) return '还没跑过库管家';
  return <String>[
    for (final Object? r in runs)
      if (r is Map) _renderCurateRun(r),
  ].join('\n');
}

CtlRequestSpec _buildCurateUndo(CtlCommandContext context) {
  final String raw = context.positional(0, '运行 id');
  if (!RegExp(r'^[1-9]\d*$').hasMatch(raw)) {
    throw CtlUsageError('运行 id 必须是正整数：$raw');
  }
  return CtlRequestSpec.post('$_curateRoot/runs/$raw/undo');
}

String _renderCurateUndo(Object? data) {
  if (data is! Map) return '$data';
  final num superseded = data['superseded'] as num? ?? 0;
  final num failed = data['failed'] as num? ?? 0;
  return '已撤销 ${data['undone']} 处'
      '${superseded > 0 ? ' · $superseded 处之后被改过、保留' : ''}'
      '${failed > 0 ? ' · $failed 处撤销失败' : ''}';
}

String _renderCuratePending(Object? data) {
  if (data is! Map) return '$data';
  final List<Object?> proposals =
      (data['organizeProposals'] as List?) ?? const <Object?>[];
  final List<Object?> items = (data['items'] as List?) ?? const <Object?>[];
  if (proposals.isEmpty && items.isEmpty) return '没有待处理的事';
  final StringBuffer out = StringBuffer();
  if (proposals.isNotEmpty) {
    out.writeln(
      '合集建议 ${proposals.length} 条'
      '（organize-proposals / organize-accept / organize-reject）',
    );
  }
  for (final Object? i in items) {
    if (i is! Map) continue;
    out.writeln(
      '#${i['runId']} ${i['stage']} · ${i['kind']} · ${i['title']}'
      '${i['reason'] == null ? '' : '（${i['reason']}）'}',
    );
  }
  return out.toString().trimRight();
}

CtlRequestSpec _buildCurateStatus(CtlCommandContext context) =>
    CtlRequestSpec.get('$_curateRoot/status');

CtlRequestSpec _buildCuratePending(CtlCommandContext context) =>
    CtlRequestSpec.get('$_curateRoot/pending');

void _configureCurateLinks(ArgParser parser) {
  parser.addFlag('auto', negatable: false, help: '按自动路径门槛（只落高置信，其余写建议）；默认手动门槛');
}

CtlRequestSpec _buildCurateLinks(CtlCommandContext context) {
  final List<String> items = context.rest;
  if (items.isEmpty) throw const CtlUsageError('至少给一个条目（<kind>:<key>）');
  return CtlRequestSpec.post(
    '$_curateRoot/links/infer',
    body: <String, Object?>{
      'items': items,
      if (context.flag('auto')) 'trigger': 'auto',
    },
  );
}

void _configureCurateMusic(ArgParser parser) {
  parser
    ..addFlag('auto', negatable: false, help: '按自动路径门槛（只落高置信，其余写建议）；默认手动门槛')
    ..addFlag('no-ai', negatable: false, help: '不问 AI，只落声纹命中 / 本地标题规则');
}

CtlRequestSpec _buildCurateMusic(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '$_curateRoot/links/music',
      body: <String, Object?>{
        if (context.flag('auto')) 'trigger': 'auto',
        if (context.flag('no-ai')) 'useAi': false,
      },
    );

String _renderCurateLinks(Object? data) {
  if (data is! Map) return '$data';
  final List<Object?> failed = (data['failed'] as List?) ?? const <Object?>[];
  return '生效 ${data['applied']} 条 · 建议 ${data['suggested']} 条 · '
      '${data['requests']} 次 AI 请求'
      '${failed.isEmpty ? '' : ' · 失败：${failed.join('、')}'}';
}

// ── AI 管库 v3（app 侧路由见 ctl_library_agent_routes.dart）─────────────────

const String _agentRoot = '/api/admin/library/agent';

/// `library map --view` 的值域（与 `LibraryMapView.wireName` 同名）。
const List<String> kLibraryMapViews = <String>[
  'summary',
  'books',
  'manga',
  'video',
  'games',
  'links',
];

void _configureMap(ArgParser parser) {
  parser
    ..addOption(
      'view',
      help: '视图：summary（默认，总览）| books | manga | video | games | links',
      allowed: kLibraryMapViews,
    )
    ..addOption('q', help: '只看标题 / 合集名含这段文字的')
    ..addOption('added-since', help: '只看这个时间（毫秒时间戳）之后入库的')
    ..addOption('offset', help: '分页起点（上一页给的 nextOffset）')
    ..addOption('limit', help: '每页行数（默认 400，上限 2000）');
}

CtlRequestSpec _buildMap(CtlCommandContext context) {
  final String? view = context.option('view');
  final String? q = context.option('q');
  final int? addedSince = context.intOption('added-since');
  final int? offset = context.intOption('offset');
  final int? limit = context.intOption('limit');
  return CtlRequestSpec.get(
    '$_agentRoot/map',
    query: <String, String>{
      if (view != null) 'view': view,
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      if (addedSince != null) 'addedSince': '$addedSince',
      if (offset != null) 'offset': '$offset',
      if (limit != null) 'limit': '$limit',
    },
  );
}

void _configureApplyChanges(ArgParser parser) {
  parser.addFlag('dry-run', negatable: false, help: '只预演、不落库（返回会怎么改）');
}

CtlRequestSpec _buildApplyChanges(CtlCommandContext context) {
  final String file = context.positional(0, '变更集 JSON 文件');
  final String text;
  try {
    text = File(ctlAbsolutePath(file)).readAsStringSync();
  } on FileSystemException catch (e) {
    throw CtlUsageError('读不了 $file：${e.message}');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw CtlUsageError('变更集不是合法 JSON：${e.message}');
  }
  if (decoded is! Map || decoded['changes'] is! List) {
    throw const CtlUsageError('变更集必须是 {"changes": [...]} 形状的 JSON 对象');
  }
  return CtlRequestSpec.post(
    '$_agentRoot/changes',
    body: <String, Object?>{
      ...decoded.cast<String, Object?>(),
      if (context.flag('dry-run')) 'dryRun': true,
    },
  );
}

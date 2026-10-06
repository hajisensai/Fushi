import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../ctl_commands.dart';

/// data 域命令（app 侧路由见 `fushi/lib/src/platform/desktop/ctl/ctl_data_routes.dart`）：
/// 备份、云同步、下载中心、媒体服务器、互联对端、存储。
const List<CtlCommandGroup> dataCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'backup',
    summary: '本地备份：创建 / 恢复 / 查看备份包',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出目录里的备份包（缺省当前目录）',
        usage: '[<dir>]',
        build: _backupLs,
        render: _renderBackupLs,
      ),
      CtlCommandSpec(
        name: 'info',
        summary: '查看一个备份包的版本与内容',
        usage: '<file>',
        build: _backupInfo,
      ),
      CtlCommandSpec(
        name: 'create',
        summary: '创建备份（缺省写到当前目录，文件名同设置页导出）',
        configure: _configureBackupCreate,
        build: _backupCreate,
        render: _renderBackupCreate,
      ),
      CtlCommandSpec(
        name: 'restore',
        summary:
            '恢复备份（给 --merge / --replace 直接开始，否则在 app 里弹确认框选；'
            '完成后 app 重启）',
        usage: '<file>',
        configure: _configureBackupRestore,
        build: _backupRestore,
        render: _renderMessage,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'sync',
    summary: '云同步与互联同步',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '同步后端与状态（不含任何凭据）',
        build: _syncLs,
        render: _renderSyncLs,
      ),
      CtlCommandSpec(
        name: 'run',
        summary: '立即同步（同设置页「立即同步」；缺省全部已启用通道，可只跑 cloud / interconnect）',
        usage: '[<cloud|interconnect>...]',
        configure: _configureSyncRun,
        build: _syncRun,
        render: _renderSyncRun,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'dl',
    summary: '下载中心（磁力 / 种子 / http 直链任务）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出下载任务',
        build: _dlLs,
        render: _renderDlLs,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '查看一个下载任务',
        usage: '<jobId>',
        build: _dlGet,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '添加任务：磁链与 http 直链直接入队；.torrent 在 app 里打开添加对话框',
        usage: '<magnet|file.torrent|url>',
        configure: _configureDlAdd,
        build: _dlAdd,
        render: _renderDlAdd,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消下载任务',
        usage: '<jobId>',
        build: _dlCancel,
      ),
      CtlCommandSpec(
        name: 'retry',
        summary: '重试下载任务',
        usage: '<jobId>',
        build: _dlRetry,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除下载任务（--delete-files 同时删已下载文件）',
        usage: '<jobId>',
        configure: _configureDlRm,
        build: _dlRm,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'mediaserver',
    summary: '媒体服务器（Jellyfin / Emby / Plex）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '已配置的媒体服务器（不含令牌）',
        build: _msLs,
        render: _renderMsLs,
      ),
      CtlCommandSpec(
        name: 'browse',
        summary: '浏览：不给 parent 列媒体库，给了列该节点的子级',
        usage: '<server> [<parentId>]',
        configure: _configurePaging,
        build: _msBrowse,
        render: _renderMsItems,
      ),
      CtlCommandSpec(
        name: 'search',
        summary: '在服务器上搜电影 / 剧集',
        usage: '<server> <query...>',
        configure: _configurePaging,
        build: _msSearch,
        render: _renderMsItems,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'peer',
    summary: '互联对端与本机 host',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '已配对的对端（本机连接的 host + 连到本机的设备）',
        build: _peerLs,
        render: _renderPeerLs,
      ),
      CtlCommandSpec(
        name: 'host',
        summary: '本机互联 host：status / start / stop',
        usage: '<status|start|stop>',
        build: _peerHost,
        render: _renderPeerHost,
      ),
      CtlCommandSpec(
        name: 'pair',
        summary: '按 fushi://pair 链接配对（在 app 里确认）',
        usage: '<fushi://pair?...>',
        build: _peerPair,
        render: _renderMessage,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'storage',
    summary: '数据位置与占用',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'root',
        summary: '数据根与数据库位置',
        build: _storageRoot,
        render: _renderStorageRoot,
      ),
      CtlCommandSpec(
        name: 'usage',
        summary: '各类目占用（同设置 › 存储）',
        build: _storageUsage,
        render: _renderStorageUsage,
      ),
    ],
  ),
];

// ── 公共 ─────────────────────────────────────────────────────────────

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认执行破坏性操作');
}

void _requireYes(CtlCommandContext c, String what) {
  if (!c.flag('yes')) throw CtlUsageError('$what 会改动数据，确认请加 --yes');
}

/// 路径参数里的一段（媒体服务器 id、任务 id 可能含 `/` `:`）。
String _seg(String raw) => Uri.encodeComponent(raw);

String _renderMessage(Object? data) {
  if (data is Map && data['message'] is String)
    return data['message'] as String;
  return renderCtlJson(data);
}

String _bytes(Object? raw) {
  final int? n = raw is int ? raw : null;
  if (n == null) return '';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double v = n.toDouble();
  int u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return u == 0 ? '$n B' : '${v.toStringAsFixed(1)} ${units[u]}';
}

// ── backup ───────────────────────────────────────────────────────────

CtlRequestSpec _backupLs(CtlCommandContext c) => CtlRequestSpec.get(
  '/api/admin/backups',
  query: <String, String>{
    'dir': ctlAbsolutePath(c.optionalPositional(0) ?? p.current),
  },
);

String _renderBackupLs(Object? data) => renderCtlTable(
  data is Map
      ? <Map<String, Object?>>[
          for (final Object? row in (data['backups'] as List<Object?>? ?? []))
            if (row is Map)
              <String, Object?>{
                ...row.cast<String, Object?>(),
                'size': _bytes(row['bytes']),
              },
        ]
      : null,
  const <(String, String)>[
    ('文件', 'name'),
    ('大小', 'size'),
    ('有效', 'valid'),
    ('版本', 'appVersion'),
    ('书', 'bookCount'),
  ],
  empty: '（没有备份包）',
);

CtlRequestSpec _backupInfo(CtlCommandContext c) => CtlRequestSpec.get(
  '/api/admin/backups/info',
  query: <String, String>{'path': ctlAbsolutePath(c.positional(0, 'file'))},
);

void _configureBackupCreate(ArgParser parser) {
  parser
    ..addOption('output', abbr: 'o', help: '输出文件或目录（缺省当前目录）')
    ..addMultiOption(
      'category',
      help:
          '只打包这些分类（可重复 / 逗号分隔：dictionary,books,audiobooks,fonts,'
          'videos,localAudio,games,progress,statistics,settings,profiles）；'
          '缺省同设置页默认（不含 videos / localAudio）',
    )
    ..addFlag('all', negatable: false, help: '打包全部分类（含视频文件与本地音频库）');
}

CtlRequestSpec _backupCreate(CtlCommandContext c) {
  final List<String> categories = c.multiOption('category');
  if (c.flag('all') && categories.isNotEmpty) {
    throw const CtlUsageError('--all 与 --category 只能二选一');
  }
  return CtlRequestSpec.post(
    '/api/admin/backups',
    body: <String, Object?>{
      'output': ctlAbsolutePath(c.option('output') ?? p.current),
      if (categories.isNotEmpty) 'categories': categories,
      if (c.flag('all')) 'all': true,
    },
  );
}

String _renderBackupCreate(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Object?> skipped =
      data['skippedDictionaries'] as List<Object?>? ?? const <Object?>[];
  return <String>[
    '备份已写入：${data['path']}（${_bytes(data['bytes'])}）',
    if (skipped.isNotEmpty) '跳过了缺少资源文件的词典：${skipped.join('、')}',
  ].join('\n');
}

void _configureBackupRestore(ArgParser parser) {
  _configureYes(parser);
  parser
    ..addFlag('merge', negatable: false, help: '合并：保留本机数据，只补上备份里有而本机没有的（不弹确认框）')
    ..addFlag('replace', negatable: false, help: '覆盖：用备份替换本机资料库（不弹确认框）')
    ..addMultiOption(
      'category',
      help:
          '配合 --merge / --replace：只恢复这些可挑选分类（可重复 / 逗号分隔：'
          'dictionary,books,audiobooks,fonts,videos,localAudio,games,progress,'
          'statistics）；其余分类恒恢复。缺省全部',
    )
    ..addFlag(
      'import-settings',
      negatable: false,
      help: '配合 --replace：连设置层一起导入（缺省保留本机设置）',
    );
}

CtlRequestSpec _backupRestore(CtlCommandContext c) {
  final String file = ctlAbsolutePath(c.positional(0, 'file'));
  final bool merge = c.flag('merge');
  final bool replace = c.flag('replace');
  if (merge && replace) {
    throw const CtlUsageError('--merge 与 --replace 只能二选一');
  }
  final List<String> categories = c.multiOption('category');
  final bool importSettings = c.flag('import-settings');
  if (!merge && !replace && (categories.isNotEmpty || importSettings)) {
    throw const CtlUsageError(
      '--category / --import-settings 要和 --merge 或 --replace 一起用',
    );
  }
  if (importSettings && !replace) {
    throw const CtlUsageError('--import-settings 只用于 --replace');
  }
  _requireYes(c, '恢复备份');
  return CtlRequestSpec.post(
    '/api/admin/backups/restore',
    body: <String, Object?>{
      'path': file,
      'confirm': true,
      if (merge) 'mode': 'merge',
      if (replace) 'mode': 'replace',
      if (categories.isNotEmpty) 'categories': categories,
      if (importSettings) 'importSettings': true,
    },
  );
}

// ── sync ─────────────────────────────────────────────────────────────

CtlRequestSpec _syncLs(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/sync');

String _renderSyncLs(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? last = data['lastFullSweep'];
  final List<String> channels = <String>[
    for (final Object? row in (data['channels'] as List<Object?>? ?? []))
      if (row is Map) '${row['id']}（${row['backend']}）',
  ];
  return <String>[
    renderCtlTable(data['backends'], const <(String, String)>[
      ('后端', 'id'),
      ('选中', 'selected'),
      ('已配置', 'configured'),
    ]),
    '',
    '可同步通道（sync run <通道>）：'
        '${channels.isEmpty ? '（无）' : channels.join('、')}',
    '自动同步：${data['autoSync'] == true ? '开' : '关'}'
        '  互联同步：${data['interconnectEnabled'] == true ? '开' : '关'}'
        '  正在同步：${data['running'] == true ? '是' : '否'}',
    if (last is Map) '上次全量同步：${last['reason']}（${last['channelsRun']} 条通道）',
  ].join('\n');
}

void _configureSyncRun(ArgParser parser) {
  parser.addFlag('wait', negatable: false, help: '等同步跑完再返回结果');
}

/// 同步通道名（app 侧 `SyncAssetChannelScope` 的取值；`sync ls` 列出本机已启用的）。
const List<String> _syncChannelNames = <String>['cloud', 'interconnect'];

CtlRequestSpec _syncRun(CtlCommandContext c) {
  final List<String> channels = <String>[
    for (final String raw in c.rest)
      for (final String name in raw.split(','))
        if (name.trim().isNotEmpty) name.trim(),
  ];
  for (final String name in channels) {
    if (!_syncChannelNames.contains(name)) {
      throw CtlUsageError(
        '未知的同步通道：$name（可选：${_syncChannelNames.join(' / ')}；'
        'sync ls 查看本机已启用的通道）',
      );
    }
  }
  return CtlRequestSpec.post(
    '/api/admin/sync/run',
    body: <String, Object?>{
      if (channels.isNotEmpty) 'channels': channels.toSet().toList(),
      if (c.flag('wait')) 'wait': true,
    },
  );
}

String _renderSyncRun(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['started'] == true) return '已开始同步（进度与结果在 app 里显示；sync ls 查看状态）';
  return '同步结束：${data['outcome']}';
}

// ── dl ───────────────────────────────────────────────────────────────

CtlRequestSpec _dlLs(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/downloads');

String _renderDlLs(Object? data) {
  if (data is Map && data['supported'] == false && data['jobs'] is List) {
    final String table = renderCtlTable(data, _dlColumns, listKey: 'jobs');
    return '本机下载后端未就绪\n$table';
  }
  return renderCtlTable(data, _dlColumns, listKey: 'jobs', empty: '（没有下载任务）');
}

const List<(String, String)> _dlColumns = <(String, String)>[
  ('任务', 'jobId'),
  ('标题', 'title'),
  ('状态', 'lifecycle'),
  ('阶段', 'stage'),
  ('进度', 'stageProgress'),
];

CtlRequestSpec _dlGet(CtlCommandContext c) => CtlRequestSpec.get(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}',
);

/// 磁链 / 种子任务的视频类型（决定刮削方式）。
const List<String> _dlVideoKinds = <String>['movie', 'tv'];

/// http 直链的内容类型（app 侧直链队列 `DiscoveryMediaKind`，决定下完入哪个库）。
const List<String> _dlDirectKinds = <String>[
  'novel',
  'audiobook',
  'game',
  'manga',
];

void _configureDlAdd(ArgParser parser) {
  parser
    ..addOption('title', help: '任务标题（缺省取磁链的 dn / 直链文件名）')
    ..addOption(
      'kind',
      allowed: <String>[..._dlVideoKinds, ..._dlDirectKinds],
      help:
          '磁链 / 种子：movie（缺省）或 tv，决定刮削方式；'
          'http 直链必填：novel / audiobook / game / manga，下完按它自动入库',
    );
}

CtlRequestSpec _dlAdd(CtlCommandContext c) {
  final String raw = c.positional(0, 'magnet|file.torrent|url');
  final bool magnet = raw.toLowerCase().startsWith('magnet:');
  final bool url = RegExp(r'^https?://', caseSensitive: false).hasMatch(raw);
  final String? kind = c.option('kind');
  if (url) {
    if (kind == null || !_dlDirectKinds.contains(kind)) {
      throw CtlUsageError(
        'http 直链要用 --kind 指定内容类型（${_dlDirectKinds.join(' / ')}）',
      );
    }
  } else if (kind != null && !_dlVideoKinds.contains(kind)) {
    throw CtlUsageError('磁链 / 种子任务的 --kind 只能是 ${_dlVideoKinds.join(' / ')}');
  }
  return CtlRequestSpec.post(
    '/api/admin/downloads',
    body: <String, Object?>{
      'target': (magnet || url) ? raw : ctlAbsolutePath(raw),
      if (c.option('title') != null) 'title': c.option('title'),
      'mediaKind': kind ?? 'movie',
    },
  );
}

String _renderDlAdd(Object? data) {
  if (data is Map && data['jobId'] != null) {
    return '已入队：${data['jobId']}（${data['title']}）';
  }
  return _renderMessage(data);
}

CtlRequestSpec _dlCancel(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}/cancel',
);

CtlRequestSpec _dlRetry(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}/retry',
);

void _configureDlRm(ArgParser parser) {
  _configureYes(parser);
  parser.addFlag('delete-files', negatable: false, help: '同时删除已下载的文件');
}

CtlRequestSpec _dlRm(CtlCommandContext c) {
  final String id = c.positional(0, 'jobId');
  _requireYes(c, '删除下载任务');
  return CtlRequestSpec.delete(
    '/api/admin/downloads/${_seg(id)}',
    query: <String, String>{
      'confirm': 'true',
      if (c.flag('delete-files')) 'deleteFiles': 'true',
    },
  );
}

// ── mediaserver ──────────────────────────────────────────────────────

CtlRequestSpec _msLs(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/media-servers');

String _renderMsLs(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('#', 'index'),
    ('类型', 'kind'),
    ('地址', 'url'),
    ('账号', 'account'),
  ],
  listKey: 'servers',
  empty: '（没有配置媒体服务器）',
);

void _configurePaging(ArgParser parser) {
  parser
    ..addOption('start', help: '起始偏移（翻页用上次结果的 nextStartIndex）')
    ..addOption('limit', help: '每页条数');
}

Map<String, String> _pagingQuery(CtlCommandContext c) => <String, String>{
  if (c.intOption('start') != null) 'start': '${c.intOption('start')}',
  if (c.intOption('limit') != null) 'limit': '${c.intOption('limit')}',
};

CtlRequestSpec _msBrowse(CtlCommandContext c) {
  final String server = c.positional(0, 'server');
  final String? parent = c.optionalPositional(1);
  return CtlRequestSpec.get(
    '/api/admin/media-servers/${_seg(server)}/items',
    query: <String, String>{
      if (parent != null) 'parent': parent,
      ..._pagingQuery(c),
    },
  );
}

CtlRequestSpec _msSearch(CtlCommandContext c) {
  final String server = c.positional(0, 'server');
  return CtlRequestSpec.get(
    '/api/admin/media-servers/${_seg(server)}/search',
    query: <String, String>{'q': c.joinedRest(1, 'query'), ..._pagingQuery(c)},
  );
}

String _renderMsItems(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('类型', 'type'),
      ('名称', 'name'),
      ('年份', 'year'),
      ('集', 'episode'),
    ],
    listKey: 'items',
    empty: '（空）',
  );
  if (data is Map && data['hasMore'] == true) {
    return '$table\n（还有更多，--start ${data['nextStartIndex']} 继续）';
  }
  return table;
}

// ── peer ─────────────────────────────────────────────────────────────

CtlRequestSpec _peerLs(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/peers');

String _renderPeerLs(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    '本机连接的 host：',
    renderCtlTable(data['hosts'], const <(String, String)>[
      ('设备', 'deviceName'),
      ('地址', 'url'),
      ('启用', 'enabled'),
      ('已配对', 'paired'),
      ('来源', 'addressKind'),
    ], empty: '（无）'),
    '',
    '连到本机的设备：',
    renderCtlTable(data['clients'], const <(String, String)>[
      ('设备', 'deviceName'),
      ('peerId', 'peerId'),
      ('最近 IP', 'lastSeenIp'),
    ], empty: '（无）'),
  ].join('\n');
}

CtlRequestSpec _peerHost(CtlCommandContext c) {
  final String action = c.positional(0, 'status|start|stop');
  switch (action) {
    case 'status':
      return const CtlRequestSpec.get('/api/admin/peers/host');
    case 'start':
      return const CtlRequestSpec.post('/api/admin/peers/host/start');
    case 'stop':
      return const CtlRequestSpec.post('/api/admin/peers/host/stop');
  }
  throw CtlUsageError('未知动作：$action（只认 status / start / stop）');
}

String _renderPeerHost(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '互联 host：${data['running'] == true ? '运行中' : '未运行'}'
      '  端口 ${data['port']}'
      '  开机自启 ${data['enabled'] == true ? '开' : '关'}'
      '  已配对设备 ${data['pairedPeers']}';
}

CtlRequestSpec _peerPair(CtlCommandContext c) {
  final String link = c.positional(0, 'fushi://pair?...');
  if (!link.toLowerCase().startsWith('fushi://pair')) {
    throw const CtlUsageError('需要 fushi://pair?… 形式的配对链接');
  }
  return CtlRequestSpec.post(
    '/api/admin/peers/pair',
    body: <String, Object?>{'link': link},
  );
}

// ── storage ──────────────────────────────────────────────────────────

CtlRequestSpec _storageRoot(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/storage/root');

String _renderStorageRoot(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    '数据根（documents）：${data['documents']}'
        '${data['customDataRoot'] == true ? '（自定义位置）' : ''}',
    '应用支持目录：${data['support']}',
    '数据库目录：${data['database']}',
    '临时目录：${data['temp']}',
  ].join('\n');
}

CtlRequestSpec _storageUsage(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/storage/usage');

String _renderStorageUsage(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final Object? row in (data['categories'] as List<Object?>? ?? []))
      if (row is Map)
        <String, Object?>{'id': row['id'], 'size': _bytes(row['bytes'])},
  ];
  return '${renderCtlTable(rows, const <(String, String)>[('类目', 'id'), ('占用', 'size')])}\n'
      '合计：${_bytes(data['totalBytes'])}';
}

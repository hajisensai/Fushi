import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../ctl_commands.dart';
import 'settings_ops_commands.dart' show plexLoginCommands, syncCompareCommands;

/// data 域命令（app 侧路由见 `fushi/lib/src/ops/ctl_data_routes.dart`）：
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
        summary: '创建备份（缺省写到当前目录，文件名同设置页导出；可只备份指定的书 / 视频）',
        configure: _configureBackupCreate,
        build: _backupCreate,
        render: _renderBackupCreate,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '备份导出进度与最近一次后台导出（create --no-wait）的结果',
        build: _backupStatus,
        render: _renderBackupStatus,
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
      ...syncCompareCommands,
    ],
  ),
  CtlCommandGroup(
    name: 'dl',
    summary: '下载中心（磁力 / 种子 / http 直链任务）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出下载任务（--device <host> 列互联 host 上的代下载任务）',
        configure: _configureDlDevice,
        build: _dlLs,
        render: _renderDlLs,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '查看一个下载任务',
        usage: '<jobId>',
        configure: _configureDlDevice,
        build: _dlGet,
      ),
      CtlCommandSpec(
        name: 'detail',
        summary: '任务详情：种子状态、速度、文件清单与落盘位置',
        usage: '<jobId>',
        build: _dlDetail,
        render: _renderDlDetail,
      ),
      CtlCommandSpec(
        name: 'targets',
        summary: '可选的目标库（--source）与执行设备（--device）',
        build: _dlTargets,
        render: _renderDlTargets,
      ),
      CtlCommandSpec(
        name: 'add',
        summary:
            '添加任务并直接入队：磁链 / .torrent（目标库、字幕、文件选择、执行设备）'
            '或 http 直链',
        usage: '<magnet|file.torrent|url>',
        configure: _configureDlAdd,
        build: _dlAdd,
        render: _renderDlAdd,
      ),
      CtlCommandSpec(
        name: 'pause',
        summary: '暂停下载任务（已下数据保留，dl resume 续传）',
        usage: '<jobId>',
        configure: _configureDlDevice,
        build: _dlCancel,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消下载任务（同 pause：已下数据保留，直链任务保留 .part）',
        usage: '<jobId>',
        configure: _configureDlDevice,
        build: _dlCancel,
      ),
      CtlCommandSpec(
        name: 'resume',
        summary: '继续已暂停的下载任务',
        usage: '<jobId>',
        build: _dlResume,
        render: _renderDlJob,
      ),
      CtlCommandSpec(
        name: 'retry',
        summary: '重试失败 / 需要处理的下载任务',
        usage: '<jobId>',
        configure: _configureDlDevice,
        build: _dlRetry,
      ),
      CtlCommandSpec(
        name: 'priority',
        summary: '调整排队优先级（high / normal / low 或整数，越大越先下）',
        usage: '<jobId> <high|normal|low|N>',
        build: _dlPriority,
        render: _renderDlJob,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary:
            '删除下载任务（--delete-files 同时删已下载文件；--device 远端任务要 host 支持该选项，'
            '老 host 不支持时文件去留由它决定）',
        usage: '<jobId>',
        configure: _configureDlRm,
        build: _dlRm,
        render: _renderMessage,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'sub',
    summary: '视频下载订阅（同浏览 › 下载 › 订阅；新建用 aidl 或发现页）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出订阅：启停、规则、上次检查与逐集计数',
        build: _subLs,
        render: _renderSubLs,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '查看一条订阅（含版本规则与目标库）',
        usage: '<subscriptionId>',
        build: _subGet,
      ),
      CtlCommandSpec(
        name: 'items',
        summary: '一条订阅的逐集历史（发现 / 排队 / 已处理 / 跳过 / 失败）',
        usage: '<subscriptionId>',
        build: _subItems,
        render: _renderSubItems,
      ),
      CtlCommandSpec(
        name: 'check',
        summary: '立即检查：给 id 只查这一条，不给 = 全部检查（所有启用的订阅）',
        usage: '[<subscriptionId>]',
        build: _subCheck,
      ),
      CtlCommandSpec(
        name: 'enable',
        summary: '启用订阅（立即排一轮检查）',
        usage: '<subscriptionId>',
        build: _subEnable,
        render: _renderSubOne,
      ),
      CtlCommandSpec(
        name: 'disable',
        summary: '停用订阅（不再检查新集；已派出的任务不动）',
        usage: '<subscriptionId>',
        build: _subDisable,
        render: _renderSubOne,
      ),
      CtlCommandSpec(
        name: 'edit',
        summary: '编辑订阅（同订阅卡「编辑」：只改给出的项，逐集历史保留）',
        usage: '<subscriptionId>',
        configure: _configureSubEdit,
        build: _subEdit,
        render: _renderSubOne,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除订阅（只删订阅与逐集历史，已下载的任务与文件不动）',
        usage: '<subscriptionId>',
        configure: _configureYes,
        build: _subRm,
        render: _renderMessage,
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
      ...plexLoginCommands,
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
        summary: '按 fushi://pair 链接配对（缺省在 app 里确认；--yes 直接配对并返回结果）',
        usage: '<fushi://pair?...>',
        configure: _configureYes,
        build: _peerPair,
        render: _renderMessage,
      ),
      CtlCommandSpec(
        name: 'pair-link',
        summary: '本机 host 签发一次性配对链接（--revoke 作废当前链接）',
        configure: _configurePairLink,
        build: _peerPairLink,
        render: _renderPairLink,
      ),
      CtlCommandSpec(
        name: 'revoke',
        summary: '吊销一台已配对到本机 host 的设备（peer ls 的 peerId）',
        usage: '<peerId>',
        configure: _configureYes,
        build: _peerRevoke,
      ),
      CtlCommandSpec(
        name: 'forget',
        summary: '忘记本机连接的一台 host（按 hostId 删掉它的全部地址）',
        usage: '<hostId|url|设备名>',
        configure: _configureYes,
        build: _peerForget,
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
      CtlCommandSpec(
        name: 'migrate',
        summary: '把数据目录迁到新位置（同设置 › 存储「更改位置」；成功后 app 自动重启）',
        usage: '<dir>',
        configure: _configureStorageMigrate,
        build: _storageMigrate,
        render: _renderStorageMigrate,
      ),
      CtlCommandSpec(
        name: 'migrate-status',
        summary: '数据目录迁移进度与结果',
        build: _storageMigrateStatus,
        render: _renderStorageMigrateStatus,
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
    ..addFlag('all', negatable: false, help: '打包全部分类（含视频文件与本地音频库）')
    ..addMultiOption('book', help: '只备份这些书（bookKey，library ls 的 id；可重复）；其余书不进包')
    ..addMultiOption(
      'video',
      help: '只备份这些视频（bookUid，library ls 的 id；可重复）；会自动带上 videos 分类',
    )
    ..addFlag(
      'no-wait',
      negatable: false,
      help: '后台打包、立即返回（backup status 查进度与结果）',
    );
}

CtlRequestSpec _backupCreate(CtlCommandContext c) {
  final List<String> categories = c.multiOption('category');
  if (c.flag('all') && categories.isNotEmpty) {
    throw const CtlUsageError('--all 与 --category 只能二选一');
  }
  final List<String> books = c.multiOption('book');
  final List<String> videos = c.multiOption('video');
  return CtlRequestSpec.post(
    '/api/admin/backups',
    body: <String, Object?>{
      'output': ctlAbsolutePath(c.option('output') ?? p.current),
      if (categories.isNotEmpty) 'categories': categories,
      if (c.flag('all')) 'all': true,
      if (books.isNotEmpty) 'books': books,
      if (videos.isNotEmpty) 'videos': videos,
      if (c.flag('no-wait')) 'wait': false,
    },
  );
}

CtlRequestSpec _backupStatus(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/backups/status');

String _renderBackupStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? progress = data['progress'];
  final Object? last = data['last'];
  return <String>[
    if (data['active'] == true)
      '正在导出备份：'
          '${progress is num ? '${(progress * 100).toStringAsFixed(0)}%' : '准备中'}'
    else
      '没有进行中的备份导出',
    if (last is Map)
      switch (last['state']) {
        'running' => '后台导出：进行中 → ${last['path']}',
        'completed' => '后台导出：已完成 → ${last['path']}（${_bytes(last['bytes'])}）',
        _ => '后台导出：失败（${last['error']}）',
      },
  ].join('\n');
}

String _renderBackupCreate(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['started'] == true) return _renderMessage(data);
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
    // 云备份通道总开关；旧 app 不带此字段：不显示。
    '${data.containsKey('cloudEnabled') ? '云备份：${data['cloudEnabled'] == true ? '开' : '关'}  ' : ''}'
        '云同步自动同步：${data['autoSync'] == true ? '开' : '关'}'
        '  互联同步：${data['interconnectEnabled'] == true ? '开' : '关'}'
        // 旧 app 不带此字段：不显示，免得把「不知道」说成「关」。
        '${data.containsKey('interconnectAutoSync') ? '  互联自动同步：${data['interconnectAutoSync'] == true ? '开' : '关'}' : ''}'
        '  正在同步：${data['running'] == true ? '是' : '否'}',
    if (last is Map) '上次全量同步：${last['reason']}（${last['channelsRun']} 条通道）',
  ].join('\n');
}

void _configureSyncRun(ArgParser parser) {
  parser
    ..addFlag('wait', negatable: false, help: '等同步跑完再返回结果')
    ..addOption(
      'conflicts',
      allowed: kSyncConflictPolicies,
      help:
          '同步中途的冲突不弹窗、按策略裁决：keep-local（保留本机）| keep-remote（采用对端）| '
          'newest（较新的一侧）| ask（不裁决，返回冲突清单，隐含 --wait）；缺省在 app 里弹窗',
    );
}

/// `sync run --conflicts` 的取值（app 侧 `SyncConflictPolicy.wire`）。
const List<String> kSyncConflictPolicies = <String>[
  'keep-local',
  'keep-remote',
  'newest',
  'ask',
];

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
      if (c.option('conflicts') != null) 'conflicts': c.option('conflicts'),
    },
  );
}

String _renderSyncRun(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['started'] == true) {
    return data['conflictPolicy'] == null
        ? '已开始同步（进度与结果在 app 里显示；sync ls 查看状态）'
        : '已开始同步，冲突按 ${data['conflictPolicy']} 裁决（sync ls 查看状态）';
  }
  final Object? conflicts = data['conflicts'];
  if (conflicts is! Map) return '同步结束：${data['outcome']}';
  String rows(Object? list) => renderCtlTable(list, const <(String, String)>[
    ('类型', 'type'),
    ('标题', 'title'),
    ('保留', 'kept'),
    ('本机更新', 'localUpdatedAt'),
    ('对端更新', 'remoteUpdatedAt'),
    ('原因', 'error'),
  ], empty: '（无）');
  final Object? unresolved = conflicts['unresolved'];
  final bool pending = unresolved is List && unresolved.isNotEmpty;
  return <String>[
    '同步结束：${data['outcome']}（冲突策略 ${conflicts['policy']}）',
    '已裁决的冲突：\n${rows(conflicts['resolved'])}',
    if (pending)
      '未解决的冲突（下一轮同步仍会报；可 sync run --conflicts keep-local|keep-remote|newest 重跑）：\n'
          '${rows(unresolved)}',
  ].join('\n');
}

// ── dl ───────────────────────────────────────────────────────────────

/// 任务操作的执行设备：缺省本机；给了 host 就操作它上面的代下载任务
/// （与下载页「远端任务」段同一协议：只有 ls / get / cancel / retry / rm）。
void _configureDlDevice(ArgParser parser) {
  parser.addOption(
    'device',
    help: '互联 host（hostId / 地址 / 设备名，dl targets 查看）；缺省本机',
  );
}

Map<String, String> _deviceQuery(CtlCommandContext c) => <String, String>{
  if (c.option('device') != null) 'device': c.option('device')!,
};

Map<String, Object?> _deviceBody(CtlCommandContext c) => <String, Object?>{
  if (c.option('device') != null) 'device': c.option('device'),
};

CtlRequestSpec _dlLs(CtlCommandContext c) =>
    CtlRequestSpec.get('/api/admin/downloads', query: _deviceQuery(c));

String _renderDlLs(Object? data) {
  if (data is Map && data['remote'] == true) {
    return '互联 host「${data['device']}」上的任务：\n'
        '${renderCtlTable(data, _dlColumns, listKey: 'jobs', empty: '（没有任务）')}';
  }
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
  query: _deviceQuery(c),
);

/// 磁链 / 种子任务的视频类型（决定刮削方式）。
const List<String> _dlVideoKinds = <String>['movie', 'tv'];

/// 按域入库的内容类型：http 直链必填其一（app 侧直链队列 `DiscoveryMediaKind`）；
/// 磁链 / 种子也可用（下完整包交发现导入按域入库）。
const List<String> _dlDirectKinds = <String>[
  'novel',
  'audiobook',
  'game',
  'manga',
];

void _configureDlAdd(ArgParser parser) {
  parser
    ..addOption('title', help: '任务标题（缺省取磁链的 dn / 种子名 / 直链文件名）')
    ..addOption(
      'kind',
      allowed: <String>[..._dlVideoKinds, ..._dlDirectKinds],
      help:
          '磁链 / 种子：movie（缺省）/ tv 是视频（决定刮削与整理方式），'
          'novel / audiobook / game / manga 下完按域入库；'
          'http 直链必填 novel / audiobook / game / manga',
    )
    ..addOption('source', help: '视频任务的目标库（受管视频来源 id，dl targets 查看；缺省同设置里的默认）')
    ..addOption(
      'subtitles',
      allowed: <String>['none', 'bestEffort', 'required'],
      help: '字幕策略：none（缺省）/ bestEffort 尽量自动配字幕 / required 配不到就停下等处理',
    )
    ..addMultiOption('files', help: '只下种子里的这些文件（下标，逗号分隔 / 可重复；只用于 .torrent）')
    ..addOption('year', help: '作品年份（视频任务）')
    ..addOption(
      'provider',
      allowed: <String>['anidb', 'mal', 'tmdb'],
      help: '作品资料源（配合 --external-id，入库后按这个身份刮削）',
    )
    ..addOption('external-id', help: '作品在 --provider 上的 id')
    ..addOption(
      'device',
      help:
          '执行设备：local 或互联 host（hostId / 地址 / 设备名，dl targets 查看）；缺省同下载设置里的「执行设备」',
    )
    ..addOption('priority', help: '排队优先级：high / normal（缺省）/ low 或整数');
}

/// `high` / `normal` / `low` / 整数 → 整数（与 app 侧任务卡的三档一致）。
int _parsePriority(String raw) => switch (raw.trim()) {
  'high' => 1,
  'normal' => 0,
  'low' => -1,
  final String other =>
    int.tryParse(other) ??
        (throw CtlUsageError('优先级只认 high / normal / low 或整数：$raw')),
};

CtlRequestSpec _dlAdd(CtlCommandContext c) {
  final String raw = c.positional(0, 'magnet|file.torrent|url');
  final bool magnet = raw.toLowerCase().startsWith('magnet:');
  final bool url = RegExp(r'^https?://', caseSensitive: false).hasMatch(raw);
  final String? kind = c.option('kind');
  final List<String> files = c.multiOption('files');
  final String? provider = c.option('provider');
  final String? externalId = c.option('external-id');
  final String? priority = c.option('priority');
  if (url) {
    if (kind == null || !_dlDirectKinds.contains(kind)) {
      throw CtlUsageError(
        'http 直链要用 --kind 指定内容类型（${_dlDirectKinds.join(' / ')}）',
      );
    }
    final List<String> torrentOnly = <String>[
      if (c.option('source') != null) '--source',
      if (c.option('subtitles') != null) '--subtitles',
      if (files.isNotEmpty) '--files',
      if (c.option('year') != null) '--year',
      if (provider != null || externalId != null) '--provider / --external-id',
      if (priority != null) '--priority',
    ];
    if (torrentOnly.isNotEmpty) {
      throw CtlUsageError('http 直链不支持 ${torrentOnly.join('、')}（只用于磁链 / 种子）');
    }
  }
  if (magnet && files.isNotEmpty) {
    throw const CtlUsageError('--files 只用于 .torrent（磁链不带文件清单）');
  }
  if ((provider == null) != (externalId == null)) {
    throw const CtlUsageError('--provider 与 --external-id 要一起给');
  }
  final bool video = kind == null || _dlVideoKinds.contains(kind);
  if (!video &&
      (c.option('source') != null ||
          c.option('year') != null ||
          provider != null)) {
    throw const CtlUsageError(
      '--source / --year / --provider 只用于视频任务（--kind movie / tv）',
    );
  }
  return CtlRequestSpec.post(
    '/api/admin/downloads',
    body: <String, Object?>{
      'target': (magnet || url) ? raw : ctlAbsolutePath(raw),
      if (c.option('title') != null) 'title': c.option('title'),
      'mediaKind': kind ?? 'movie',
      if (c.intOption('source') != null) 'source': c.intOption('source'),
      if (c.option('subtitles') != null)
        'subtitlePolicy': c.option('subtitles'),
      if (files.isNotEmpty) 'files': files,
      if (c.intOption('year') != null) 'year': c.intOption('year'),
      if (provider != null) 'metadataProvider': provider,
      if (externalId != null) 'externalId': externalId,
      if (c.option('device') != null) 'device': c.option('device'),
      if (priority != null) 'priority': _parsePriority(priority),
    },
  );
}

String _renderDlAdd(Object? data) {
  if (data is Map && data['jobId'] != null) {
    final Object? device = data['device'];
    return '已入队：${data['jobId']}（${data['title']}）'
        '${device == null || device == 'local' ? '' : ' → $device'}';
  }
  return _renderMessage(data);
}

CtlRequestSpec _dlCancel(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}/cancel',
  body: _deviceBody(c),
);

CtlRequestSpec _dlRetry(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}/retry',
  body: _deviceBody(c),
);

CtlRequestSpec _dlResume(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}/resume',
);

CtlRequestSpec _dlPriority(CtlCommandContext c) {
  final String id = c.positional(0, 'jobId');
  final int priority = _parsePriority(c.positional(1, 'high|normal|low|N'));
  return CtlRequestSpec.post(
    '/api/admin/downloads/${_seg(id)}/priority',
    body: <String, Object?>{'priority': priority},
  );
}

String _renderDlJob(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['jobId']}（${data['title']}）：${data['lifecycle']} / '
      '${data['stage']}${data['priority'] != null ? '  优先级 ${data['priority']}' : ''}';
}

CtlRequestSpec _dlDetail(CtlCommandContext c) => CtlRequestSpec.get(
  '/api/admin/downloads/${_seg(c.positional(0, 'jobId'))}/details',
);

String _renderDlDetail(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? torrent = data['torrent'];
  final List<Map<String, Object?>> files = <Map<String, Object?>>[
    for (final Object? row in (data['files'] as List<Object?>? ?? []))
      if (row is Map)
        <String, Object?>{
          ...row.cast<String, Object?>(),
          'size': _bytes(row['bytes']),
          'done': row['progress'] is num
              ? '${((row['progress'] as num) * 100).toStringAsFixed(0)}%'
              : '',
        },
  ];
  return <String>[
    '${data['jobId']}（${data['title']}）：${data['lifecycle']} / ${data['stage']}',
    if (torrent is Map)
      '种子：${torrent['name']}  状态 ${torrent['state']}  '
          '↓ ${_bytes(torrent['downRateBps'])}/s  ↑ ${_bytes(torrent['upRateBps'])}/s',
    if (data['liveData'] != null && data['liveData'] != 'none')
      '实时数据：${data['liveData']}',
    if (data['location'] != null) '位置：${data['location']}',
    renderCtlTable(files, const <(String, String)>[
      ('#', 'index'),
      ('文件', 'name'),
      ('大小', 'size'),
      ('完成', 'done'),
    ], empty: '（没有文件清单）'),
  ].join('\n');
}

CtlRequestSpec _dlTargets(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/download-targets');

String _renderDlTargets(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    '本机下载后端：${data['localBackend']}  当前执行设备：${data['executionDevice']}',
    '',
    '目标库（--source）：',
    renderCtlTable(data['sources'], const <(String, String)>[
      ('id', 'id'),
      ('名称', 'label'),
      ('路径', 'rootPath'),
      ('默认', 'default'),
    ], empty: '（没有受管视频来源）'),
    '',
    '可代下载的互联 host（--device）：',
    renderCtlTable(data['hosts'], const <(String, String)>[
      ('设备', 'device'),
      ('hostId', 'hostId'),
      ('地址', 'url'),
      ('后端', 'backend'),
      ('内容', 'kinds'),
    ], empty: '（无在线 host）'),
  ].join('\n');
}

void _configureDlRm(ArgParser parser) {
  _configureYes(parser);
  _configureDlDevice(parser);
  parser.addFlag(
    'delete-files',
    negatable: false,
    help: '同时删除已下载的文件（远端任务要 host 宣告支持，否则报错）',
  );
}

CtlRequestSpec _dlRm(CtlCommandContext c) {
  final String id = c.positional(0, 'jobId');
  _requireYes(c, '删除下载任务');
  return CtlRequestSpec.delete(
    '/api/admin/downloads/${_seg(id)}',
    query: <String, String>{
      'confirm': 'true',
      if (c.flag('delete-files')) 'deleteFiles': 'true',
      ..._deviceQuery(c),
    },
  );
}

// ── sub ──────────────────────────────────────────────────────────────

CtlRequestSpec _subLs(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/subscriptions');

/// 订阅 id 路径段。路径一律在调用处写全字面量（不拼后缀），覆盖守卫才认得出每条请求。
String _subId(CtlCommandContext c) => _seg(c.positional(0, 'subscriptionId'));

String _renderSubLs(Object? data) {
  final Object? rows = data is Map ? data['subscriptions'] : null;
  final String table = renderCtlTable(
    <String, Object?>{
      'subscriptions': <Object?>[
        if (rows is List)
          for (final Object? row in rows)
            if (row is Map)
              <String, Object?>{
                ...row.cast<String, Object?>(),
                'state': _subState(row),
              },
      ],
    },
    _subColumns,
    listKey: 'subscriptions',
    empty: '（没有订阅）',
  );
  if (data is Map && data['supported'] == false) {
    return '本机下载后端未就绪（订阅不会被检查）\n$table';
  }
  return table;
}

const List<(String, String)> _subColumns = <(String, String)>[
  ('订阅', 'subscriptionId'),
  ('标题', 'title'),
  ('模式', 'mode'),
  ('状态', 'state'),
  ('起始集之后', 'startAfterEpisode'),
];

/// 启停 + 完成 / 最近错误，一列看清这条订阅现在在不在干活。
String _subState(Map<Object?, Object?> row) {
  if (row['fulfilledAt'] != null) return '已完成';
  if (row['enabled'] != true) return '已停用';
  final Object? error = row['lastError'];
  return error is String && error.isNotEmpty ? '出错：$error' : '启用';
}

String _renderSubOne(Object? data) {
  if (data is Map && data['subscriptionId'] != null) {
    return '${data['subscriptionId']}（${data['title']}）：${_subState(data)}';
  }
  return _renderMessage(data);
}

CtlRequestSpec _subGet(CtlCommandContext c) =>
    CtlRequestSpec.get('/api/admin/subscriptions/${_subId(c)}');

CtlRequestSpec _subItems(CtlCommandContext c) =>
    CtlRequestSpec.get('/api/admin/subscriptions/${_subId(c)}/items');

String _renderSubItems(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('季', 'season'),
    ('集', 'episode'),
    ('状态', 'status'),
    ('任务', 'jobId'),
    ('标题', 'title'),
  ],
  listKey: 'items',
  empty: '（还没有发现过任何一集）',
);

CtlRequestSpec _subCheck(CtlCommandContext c) {
  final String? id = c.optionalPositional(0);
  return CtlRequestSpec.post(
    id == null
        ? '/api/admin/subscriptions/check'
        : '/api/admin/subscriptions/${_seg(id)}/check',
  );
}

CtlRequestSpec _subEnable(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/subscriptions/${_subId(c)}/enable',
  body: const <String, Object?>{'enabled': true},
);

CtlRequestSpec _subDisable(CtlCommandContext c) => CtlRequestSpec.post(
  '/api/admin/subscriptions/${_subId(c)}/enable',
  body: const <String, Object?>{'enabled': false},
);

void _configureSubEdit(ArgParser parser) {
  parser
    ..addOption('query', help: '搜索词')
    ..addOption('start-after', help: '只下这一集之后的（整数）；none = 清掉，从头下')
    ..addOption(
      'subtitles',
      allowed: <String>['none', 'bestEffort', 'required'],
      help: '字幕策略',
    )
    ..addOption('source', help: '目标库（受管视频来源 id，dl targets 查看）')
    ..addMultiOption('group', help: '字幕组（可重复 / 逗号分隔；给空串 = 去掉这条规则）')
    ..addMultiOption('resolution', help: '分辨率，如 1080p（同上）')
    ..addMultiOption('include', help: '标题必须包含（同上）')
    ..addMultiOption('exclude', help: '标题不得包含（同上）');
}

CtlRequestSpec _subEdit(CtlCommandContext c) {
  final Map<String, Object?> body = <String, Object?>{};
  if (c.option('query') != null) body['searchQuery'] = c.option('query');
  final String? startAfter = c.option('start-after');
  if (startAfter != null) {
    body['startAfterEpisode'] = startAfter.trim().toLowerCase() == 'none'
        ? null
        : int.tryParse(startAfter.trim()) ??
              (throw CtlUsageError('--start-after 只认整数或 none：$startAfter'));
  }
  if (c.option('subtitles') != null) {
    body['subtitlePolicy'] = c.option('subtitles');
  }
  if (c.intOption('source') != null) body['source'] = c.intOption('source');
  for (final (String flag, String key) in const <(String, String)>[
    ('group', 'releaseGroups'),
    ('resolution', 'resolutions'),
    ('include', 'titleIncludes'),
    ('exclude', 'titleExcludes'),
  ]) {
    if (c.args.wasParsed(flag)) {
      body[key] = <String>[
        for (final String v in c.multiOption(flag))
          if (v.trim().isNotEmpty) v.trim(),
      ];
    }
  }
  if (body.isEmpty) {
    throw const CtlUsageError(
      '没有要改的项（--query / --start-after / --subtitles / --source / '
      '--group / --resolution / --include / --exclude）',
    );
  }
  return CtlRequestSpec.put(
    '/api/admin/subscriptions/${_subId(c)}',
    body: body,
  );
}

CtlRequestSpec _subRm(CtlCommandContext c) {
  final String path = '/api/admin/subscriptions/${_subId(c)}';
  _requireYes(c, '删除订阅');
  return CtlRequestSpec.delete(
    path,
    query: const <String, String>{'confirm': 'true'},
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
    body: <String, Object?>{'link': link, if (c.flag('yes')) 'confirm': true},
  );
}

void _configurePairLink(ArgParser parser) {
  parser.addFlag('revoke', negatable: false, help: '作废当前配对链接（未用掉的票据立即失效）');
}

CtlRequestSpec _peerPairLink(CtlCommandContext c) => c.flag('revoke')
    ? const CtlRequestSpec.delete('/api/admin/peers/pair-link')
    : const CtlRequestSpec.post('/api/admin/peers/pair-link');

String _renderPairLink(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['revoked'] == true) return '已作废当前配对链接';
  return <String>[
    '${data['link']}',
    '把上面的链接交给要配对的设备（设置 › 互联 › 粘贴链接，或 fushi_cli peer pair）；'
        '${data['oneTime'] == true ? '一次性票据，用过或重新签发即失效。' : ''}',
  ].join('\n');
}

CtlRequestSpec _peerRevoke(CtlCommandContext c) {
  final String peerId = c.positional(0, 'peerId');
  _requireYes(c, '吊销已配对设备');
  return CtlRequestSpec.delete(
    '/api/admin/peers/clients/${_seg(peerId)}',
    query: const <String, String>{'confirm': 'true'},
  );
}

CtlRequestSpec _peerForget(CtlCommandContext c) {
  final String host = c.positional(0, 'hostId|url|设备名');
  _requireYes(c, '忘记 host');
  return CtlRequestSpec.delete(
    '/api/admin/peers/hosts/${_seg(host)}',
    query: const <String, String>{'confirm': 'true'},
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

void _configureStorageMigrate(ArgParser parser) {
  _configureYes(parser);
  parser.addFlag(
    'dry-run',
    negatable: false,
    help: '只解析并校验目标、列出数据会落到哪两个目录，不迁移',
  );
}

CtlRequestSpec _storageMigrate(CtlCommandContext c) {
  final String dir = ctlAbsolutePath(c.positional(0, 'dir'));
  final bool dryRun = c.flag('dry-run');
  if (!dryRun) _requireYes(c, '迁移数据目录（会关闭数据库并重启 app）');
  return CtlRequestSpec.post(
    '/api/admin/storage/migrate',
    body: <String, Object?>{
      'path': dir,
      if (dryRun) 'dryRun': true,
      if (!dryRun) 'confirm': true,
    },
  );
}

String _renderStorageMigrate(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    if (data['dryRun'] == true) '迁移计划（未执行）：' else '${data['message']}',
    '  数据（documents）：${data['fromDocumentsRoot']} → ${data['documentsRoot']}',
    '  数据库（support）：${data['fromSupportRoot']} → ${data['supportRoot']}',
  ].join('\n');
}

CtlRequestSpec _storageMigrateStatus(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/storage/migrate');

String _renderStorageMigrateStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? last = data['last'];
  return <String>[
    if (data['failure'] != null)
      '迁移已结束但需要处理：${data['failure']}'
    else if (data['active'] == true)
      '正在迁移'
          '${data['totalFiles'] != null ? '：${data['copiedFiles']} / ${data['totalFiles']} 个文件' : ''}'
    else
      '没有进行中的迁移',
    if (last is Map) '终端发起的最近一次：${last['state']} → ${last['documentsRoot']}',
  ].join('\n');
}

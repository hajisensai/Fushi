import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'ai_download_commands.dart';

/// online 域命令（app 侧路由见 `fushi/lib/src/ops/ctl_online_routes.dart`）。
///
/// 六组：`ext`（扩展仓库 / 扩展 / 启停）、`source`（在线源启停 / 置顶 / 偏好 /
/// 筛选浏览 / 搜索 / 作品 / 入库 / 下载）、`discover`（发现源搜索与一键获取）、
/// `aidl`（AI 下载会话，见 `ai_download_commands.dart`）、`play`（播放遥控）、
/// `nav`（顶层页面导航）。
const List<CtlCommandGroup> onlineCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'ext',
    summary: '在线扩展：仓库、安装、更新、卸载（漫画 / 视频 / 小说）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'repo',
        summary: '扩展仓库：ls | add <url> | rm <url> | sync',
        usage: '<ls|add|rm|sync> [url]',
        configure: _configureRepo,
        build: _buildRepo,
        render: _renderRepo,
      ),
      CtlCommandSpec(
        name: 'ls',
        summary: '列出已装扩展（--available 连同仓库目录）',
        configure: _configureExtLs,
        build: _buildExtLs,
        render: _renderExtLs,
      ),
      CtlCommandSpec(
        name: 'install',
        summary: '从仓库安装扩展（未受信任的签名需 --trust-signer）',
        usage: '<id>',
        configure: _configureInstall,
        build: _buildInstall,
        render: _renderInstall,
      ),
      CtlCommandSpec(
        name: 'update',
        summary: '更新有新版本的扩展（不给 id 即全部）',
        usage: '[id]',
        configure: _configureKindOnly,
        build: _buildUpdate,
        render: _renderBulkReport,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '卸载扩展（需 --yes）',
        usage: '<id>',
        configure: _configureExtRm,
        build: _buildExtRm,
        render: _renderOk,
      ),
      CtlCommandSpec(
        name: 'enable',
        summary: '启用已装扩展（小说：插件本身）',
        usage: '<id>',
        configure: _configureKindOnly,
        build: _buildExtEnable,
        render: _renderEnabled,
      ),
      CtlCommandSpec(
        name: 'disable',
        summary: '停用已装扩展（其下的源一并不可用）',
        usage: '<id>',
        configure: _configureKindOnly,
        build: _buildExtDisable,
        render: _renderEnabled,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'source',
    summary: '在线源：搜索、作品详情、加入库、下载',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出已装的在线源',
        configure: _configureKindOnly,
        build: _buildSourceLs,
        render: _renderSourceLs,
      ),
      CtlCommandSpec(
        name: 'search',
        summary: '在一个源里搜索作品',
        usage: '<sourceId> <关键词...>',
        configure: _configureSourceSearch,
        build: _buildSourceSearch,
        render: _renderSourceSearch,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '作品详情与章节 / 剧集列表',
        usage: '<sourceId> <url>',
        configure: _configureKindOnly,
        build: _buildSourceGet,
        render: _renderSourceGet,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '加入书架 / 媒体库',
        usage: '<sourceId> <url>',
        configure: _configureKindOnly,
        build: _buildSourceAdd,
        render: _renderSourceAdd,
      ),
      CtlCommandSpec(
        name: 'dl',
        summary: '下载章节 / 剧集（--chapters 1-10,15；缺省全部）',
        usage: '<sourceId> <url>',
        configure: _configureSourceDl,
        build: _buildSourceDl,
        render: _renderSourceDl,
      ),
      CtlCommandSpec(
        name: 'task',
        summary: '查看 CLI 发起的小说下载任务（不给 id 即全部；--cancel 取消）',
        usage: '[taskId]',
        configure: _configureSourceTask,
        build: _buildSourceTask,
        render: _renderSourceTask,
      ),
      CtlCommandSpec(
        name: 'manga-dl',
        summary:
            '漫画章节下载队列：ls | cancel <id> | retry <id> | rm <id> | clear（rm / clear 需 --yes）',
        usage: '<ls|cancel|retry|rm|clear> [jobId]',
        configure: _configureMangaDl,
        build: _buildMangaDl,
        render: _renderMangaDl,
      ),
      CtlCommandSpec(
        name: 'anime-dl',
        summary:
            '视频源剧集下载：ls | get <id> | pause <id> | resume <id> | rm <id>（rm 需 --yes）',
        usage: '<ls|get|pause|resume|rm> [taskId]',
        configure: _configureAnimeDl,
        build: _buildAnimeDl,
        render: _renderAnimeDl,
      ),
      CtlCommandSpec(
        name: 'enable',
        summary: '启用一个源',
        usage: '<sourceId>',
        configure: _configureKindOnly,
        build: _buildSourceEnable,
        render: _renderSourceSettings,
      ),
      CtlCommandSpec(
        name: 'disable',
        summary: '停用一个源',
        usage: '<sourceId>',
        configure: _configureKindOnly,
        build: _buildSourceDisable,
        render: _renderSourceSettings,
      ),
      CtlCommandSpec(
        name: 'pin',
        summary: '置顶一个源',
        usage: '<sourceId>',
        configure: _configureKindOnly,
        build: _buildSourcePin,
        render: _renderSourceSettings,
      ),
      CtlCommandSpec(
        name: 'unpin',
        summary: '取消置顶',
        usage: '<sourceId>',
        configure: _configureKindOnly,
        build: _buildSourceUnpin,
        render: _renderSourceSettings,
      ),
      CtlCommandSpec(
        name: 'prefs',
        summary: '源偏好：不给 key 列出；给 key 与取值即设置（漫画 / 视频）',
        usage: '<sourceId> [<key> <取值...>]',
        configure: _configureSourcePrefs,
        build: _buildSourcePrefs,
        render: _renderSourcePrefs,
      ),
      CtlCommandSpec(
        name: 'clear-data',
        summary: '清除源数据（漫画 / 视频：运行时数据与偏好；小说：插件登录态）（需 --yes）',
        usage: '<sourceId>',
        configure: _configureSourceClearData,
        build: _buildSourceClearData,
        render: _renderOk,
      ),
      CtlCommandSpec(
        name: 'filters',
        summary: '列出源支持的筛选项（漫画 / 视频作用于搜索，小说作用于热门 / 最新）',
        usage: '<sourceId>',
        configure: _configureKindOnly,
        build: _buildSourceFilters,
        render: _renderSourceFilters,
      ),
      CtlCommandSpec(
        name: 'browse',
        summary: '浏览源：热门 / 最新 / 关键词 + 筛选，分页',
        usage: '<sourceId>',
        configure: _configureSourceBrowse,
        build: _buildSourceBrowse,
        render: _renderSourceBrowse,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'discover',
    summary: '发现源：搜索资源、一键获取入库',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'sources',
        summary: '列出发现源',
        configure: _configureDomain,
        build: _buildDiscoverSources,
        render: _renderDiscoverSources,
      ),
      CtlCommandSpec(
        name: 'search',
        summary: '搜索发现源（结果 id 用于 discover get）',
        usage: '<关键词...>',
        configure: _configureDiscoverSearch,
        build: _buildDiscoverSearch,
        render: _renderDiscoverSearch,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '下载一条搜索结果并自动入库',
        usage: '<resultId>',
        build: _buildDiscoverGet,
        render: _renderDiscoverGet,
      ),
    ],
  ),
  aiDownloadCommandGroup,
  CtlCommandGroup(
    name: 'play',
    summary: '播放遥控（视频播放页 / 有声书，缺省视频页开着就控制视频）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'status',
        summary: '当前播放状态',
        configure: _configurePlayTarget,
        build: _buildPlayStatus,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'pause',
        summary: '暂停',
        configure: _configurePlayTarget,
        build: _buildPlayPause,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'resume',
        summary: '继续播放',
        configure: _configurePlayTarget,
        build: _buildPlayResume,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'toggle',
        summary: '播放 / 暂停切换',
        configure: _configurePlayTarget,
        build: _buildPlayToggle,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'seek',
        summary: '跳到绝对位置或前后跳（负数前加 --：play seek -- -10）',
        usage: '<秒|mm:ss|+N|-N>',
        configure: _configurePlayTarget,
        build: _buildPlaySeek,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'next',
        summary: '下一句',
        configure: _configurePlayTarget,
        build: _buildPlayNext,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'prev',
        summary: '上一句',
        configure: _configurePlayTarget,
        build: _buildPlayPrev,
        render: _renderPlayback,
      ),
      CtlCommandSpec(
        name: 'rate',
        summary: '设置倍速（0.25–4）',
        usage: '<倍速>',
        configure: _configurePlayTarget,
        build: _buildPlayRate,
        render: _renderPlayback,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'nav',
    summary: '切换 app 顶层页面',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出可跳转的顶层页面',
        build: _buildNavLs,
        render: _renderNavLs,
      ),
      CtlCommandSpec(
        name: 'go',
        summary: '切到某个顶层页面（--pop 先退出阅读器 / 播放器等上层页面）',
        usage: '<页面>',
        configure: _configureNavGo,
        build: _buildNavGo,
        render: _renderNavGo,
      ),
    ],
  ),
];

const List<String> _kinds = <String>['manga', 'anime', 'novel'];

const List<String> _domains = <String>['book', 'audiobook', 'manga', 'game'];

// ── 共用参数 ──────────────────────────────────────────────────────────────

void _addKind(ArgParser parser) => parser.addOption(
  'kind',
  allowed: _kinds,
  help: '内容域：manga（Mihon）/ anime（Aniyomi）/ novel（LNReader）',
);

void _addYes(ArgParser parser) =>
    parser.addFlag('yes', negatable: false, help: '确认执行破坏性操作');

void _configureKindOnly(ArgParser parser) => _addKind(parser);

String _kind(CtlCommandContext context) {
  final String? kind = context.option('kind');
  if (kind == null)
    throw const CtlUsageError('缺少 --kind（manga | anime | novel）');
  return kind;
}

void _requireYes(CtlCommandContext context, String what) {
  if (!context.flag('yes')) throw CtlUsageError('$what 需要 --yes 确认');
}

/// 路径段编码（源 id / 扩展 id 可能含 `/` `:` 等字符）。
String _seg(String raw) => Uri.encodeComponent(raw);

String _renderOk(Object? data) => '完成';

// ── ext ──────────────────────────────────────────────────────────────────

void _configureRepo(ArgParser parser) {
  _addKind(parser);
  _addYes(parser);
  parser.addFlag('insecure', negatable: false, help: '允许明文 http 仓库（漫画 / 视频）');
}

CtlRequestSpec _buildRepo(CtlCommandContext context) {
  final String verb = context.positional(0, 'ls|add|rm|sync');
  final String kind = _kind(context);
  switch (verb) {
    case 'ls':
      return CtlRequestSpec.get(
        '/api/admin/extensions/repos',
        query: <String, String>{'kind': kind},
      );
    case 'add':
      return CtlRequestSpec.post(
        '/api/admin/extensions/repos',
        body: <String, Object?>{
          'kind': kind,
          'url': context.positional(1, 'url'),
          if (context.flag('insecure')) 'allowInsecure': true,
        },
      );
    case 'rm':
      final String url = context.positional(1, 'url');
      _requireYes(context, '删除仓库');
      return CtlRequestSpec.delete(
        '/api/admin/extensions/repos',
        query: <String, String>{'kind': kind, 'url': url, 'confirm': 'true'},
      );
    case 'sync':
      return CtlRequestSpec.post(
        '/api/admin/extensions/repos/sync',
        body: <String, Object?>{'kind': kind},
      );
  }
  throw CtlUsageError('未知操作：$verb（ls | add | rm | sync）');
}

String _renderRepo(Object? data) {
  if (data is Map && data['repos'] is List) {
    return renderCtlTable(data, const <(String, String)>[
      ('地址', 'url'),
      ('名称', 'name'),
      ('错误', 'lastError'),
    ], listKey: 'repos');
  }
  if (data is Map && data.containsKey('available')) {
    final Map<Object?, Object?> errors =
        (data['errors'] as Map<Object?, Object?>?) ??
        const <Object?, Object?>{};
    return <String>[
      '目录已刷新：可装 ${data['available']} 个',
      for (final MapEntry<Object?, Object?> e in errors.entries)
        '  失败 ${e.key}: ${e.value}',
    ].join('\n');
  }
  if (data is Map && data['url'] != null) return '已添加仓库 ${data['url']}';
  return '完成';
}

void _configureExtLs(ArgParser parser) {
  _addKind(parser);
  parser
    ..addFlag('available', negatable: false, help: '同时列出仓库目录里可装的扩展')
    ..addOption('query', help: '按名称 / id 过滤')
    ..addOption('lang', help: '按语言过滤（如 ja、en）');
}

CtlRequestSpec _buildExtLs(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/extensions',
  query: <String, String>{
    'kind': _kind(context),
    if (context.flag('available')) 'available': 'true',
    if (context.option('query') case final String q) 'query': q,
    if (context.option('lang') case final String l) 'lang': l,
  },
);

String _renderExtLs(Object? data) {
  final List<String> parts = <String>[
    '已安装：',
    renderCtlTable(data, const <(String, String)>[
      ('id', 'id'),
      ('名称', 'name'),
      ('版本', 'version'),
      ('语言', 'lang'),
      ('启用', 'enabled'),
      ('有更新', 'hasUpdate'),
    ], listKey: 'installed'),
  ];
  if (data is Map && data['available'] is List) {
    parts
      ..add('\n可安装：')
      ..add(
        renderCtlTable(data, const <(String, String)>[
          ('id', 'id'),
          ('名称', 'name'),
          ('版本', 'version'),
          ('语言', 'lang'),
          ('已装', 'installed'),
        ], listKey: 'available'),
      );
  }
  if (data is Map && data['error'] != null) {
    parts.add('\n仓库刷新错误：${data['error']}');
  }
  return parts.join('\n');
}

void _configureInstall(ArgParser parser) {
  _addKind(parser);
  parser.addFlag(
    'trust-signer',
    negatable: false,
    help: '信任该扩展的签名者（首次安装某签名者的扩展时需要）',
  );
}

CtlRequestSpec _buildInstall(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/extensions/install',
  body: <String, Object?>{
    'kind': _kind(context),
    'id': context.positional(0, 'id'),
    if (context.flag('trust-signer')) 'trustSigner': true,
  },
);

String _renderInstall(Object? data) => data is Map
    ? '已安装 ${data['id']} ${data['version'] ?? ''}'.trimRight()
    : '完成';

CtlRequestSpec _buildUpdate(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/extensions/update',
  body: <String, Object?>{
    'kind': _kind(context),
    if (context.optionalPositional(0) case final String id) 'id': id,
  },
);

String _renderBulkReport(Object? data) {
  if (data is! Map) return '完成';
  final List<Object?> installed =
      (data['installed'] as List<Object?>?) ?? const <Object?>[];
  final Map<Object?, Object?> failed =
      (data['failed'] as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
  return <String>[
    installed.isEmpty
        ? '没有可更新的扩展'
        : '已更新 ${installed.length} 个：${installed.join(', ')}',
    for (final MapEntry<Object?, Object?> e in failed.entries)
      '  失败 ${e.key}: ${e.value}',
  ].join('\n');
}

void _configureExtRm(ArgParser parser) {
  _addKind(parser);
  _addYes(parser);
  parser.addFlag(
    'clear-data',
    negatable: false,
    help: '同时清除扩展数据（漫画 / 视频：各源设置；小说：插件存储 / 登录态）；不加则保留，重装即接回',
  );
}

CtlRequestSpec _buildExtRm(CtlCommandContext context) {
  final String id = context.positional(0, 'id');
  final String kind = _kind(context);
  _requireYes(context, '卸载扩展');
  return CtlRequestSpec.delete(
    '/api/admin/extensions/${_seg(id)}',
    query: <String, String>{
      'kind': kind,
      'confirm': 'true',
      if (context.flag('clear-data')) 'clearData': 'true',
    },
  );
}

CtlRequestSpec _extEnabled(CtlCommandContext context, bool enabled) {
  final String id = context.positional(0, 'id');
  return CtlRequestSpec.post(
    '/api/admin/extensions/${_seg(id)}/enabled',
    body: <String, Object?>{'kind': _kind(context), 'enabled': enabled},
  );
}

CtlRequestSpec _buildExtEnable(CtlCommandContext context) =>
    _extEnabled(context, true);

CtlRequestSpec _buildExtDisable(CtlCommandContext context) =>
    _extEnabled(context, false);

String _renderEnabled(Object? data) => data is Map
    ? '${data['id']}：${data['enabled'] == true ? '已启用' : '已停用'}'
    : '完成';

// ── source ───────────────────────────────────────────────────────────────

CtlRequestSpec _buildSourceLs(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/sources',
  query: <String, String>{'kind': _kind(context)},
);

String _renderSourceLs(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('id', 'id'),
      ('名称', 'name'),
      ('语言', 'lang'),
      ('启用', 'enabled'),
    ], listKey: 'sources');

void _configureSourceSearch(ArgParser parser) {
  _addKind(parser);
  parser.addOption('page', help: '页码（从 1 开始）');
}

CtlRequestSpec _buildSourceSearch(CtlCommandContext context) {
  final String sourceId = context.positional(0, 'sourceId');
  final String query = context.joinedRest(1, '关键词');
  final int? page = context.intOption('page');
  if (page != null && page < 1) throw const CtlUsageError('--page 从 1 开始');
  return CtlRequestSpec.get(
    '/api/admin/sources/${_seg(sourceId)}/search',
    query: <String, String>{
      'kind': _kind(context),
      'q': query,
      if (page != null) 'page': '$page',
    },
  );
}

String _renderSourceSearch(Object? data) {
  final String table = renderCtlTable(data, const <(String, String)>[
    ('标题', 'title'),
    ('url', 'url'),
  ], listKey: 'items');
  if (data is Map && data['hasNextPage'] == true) {
    return '$table\n（还有下一页：--page ${(data['page'] as int? ?? 1) + 1}）';
  }
  return table;
}

String _workPath(CtlCommandContext context, String tail) =>
    '/api/admin/sources/${_seg(context.positional(0, 'sourceId'))}/$tail';

CtlRequestSpec _buildSourceGet(CtlCommandContext context) => CtlRequestSpec.get(
  _workPath(context, 'work'),
  query: <String, String>{
    'kind': _kind(context),
    'url': context.positional(1, 'url'),
  },
);

String _renderSourceGet(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final bool anime = data['episodes'] is List;
  return <String>[
    '${data['title'] ?? ''}'
        '${data['author'] == null ? '' : ' / ${data['author']}'}',
    if (data['bookKey'] != null) '已在书架：${data['bookKey']}',
    renderCtlTable(
      data,
      anime
          ? const <(String, String)>[
              ('#', 'index'),
              ('剧集', 'name'),
              ('已入库', 'inLibrary'),
              ('已下载', 'downloaded'),
            ]
          : const <(String, String)>[
              ('#', 'index'),
              ('章节', 'name'),
              ('锁定', 'locked'),
            ],
      listKey: anime ? 'episodes' : 'chapters',
    ),
  ].join('\n');
}

CtlRequestSpec _buildSourceAdd(CtlCommandContext context) =>
    CtlRequestSpec.post(
      _workPath(context, 'library'),
      body: <String, Object?>{
        'kind': _kind(context),
        'url': context.positional(1, 'url'),
      },
    );

String _renderSourceAdd(Object? data) {
  if (data is! Map) return '完成';
  if (data['added'] != null) {
    return '已加入媒体库：${data['title']}（新增 ${data['added']} / 共 ${data['episodes']} 集）';
  }
  return '已加入书架：${data['title']}（${data['bookKey']}）';
}

/// `--chapters` 的形状校验（`1-10,15,20-`）；越界由 app 按真实章数判。
final RegExp _rangePattern = RegExp(
  r'^\s*(\d*\s*-?\s*\d*)(\s*,\s*\d*\s*-?\s*\d*)*\s*$',
);

void _configureSourceDl(ArgParser parser) {
  _addKind(parser);
  parser.addOption(
    'chapters',
    help: '章节 / 剧集序号范围，如 1-10,15,20-（见 source get 的 #）',
  );
}

CtlRequestSpec _buildSourceDl(CtlCommandContext context) {
  final String? chapters = context.option('chapters');
  if (chapters != null &&
      (!_rangePattern.hasMatch(chapters) ||
          !chapters.contains(RegExp(r'\d')))) {
    throw CtlUsageError('--chapters 格式不对：$chapters（如 1-10,15,20-）');
  }
  return CtlRequestSpec.post(
    _workPath(context, 'downloads'),
    body: <String, Object?>{
      'kind': _kind(context),
      'url': context.positional(1, 'url'),
      if (chapters != null) 'chapters': chapters,
    },
  );
}

String _renderSourceDl(Object? data) {
  if (data is! Map) return '完成';
  if (data['status'] != null) {
    return '已开始下载《${data['title']}》${data['total']} 章：任务 ${data['id']}'
        '（fushi_cli source task ${data['id']} 查看进度）';
  }
  final Object? locked = data['lockedSkipped'];
  final String hint = data['taskIds'] is List
      ? '\n进度：fushi_cli source anime-dl ls（任务 id 即剧集 id）'
      : data['bookKey'] != null
      ? '\n进度：fushi_cli source manga-dl ls --book ${data['bookKey']}'
      : '';
  return '已加入下载队列：${data['title']} ${data['queued']} 项'
      '${locked is int && locked > 0 ? '（跳过 $locked 个锁定章节）' : ''}$hint';
}

void _configureSourceTask(ArgParser parser) =>
    parser.addFlag('cancel', negatable: false, help: '取消这个任务（在下一章之前停下）');

CtlRequestSpec _buildSourceTask(CtlCommandContext context) {
  final String? id = context.optionalPositional(0);
  if (context.flag('cancel')) {
    if (id == null) throw const CtlUsageError('--cancel 需要 <taskId>');
    return CtlRequestSpec.post('/api/admin/online/tasks/${_seg(id)}/cancel');
  }
  return CtlRequestSpec.get(
    id == null
        ? '/api/admin/online/tasks'
        : '/api/admin/online/tasks/${_seg(id)}',
  );
}

String _renderSourceTask(Object? data) {
  if (data is Map && data['tasks'] is List) {
    return renderCtlTable(
      data,
      const <(String, String)>[
        ('id', 'id'),
        ('标题', 'title'),
        ('状态', 'status'),
        ('进度', 'done'),
        ('总数', 'total'),
        ('错误', 'error'),
      ],
      listKey: 'tasks',
      empty: '没有任务',
    );
  }
  if (data is Map) {
    return '${data['id']} ${data['title']}：${data['status']} '
        '${data['done']}/${data['total']}'
        '${data['cancelRequested'] == true ? '（已请求取消，下一章前停下）' : ''}'
        '${data['error'] == null ? '' : '\n  错误：${data['error']}'}'
        '${data['resultKey'] == null ? '' : '\n  书：${data['resultKey']}'}';
  }
  return renderCtlJson(data);
}

// ── source 下载任务：漫画章节队列 / 视频源剧集 ──────────────────────────────

const String _mangaDl = '/api/admin/online/manga-downloads';
const String _animeDl = '/api/admin/online/episode-downloads';

void _configureMangaDl(ArgParser parser) {
  _addYes(parser);
  parser
    ..addOption('book', help: 'ls：只看这本书（bookKey，source dl / add 的输出）')
    ..addOption(
      'status',
      help: 'ls：按状态过滤，逗号分隔（queued,running,done,failed,cancelled）',
    );
}

CtlRequestSpec _buildMangaDl(CtlCommandContext context) {
  final String verb = context.positional(0, 'ls|cancel|retry|rm|clear');
  String job() => _seg(context.positional(1, 'jobId'));
  switch (verb) {
    case 'ls':
      return CtlRequestSpec.get(
        _mangaDl,
        query: <String, String>{
          if (context.option('book') case final String b) 'book': b,
          if (context.option('status') case final String s) 'status': s,
        },
      );
    case 'cancel':
      return CtlRequestSpec.post('$_mangaDl/${job()}/cancel');
    case 'retry':
      return CtlRequestSpec.post('$_mangaDl/${job()}/retry');
    case 'rm':
      final String id = job();
      _requireYes(context, '删除下载任务');
      return CtlRequestSpec.delete(
        '$_mangaDl/$id',
        query: const <String, String>{'confirm': 'true'},
      );
    case 'clear':
      _requireYes(context, '清除已结束的任务');
      return const CtlRequestSpec.delete(
        _mangaDl,
        query: <String, String>{'finished': 'true', 'confirm': 'true'},
      );
  }
  throw CtlUsageError('未知操作：$verb（ls | cancel | retry | rm | clear）');
}

String _renderMangaDl(Object? data) {
  if (data is Map && data['jobs'] is List) {
    return renderCtlTable(
      <String, Object?>{
        'rows': <Map<String, Object?>>[
          for (final Object? j in data['jobs'] as List)
            if (j is Map)
              <String, Object?>{
                ...j.cast<String, Object?>(),
                'pages': '${j['pagesDone']}/${j['pagesTotal']}',
              },
        ],
      },
      const <(String, String)>[
        ('id', 'id'),
        ('作品', 'title'),
        ('章节', 'chapter'),
        ('状态', 'status'),
        ('页', 'pages'),
        ('错误', 'error'),
      ],
      listKey: 'rows',
      empty: '没有漫画下载任务',
    );
  }
  if (data is Map && data['id'] != null) {
    return '${data['id']} ${data['title']} ${data['chapter'] ?? ''}：'
        '${data['status']} ${data['pagesDone']}/${data['pagesTotal']}';
  }
  return '完成';
}

void _configureAnimeDl(ArgParser parser) {
  _addYes(parser);
  parser
    ..addFlag(
      'all',
      negatable: false,
      help: 'ls：连同互联设备 / 媒体服务器拉取的任务（缺省只看视频扩展源）',
    )
    ..addFlag(
      'delete-files',
      negatable: false,
      help:
          'rm：未完成任务连同已下的 .part 一起删（缺省保留以便续传）；'
          '已完成剧集连同成品删（媒体库行 + 文件，同下载页「删除并删文件」）',
    );
}

CtlRequestSpec _buildAnimeDl(CtlCommandContext context) {
  final String verb = context.positional(0, 'ls|get|pause|resume|rm');
  String task() => _seg(context.positional(1, 'taskId'));
  switch (verb) {
    case 'ls':
      return CtlRequestSpec.get(
        _animeDl,
        query: <String, String>{if (context.flag('all')) 'all': 'true'},
      );
    case 'get':
      return CtlRequestSpec.get('$_animeDl/${task()}');
    case 'pause':
      return CtlRequestSpec.post('$_animeDl/${task()}/pause');
    case 'resume':
      return CtlRequestSpec.post('$_animeDl/${task()}/resume');
    case 'rm':
      final String id = task();
      _requireYes(context, '删除剧集下载任务');
      return CtlRequestSpec.delete(
        '$_animeDl/$id',
        query: <String, String>{
          'confirm': 'true',
          if (context.flag('delete-files')) 'deleteFiles': 'true',
        },
      );
  }
  throw CtlUsageError('未知操作：$verb（ls | get | pause | resume | rm）');
}

String _percent(Object? progress) =>
    progress is num ? '${(progress * 100).toStringAsFixed(1)}%' : '--';

String _renderAnimeDl(Object? data) {
  if (data is Map && data['tasks'] is List) {
    return renderCtlTable(
      <String, Object?>{
        'rows': <Map<String, Object?>>[
          for (final Object? t in data['tasks'] as List)
            if (t is Map)
              <String, Object?>{
                ...t.cast<String, Object?>(),
                'pct': _percent(t['progress']),
              },
        ],
      },
      const <(String, String)>[
        ('id', 'id'),
        ('标题', 'title'),
        ('状态', 'status'),
        ('进度', 'pct'),
        ('来源', 'origin'),
        ('错误', 'error'),
      ],
      listKey: 'rows',
      empty: '没有剧集下载任务',
    );
  }
  if (data is Map && data['deletedFile'] != null) {
    return '已删除成品 ${data['deletedFile']}'
        '${data['deletedRows'] is int && (data['deletedRows'] as int) > 0 ? '（连同 ${data['deletedRows']} 条媒体库行）' : ''}';
  }
  if (data is Map && data['id'] != null) {
    return '${data['id']} ${data['title']}：${data['status']} '
        '${_percent(data['progress'])}'
        '${data['error'] == null ? '' : '\n  错误：${data['error']}'}';
  }
  return '完成';
}

// ── source 管理：启停 / 置顶 / 偏好 / 筛选浏览 ──────────────────────────────

CtlRequestSpec _sourceSettings(
  CtlCommandContext context,
  Map<String, Object?> change,
) => CtlRequestSpec.post(
  _workPath(context, 'settings'),
  body: <String, Object?>{'kind': _kind(context), ...change},
);

CtlRequestSpec _buildSourceEnable(CtlCommandContext context) =>
    _sourceSettings(context, const <String, Object?>{'enabled': true});

CtlRequestSpec _buildSourceDisable(CtlCommandContext context) =>
    _sourceSettings(context, const <String, Object?>{'enabled': false});

CtlRequestSpec _buildSourcePin(CtlCommandContext context) =>
    _sourceSettings(context, const <String, Object?>{'pinned': true});

CtlRequestSpec _buildSourceUnpin(CtlCommandContext context) =>
    _sourceSettings(context, const <String, Object?>{'pinned': false});

String _renderSourceSettings(Object? data) => data is Map
    ? '${data['id']}：${data['enabled'] == true ? '启用' : '停用'}'
          '${data['pinned'] == true ? ' · 置顶' : ''}'
    : '完成';

void _configureSourcePrefs(ArgParser parser) {
  _addKind(parser);
  parser.addOption('value', help: '取值（可为空串；不给时取 <key> 之后的位置参数）');
}

CtlRequestSpec _buildSourcePrefs(CtlCommandContext context) {
  final String? key = context.optionalPositional(1);
  final String kind = _kind(context);
  if (key == null) {
    return CtlRequestSpec.get(
      _workPath(context, 'preferences'),
      query: <String, String>{'kind': kind},
    );
  }
  // 直接读原始值：`option()` 会把空串当作没给，而清空文本偏好正需要空串。
  final String? explicit = context.args['value'] as String?;
  final String value =
      explicit ??
      (context.rest.length > 2
          ? context.rest.sublist(2).join(' ')
          : throw CtlUsageError('偏好 $key 缺少取值（或用 --value）'));
  return CtlRequestSpec.post(
    _workPath(context, 'preferences'),
    body: <String, Object?>{'kind': kind, 'key': key, 'value': value},
  );
}

String _renderSourcePrefs(Object? data) {
  final String table = renderCtlTable(
    data is Map
        ? <String, Object?>{
            'preferences': <Map<String, Object?>>[
              for (final Object? p
                  in (data['preferences'] as List<Object?>? ??
                      const <Object?>[]))
                if (p is Map)
                  <String, Object?>{
                    ...p.cast<String, Object?>(),
                    'shown': p['valueLabel'] ?? p['value'],
                    'choices': p['entries'],
                  },
            ],
          }
        : data,
    const <(String, String)>[
      ('key', 'key'),
      ('名称', 'title'),
      ('类型', 'kind'),
      ('当前值', 'shown'),
      ('可选', 'choices'),
    ],
    listKey: 'preferences',
    empty: '这个源没有偏好',
  );
  if (data is Map && data['key'] != null) return '已设置 ${data['key']}\n$table';
  return table;
}

void _configureSourceClearData(ArgParser parser) {
  _addKind(parser);
  _addYes(parser);
}

CtlRequestSpec _buildSourceClearData(CtlCommandContext context) {
  final String path = _workPath(context, 'data');
  final String kind = _kind(context);
  _requireYes(context, '清除源数据');
  return CtlRequestSpec.delete(
    path,
    query: <String, String>{'kind': kind, 'confirm': 'true'},
  );
}

CtlRequestSpec _buildSourceFilters(CtlCommandContext context) =>
    CtlRequestSpec.get(
      _workPath(context, 'filters'),
      query: <String, String>{'kind': _kind(context)},
    );

/// 把嵌套的筛选器（Mihon 分组）拍平成表格行。
List<Map<String, Object?>> _flattenFilters(
  Object? raw, [
  String indent = '',
]) => <Map<String, Object?>>[
  if (raw is List)
    for (final Object? f in raw)
      if (f is Map) ...<Map<String, Object?>>[
        <String, Object?>{
          'key': '$indent${f['path'] ?? f['key']}',
          'name': f['name'],
          'kind': f['kind'],
          'state': f['state'] is Map ? renderCtlJson(f['state']) : f['state'],
          'options': f['options'] is List
              ? <String>[
                  for (final Object? o in f['options'] as List)
                    o is Map ? '${o['label']}=${o['value']}' : '$o',
                ]
              : null,
        },
        ..._flattenFilters(f['children'], '$indent  '),
      ],
];

String _renderSourceFilters(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String scope = data['appliesTo'] == 'search'
      ? '作用于搜索（source browse --query / 只给 --filter 即空关键词搜索）'
      : '作用于热门 / 最新（source browse --listing popular|latest）';
  return <String>[
    '筛选$scope；--filter <key>=<取值>，选项可写显示名或 #N',
    renderCtlTable(
      <String, Object?>{'rows': _flattenFilters(data['filters'])},
      const <(String, String)>[
        ('key', 'key'),
        ('名称', 'name'),
        ('类型', 'kind'),
        ('当前', 'state'),
        ('选项', 'options'),
      ],
      listKey: 'rows',
      empty: '这个源没有筛选项',
    ),
  ].join('\n');
}

void _configureSourceBrowse(ArgParser parser) {
  _addKind(parser);
  parser
    ..addOption(
      'listing',
      allowed: const <String>['popular', 'latest'],
      help: '热门 / 最新（与 --query 二选一；都不给 = 热门）',
    )
    ..addOption('query', help: '关键词搜索')
    ..addMultiOption(
      'filter',
      splitCommas: false,
      help: '筛选 <key>=<取值>（key 见 source filters；可重复）',
    )
    ..addOption('page', help: '页码（从 1 开始）');
}

CtlRequestSpec _buildSourceBrowse(CtlCommandContext context) {
  final String path = _workPath(context, 'browse');
  final String kind = _kind(context);
  final int? page = context.intOption('page');
  if (page != null && page < 1) throw const CtlUsageError('--page 从 1 开始');
  final String? listing = context.option('listing');
  final String? query = context.option('query');
  if (listing != null && query != null) {
    throw const CtlUsageError('--listing 与 --query 二选一');
  }
  final Map<String, String> filters = <String, String>{};
  for (final String raw in context.multiOption('filter')) {
    final int eq = raw.indexOf('=');
    if (eq <= 0) throw CtlUsageError('--filter 要写成 <key>=<取值>：$raw');
    filters[raw.substring(0, eq).trim()] = raw.substring(eq + 1);
  }
  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      'kind': kind,
      if (listing != null) 'listing': listing,
      if (query != null) 'query': query,
      if (filters.isNotEmpty) 'filters': filters,
      if (page != null) 'page': page,
    },
  );
}

String _renderSourceBrowse(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[('标题', 'title'), ('url', 'url')],
    listKey: 'items',
    empty: '没有结果',
  );
  if (data is Map && data['hasNextPage'] == true) {
    return '$table\n（还有下一页：--page ${(data['page'] as int? ?? 1) + 1}）';
  }
  return table;
}

// ── discover ─────────────────────────────────────────────────────────────

void _configureDomain(ArgParser parser) => parser.addOption(
  'domain',
  allowed: _domains,
  help: '内容域：book / audiobook / manga / game',
);

CtlRequestSpec _buildDiscoverSources(CtlCommandContext context) =>
    CtlRequestSpec.get(
      '/api/admin/discovery/sources',
      query: <String, String>{
        if (context.option('domain') case final String d) 'domain': d,
      },
    );

String _renderDiscoverSources(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('id', 'id'),
      ('名称', 'name'),
      ('内容域', 'domains'),
      ('启用', 'enabled'),
    ], listKey: 'sources');

void _configureDiscoverSearch(ArgParser parser) {
  _configureDomain(parser);
  parser.addOption('source', help: '只搜这个发现源（id 见 discover sources）');
}

CtlRequestSpec _buildDiscoverSearch(CtlCommandContext context) =>
    CtlRequestSpec.get(
      '/api/admin/discovery/search',
      query: <String, String>{
        'q': context.joinedRest(0, '关键词'),
        'domain': context.option('domain') ?? 'book',
        if (context.option('source') case final String s) 'source': s,
      },
    );

String _renderDiscoverSearch(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('标题', 'title'),
      ('来源', 'source'),
      ('大小', 'size'),
      ('做种', 'seeders'),
    ],
    listKey: 'items',
    empty: '没有结果',
  );
  final Object? failures = data is Map ? data['failures'] : null;
  if (failures is List && failures.isNotEmpty) {
    return <String>[
      table,
      for (final Object? f in failures)
        if (f is Map) '  来源失败 ${f['source']}: ${f['message']}',
    ].join('\n');
  }
  return table;
}

CtlRequestSpec _buildDiscoverGet(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/discovery/acquire',
      body: <String, Object?>{'id': context.positional(0, 'resultId')},
    );

String _renderDiscoverGet(Object? data) => data is Map
    ? (data['started'] == true
          ? '已开始获取：${data['title']}'
                '${data['message'] == null ? '' : '（${data['message']}）'}'
          : '未开始：${data['title']}'
                '${data['reason'] == null ? '' : '（${data['reason']}）'}')
    : '完成';

// ── play ─────────────────────────────────────────────────────────────────

const String _playback = '/api/admin/playback';

void _configurePlayTarget(ArgParser parser) => parser.addOption(
  'target',
  allowed: const <String>['video', 'audiobook'],
  help: '要控制的播放器（缺省：视频播放页开着就控制视频，否则有声书）',
);

/// `--target` 透传：GET 走 query、POST 走 body。
String? _playTarget(CtlCommandContext context) => context.option('target');

CtlRequestSpec _control(CtlCommandContext context, String action) {
  final String? target = _playTarget(context);
  return CtlRequestSpec.post(
    '$_playback/control',
    body: <String, Object?>{
      'action': action,
      if (target != null) 'target': target,
    },
  );
}

CtlRequestSpec _buildPlayStatus(CtlCommandContext context) {
  final String? target = _playTarget(context);
  return CtlRequestSpec.get(
    _playback,
    query: <String, String>{if (target != null) 'target': target},
  );
}

CtlRequestSpec _buildPlayPause(CtlCommandContext context) =>
    _control(context, 'pause');

CtlRequestSpec _buildPlayResume(CtlCommandContext context) =>
    _control(context, 'resume');

CtlRequestSpec _buildPlayToggle(CtlCommandContext context) =>
    _control(context, 'toggle');

CtlRequestSpec _buildPlayNext(CtlCommandContext context) =>
    _control(context, 'next');

CtlRequestSpec _buildPlayPrev(CtlCommandContext context) =>
    _control(context, 'prev');

CtlRequestSpec _buildPlaySeek(CtlCommandContext context) {
  final ({double seconds, bool relative}) target = parseCtlSeekTarget(
    context.positional(0, '秒|mm:ss|+N|-N'),
  );
  final String? player = _playTarget(context);
  return CtlRequestSpec.post(
    '$_playback/seek',
    body: <String, Object?>{
      'seconds': target.seconds,
      'relative': target.relative,
      if (player != null) 'target': player,
    },
  );
}

CtlRequestSpec _buildPlayRate(CtlCommandContext context) {
  final String raw = context.positional(0, '倍速');
  final double? rate = double.tryParse(raw.replaceAll(RegExp(r'[xX×]$'), ''));
  if (rate == null || rate < 0.25 || rate > 4) {
    throw CtlUsageError('倍速必须在 0.25–4 之间：$raw');
  }
  final String? player = _playTarget(context);
  return CtlRequestSpec.post(
    '$_playback/rate',
    body: <String, Object?>{'rate': rate, if (player != null) 'target': player},
  );
}

/// 解析 `play seek` 的目标：`90` / `1:30` / `1:02:03`（绝对）、`+10` / `-10`（相对）。
({double seconds, bool relative}) parseCtlSeekTarget(String raw) {
  final String text = raw.trim();
  final bool relative = text.startsWith('+') || text.startsWith('-');
  final bool negative = text.startsWith('-');
  final String body = relative ? text.substring(1) : text;
  double? seconds;
  if (body.contains(':')) {
    final List<String> parts = body.split(':');
    if (parts.length <= 3 && parts.every((String p) => p.isNotEmpty)) {
      double total = 0;
      for (final String part in parts) {
        final double? value = double.tryParse(part);
        if (value == null || value < 0) {
          total = double.nan;
          break;
        }
        total = total * 60 + value;
      }
      if (!total.isNaN) seconds = total;
    }
  } else {
    final double? value = double.tryParse(body);
    if (value != null && value >= 0) seconds = value;
  }
  if (seconds == null) {
    throw CtlUsageError('无法解析位置：$raw（如 90、1:30、+10、-10）');
  }
  return (seconds: negative ? -seconds : seconds, relative: relative);
}

String _clock(Object? ms) {
  if (ms is! int || ms < 0) return '--:--';
  final int total = ms ~/ 1000;
  final int h = total ~/ 3600;
  final String mm = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  final String ss = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String _renderPlayback(Object? data) {
  if (data is! Map || data['active'] != true) {
    return switch (data is Map ? data['kind'] : null) {
      'video' => '没有打开的视频播放页',
      'audiobook' => '没有正在播放的有声书',
      _ => '没有正在播放的视频或有声书',
    };
  }
  final String kind = data['kind'] == 'video' ? '视频' : '有声书';
  if (data['ready'] == false) return '[$kind] 加载中…';
  return <String>[
    '[$kind] ${data['playing'] == true ? '▶ 播放中' : '⏸ 已暂停'}  ${data['title'] ?? ''}',
    '${_clock(data['positionMs'])} / ${_clock(data['durationMs'])}  ×${data['speed']}'
        '${data['volume'] is num ? '  音量 ${(data['volume'] as num).round()}' : ''}',
    if (data['audioTrack'] != null) '音轨：${data['audioTrack']}',
    if (data['subtitle'] != null) '字幕：${_subtitleLabel(data['subtitle'])}',
    if (data['secondarySubtitle'] != null)
      '副字幕：${_subtitleLabel(data['secondarySubtitle'])}',
    if (data['cue'] != null) '「${data['cue']}」',
  ].join('\n');
}

/// 字幕源的持久化值 → 可读：`off:` 哨兵 = 关闭，`embedded:<n>` = 内嵌第 n 轨，
/// 其余是外挂文件路径（原样）。
String _subtitleLabel(Object? source) {
  final String text = '$source';
  if (text.startsWith('off:')) return '关闭';
  if (text.startsWith('embedded:')) return '内嵌轨 ${text.substring(9)}';
  return text;
}

// ── nav ──────────────────────────────────────────────────────────────────

CtlRequestSpec _buildNavLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/navigation');

String _renderNavLs(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('页面', 'name'),
      ('可用', 'available'),
      ('当前', 'current'),
    ], listKey: 'pages');

void _configureNavGo(ArgParser parser) =>
    parser.addFlag('pop', negatable: false, help: '先关闭压在首页之上的页面（阅读器 / 播放器等）');

CtlRequestSpec _buildNavGo(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/navigation',
  body: <String, Object?>{
    'page': context.positional(0, '页面'),
    if (context.flag('pop')) 'pop': true,
  },
);

String _renderNavGo(Object? data) {
  if (data is! Map) return '完成';
  return data['covered'] == true
      ? '已切到 ${data['page']}（上层还有打开的页面，加 --pop 可先关闭）'
      : '已切到 ${data['page']}';
}

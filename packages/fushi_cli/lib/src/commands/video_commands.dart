import 'package:args/args.dart';

import '../ctl_commands.dart';

/// video 域命令（app 侧路由见 `fushi/lib/src/platform/desktop/ctl/ctl_video_routes.dart`）：
/// 视频库刮削（作品列表 / 重刮 / 手动候选 / 手动指定身份）与视频发现（搜作品 →
/// 搜资源 → 入队下载）。
const List<CtlCommandGroup> videoCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'video',
    summary: '视频库刮削（重刮 / 手动识别）与视频发现下载',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'works',
        summary: '列出视频作品（作品 id 用于 scrape / candidates / identify）',
        configure: _configureWorks,
        build: _buildWorks,
        render: _renderWorks,
      ),
      CtlCommandSpec(
        name: 'scrape',
        summary: '重刮一个来源（数字 id）或一部作品（book:<uid> / collection:<id>）',
        usage: '<sourceId|workId>',
        configure: _configureScrape,
        build: _buildScrape,
        render: _renderScrape,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '刮削进度与最近的刮削记录',
        configure: _configureStatus,
        build: _buildStatus,
        render: _renderStatus,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消正在进行的刮削批次',
        build: _buildCancel,
        render: _renderCancel,
      ),
      CtlCommandSpec(
        name: 'candidates',
        summary: '为一部作品手动搜资料源候选（AniDB / MAL / TMDB）',
        usage: '<workId>',
        configure: _configureCandidates,
        build: _buildCandidates,
        render: _renderCandidates,
      ),
      CtlCommandSpec(
        name: 'identify',
        summary: '手动指定作品身份并重刮（--provider anidb|mal|tmdb --id <数字>）',
        usage: '<workId>',
        configure: _configureIdentify,
        build: _buildIdentify,
        render: _renderIdentify,
      ),
      CtlCommandSpec(
        name: 'discover',
        summary: '在视频发现源里搜作品（结果 id 用于 video resources）',
        usage: '<关键词...>',
        configure: _configureDiscover,
        build: _buildDiscover,
        render: _renderDiscover,
      ),
      CtlCommandSpec(
        name: 'resources',
        summary: '为发现到的作品搜下载资源（结果 id 用于 video get）',
        usage: '<作品结果 id>',
        configure: _configureResources,
        build: _buildResources,
        render: _renderResources,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '把一条资源交给下载管线（完成后自动入库，dl get <jobId> 看进度）',
        usage: '<资源结果 id>',
        configure: _configureGet,
        build: _buildGet,
        render: _renderGet,
      ),
    ],
  ),
];

/// 刮削白名单（CLAUDE.md「动画刮削参考与 provider 边界」）。
const List<String> _providers = <String>['anidb', 'mal', 'tmdb'];

/// 路径段编码（作品 id 含 `:`，bookUid 可能含任意字符）。
String _seg(String raw) => Uri.encodeComponent(raw);

/// CLI 侧先挡掉明显不对的作品 id，app 侧再按计划器定位。
String _workId(CtlCommandContext context) {
  final String id = context.positional(0, 'workId').trim();
  final bool book = id.startsWith('book:') && id.length > 'book:'.length;
  final bool collection = RegExp(r'^collection:[1-9]\d*$').hasMatch(id);
  if (!book && !collection) {
    throw CtlUsageError(
      '作品 id 格式不对：$id（book:<uid> 或 collection:<id>，见 video works）',
    );
  }
  return id;
}

String _provider(String? raw) {
  if (raw == null)
    throw const CtlUsageError('缺少 --provider（anidb | mal | tmdb）');
  final String name = raw.toLowerCase();
  if (!_providers.contains(name)) {
    throw CtlUsageError('不支持的资料源：$raw（anidb | mal | tmdb）');
  }
  return name;
}

// ── works ────────────────────────────────────────────────────────────────

void _configureWorks(ArgParser parser) {
  parser.addFlag('pending', negatable: false, help: '只列待确认（没刮出身份）的作品及原因');
}

CtlRequestSpec _buildWorks(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/video/works',
  query: <String, String>{if (context.flag('pending')) 'pending': 'true'},
);

String _renderWorks(Object? data) {
  if (data is Map && data['pending'] == true) {
    return renderCtlTable(
      data,
      const <(String, String)>[
        ('id', 'id'),
        ('标题', 'title'),
        ('来源', 'source'),
        ('文件', 'members'),
        ('原因', 'reason'),
      ],
      listKey: 'works',
      empty: '没有待确认的作品',
    );
  }
  return renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('标题', 'title'),
      ('来源', 'source'),
      ('文件', 'members'),
      ('身份', 'identity'),
      ('资料标题', 'scrapedTitle'),
    ],
    listKey: 'works',
    empty: '视频库里没有可刮削的作品',
  );
}

// ── scrape / status / cancel ─────────────────────────────────────────────

void _configureScrape(ArgParser parser) {
  parser
    ..addFlag('wait', negatable: false, help: '等刮削结束并输出结果（缺省后台进行）')
    ..addFlag(
      'allow-overwrite',
      negatable: false,
      help: '来源设置要求覆盖外部 NFO / 图片时允许覆盖（需 --yes）',
    )
    ..addFlag('yes', abbr: 'y', negatable: false, help: '确认覆盖');
}

CtlRequestSpec _buildScrape(CtlCommandContext context) {
  final String target = context.positional(0, 'sourceId|workId').trim();
  final bool isSource = RegExp(r'^[1-9]\d*$').hasMatch(target);
  if (!isSource) {
    final bool book =
        target.startsWith('book:') && target.length > 'book:'.length;
    if (!book && !RegExp(r'^collection:[1-9]\d*$').hasMatch(target)) {
      throw CtlUsageError(
        '目标格式不对：$target（来源 id 数字，或作品 id book:<uid> / collection:<id>）',
      );
    }
  }
  final bool overwrite = context.flag('allow-overwrite');
  if (overwrite) {
    if (!isSource) throw const CtlUsageError('--allow-overwrite 只用于整来源刮削');
    if (!context.flag('yes')) {
      throw const CtlUsageError('覆盖外部 NFO / 图片需要 --yes 确认');
    }
  }
  return CtlRequestSpec.post(
    '/api/admin/video/scrape',
    body: <String, Object?>{
      'target': target,
      if (context.flag('wait')) 'wait': true,
      if (overwrite) 'allowOverwrite': true,
      if (overwrite) 'confirm': true,
    },
  );
}

String _reportLine(Object? report) {
  if (report is! Map) return '';
  return '成功 ${report['succeededWorks']} / 失败 ${report['failedWorks']} / '
      '待确认 ${report['pendingConfirmations']}（共 ${report['totalWorks']}）';
}

String _reportIssues(Object? report) {
  if (report is! Map) return '';
  final List<String> lines = <String>[
    for (final Object? e in (report['errors'] as List<Object?>?) ?? <Object?>[])
      if (e is Map) '  错误 ${e['work']}: ${e['message']}',
    for (final Object? w
        in (report['warnings'] as List<Object?>?) ?? <Object?>[])
      if (w is Map) '  提示 ${w['work']}: ${w['message']}',
  ];
  return lines.join('\n');
}

String _renderOutcome(Map<Object?, Object?> data, String subject) {
  if (data['started'] == true || data['queued'] == true) {
    return '已开始：$subject（fushi_cli video status 查看进度）';
  }
  final String issues = _reportIssues(data['report']);
  return <String>[
    '${data['ok'] == true ? '完成' : '未成功'}：$subject  ${_reportLine(data['report'])}',
    if (issues.isNotEmpty) issues,
  ].join('\n');
}

String _renderScrape(Object? data) {
  if (data is! Map) return '完成';
  final String subject = data['mode'] == 'source'
      ? '来源 ${data['source']}（${data['sourceId']}）'
      : '${data['title']}（${data['workId']}，'
            '${data['mode'] == 'identity' ? '按已有身份' : '自动识别'}）';
  return _renderOutcome(data, subject);
}

void _configureStatus(ArgParser parser) {
  parser.addOption('limit', help: '显示最近多少条刮削记录（缺省 10）');
}

CtlRequestSpec _buildStatus(CtlCommandContext context) {
  final int? limit = context.intOption('limit');
  if (limit != null && limit < 1) throw const CtlUsageError('--limit 至少为 1');
  return CtlRequestSpec.get(
    '/api/admin/video/scrape',
    query: <String, String>{if (limit != null) 'limit': '$limit'},
  );
}

String _renderStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? progress = data['progress'];
  final List<String> lines = <String>[
    if (data['busy'] == true && progress is Map)
      '进行中：${progress['phase']} ${progress['current']}/${progress['total']}'
          '${progress['work'] == null ? '' : ' · ${progress['work']}'}'
    else
      '空闲',
    if (data['queuedManual'] is int && (data['queuedManual'] as int) > 0)
      '手动指定排队：${data['queuedManual']}',
    if (data['pendingConfirmation'] is Map)
      '等待在 app 内确认：${(data['pendingConfirmation'] as Map)['work']}',
    '',
    renderCtlTable(
      data,
      const <(String, String)>[
        ('id', 'id'),
        ('来源', 'sourceId'),
        ('范围', 'scope'),
        ('状态', 'status'),
        ('成功', 'succeeded'),
        ('失败', 'failed'),
        ('待确认', 'pending'),
        ('错误', 'error'),
      ],
      listKey: 'runs',
      empty: '还没有刮削记录',
    ),
  ];
  return lines.join('\n');
}

CtlRequestSpec _buildCancel(CtlCommandContext context) =>
    const CtlRequestSpec.post('/api/admin/video/scrape/cancel');

String _renderCancel(Object? data) => '已请求取消当前刮削批次';

// ── candidates / identify ────────────────────────────────────────────────

void _configureCandidates(ArgParser parser) {
  parser
    ..addOption('provider', help: '只看某个资料源的候选（anidb | mal | tmdb）')
    ..addOption('query', abbr: 'q', help: '搜索词（缺省用作品标题；也可直接给 anidb:123 这类身份）');
}

CtlRequestSpec _buildCandidates(CtlCommandContext context) {
  final String id = _workId(context);
  final String? provider = context.option('provider');
  return CtlRequestSpec.get(
    '/api/admin/video/works/${_seg(id)}/candidates',
    query: <String, String>{
      if (provider != null) 'provider': _provider(provider),
      if (context.option('query') case final String q) 'q': q,
    },
  );
}

String _renderCandidates(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('身份', 'identity'),
      ('类型', 'mediaKind'),
      ('标题', 'title'),
      ('原名', 'originalTitle'),
      ('年份', 'year'),
      ('集数', 'episodes'),
    ],
    listKey: 'candidates',
    empty: '没有候选',
  );
  if (data is! Map) return table;
  return '${data['workId']} · 搜索「${data['query']}」\n$table\n'
      '（用 fushi_cli video identify ${data['workId']} --provider <p> --id <id> 指定）';
}

void _configureIdentify(ArgParser parser) {
  parser
    ..addOption('provider', help: '资料源：anidb | mal | tmdb')
    ..addOption('id', help: '该资料源上的作品 id（正整数）')
    ..addOption('type', help: 'tv | movie（TMDB 的剧集 / 电影是两个 id 空间）')
    ..addFlag('wait', defaultsTo: true, help: '等重刮结束（--no-wait 只入队）');
}

CtlRequestSpec _buildIdentify(CtlCommandContext context) {
  final String id = _workId(context);
  final String provider = _provider(context.option('provider'));
  final String? externalId = context.option('id');
  if (externalId == null) throw const CtlUsageError('缺少 --id');
  if (!RegExp(r'^[1-9]\d*$').hasMatch(externalId)) {
    throw CtlUsageError('--id 必须是正整数：$externalId');
  }
  final String? type = context.option('type')?.toLowerCase();
  if (type != null && type != 'tv' && type != 'movie') {
    throw CtlUsageError('--type 只能是 tv 或 movie：$type');
  }
  return CtlRequestSpec.post(
    '/api/admin/video/works/${_seg(id)}/identify',
    body: <String, Object?>{
      'provider': provider,
      'externalId': externalId,
      if (type != null) 'type': type,
      if (!context.flag('wait')) 'wait': false,
    },
  );
}

String _renderIdentify(Object? data) {
  if (data is! Map) return '完成';
  final Object? identity = data['identity'];
  final String who = identity is Map
      ? '${identity['provider']}:${identity['externalId']}'
      : '';
  return _renderOutcome(
    data,
    '${data['workId']} → $who ${data['title'] ?? ''}',
  );
}

// ── discover / resources / get ───────────────────────────────────────────

void _configureDiscover(ArgParser parser) {
  parser
    ..addOption('category', help: 'anime | tv | movie（缺省不限）')
    ..addOption('page', help: '页码（从 1 开始）');
}

CtlRequestSpec _buildDiscover(CtlCommandContext context) {
  final String query = context.joinedRest(0, '关键词');
  final String? category = context.option('category')?.toLowerCase();
  if (category != null &&
      !const <String>['anime', 'tv', 'movie', 'all'].contains(category)) {
    throw CtlUsageError('--category 只能是 anime | tv | movie：$category');
  }
  final int? page = context.intOption('page');
  if (page != null && page < 1) throw const CtlUsageError('--page 从 1 开始');
  return CtlRequestSpec.get(
    '/api/admin/video/discovery/search',
    query: <String, String>{
      'q': query,
      if (category != null) 'category': category,
      if (page != null) 'page': '$page',
    },
  );
}

String _failures(Object? data) {
  if (data is! Map || data['failures'] is! List) return '';
  return <String>[
    for (final Object? f in data['failures'] as List<Object?>)
      if (f is Map) '  来源失败 ${f['source']}: ${f['message']}',
  ].join('\n');
}

String _withFailures(String table, Object? data) {
  final String failures = _failures(data);
  return failures.isEmpty ? table : '$table\n$failures';
}

String _renderDiscover(Object? data) => _withFailures(
  renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('标题', 'title'),
      ('原名', 'originalTitle'),
      ('年份', 'year'),
      ('类型', 'kind'),
      ('资料源', 'provider'),
    ],
    listKey: 'works',
    empty: '没有结果',
  ),
  data,
);

void _configureResources(ArgParser parser) {
  parser.addOption('query', abbr: 'q', help: '资源搜索词（缺省用作品的首选检索词）');
}

CtlRequestSpec _buildResources(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/video/discovery/works/'
  '${_seg(context.positional(0, '作品结果 id'))}/resources',
  query: <String, String>{
    if (context.option('query') case final String q) 'q': q,
  },
);

String _renderResources(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('标题', 'title'),
      ('来源', 'provider'),
      ('大小', 'size'),
      ('做种', 'seeders'),
      ('分辨率', 'resolution'),
    ],
    listKey: 'resources',
    empty: '没有资源',
  );
  final String head = data is Map
      ? '${data['title']} · 搜索「${data['query']}」\n'
      : '';
  return _withFailures('$head$table', data);
}

void _configureGet(ArgParser parser) {
  parser
    ..addOption('source', help: '落地的受管视频来源 id（缺省用下载设置里的默认来源）')
    ..addOption(
      'subtitles',
      help: '字幕策略：none | bestEffort | required（缺省 bestEffort）',
    );
}

CtlRequestSpec _buildGet(CtlCommandContext context) {
  final String id = context.positional(0, '资源结果 id');
  final int? source = context.intOption('source');
  final String? subtitles = context.option('subtitles');
  if (subtitles != null &&
      !const <String>[
        'none',
        'besteffort',
        'required',
      ].contains(subtitles.toLowerCase())) {
    throw CtlUsageError(
      '--subtitles 只能是 none | bestEffort | required：$subtitles',
    );
  }
  return CtlRequestSpec.post(
    '/api/admin/video/discovery/acquire',
    body: <String, Object?>{
      'id': id,
      if (source != null) 'sourceId': source,
      if (subtitles != null) 'subtitles': subtitles,
    },
  );
}

String _renderGet(Object? data) => data is Map
    ? '已入队：${data['title']} → ${data['source']}，任务 ${data['jobId']}'
          '（fushi_cli dl get ${data['jobId']} 查看进度）'
    : '完成';

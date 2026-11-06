import 'dart:convert';

import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'settings_commands.dart' show buildCtlCliArgsBody;

/// 设置页里「对话框 / 播放页交互」类操作的 CLI 命令。它们在 app 侧都是设置条目的
/// 控制通道入口（`/api/admin/settings/<key>/run` 与 `.../items`），这里给出顺手的
/// 命令名并把参数映射过去：
/// - `audiosrc`：音频来源管理对话框（列表 / 增删改 / 启停 / 排序 / 重置 / 本地子来源）；
/// - [syncCompareCommands]（挂在 `sync` 组）：同步差异对比与逐条应用；
/// - [plexLoginCommands]（挂在 `mediaserver` 组）：plex.tv 账号 PIN 授权；
/// - [ankiSyncClientCommands]（挂在 `anki` 组）：内置 Anki 同步客户端登录区块；
/// - [videoSettingsOpsCommands]（挂在 `video` 组）：字幕位置、着色器档位 / 本机 mpv。
const List<CtlCommandGroup> settingsOpsCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'audiosrc',
    summary: '查词音频来源（远端 / 本地音频库 / 互联）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出音频来源（顺序即优先级）',
        build: _buildAudioLs,
        render: _renderAudioList,
      ),
      CtlCommandSpec(
        name: 'add',
        summary:
            '新增：--url <含 {term}/{reading} 的地址> | --path <本地音频库 .db> | --fushi-remote',
        configure: _configureAudioAdd,
        build: _buildAudioAdd,
        render: _renderAudioItem,
      ),
      CtlCommandSpec(
        name: 'set',
        summary: '修改一条：启停 / 显示名 / 地址 / 换库文件 / 挪位置',
        usage: '<id>',
        configure: _configureAudioSet,
        build: _buildAudioSet,
        render: _renderAudioItem,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除一条（需 --yes；互联源不能删，只能 --disable）',
        usage: '<id>',
        configure: _configureYes,
        build: _buildAudioRm,
        render: _renderAudioRemoved,
      ),
      CtlCommandSpec(
        name: 'reset',
        summary: '重置（保留本地库与互联源，远端只剩内置 Anki 预设；需 --yes）',
        configure: _configureYes,
        build: _buildAudioReset,
        render: _renderAudioReset,
      ),
      CtlCommandSpec(
        name: 'local-sources',
        summary: '本地音频库的子来源：不给 --set 只查询；--set "a,!b,c"（! = 停用，顺序即优先级）',
        usage: '<库 path>',
        configure: _configureLocalSources,
        build: _buildLocalSources,
        render: _renderActionResult,
      ),
    ],
  ),
];

/// `sync compare` / `sync compare-apply`。
const List<CtlCommandSpec> syncCompareCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'compare',
    summary: '同步差异对比：列出每本书两端的差异与默认选择（会联网拉远端）',
    build: _buildSyncCompare,
    render: _renderSyncCompare,
  ),
  CtlCommandSpec(
    name: 'compare-apply',
    summary:
        '按选择应用差异（需 --yes）：--keep auto|local|remote|skip 管没点名的书，'
        '--item <id>=local|remote|skip 逐条（远端独有的书给 remote = 下载）',
    configure: _configureSyncCompareApply,
    build: _buildSyncCompareApply,
    render: _renderActionResult,
  ),
];

/// `mediaserver plex-login`。
const List<CtlCommandSpec> plexLoginCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'plex-login',
    summary: 'Plex 账号登录（plex.tv PIN）：打印授权链接与 PIN，后台等你在浏览器里同意',
    configure: _configurePlexLogin,
    build: _buildPlexLogin,
    render: _renderPlexLogin,
  ),
];

/// `anki sync-status | sync-use | sync-login | sync-logout`（立即同步沿用 `anki sync`）。
const List<CtlCommandSpec> ankiSyncClientCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'sync-status',
    summary: '内置 Anki 同步客户端：是否启用、登录账号、同步状态',
    build: _buildAnkiSyncStatus,
    render: _renderActionResult,
  ),
  CtlCommandSpec(
    name: 'sync-use',
    summary: '切换制卡后端到 / 离开内置 Anki 同步客户端（on 需 --yes 确认风险）',
    usage: '<on|off>',
    configure: _configureYes,
    build: _buildAnkiSyncUse,
    render: _renderAnkiSyncUse,
  ),
  CtlCommandSpec(
    name: 'sync-login',
    summary:
        '登录同步服务器（密码只收 --password-stdin / --password-from-env；不给 --server = AnkiWeb）',
    usage: '<username>',
    configure: _configureAnkiLogin,
    build: _buildAnkiLogin,
    render: _renderActionResult,
  ),
  CtlCommandSpec(
    name: 'sync-logout',
    summary: '退出登录（有未同步卡时拒绝；--discard --yes 放弃它们并退出）',
    configure: _configureAnkiLogout,
    build: _buildAnkiLogout,
    render: _renderActionResult,
  ),
];

/// `video sub-position | shader-tier | shader-discover | mpv-dir`。
const List<CtlCommandSpec> videoSettingsOpsCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'sub-position',
    summary: '字幕位置（同播放页拖动字幕）：不给参数 = 查看；播放中即时生效',
    configure: _configureSubPosition,
    build: _buildSubPosition,
    render: _renderActionResult,
  ),
  CtlCommandSpec(
    name: 'shader-tier',
    summary: '画质档位：不给 = 查看；off|low|medium|high|ultra = 一键选档（缺的着色器先下载）',
    usage: '[<档位>]',
    build: _buildShaderTier,
    render: _renderSetting,
  ),
  CtlCommandSpec(
    name: 'shader-discover',
    summary: '从本机 mpv 发现着色器；--import all|a.glsl,b.glsl 导入到着色器目录',
    configure: _configureShaderDiscover,
    build: _buildShaderDiscover,
    render: _renderActionResult,
  ),
  CtlCommandSpec(
    name: 'mpv-dir',
    summary: '本机 mpv 配置 / 着色器目录：不给 = 查看；给目录 = 设置；"" = 清掉',
    usage: '[<目录>]',
    build: _buildMpvDir,
    render: _renderSetting,
  ),
];

// ── 通用 ────────────────────────────────────────────────────────────────────

String _settingPath(String key) =>
    '/api/admin/settings/${Uri.encodeComponent(key)}';

String _runPath(String key) => '${_settingPath(key)}/run';

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认操作');
}

void _requireYes(CtlCommandContext context, String what) {
  if (!context.flag('yes')) throw CtlUsageError('$what需要 --yes 确认');
}

CtlRequestSpec _run(
  String key, {
  Map<String, String> args = const <String, String>{},
  bool confirm = false,
}) => CtlRequestSpec.post(
  _runPath(key),
  body: <String, Object?>{
    if (args.isNotEmpty) 'args': args,
    if (confirm) 'confirm': true,
  },
);

Object? _actionResult(Object? data) => data is Map ? data['result'] : data;

/// 设置项读写应答：`键 = 值`。
String _renderSetting(Object? data) =>
    data is Map ? '${data['key']} = ${data['display']}' : renderCtlJson(data);

String _renderAudioRemoved(Object? data) => '已删除';

String _renderActionResult(Object? data) => renderCtlJson(_actionResult(data));

/// `sync-use`：off 回的是设置项应答（`键 = 值`），on 回的是动作应答（状态 JSON）。
String _renderAnkiSyncUse(Object? data) => data is Map && data['ran'] == true
    ? _renderActionResult(data)
    : _renderSetting(data);

// ── audiosrc ────────────────────────────────────────────────────────────────

const String _audioItems = 'lookup.audio_sources.items';

void _configureAudioCommon(ArgParser parser) {
  parser
    ..addOption('label', help: '显示名')
    ..addOption('position', help: '放到第几位（0 = 最高优先级）')
    ..addFlag('reference', negatable: false, help: '本地库：引用原文件不复制');
}

void _configureAudioAdd(ArgParser parser) {
  _configureAudioCommon(parser);
  parser
    ..addOption('url', help: '远端地址（含 {term} / {reading}）')
    ..addOption('path', help: '本地音频库文件（.db）')
    ..addFlag('fushi-remote', negatable: false, help: '加 Fushi 互联源')
    ..addFlag('disabled', negatable: false, help: '添加后先停用');
}

void _configureAudioSet(ArgParser parser) {
  _configureAudioCommon(parser);
  parser
    ..addOption('url', help: '新的远端地址')
    ..addOption('path', help: '换成另一个本地音频库文件')
    ..addFlag('enable', negatable: false, help: '启用')
    ..addFlag('disable', negatable: false, help: '停用');
}

CtlRequestSpec _buildAudioLs(CtlCommandContext context) =>
    CtlRequestSpec.get('${_settingPath(_audioItems)}/items');

Map<String, String> _audioCommonFields(CtlCommandContext context) {
  final String? label = context.option('label');
  final String? position = context.option('position');
  final String? path = context.option('path');
  return <String, String>{
    if (label != null) 'label': label,
    if (position != null) 'position': position,
    if (path != null) 'path': ctlAbsolutePath(path),
    if (context.flag('reference')) 'reference': 'true',
  };
}

CtlRequestSpec _buildAudioAdd(CtlCommandContext context) {
  final String? url = context.option('url');
  final bool fushi = context.flag('fushi-remote');
  final Map<String, String> fields = _audioCommonFields(context);
  final int kinds =
      (url != null ? 1 : 0) +
      (fields.containsKey('path') ? 1 : 0) +
      (fushi ? 1 : 0);
  if (kinds != 1) {
    throw const CtlUsageError('--url、--path、--fushi-remote 恰好给一个');
  }
  return CtlRequestSpec.post(
    '${_settingPath(_audioItems)}/items',
    body: <String, Object?>{
      'args': <String, String>{
        ...fields,
        'kind': fushi
            ? 'fushi_remote'
            : url != null
            ? 'remote'
            : 'local',
        if (url != null) 'url': url,
        if (context.flag('disabled')) 'enabled': 'false',
      },
    },
  );
}

CtlRequestSpec _buildAudioSet(CtlCommandContext context) {
  final String id = context.positional(0, 'id');
  if (context.flag('enable') && context.flag('disable')) {
    throw const CtlUsageError('--enable 与 --disable 只能给一个');
  }
  final String? url = context.option('url');
  final Map<String, String> fields = <String, String>{
    ..._audioCommonFields(context),
    if (url != null) 'url': url,
    if (context.flag('enable')) 'enabled': 'true',
    if (context.flag('disable')) 'enabled': 'false',
  };
  if (fields.isEmpty) throw const CtlUsageError('没有要改的字段');
  return CtlRequestSpec.put(
    '${_settingPath(_audioItems)}/items/${Uri.encodeComponent(id)}',
    body: <String, Object?>{'args': fields},
  );
}

CtlRequestSpec _buildAudioRm(CtlCommandContext context) {
  final String id = context.positional(0, 'id');
  _requireYes(context, '删除音频来源');
  return CtlRequestSpec.delete(
    '${_settingPath(_audioItems)}/items/${Uri.encodeComponent(id)}',
    query: const <String, String>{'confirm': 'true'},
  );
}

CtlRequestSpec _buildAudioReset(CtlCommandContext context) {
  _requireYes(context, '重置音频来源');
  return _run('lookup.audio_sources.reset', confirm: true);
}

void _configureLocalSources(ArgParser parser) {
  parser.addOption('set', help: '子来源顺序与启停：a,!b,c');
}

CtlRequestSpec _buildLocalSources(CtlCommandContext context) {
  final String? spec = context.option('set');
  return _run(
    'lookup.audio_sources.local_sources',
    args: <String, String>{
      'path': context.positional(0, '库 path'),
      if (spec != null) 'value': spec,
    },
  );
}

String _renderAudioList(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('#', 'position'),
    ('ID', 'id'),
    ('种类', 'kind'),
    ('启用', 'enabled'),
    ('名称', 'label'),
  ],
  listKey: 'items',
  empty: '（没有音频来源）',
);

String _renderAudioItem(Object? data) =>
    renderCtlJson(data is Map ? data['item'] ?? data : data);

String _renderAudioReset(Object? data) {
  final Object? result = _actionResult(data);
  return _renderAudioList(<String, Object?>{
    'items': result is Map ? result['sources'] : null,
  });
}

// ── sync compare ────────────────────────────────────────────────────────────

void _configureSyncCompareApply(ArgParser parser) {
  _configureYes(parser);
  parser
    ..addOption(
      'keep',
      allowed: const <String>['auto', 'local', 'remote', 'skip'],
      help: '没点名的书怎么处理（缺省 auto = 同对话框默认）',
    )
    ..addMultiOption(
      'item',
      valueHelp: 'id=local|remote|skip',
      help: '逐条选择（可重复）',
    );
}

CtlRequestSpec _buildSyncCompare(CtlCommandContext context) =>
    _run('sync.compare');

CtlRequestSpec _buildSyncCompareApply(CtlCommandContext context) {
  _requireYes(context, '应用同步差异（会改写本机或远端的进度）');
  final Map<String, String> items = <String, String>{};
  for (final String raw in context.multiOption('item')) {
    final int eq = raw.lastIndexOf('=');
    if (eq <= 0)
      throw CtlUsageError('--item 写成 <id>=local|remote|skip，收到「$raw」');
    items[raw.substring(0, eq)] = raw.substring(eq + 1);
  }
  final String? keep = context.option('keep');
  return _run(
    'sync.compare_apply',
    confirm: true,
    args: <String, String>{
      if (keep != null) 'keep': keep,
      if (items.isNotEmpty) 'items': _jsonObject(items),
    },
  );
}

String _jsonObject(Map<String, String> map) => jsonEncode(map);

String _renderSyncCompare(Object? data) {
  final Object? result = _actionResult(data);
  if (result is! Map) return renderCtlJson(result);
  final StringBuffer out = StringBuffer()
    ..writeln('后端：${result['backend']}')
    ..writeln(
      renderCtlTable(
        result,
        const <(String, String)>[
          ('ID', 'id'),
          ('书名', 'title'),
          ('状态', 'status'),
          ('默认', 'default'),
        ],
        listKey: 'books',
        empty: '（没有书）',
      ),
    );
  final Object? dicts = result['dictionaries'];
  if (dicts is List && dicts.isNotEmpty) {
    out
      ..writeln('\n词典：')
      ..writeln(
        renderCtlTable(result, const <(String, String)>[
          ('名称', 'title'),
          ('本机', 'local'),
          ('远端', 'remote'),
        ], listKey: 'dictionaries'),
      );
  }
  out.write(
    '应用：fushi_cli sync compare-apply --yes [--keep …] [--item <id>=local|remote]',
  );
  return out.toString();
}

// ── plex ────────────────────────────────────────────────────────────────────

void _configurePlexLogin(ArgParser parser) {
  parser
    ..addFlag('open', negatable: false, help: '在本机默认浏览器里打开授权页')
    ..addOption('timeout', valueHelp: '秒', help: '最多等多少秒（60…1800，缺省 600）');
}

CtlRequestSpec _buildPlexLogin(CtlCommandContext context) {
  final String? timeout = context.option('timeout');
  return _run(
    'services.media_server.plex.sign_in',
    args: <String, String>{
      if (context.flag('open')) 'open': 'true',
      if (timeout != null) 'timeout': timeout,
    },
  );
}

String _renderPlexLogin(Object? data) {
  final Object? task = _actionResult(data);
  if (task is! Map) return renderCtlJson(task);
  final Object? detail = task['detail'];
  final StringBuffer out = StringBuffer();
  if (detail is Map) {
    out
      ..writeln('在浏览器里打开下面的链接并同意 Fushi 访问你的 Plex 账号：')
      ..writeln('  ${detail['authUrl']}')
      ..writeln('PIN：${detail['pin']}');
  }
  out.write(
    '等授权完成：fushi_cli task get ${task['id']} --wait 300'
    '（取消：fushi_cli task cancel ${task['id']}）',
  );
  return out.toString();
}

// ── anki 同步客户端 ─────────────────────────────────────────────────────────

const String _ankiSync = 'card_creation.anki.sync_client';

CtlRequestSpec _buildAnkiSyncStatus(CtlCommandContext context) =>
    _run('$_ankiSync.status');

/// 启用与设置页同一道闸：设置页先弹「启用 Anki 同步？」警告确认，这里就要
/// `--yes`，走带确认的 `.enable` 动作（直接写开关为 true 会被 app 拒）。关闭不用确认。
CtlRequestSpec _buildAnkiSyncUse(CtlCommandContext context) {
  switch (context.positional(0, 'on|off')) {
    case 'on':
      _requireYes(
        context,
        '启用内置 Anki 同步客户端（实验功能：同步到 AnkiWeb 不被第三方客户端允许，'
        '可能失败或危及账号）',
      );
      return _run('$_ankiSync.enable', confirm: true);
    case 'off':
      return CtlRequestSpec.put(
        _settingPath('$_ankiSync.enabled'),
        body: const <String, Object?>{'value': 'false', 'source': 'argv'},
      );
    case final String other:
      throw CtlUsageError('取 on / off，收到「$other」');
  }
}

void _configureAnkiLogin(ArgParser parser) {
  parser
    ..addOption('server', help: '自建同步服务器根地址（不给 = AnkiWeb）')
    ..addFlag('password-stdin', negatable: false, help: '从标准输入读密码')
    ..addOption('password-from-env', valueHelp: 'VAR', help: '从环境变量读密码')
    ..addFlag(
      'accept-ankiweb',
      negatable: false,
      help: '登录 AnkiWeb：已知晓 AnkiWeb 条款只允许官方客户端同步',
    );
}

CtlRequestSpec _buildAnkiLogin(CtlCommandContext context) {
  final String username = context.positional(0, 'username');
  final String? env = context.option('password-from-env');
  final bool stdinPassword = context.flag('password-stdin');
  if ((env != null) == stdinPassword) {
    throw const CtlUsageError(
      '密码只收 --password-stdin 或 --password-from-env（二选一）',
    );
  }
  final String? server = context.option('server');
  if (server == null && !context.flag('accept-ankiweb')) {
    throw const CtlUsageError(
      '不给 --server 就是登录 AnkiWeb：AnkiWeb 条款只允许官方 Anki 客户端同步，'
      '可能拒绝连接或处理账号；确认请加 --accept-ankiweb',
    );
  }
  // 复用 config run 的凭据通道：密码进 body.secrets，不进 args、不进命令行。
  final ArgParser shadow = ArgParser()
    ..addMultiOption('arg')
    ..addOption('secret-stdin')
    ..addMultiOption('secret-from-env');
  final CtlCommandContext secrets = CtlCommandContext(
    shadow.parse(<String>[
      if (stdinPassword) ...<String>['--secret-stdin', 'password'],
      if (env != null) ...<String>['--secret-from-env', 'password=$env'],
    ]),
  );
  final Map<String, Object?> body = buildCtlCliArgsBody(secrets);
  return CtlRequestSpec.post(
    _runPath('$_ankiSync.sign_in'),
    body: <String, Object?>{
      ...body,
      'args': <String, String>{
        'username': username,
        if (server != null) 'server': server,
        if (server == null) 'accept_ankiweb': 'true',
      },
    },
  );
}

void _configureAnkiLogout(ArgParser parser) {
  _configureYes(parser);
  parser.addFlag('discard', negatable: false, help: '放弃未同步的卡并退出（需 --yes）');
}

CtlRequestSpec _buildAnkiLogout(CtlCommandContext context) {
  if (context.flag('discard')) {
    _requireYes(context, '放弃未同步的卡');
    return _run('$_ankiSync.sign_out_discard', confirm: true);
  }
  return _run('$_ankiSync.sign_out');
}

// ── video ───────────────────────────────────────────────────────────────────

void _configureSubPosition(ArgParser parser) {
  parser
    ..addOption('position', help: '主字幕离锚定边的距离 0…400（顶锚 = 离顶）')
    ..addOption(
      'anchor',
      allowed: const <String>['bottom', 'top'],
      help: '主字幕锚定边',
    )
    ..addOption('secondary-position', help: '副字幕距离 0…400')
    ..addOption(
      'secondary-anchor',
      allowed: const <String>['bottom', 'top'],
      help: '副字幕锚定边',
    );
}

CtlRequestSpec _buildSubPosition(CtlCommandContext context) {
  final String? position = context.option('position');
  final String? anchor = context.option('anchor');
  final String? secondaryPosition = context.option('secondary-position');
  final String? secondaryAnchor = context.option('secondary-anchor');
  return _run(
    'video.subtitle.drag_adjust',
    args: <String, String>{
      if (position != null) 'position': position,
      if (anchor != null) 'anchor': anchor,
      if (secondaryPosition != null) 'secondary_position': secondaryPosition,
      if (secondaryAnchor != null) 'secondary_anchor': secondaryAnchor,
    },
  );
}

CtlRequestSpec _buildShaderTier(CtlCommandContext context) {
  final String? tier = context.optionalPositional(0);
  const String key = 'video.player.shader_tier';
  if (tier == null) return CtlRequestSpec.get(_settingPath(key));
  return CtlRequestSpec.put(
    _settingPath(key),
    body: <String, Object?>{'value': tier, 'source': 'argv'},
  );
}

void _configureShaderDiscover(ArgParser parser) {
  parser
    ..addOption('dir', help: '先把这个目录记成 mpv 目录再扫')
    ..addOption('import', help: 'all 或逗号分隔的文件名');
}

CtlRequestSpec _buildShaderDiscover(CtlCommandContext context) {
  final String? dir = context.option('dir');
  final String? import = context.option('import');
  return _run(
    'video.player.shader_discover',
    args: <String, String>{
      if (dir != null) 'dir': ctlAbsolutePath(dir),
      if (import != null) 'import': import,
    },
  );
}

CtlRequestSpec _buildMpvDir(CtlCommandContext context) {
  const String key = 'video.player.mpv_shader_dir';
  if (context.rest.isEmpty) return CtlRequestSpec.get(_settingPath(key));
  final String raw = context.rest.first;
  return CtlRequestSpec.put(
    _settingPath(key),
    body: <String, Object?>{
      'value': raw.trim().isEmpty ? '' : ctlAbsolutePath(raw),
      'source': 'argv',
    },
  );
}

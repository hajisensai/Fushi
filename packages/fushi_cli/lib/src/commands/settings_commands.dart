import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';

/// settings 域命令（app 侧路由见 `fushi/lib/src/platform/desktop/ctl/ctl_settings_routes.dart`）。
///
/// 五个命令组：
/// - `config`：设置项读写（键 = 设置 schema 的条目 id，写入走设置页同一个 onChanged）；
/// - `module`：功能模块开关；
/// - `profile`：配置（Profile）管理；
/// - `stats`：学习统计摘要 / 会话 / 诊断导出；
/// - `keys`：快捷键绑定清单（只读）。
const List<CtlCommandGroup> settingsCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'config',
    summary: '设置项读写（键见 config ls）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出可读写的设置项',
        configure: _configureConfigLs,
        build: _buildConfigLs,
        render: _renderConfigLs,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '读一个设置项（机密值一律打码）',
        usage: '<key>',
        build: _buildConfigGet,
        render: _renderConfigEntry,
      ),
      CtlCommandSpec(
        name: 'set',
        summary: '写一个设置项，与设置页改动等价（机密值只收 --stdin / --from-env）',
        usage: '<key> [<value>]',
        configure: _configureConfigSet,
        build: _buildConfigSet,
        render: _renderConfigEntry,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'module',
    summary: '功能模块开关',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出功能模块与开关状态',
        build: _buildModuleLs,
        render: _renderModuleLs,
      ),
      CtlCommandSpec(
        name: 'enable',
        summary: '打开一个模块',
        usage: '<id>',
        build: _buildModuleEnable,
        render: _renderModule,
      ),
      CtlCommandSpec(
        name: 'disable',
        summary: '关闭一个模块',
        usage: '<id>',
        build: _buildModuleDisable,
        render: _renderModule,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'profile',
    summary: '配置（Profile）管理',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出全部 Profile',
        build: _buildProfileLs,
        render: _renderProfileLs,
      ),
      CtlCommandSpec(
        name: 'use',
        summary: '切换到某个 Profile（id 或名字）',
        usage: '<id|名字>',
        build: _buildProfileUse,
        render: _renderProfile,
      ),
      CtlCommandSpec(
        name: 'new',
        summary: '以当前设置新建 Profile 并切换过去',
        usage: '<名字>',
        build: _buildProfileNew,
        render: _renderProfile,
      ),
      CtlCommandSpec(
        name: 'rename',
        summary: '重命名 Profile',
        usage: '<id|名字> <新名字>',
        build: _buildProfileRename,
        render: _renderProfile,
      ),
      CtlCommandSpec(
        name: 'copy',
        summary: '复制 Profile',
        usage: '<id|名字> <新名字>',
        build: _buildProfileCopy,
        render: _renderProfile,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除 Profile（需 --yes）',
        usage: '<id|名字>',
        configure: _configureYes,
        build: _buildProfileRm,
      ),
      CtlCommandSpec(
        name: 'export',
        summary: '导出 Profile 为 JSON（凭据已剔除；覆盖已有文件需 --yes）',
        usage: '<id|名字> <文件>',
        configure: _configureYes,
        build: _buildProfileExport,
        render: _renderPathResult,
      ),
      CtlCommandSpec(
        name: 'import',
        summary: '从 JSON 导入 Profile（默认新建；--into 覆盖已有需 --yes）',
        usage: '<文件>',
        configure: _configureProfileImport,
        build: _buildProfileImport,
        render: _renderProfile,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'stats',
    summary: '学习统计',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'show',
        summary: '统计摘要（当前 Profile）',
        configure: _configureStatsFilter,
        build: _buildStatsShow,
        render: _renderStatsShow,
      ),
      CtlCommandSpec(
        name: 'sessions',
        summary: '最近学习会话（stats sessions [ls]）',
        usage: '[ls]',
        configure: _configureStatsSessions,
        build: _buildStatsSessions,
        render: _renderStatsSessions,
      ),
      CtlCommandSpec(
        name: 'export',
        summary: '导出统计诊断日志（与 设置 › 诊断 同一份；覆盖需 --yes）',
        usage: '<文件>',
        configure: _configureYes,
        build: _buildStatsExport,
        render: _renderPathResult,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'keys',
    summary: '快捷键绑定（只读）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出快捷键绑定',
        configure: _configureKeysLs,
        build: _buildKeysLs,
        render: _renderKeysLs,
      ),
    ],
  ),
];

// ── config ──────────────────────────────────────────────────────────────────

void _configureConfigLs(ArgParser parser) {
  parser
    ..addOption('search', abbr: 's', help: '按键名 / 标题 / 分区筛选')
    ..addFlag('all', negatable: false, help: '连当前不可见的设置项一起列出');
}

CtlRequestSpec _buildConfigLs(CtlCommandContext context) {
  final String? search = context.option('search');
  return CtlRequestSpec.get(
    '/api/admin/settings',
    query: <String, String>{
      if (search != null) 'search': search,
      if (context.flag('all')) 'all': 'true',
    },
  );
}

CtlRequestSpec _buildConfigGet(CtlCommandContext context) =>
    CtlRequestSpec.get(_settingPath(context.positional(0, 'key')));

void _configureConfigSet(ArgParser parser) {
  parser
    ..addFlag('stdin', negatable: false, help: '从标准输入读值（机密值用它）')
    ..addOption('from-env', valueHelp: 'VAR', help: '从环境变量读值（机密值用它）');
}

CtlRequestSpec _buildConfigSet(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final String? argvValue = context.optionalPositional(1);
  final String? envName = context.option('from-env');
  final bool fromStdin = context.flag('stdin');
  final int sources =
      (argvValue != null ? 1 : 0) +
      (envName != null ? 1 : 0) +
      (fromStdin ? 1 : 0);
  if (sources == 0) {
    throw const CtlUsageError('缺少值：给 <value>、--stdin 或 --from-env 之一');
  }
  if (sources > 1) {
    throw const CtlUsageError('<value>、--stdin、--from-env 只能给一个');
  }
  if (context.rest.length > 2) {
    throw const CtlUsageError('值里有空格请用引号包起来');
  }
  final String value;
  final String source;
  if (envName != null) {
    final String? fromEnv = Platform.environment[envName];
    if (fromEnv == null) throw CtlUsageError('环境变量 $envName 未设置');
    value = fromEnv;
    source = 'env';
  } else if (fromStdin) {
    value = readCtlSecretFromStdin();
    source = 'stdin';
  } else {
    value = argvValue!;
    source = 'argv';
  }
  return CtlRequestSpec.put(
    _settingPath(key),
    body: <String, Object?>{'value': value, 'source': source},
  );
}

/// 从标准输入读一行（去掉行尾换行）；读不到抛 [CtlUsageError]。
String readCtlSecretFromStdin() {
  final String? line = stdin.readLineSync();
  if (line == null) throw const CtlUsageError('标准输入为空');
  return line;
}

String _settingPath(String key) =>
    '/api/admin/settings/${Uri.encodeComponent(key)}';

String _renderConfigLs(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('键', 'key'),
      ('类型', 'type'),
      ('当前值', 'display'),
      ('标题', 'title'),
    ], listKey: 'settings');

String _renderConfigEntry(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..writeln('${data['key']} = ${data['display']}')
    ..write('  ${data['type']} · ${data['title']}');
  final Object? options = data['options'];
  if (options is List && options.isNotEmpty) {
    out.write('\n  可选：${options.join(' | ')}');
  }
  final Object? min = data['min'];
  final Object? max = data['max'];
  if (min != null || max != null)
    out.write('\n  范围：${min ?? ''} … ${max ?? ''}');
  if (data['visible'] == false) out.write('\n  （当前不可见，不能写）');
  return out.toString();
}

// ── module ──────────────────────────────────────────────────────────────────

CtlRequestSpec _buildModuleLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/modules');

CtlRequestSpec _buildModuleEnable(CtlCommandContext context) =>
    _moduleToggle(context, enabled: true);

CtlRequestSpec _buildModuleDisable(CtlCommandContext context) =>
    _moduleToggle(context, enabled: false);

CtlRequestSpec _moduleToggle(
  CtlCommandContext context, {
  required bool enabled,
}) => CtlRequestSpec.put(
  '/api/admin/modules/${Uri.encodeComponent(context.positional(0, 'id'))}',
  body: <String, Object?>{'enabled': enabled},
);

String _renderModuleLs(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('模块', 'id'),
      ('本平台可用', 'available'),
      ('开关', 'enabled'),
      ('生效', 'visible'),
    ], listKey: 'modules');

String _renderModule(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '模块 ${data['id']}：${data['enabled'] == true ? '已打开' : '已关闭'}';
}

// ── profile ─────────────────────────────────────────────────────────────────

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认破坏性操作');
}

String _profilePath(String ref) =>
    '/api/admin/profiles/${Uri.encodeComponent(ref)}';

CtlRequestSpec _buildProfileLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/profiles');

CtlRequestSpec _buildProfileUse(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '${_profilePath(context.positional(0, 'id'))}/activate',
    );

CtlRequestSpec _buildProfileNew(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/profiles',
      body: <String, Object?>{'name': context.joinedRest(0, '名字')},
    );

CtlRequestSpec _buildProfileRename(CtlCommandContext context) =>
    CtlRequestSpec.put(
      _profilePath(context.positional(0, 'id')),
      body: <String, Object?>{'name': context.joinedRest(1, '新名字')},
    );

CtlRequestSpec _buildProfileCopy(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '${_profilePath(context.positional(0, 'id'))}/copy',
      body: <String, Object?>{'name': context.joinedRest(1, '新名字')},
    );

CtlRequestSpec _buildProfileRm(CtlCommandContext context) {
  final String ref = context.positional(0, 'id');
  _requireYes(context, '删除 Profile');
  return CtlRequestSpec.delete(
    _profilePath(ref),
    query: const <String, String>{'confirm': 'true'},
  );
}

CtlRequestSpec _buildProfileExport(CtlCommandContext context) {
  final String ref = context.positional(0, 'id');
  final String path = ctlAbsolutePath(context.positional(1, '文件'));
  return CtlRequestSpec.post(
    '${_profilePath(ref)}/export',
    body: <String, Object?>{
      'path': path,
      if (context.flag('yes')) 'confirm': true,
    },
  );
}

void _configureProfileImport(ArgParser parser) {
  _configureYes(parser);
  parser.addOption('into', valueHelp: 'id|名字', help: '覆盖这个已有 Profile（需 --yes）');
}

CtlRequestSpec _buildProfileImport(CtlCommandContext context) {
  final String path = ctlAbsolutePath(context.positional(0, '文件'));
  final String? into = context.option('into');
  if (into != null) _requireYes(context, '覆盖 Profile');
  return CtlRequestSpec.post(
    '/api/admin/profiles/import',
    body: <String, Object?>{
      'path': path,
      if (into != null) 'into': into,
      if (into != null) 'confirm': true,
    },
  );
}

void _requireYes(CtlCommandContext context, String action) {
  if (!context.flag('yes')) throw CtlUsageError('$action是破坏性操作，确认请加 --yes');
}

String _renderProfileLs(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[('id', 'id'), ('名字', 'name'), ('当前', 'active')],
  listKey: 'profiles',
);

String _renderProfile(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? profile = data['profile'];
  if (profile is Map) {
    final String active = profile['active'] == true ? '（当前）' : '';
    return '${data['action'] ?? 'Profile'}：#${profile['id']} ${profile['name']}$active';
  }
  return renderCtlJson(data);
}

String _renderPathResult(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已写入 ${data['path']}（${data['bytes']} 字节）';
}

// ── stats ───────────────────────────────────────────────────────────────────

void _configureStatsFilter(ArgParser parser) {
  parser
    ..addOption(
      'window',
      abbr: 'w',
      allowed: const <String>['today', '7d', '30d', 'all'],
      defaultsTo: '7d',
      help: '统计窗口',
    )
    ..addOption(
      'kind',
      abbr: 'k',
      allowed: const <String>['read', 'watch', 'game'],
      help: '只看某一域（缺省 = 全部）',
    );
}

void _configureStatsSessions(ArgParser parser) {
  _configureStatsFilter(parser);
  parser.addOption('limit', abbr: 'n', defaultsTo: '20', help: '最多条数');
}

Map<String, String> _statsQuery(CtlCommandContext context) {
  final String? kind = context.option('kind');
  return <String, String>{
    'window': context.option('window') ?? '7d',
    if (kind != null) 'kind': kind,
  };
}

CtlRequestSpec _buildStatsShow(CtlCommandContext context) {
  if (context.rest.isNotEmpty) {
    throw CtlUsageError('多余的参数：${context.rest.join(' ')}');
  }
  return CtlRequestSpec.get('/api/admin/stats', query: _statsQuery(context));
}

CtlRequestSpec _buildStatsSessions(CtlCommandContext context) {
  final String? verb = context.optionalPositional(0);
  if (verb != null && verb != 'ls') {
    throw CtlUsageError('未知子命令 $verb（只支持 ls）');
  }
  final int limit = context.intOption('limit') ?? 20;
  if (limit <= 0) throw const CtlUsageError('--limit 必须是正整数');
  return CtlRequestSpec.get(
    '/api/admin/stats/sessions',
    query: <String, String>{..._statsQuery(context), 'limit': '$limit'},
  );
}

CtlRequestSpec _buildStatsExport(CtlCommandContext context) {
  final String path = ctlAbsolutePath(context.positional(0, '文件'));
  return CtlRequestSpec.post(
    '/api/admin/stats/export',
    body: <String, Object?>{
      'path': path,
      if (context.flag('yes')) 'confirm': true,
    },
  );
}

String _renderStatsShow(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..writeln(
      '窗口 ${data['window']}（${data['fromKey'] ?? '最早'} … ${data['toKey']}）'
      '${data['kind'] == null ? '' : ' · ${data['kind']}'}',
    );
  final Object? totals = data['totals'];
  if (totals is Map) out.writeln('合计：${_statLine(totals)}');
  final Object? byKind = data['byKind'];
  if (byKind is Map) {
    for (final MapEntry<Object?, Object?> e in byKind.entries) {
      if (e.value is Map)
        out.writeln('  ${e.key}: ${_statLine(e.value! as Map)}');
    }
  }
  final Object? top = data['topMedia'];
  if (top is List && top.isNotEmpty) {
    out
      ..writeln('最多的条目：')
      ..write(
        renderCtlTable(top, const <(String, String)>[
          ('域', 'kind'),
          ('时长', 'duration'),
          ('字数', 'chars'),
          ('标题', 'title'),
        ]),
      );
  }
  return out.toString().trimRight();
}

String _statLine(Map<Object?, Object?> m) =>
    '${m['duration']} · ${m['chars']} 字 · ${m['pages']} 页 · ${m['activeDays']} 天';

String _renderStatsSessions(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('开始', 'start'),
      ('域', 'kind'),
      ('时长', 'duration'),
      ('字数', 'chars'),
      ('标题', 'title'),
    ], listKey: 'sessions');

// ── keys ────────────────────────────────────────────────────────────────────

void _configureKeysLs(ArgParser parser) {
  parser.addOption('scope', help: '只看某个作用域（reader / video / global …）');
}

CtlRequestSpec _buildKeysLs(CtlCommandContext context) {
  final String? scope = context.option('scope');
  return CtlRequestSpec.get(
    '/api/admin/shortcuts',
    query: <String, String>{if (scope != null) 'scope': scope},
  );
}

String _renderKeysLs(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('作用域', 'scope'),
      ('动作', 'action'),
      ('键盘', 'keyboard'),
      ('手柄', 'gamepad'),
      ('鼠标', 'mouse'),
      ('说明', 'label'),
    ], listKey: 'shortcuts');

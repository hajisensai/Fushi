import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'settings_ai_commands.dart';
import 'settings_model_commands.dart';
import 'settings_ops_commands.dart';
import 'settings_task_commands.dart';

/// settings 域命令（app 侧路由见 `fushi/lib/src/ops/ctl_settings_routes.dart`）。
///
/// 命令组：
/// - `config`：设置项读写 / 恢复默认 / 执行动作行（键 = 设置 schema 的条目 id，
///   写入走设置页同一个 onChanged）；
/// - `module`：功能模块开关与底栏顺序；
/// - `profile`：配置（Profile）管理与媒体类型 / 语言绑定；
/// - `stats`：学习统计摘要 / 会话 / 诊断导出；
/// - `keys`：快捷键绑定（列出 / 改绑 / 解绑 / 恢复默认）；
/// - `ai`：AI 提供商与功能指派（见 `settings_ai_commands.dart`）；
/// - `models` / `voice`：OCR / 语音转录 / 本机 GPT-SoVITS 模型文件与朗读声音
///   （见 `settings_model_commands.dart`）。
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
      CtlCommandSpec(
        name: 'reset',
        summary: '把一个设置项恢复默认（与详情页「恢复默认」同一判据）',
        usage: '<key>',
        build: _buildConfigReset,
        render: _renderConfigEntry,
      ),
      CtlCommandSpec(
        name: 'run',
        summary:
            '执行一个动作（config ls --kind action 看参数；--value / --arg k=v 给值，'
            '破坏性需 --yes，不会在 app 里弹对话框）',
        usage: '<key>',
        configure: _configureConfigRun,
        build: _buildConfigRun,
        render: _renderConfigEntry,
      ),
      CtlCommandSpec(
        name: 'items',
        summary: '记录列表的增删改查（config ls --kind list 列出可用列表）',
        usage: '<key> ls|add|set|rm [<id>]',
        configure: _configureConfigItems,
        build: _buildConfigItems,
        render: _renderConfigItems,
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
      CtlCommandSpec(
        name: 'order',
        summary: '查看 / 调整底栏模块顺序（给出的模块排到最前，其余保持原序）',
        usage: '[<id>...]',
        build: _buildModuleOrder,
        render: _renderModuleOrder,
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
      CtlCommandSpec(
        name: 'bindings',
        summary: '列出媒体类型 / 内容语言 → Profile 的自动切换绑定',
        build: _buildProfileBindings,
        render: _renderProfileBindings,
      ),
      CtlCommandSpec(
        name: 'bind',
        summary: '绑定媒体类型或内容语言到某个 Profile（none = 解绑）',
        usage: '<media|language> <类型|语言标签> <id|名字|none>',
        build: _buildProfileBind,
        render: _renderProfileBindings,
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
    summary: '快捷键绑定',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出快捷键绑定（--json 的 tokens 字段是可抄回 set 的写法）',
        configure: _configureKeysLs,
        build: _buildKeysLs,
        render: _renderKeysLs,
      ),
      CtlCommandSpec(
        name: 'set',
        summary:
            '改绑：给出的绑定替换该通道原有绑定（--add 追加；撞车默认报错，'
            '--steal 抢过来，--keep-both 两边都留）',
        usage: '<action> <绑定>...',
        configure: _configureKeysSet,
        build: _buildKeysSet,
        render: _renderKeysChange,
      ),
      CtlCommandSpec(
        name: 'unbind',
        summary: '解绑给出的绑定（--all --yes 清空该动作全部绑定）',
        usage: '<action> [<绑定>...]',
        configure: _configureKeysUnbind,
        build: _buildKeysUnbind,
        render: _renderKeysChange,
      ),
      CtlCommandSpec(
        name: 'reset',
        summary: '恢复默认：单个动作；--scope 一组 / --all 全部（需 --yes）',
        usage: '[<action>]',
        configure: _configureKeysReset,
        build: _buildKeysReset,
        render: _renderKeysChange,
      ),
    ],
  ),
  ...settingsAiCommandGroups,
  ...settingsModelCommandGroups,
  ...settingsTaskCommandGroups,
  ...settingsOpsCommandGroups,
];

// ── config ──────────────────────────────────────────────────────────────────

void _configureConfigLs(ArgParser parser) {
  parser
    ..addOption('search', abbr: 's', help: '按键名 / 标题 / 分区筛选')
    ..addFlag('all', negatable: false, help: '连当前不可见的设置项一起列出')
    ..addOption(
      'kind',
      abbr: 'k',
      allowed: const <String>[
        'value',
        'action',
        'status',
        'list',
        'custom',
        'all',
      ],
      help:
          '条目大类：value 可读写的值（缺省）/ action 可执行的动作 / '
          'status 只读状态 / list 记录列表 / custom 自绘行 / all 全部',
    );
}

/// `--arg k=v` / `--secret-stdin KEY` / `--secret-from-env KEY=VAR`：动作与列表
/// 操作共用的参数写法。
void _configureCliArgs(ArgParser parser) {
  parser
    ..addMultiOption('arg', abbr: 'a', valueHelp: 'k=v', help: '参数（可重复）')
    ..addOption('secret-stdin', valueHelp: 'KEY', help: '从标准输入读这个凭据参数')
    ..addMultiOption(
      'secret-from-env',
      valueHelp: 'KEY=VAR',
      help: '从环境变量读凭据参数（可重复）',
    );
}

/// 把 `--value` / `--arg` / 凭据选项组装成控制通道 body 的
/// `args` / `secrets` / `secretSource`。
Map<String, Object?> buildCtlCliArgsBody(CtlCommandContext context) {
  final Map<String, String> args = <String, String>{};
  for (final String raw in context.multiOption('arg')) {
    final int eq = raw.indexOf('=');
    if (eq <= 0) throw CtlUsageError('--arg 必须写成 key=value，收到「$raw」');
    args[raw.substring(0, eq).trim()] = raw.substring(eq + 1);
  }
  if (context.args.options.contains('value') &&
      context.args.wasParsed('value')) {
    if (args.containsKey('value')) {
      throw const CtlUsageError('--value 与 --arg value=… 只能给一个');
    }
    args['value'] = context.args['value'] as String;
  }
  final Map<String, String> secrets = <String, String>{};
  String? source;
  for (final String raw in context.multiOption('secret-from-env')) {
    final int eq = raw.indexOf('=');
    if (eq <= 0) {
      throw CtlUsageError('--secret-from-env 必须写成 KEY=VAR，收到「$raw」');
    }
    final String name = raw.substring(eq + 1).trim();
    final String? value = Platform.environment[name];
    if (value == null) throw CtlUsageError('环境变量 $name 未设置');
    secrets[raw.substring(0, eq).trim()] = value;
    source = 'env';
  }
  final String? stdinKey = context.option('secret-stdin');
  if (stdinKey != null) {
    if (source != null) {
      throw const CtlUsageError('--secret-stdin 与 --secret-from-env 只能用一种');
    }
    secrets[stdinKey] = readCtlSecretFromStdin();
    source = 'stdin';
  }
  return <String, Object?>{
    if (args.isNotEmpty) 'args': args,
    if (secrets.isNotEmpty) 'secrets': secrets,
    if (source != null) 'secretSource': source,
  };
}

void _configureConfigRun(ArgParser parser) {
  _configureYes(parser);
  _configureCliArgs(parser);
  parser.addOption('value', abbr: 'v', help: '单参数动作的值（等同 --arg value=…）');
}

void _configureConfigItems(ArgParser parser) {
  _configureYes(parser);
  _configureCliArgs(parser);
}

CtlRequestSpec _buildConfigItems(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final String verb = context.positional(1, 'ls|add|set|rm');
  final String base = '${_settingPath(key)}/items';
  switch (verb) {
    case 'ls':
      return CtlRequestSpec.get(base);
    case 'add':
      return CtlRequestSpec.post(base, body: buildCtlCliArgsBody(context));
    case 'set':
      final String id = context.positional(2, 'id');
      final Map<String, Object?> body = buildCtlCliArgsBody(context);
      if (body.isEmpty) throw const CtlUsageError('没有要改的字段（--arg k=v）');
      return CtlRequestSpec.put('$base/${Uri.encodeComponent(id)}', body: body);
    case 'rm':
      final String id = context.positional(2, 'id');
      _requireYes(context, '删除记录');
      return CtlRequestSpec.delete(
        '$base/${Uri.encodeComponent(id)}',
        query: const <String, String>{'confirm': 'true'},
      );
  }
  throw CtlUsageError('未知操作 $verb（ls / add / set / rm）');
}

String _renderConfigItems(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? items = data['items'];
  if (items is List) {
    if (items.isEmpty) return '${data['key']}：（空）';
    final List<String> columns = <String>[];
    for (final Object? item in items) {
      if (item is! Map) continue;
      for (final Object? k in item.keys) {
        if (!columns.contains('$k')) columns.add('$k');
      }
    }
    return renderCtlTable(items, <(String, String)>[
      for (final String c in columns) (c, c),
    ]);
  }
  return '${data['action'] ?? ''}：${renderCtlJson(data['item'])}';
}

CtlRequestSpec _buildConfigLs(CtlCommandContext context) {
  final String? search = context.option('search');
  final String? kind = context.option('kind');
  return CtlRequestSpec.get(
    '/api/admin/settings',
    query: <String, String>{
      if (search != null) 'search': search,
      if (context.flag('all')) 'all': 'true',
      if (kind != null) 'kind': kind,
    },
  );
}

CtlRequestSpec _buildConfigReset(CtlCommandContext context) =>
    CtlRequestSpec.post('${_settingPath(context.positional(0, 'key'))}/reset');

CtlRequestSpec _buildConfigRun(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '${_settingPath(context.positional(0, 'key'))}/run',
      body: <String, Object?>{
        ...buildCtlCliArgsBody(context),
        if (context.flag('yes')) 'confirm': true,
      },
    );

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
  final Object? defaultLabel = data['default'];
  if (defaultLabel != null) {
    out.write('\n  默认：$defaultLabel${data['modified'] == true ? '（已改过）' : ''}');
  }
  if (data['wasModified'] == false) out.write('\n  （本来就是默认值）');
  if (data['runnable'] == true && data['ran'] != true) {
    out.write('\n  可执行：config run ${data['key']}');
  }
  final Object? help = data['help'];
  if (help != null) out.write('\n  写法：$help');
  final Object? params = data['params'] ?? data['fields'];
  if (params is List && params.isNotEmpty) {
    out.write('\n  参数：');
    for (final Object? param in params) {
      if (param is! Map) continue;
      out.write(
        '\n    ${param['name']}${param['required'] == true ? '（必填）' : ''}'
        '${param['secret'] == true ? '（凭据：--secret-stdin / --secret-from-env）' : ''}'
        '：${param['help']}',
      );
    }
  }
  final Object? ops = data['listOps'];
  if (ops is List) {
    out.write('\n  列表操作：config items ${data['key']} ${ops.join(' | ')}');
  }
  final Object? hint = data['hint'];
  if (hint != null) out.write('\n  只能在界面里做：$hint');
  if (data['ran'] == true) {
    out.write('\n  已执行');
    final Object? result = data['result'];
    if (result != null) out.write('\n${renderCtlJson(result)}');
  }
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

CtlRequestSpec _buildModuleOrder(CtlCommandContext context) {
  if (context.rest.isEmpty)
    return const CtlRequestSpec.get('/api/admin/modules');
  return CtlRequestSpec.post(
    '/api/admin/modules/order',
    body: <String, Object?>{'order': context.rest},
  );
}

String _renderModuleOrder(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? order = data['order'];
  if (order is! List) return renderCtlJson(data);
  return '模块顺序：${order.join(' > ')}';
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

CtlRequestSpec _buildProfileBindings(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/profiles/bindings');

CtlRequestSpec _buildProfileBind(CtlCommandContext context) {
  final String scope = context.positional(0, 'media|language');
  final String key = context.positional(1, '类型|语言标签');
  final String profile = context.joinedRest(2, 'id|名字|none');
  final String normalized = switch (scope.toLowerCase()) {
    'media' => 'media',
    'language' || 'lang' => 'language',
    _ => throw CtlUsageError('绑定范围只能是 media / language，收到「$scope」'),
  };
  return CtlRequestSpec.put(
    '/api/admin/profiles/bindings/$normalized/${Uri.encodeComponent(key)}',
    body: <String, Object?>{'profile': profile},
  );
}

String _renderProfileBindings(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Object?> rows = <Object?>[
    ...?(data['media'] as List<Object?>?),
    ...?(data['language'] as List<Object?>?),
  ];
  return renderCtlTable(rows, const <(String, String)>[
    ('范围', 'scope'),
    ('键', 'key'),
    ('Profile id', 'profileId'),
    ('Profile', 'profile'),
  ]);
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

const List<(String, String)> _keysColumns = <(String, String)>[
  ('作用域', 'scope'),
  ('动作', 'action'),
  ('键盘', 'keyboard'),
  ('手柄', 'gamepad'),
  ('鼠标', 'mouse'),
  ('说明', 'label'),
];

String _renderKeysLs(Object? data) =>
    renderCtlTable(data, _keysColumns, listKey: 'shortcuts');

String _shortcutPath(String action) =>
    '/api/admin/shortcuts/${Uri.encodeComponent(action)}';

void _configureKeysSet(ArgParser parser) {
  parser
    ..addFlag('add', negatable: false, help: '追加到已有绑定，而不是替换该通道')
    ..addFlag('steal', negatable: false, help: '撞车时把绑定从原动作上摘掉')
    ..addFlag('keep-both', negatable: false, help: '撞车时两个动作都保留');
}

CtlRequestSpec _buildKeysSet(CtlCommandContext context) {
  final String action = context.positional(0, 'action');
  final List<String> bindings = context.rest.skip(1).toList();
  if (bindings.isEmpty) {
    throw const CtlUsageError('缺少绑定（如 Ctrl+F、MouseBack、Alt+WheelDown、pad:A）');
  }
  if (context.flag('steal') && context.flag('keep-both')) {
    throw const CtlUsageError('--steal 与 --keep-both 只能给一个');
  }
  return CtlRequestSpec.put(
    _shortcutPath(action),
    body: <String, Object?>{
      'bindings': bindings,
      'mode': context.flag('add') ? 'add' : 'replace',
      'conflict': context.flag('steal')
          ? 'steal'
          : context.flag('keep-both')
          ? 'keep'
          : 'fail',
    },
  );
}

void _configureKeysUnbind(ArgParser parser) {
  _configureYes(parser);
  parser.addFlag('all', negatable: false, help: '清空该动作的全部绑定（需 --yes）');
}

CtlRequestSpec _buildKeysUnbind(CtlCommandContext context) {
  final String action = context.positional(0, 'action');
  final List<String> bindings = context.rest.skip(1).toList();
  final bool all = context.flag('all');
  if (bindings.isEmpty && !all) {
    throw const CtlUsageError('给出要解绑的绑定，或 --all --yes 清空全部');
  }
  if (bindings.isNotEmpty && all) {
    throw const CtlUsageError('--all 与具体绑定只能给一种');
  }
  if (all) _requireYes(context, '清空全部绑定');
  return CtlRequestSpec.post(
    '${_shortcutPath(action)}/unbind',
    body: <String, Object?>{
      if (bindings.isNotEmpty) 'bindings': bindings,
      if (all) 'all': true,
      if (all) 'confirm': true,
    },
  );
}

void _configureKeysReset(ArgParser parser) {
  _configureYes(parser);
  parser
    ..addOption('scope', help: '整组恢复默认（reader / video / global …，需 --yes）')
    ..addFlag('all', negatable: false, help: '全部恢复默认（需 --yes）');
}

CtlRequestSpec _buildKeysReset(CtlCommandContext context) {
  final String? action = context.optionalPositional(0);
  final String? scope = context.option('scope');
  final bool all = context.flag('all');
  final int targets =
      (action != null ? 1 : 0) + (scope != null ? 1 : 0) + (all ? 1 : 0);
  if (targets != 1) {
    throw const CtlUsageError('<action>、--scope、--all 必须且只能给一个');
  }
  if (action == null) {
    _requireYes(context, all ? '全部快捷键恢复默认' : '整组快捷键恢复默认');
  }
  return CtlRequestSpec.post(
    '/api/admin/shortcuts/reset',
    body: <String, Object?>{
      if (action != null) 'action': action,
      if (scope != null) 'scope': scope,
      if (all) 'all': true,
      if (action == null) 'confirm': true,
    },
  );
}

String _renderKeysChange(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? single = data['shortcut'];
  final List<Object?> rows = single is Map
      ? <Object?>[single]
      : (data['shortcuts'] as List<Object?>? ?? const <Object?>[]);
  final StringBuffer out = StringBuffer();
  if (data['reset'] != null) out.writeln('已恢复默认 ${data['reset']} 个动作');
  out.write(renderCtlTable(rows, _keysColumns));
  final Object? conflicts = data['conflicts'];
  if (conflicts is List && conflicts.isNotEmpty) {
    for (final Object? c in conflicts) {
      if (c is! Map) continue;
      out.write(
        '\n${c['binding']} 原属 ${c['action']}：'
        '${c['resolution'] == 'removed' ? '已从原动作摘掉' : '两边都保留'}',
      );
    }
  }
  return out.toString();
}

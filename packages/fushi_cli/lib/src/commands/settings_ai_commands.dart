import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'ai_agent_commands.dart';
import 'settings_commands.dart' show readCtlSecretFromStdin;

/// `ai` 命令组：AI（大语言模型）提供商增删改、连接探测、功能指派。
///
/// app 侧路由见 `fushi/lib/src/ops/ctl_settings_ai_routes.dart`，
/// 读写与「设置 › 模型 › LLM」同一对偏好。API Key 只收 `--key-stdin` /
/// `--key-from-env`，不收命令行明文；应答里只回显末 4 位。
const List<CtlCommandGroup> settingsAiCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'ai',
    summary: 'AI 提供商与功能指派；AI 助手（ask / undo / log）',
    commands: <CtlCommandSpec>[
      ...aiAgentCommands,
      CtlCommandSpec(
        name: 'presets',
        summary: '列出内置提供商预设（add 用它的 id）',
        build: _buildPresets,
        render: _renderPresets,
      ),
      CtlCommandSpec(
        name: 'ls',
        summary: '列出已配置的提供商（Key 只显示末 4 位）',
        build: _buildLs,
        render: _renderLs,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '按预设添加一家提供商（自定义预设需 --base-url）',
        usage: '<preset>',
        configure: _configureAdd,
        build: _buildAdd,
        render: _renderProvider,
      ),
      CtlCommandSpec(
        name: 'set',
        summary: '修改一家提供商（只改给出的字段）',
        usage: '<id|名字>',
        configure: _configureSet,
        build: _buildSet,
        render: _renderProvider,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除一家提供商并清掉指向它的功能指派（需 --yes）',
        usage: '<id|名字>',
        configure: _configureYes,
        build: _buildRm,
      ),
      CtlCommandSpec(
        name: 'probe',
        summary: '测试连接（对所配模型发一次最小请求）；--models 拉模型列表',
        usage: '<id|名字>',
        configure: _configureProbe,
        build: _buildProbe,
        render: _renderProbe,
      ),
      CtlCommandSpec(
        name: 'features',
        summary: '列出 AI 功能与各自用哪家提供商',
        build: _buildFeatures,
        render: _renderFeatures,
      ),
      CtlCommandSpec(
        name: 'assign',
        summary: '指派某个功能用哪家（default = 跟随默认，off = 不用 AI）',
        usage: '<功能> <id|名字|default|off>',
        build: _buildAssign,
        render: _renderFeatures,
      ),
      CtlCommandSpec(
        name: 'default',
        summary: '设置默认提供商（none = 清掉默认）',
        usage: '<id|名字|none>',
        build: _buildDefault,
        render: _renderFeatures,
      ),
    ],
  ),
];

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认破坏性操作');
}

String _providerPath(String ref) =>
    '/api/admin/ai/providers/${Uri.encodeComponent(ref)}';

/// add / set 共用的字段。
void _configureFields(ArgParser parser) {
  parser
    ..addOption('name', help: '显示名')
    ..addOption('base-url', valueHelp: 'URL', help: 'API 地址')
    ..addOption('model', help: '模型名')
    ..addOption(
      'protocol',
      allowed: const <String>['openai', 'anthropic', 'gemini'],
      help: 'wire 协议',
    )
    ..addOption(
      'reasoning',
      allowed: const <String>['none', 'low', 'medium', 'high'],
      help: '推理档位（只有非 none 才会往请求里加推理字段）',
    )
    ..addOption('rpm', help: '每分钟最多请求数（0 = 不限）')
    ..addFlag(
      'allow-http',
      defaultsTo: null,
      help: '允许明文 HTTP（本地服务默认允许；--no-allow-http 关掉）',
    )
    ..addFlag('key-stdin', negatable: false, help: '从标准输入读 API Key')
    ..addOption('key-from-env', valueHelp: 'VAR', help: '从环境变量读 API Key');
}

void _configureAdd(ArgParser parser) {
  _configureFields(parser);
  parser
    ..addFlag('disabled', negatable: false, help: '添加后先停用')
    ..addFlag('default', negatable: false, help: '设为默认提供商');
}

void _configureSet(ArgParser parser) {
  _configureFields(parser);
  parser
    ..addFlag('enable', negatable: false, help: '启用')
    ..addFlag('disable', negatable: false, help: '停用')
    ..addFlag('append-key', negatable: false, help: '新 Key 追加到已有列表（缺省替换）')
    ..addFlag('clear-keys', negatable: false, help: '清空全部 Key');
}

/// 读 API Key：只收 stdin / 环境变量。
Map<String, Object?> _keyFields(CtlCommandContext context) {
  final String? envName = context.option('key-from-env');
  final bool fromStdin = context.flag('key-stdin');
  if (envName != null && fromStdin) {
    throw const CtlUsageError('--key-stdin 与 --key-from-env 只能给一个');
  }
  if (envName != null) {
    final String? value = Platform.environment[envName];
    if (value == null) throw CtlUsageError('环境变量 $envName 未设置');
    return <String, Object?>{'apiKey': value, 'apiKeySource': 'env'};
  }
  if (fromStdin) {
    return <String, Object?>{
      'apiKey': readCtlSecretFromStdin(),
      'apiKeySource': 'stdin',
    };
  }
  return const <String, Object?>{};
}

Map<String, Object?> _fieldBody(CtlCommandContext context) {
  final int? rpm = context.intOption('rpm');
  final String? name = context.option('name');
  final String? baseUrl = context.option('base-url');
  final String? model = context.option('model');
  final String? protocol = context.option('protocol');
  final String? reasoning = context.option('reasoning');
  final bool? allowHttp = context.explicitFlag('allow-http');
  return <String, Object?>{
    if (name != null) 'name': name,
    if (baseUrl != null) 'baseUrl': baseUrl,
    if (model != null) 'model': model,
    if (protocol != null) 'protocol': protocol,
    if (reasoning != null) 'reasoning': reasoning,
    if (rpm != null) 'rpm': rpm,
    if (allowHttp != null) 'allowInsecureHttp': allowHttp,
    ..._keyFields(context),
  };
}

CtlRequestSpec _buildPresets(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/ai/presets');

CtlRequestSpec _buildLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/ai/providers');

CtlRequestSpec _buildAdd(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/ai/providers',
  body: <String, Object?>{
    'preset': context.positional(0, 'preset'),
    ..._fieldBody(context),
    if (context.flag('disabled')) 'enabled': false,
    if (context.flag('default')) 'makeDefault': true,
  },
);

CtlRequestSpec _buildSet(CtlCommandContext context) {
  final String ref = context.positional(0, 'id|名字');
  if (context.flag('enable') && context.flag('disable')) {
    throw const CtlUsageError('--enable 与 --disable 只能给一个');
  }
  final Map<String, Object?> body = <String, Object?>{
    ..._fieldBody(context),
    if (context.flag('enable')) 'enabled': true,
    if (context.flag('disable')) 'enabled': false,
    if (context.flag('append-key')) 'appendKey': true,
    if (context.flag('clear-keys')) 'clearKeys': true,
  };
  if (body.isEmpty) throw const CtlUsageError('没有要改的字段');
  if (body['appendKey'] == true && body['apiKey'] == null) {
    throw const CtlUsageError('--append-key 要配合 --key-stdin 或 --key-from-env');
  }
  return CtlRequestSpec.put(_providerPath(ref), body: body);
}

CtlRequestSpec _buildRm(CtlCommandContext context) {
  final String ref = context.positional(0, 'id|名字');
  if (!context.flag('yes')) {
    throw const CtlUsageError('删除 AI 提供商是破坏性操作，确认请加 --yes');
  }
  return CtlRequestSpec.delete(
    _providerPath(ref),
    query: const <String, String>{'confirm': 'true'},
  );
}

void _configureProbe(ArgParser parser) {
  parser.addFlag('models', negatable: false, help: '拉取可用模型列表');
}

CtlRequestSpec _buildProbe(CtlCommandContext context) => CtlRequestSpec.post(
  '${_providerPath(context.positional(0, 'id|名字'))}/probe',
  body: <String, Object?>{if (context.flag('models')) 'models': true},
);

CtlRequestSpec _buildFeatures(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/ai/features');

CtlRequestSpec _buildAssign(CtlCommandContext context) => CtlRequestSpec.put(
  '/api/admin/ai/features/${Uri.encodeComponent(context.positional(0, '功能'))}',
  body: <String, Object?>{
    'provider': context.joinedRest(1, 'id|名字|default|off'),
  },
);

CtlRequestSpec _buildDefault(CtlCommandContext context) => CtlRequestSpec.put(
  '/api/admin/ai/default',
  body: <String, Object?>{'provider': context.joinedRest(0, 'id|名字|none')},
);

String _renderPresets(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('id', 'id'),
      ('名称', 'name'),
      ('协议', 'protocol'),
      ('默认模型', 'model'),
      ('地址', 'baseUrl'),
    ], listKey: 'presets');

String _renderLs(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String table = renderCtlTable(data, const <(String, String)>[
    ('id', 'id'),
    ('名称', 'name'),
    ('模型', 'model'),
    ('协议', 'protocol'),
    ('启用', 'enabled'),
    ('可用', 'usable'),
    ('默认', 'isDefault'),
    ('Key 数', 'keyCount'),
  ], listKey: 'providers');
  return data['moduleEnabled'] == false ? '$table\n（AI 模块已关闭：功能不会发请求）' : table;
}

String _renderProvider(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? provider = data['provider'];
  if (provider is! Map) return renderCtlJson(data);
  final List<String> keys = <String>[
    for (final Object? k in provider['keys'] as List<Object?>? ?? <Object?>[])
      if (k is Map) '${k['tail']}${k['enabled'] == false ? '(停用)' : ''}',
  ];
  return '${data['action']}：${provider['id']} ${provider['name']}\n'
      '  ${provider['baseUrl']} · ${provider['protocol']} · 模型 ${provider['model']}\n'
      '  启用 ${provider['enabled']} · 可用 ${provider['usable']}'
      '${provider['isDefault'] == true ? ' · 默认' : ''}'
      ' · Key ${keys.isEmpty ? '无' : keys.join(', ')}';
}

String _renderProbe(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? models = data['models'];
  if (models is List) {
    return '连接正常，可用模型 ${models.length} 个：\n${models.join('\n')}';
  }
  return '连接正常（模型 ${data['model']} 可用）';
}

String _renderFeatures(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String table = renderCtlTable(data, const <(String, String)>[
    ('功能', 'feature'),
    ('指派', 'assignment'),
    ('实际使用', 'effectiveProvider'),
    ('可用', 'usable'),
  ], listKey: 'features');
  final String head = '默认提供商：${data['defaultProvider'] ?? '（未设）'}';
  final String tail = data['moduleEnabled'] == false
      ? '\n（AI 模块已关闭：功能不会发请求）'
      : '';
  return '$head\n$table$tail';
}

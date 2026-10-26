import 'dart:convert';

import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli op ls|describe|call`：操作目录的通用命令（spec §3 第 4 点）。
///
/// 只要一条路由在 app 侧带了描述（`FushiOp`），这里就能调到，不必等手写命令。
/// 参数用 `--arg name=value`（可重复）或 `--args '<JSON 对象>'` 给；表态参数
/// （confirm / yes / trustSigner…）要么自己 `--arg confirm=true`，要么 `--yes`
/// 一次性全给。
// 与 `ops/op_routes.dart` 的 kCtlOps* 同值；写成本文件字面量，路由覆盖守卫才扫得到。
const String _opsPath = '/api/admin/ops';
const String _opsDescribePath = '/api/admin/ops/describe';
const String _opsCallPath = '/api/admin/ops/call';

const List<CtlCommandGroup> opCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'op',
    summary: '操作目录：列出 / 查看 / 调用任意带描述的操作',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出当前可用的操作；给关键词时按相关度排序',
        usage: '[关键词…]',
        build: _buildLs,
        render: _renderLs,
      ),
      CtlCommandSpec(
        name: 'describe',
        summary: '查看一条操作的参数、风险级与是否可撤销',
        usage: '<id>',
        build: _buildDescribe,
        render: _renderDescribe,
      ),
      CtlCommandSpec(
        name: 'call',
        summary: '调用一条操作：--arg k=v（可重复）/ --args <JSON>；--yes 给全部表态参数',
        usage: '<id>',
        configure: _configureCall,
        build: _buildCall,
      ),
    ],
  ),
];

CtlRequestSpec _buildLs(CtlCommandContext context) {
  final String query = context.rest.join(' ').trim();
  return CtlRequestSpec.get(
    _opsPath,
    query: query.isEmpty ? null : <String, String>{'q': query},
  );
}

String _renderLs(Object? data) => renderCtlTable(data, const <(String, String)>[
  ('ID', 'id'),
  ('风险', 'risk'),
  ('说明', 'summary'),
], listKey: 'ops');

CtlRequestSpec _buildDescribe(CtlCommandContext context) => CtlRequestSpec.get(
  '$_opsDescribePath/${Uri.encodeComponent(context.positional(0, 'id'))}',
);

String _renderDescribe(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..writeln(
      '${data['id']}  [${data['risk']}]'
      '${data['undoable'] == true ? '  可撤销' : ''}'
      '${data['confirm'] == true ? '  需确认' : ''}'
      '${data['longRunning'] == true ? '  长任务' : ''}',
    )
    ..writeln('  ${data['summary']}')
    ..writeln('  ${data['method']} ${data['path']}');
  if (data['available'] == false) {
    out.writeln(
      '  不可用：${data['unavailableCode']}'
      '${data['unavailableMessage'] == null ? '' : '（${data['unavailableMessage']}）'}',
    );
  }
  final Object? params = data['params'];
  if (params is List && params.isNotEmpty) {
    out.writeln('  参数：');
    for (final Object? p in params) {
      if (p is! Map) continue;
      final List<String> tags = <String>[
        '${p['type']}',
        if (p['required'] == true) '必填',
        if (p['userGate'] == true) '表态',
        if (p['enum'] is List) (p['enum'] as List).join('|'),
      ];
      out.writeln(
        '    ${p['name']}  (${tags.join(', ')})  ${p['description']}',
      );
    }
  }
  return out.toString().trimRight();
}

void _configureCall(ArgParser parser) {
  parser
    ..addMultiOption(
      'arg',
      help: '参数 name=value（可重复；值按操作声明的类型解析）',
      splitCommas: false,
    )
    ..addOption('args', help: '全部参数，JSON 对象')
    ..addFlag('yes', negatable: false, help: '给出该操作的全部表态参数（confirm / yes …）');
}

CtlRequestSpec _buildCall(CtlCommandContext context) {
  final String id = context.positional(0, 'id');
  final Map<String, Object?> args = <String, Object?>{};
  final String? json = context.option('args');
  if (json != null) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const CtlUsageError('--args 不是合法 JSON');
    }
    if (decoded is! Map) throw const CtlUsageError('--args 必须是 JSON 对象');
    args.addAll(Map<String, Object?>.from(decoded));
  }
  for (final String pair in context.multiOption('arg')) {
    final int eq = pair.indexOf('=');
    if (eq <= 0) throw CtlUsageError('--arg 要写成 name=value：$pair');
    args[pair.substring(0, eq).trim()] = pair.substring(eq + 1);
  }
  return CtlRequestSpec.post(
    _opsCallPath,
    body: <String, Object?>{
      'id': id,
      'args': args,
      if (context.flag('yes')) 'yes': true,
    },
  );
}

import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';
import '../ops/specs/leaderboard_ops.dart';
import 'settings_commands.dart' show readCtlSecretFromStdin;

/// `fushi_cli leaderboard …`：排行榜账户（app 侧路由见
/// `fushi/lib/src/ops/ctl_leaderboard_routes.dart`）。恢复码含账户私钥，只从标准输入或
/// 环境变量读，不收命令行明文（会留在 shell 历史与进程列表里）。
const List<CtlCommandGroup> leaderboardCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'leaderboard',
    summary: '排行榜账户：状态 / 用恢复码登录',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'status',
        summary: '本 profile 的排行榜账户：是否登录、昵称、公开范围、是否同意上传',
        op: LeaderboardOps.status,
        call: _callStatus,
        render: _renderStatus,
      ),
      CtlCommandSpec(
        name: 'recovery-import',
        summary: '用恢复码在本机登录（恢复码从标准输入读，或 --from-env 变量名）',
        configure: _configureRecovery,
        op: LeaderboardOps.recoveryImport,
        call: _callRecovery,
        render: _renderStatus,
      ),
    ],
  ),
];

CtlOpCall _callStatus(CtlCommandContext c) => const CtlOpCall();

void _configureRecovery(ArgParser parser) {
  parser
    ..addOption('from-env', valueHelp: 'VAR', help: '从这个环境变量读恢复码（不给 = 读标准输入一行）')
    ..addFlag('consent', negatable: false, help: '同意公开上传书架（与账户页的勾选同义）');
}

CtlOpCall _callRecovery(CtlCommandContext c) {
  final String? env = c.option('from-env');
  final String code;
  if (env != null) {
    final String? value = Platform.environment[env];
    if (value == null) throw CtlUsageError('环境变量 $env 未设置');
    code = value;
  } else {
    code = readCtlSecretFromStdin();
  }
  if (code.trim().isEmpty) throw const CtlUsageError('恢复码为空');
  return CtlOpCall(
    args: <String, Object?>{
      LeaderboardOps.recoveryCode.name: code.trim(),
      if (c.flag('consent')) LeaderboardOps.recoveryConsent.name: true,
    },
  );
}

String _renderStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['status'] != 'active') return '本 profile 没有登录排行榜账户';
  return <String>[
    '已登录${data['nickname'] == null ? '' : '：${data['nickname']}'}',
    if (data['visibility'] != null) '公开范围：${data['visibility']}',
    '上传书架：${data['uploadConsent'] == true ? '已同意' : '未同意'}',
  ].join('\n');
}

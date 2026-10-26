import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/settings/settings_cli_tasks.dart';

/// 设置类后台任务（[SettingsCliTaskRegistry]：更新下载 / 安装、Plex 账号授权、
/// Hoshi 备份导入…）的查询、等待与取消。CLI 侧：`fushi_cli task ls|get|cancel`
/// （`packages/fushi_cli/lib/src/commands/settings_task_commands.dart`）。
List<CtlRoute> buildSettingsTaskCtlRoutes({SettingsCliTaskRegistry? registry}) {
  SettingsCliTaskRegistry tasks() =>
      registry ?? SettingsCliTaskRegistry.instance;
  return <CtlRoute>[
    CtlRoute.get(
      '/api/admin/tasks',
      (CtlCall call) async =>
          listSettingsTasks(tasks(), call.optString('kind')),
    ),
    CtlRoute.get(
      '/api/admin/tasks/:id',
      (CtlCall call) => getSettingsTask(
        tasks(),
        call.params['id']!,
        waitSeconds: call.optInt('wait'),
      ),
    ),
    CtlRoute.post(
      '/api/admin/tasks/:id/cancel',
      (CtlCall call) async => cancelSettingsTask(tasks(), call.params['id']!),
    ),
  ];
}

/// 等待上限：CLI 要更久就循环调。
const int kSettingsTaskMaxWaitSeconds = 600;

Map<String, Object?> listSettingsTasks(
  SettingsCliTaskRegistry registry,
  String? kind,
) => <String, Object?>{
  'tasks': <Map<String, Object?>>[
    for (final SettingsCliTask task in registry.tasks.reversed)
      // kind 也认前缀族：`update` 同时列出 update-download / update-install。
      if (kind == null || task.kind == kind || task.kind.startsWith('$kind-'))
        task.toJson(),
  ],
};

SettingsCliTask _requireTask(SettingsCliTaskRegistry registry, String id) {
  final SettingsCliTask? task = registry.byId(id);
  if (task == null) {
    throw CtlFailure.notFound('没有任务「$id」（task ls 列出最近的任务）');
  }
  return task;
}

/// 读任务快照；[waitSeconds] > 0 时最多等这么久直到任务结束（结束即返回）。
Future<Map<String, Object?>> getSettingsTask(
  SettingsCliTaskRegistry registry,
  String id, {
  int? waitSeconds,
}) async {
  final SettingsCliTask task = _requireTask(registry, id);
  final int wait = waitSeconds ?? 0;
  if (wait < 0 || wait > kSettingsTaskMaxWaitSeconds) {
    throw CtlFailure.badRequest('wait 取 0…$kSettingsTaskMaxWaitSeconds 秒');
  }
  bool finished = task.isTerminal;
  if (wait > 0 && !finished) {
    finished = await registry.wait(task, Duration(seconds: wait));
  }
  return <String, Object?>{...task.toJson(), 'finished': finished};
}

Map<String, Object?> cancelSettingsTask(
  SettingsCliTaskRegistry registry,
  String id,
) {
  final SettingsCliTask task = _requireTask(registry, id);
  final SettingsCliCancelOutcome outcome = registry.cancel(task);
  if (outcome == SettingsCliCancelOutcome.refused) {
    throw CtlFailure.conflict(
      task.committing ? '任务已进入提交阶段（写库 / 安装），不能取消' : '这个任务不支持取消',
    );
  }
  return <String, Object?>{'outcome': outcome.name, ...task.toJson()};
}

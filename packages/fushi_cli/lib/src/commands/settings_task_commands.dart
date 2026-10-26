import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `task` / `update` 命令组。
///
/// - `task`：设置类后台任务（更新下载 / 安装、Plex 账号授权、Hoshi 备份导入…）的
///   查询、等待与取消；app 侧路由见
///   `fushi/lib/src/ops/ctl_settings_task_routes.dart`。
/// - `update`：应用自更新三步（检查 / 后台下载 / 确认安装），与设置页「立即检查
///   更新」→「发现新版本」对话框同一条链路（`fushi/lib/src/updates/app_update_cli.dart`）。
const List<CtlCommandGroup> settingsTaskCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'task',
    summary: '设置类后台任务（更新下载、Plex 授权、备份导入…）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出最近的任务（新的在前）',
        configure: _configureTaskLs,
        build: _buildTaskLs,
        render: renderCtlTaskList,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '查看一个任务；--wait <秒> 等它结束（最多 600 秒）',
        usage: '<id>',
        configure: _configureTaskGet,
        build: _buildTaskGet,
        render: renderCtlTask,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消一个任务（已进入写库 / 安装阶段的不能取消）',
        usage: '<id>',
        build: _buildTaskCancel,
        render: renderCtlTask,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'update',
    summary: '应用自更新：检查 / 下载 / 安装',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'check',
        summary: '检查新版本（返回版本与更新说明；不弹对话框）',
        build: _buildUpdateCheck,
        render: _renderUpdateCheck,
      ),
      CtlCommandSpec(
        name: 'download',
        summary: '后台下载新版本（app 里同时显示下载浮层）；返回任务号',
        build: _buildUpdateDownload,
        render: _renderActionTask,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '最近的下载 / 安装任务',
        build: _buildUpdateStatus,
        render: renderCtlTaskList,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消进行中的下载（同下载浮层「取消」）',
        build: _buildUpdateCancel,
        render: _renderActionResult,
      ),
      CtlCommandSpec(
        name: 'install',
        summary: '安装已下载好的包（需 --yes；桌面上 app 会退出并在装好后重启）',
        configure: _configureYes,
        build: _buildUpdateInstall,
        render: _renderActionTask,
      ),
    ],
  ),
];

const String _tasksPath = '/api/admin/tasks';

String _taskPath(String id) => '$_tasksPath/${Uri.encodeComponent(id)}';

/// 动作行的执行入口（同 `config run`）。
String _runPath(String key) =>
    '/api/admin/settings/${Uri.encodeComponent(key)}/run';

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认操作');
}

void _configureTaskLs(ArgParser parser) {
  parser.addOption(
    'kind',
    help:
        '只看某种任务（update-download / update-install / plex-sign-in / external-reader-import…）',
  );
}

void _configureTaskGet(ArgParser parser) {
  parser.addOption('wait', valueHelp: '秒', help: '等任务结束，最多这么多秒（0…600）');
}

CtlRequestSpec _buildTaskLs(CtlCommandContext context) {
  final String? kind = context.option('kind');
  return CtlRequestSpec.get(
    _tasksPath,
    query: <String, String>{if (kind != null) 'kind': kind},
  );
}

CtlRequestSpec _buildTaskGet(CtlCommandContext context) {
  final int? wait = context.intOption('wait');
  if (wait != null && (wait < 0 || wait > 600)) {
    throw const CtlUsageError('--wait 取 0…600 秒');
  }
  return CtlRequestSpec.get(
    _taskPath(context.positional(0, 'id')),
    query: <String, String>{if (wait != null) 'wait': '$wait'},
  );
}

CtlRequestSpec _buildTaskCancel(CtlCommandContext context) =>
    CtlRequestSpec.post('${_taskPath(context.positional(0, 'id'))}/cancel');

CtlRequestSpec _buildUpdateCheck(CtlCommandContext context) =>
    CtlRequestSpec.post(_runPath('system.check_update_now'));

CtlRequestSpec _buildUpdateDownload(CtlCommandContext context) =>
    CtlRequestSpec.post(_runPath('system.update.download'));

CtlRequestSpec _buildUpdateStatus(CtlCommandContext context) =>
    CtlRequestSpec.get(
      _tasksPath,
      query: const <String, String>{'kind': 'update'},
    );

CtlRequestSpec _buildUpdateCancel(CtlCommandContext context) =>
    CtlRequestSpec.post(_runPath('system.update.cancel'));

CtlRequestSpec _buildUpdateInstall(CtlCommandContext context) {
  if (!context.flag('yes')) {
    throw const CtlUsageError('安装会让 app 退出并重启，需要 --yes 确认');
  }
  return CtlRequestSpec.post(
    _runPath('system.update.install'),
    body: const <String, Object?>{'confirm': true},
  );
}

/// 一个任务快照的人读形式（其它命令组起任务后也用它渲染）。
String renderCtlTask(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..write('${data['id']}  ${data['kind']}  ${data['status']}');
  final Object? phase = data['phase'];
  if (phase != null) out.write('  $phase');
  final Object? progress = data['progress'];
  if (progress != null) out.write('  $progress%');
  if (data['outcome'] != null) out.write('\n  取消：${data['outcome']}');
  final Object? detail = data['detail'];
  if (detail is Map) {
    detail.forEach((Object? k, Object? v) => out.write('\n  $k：$v'));
  }
  final Object? error = data['error'];
  if (error != null) out.write('\n  失败：$error');
  final Object? result = data['result'];
  if (result != null) out.write('\n${renderCtlJson(result)}');
  if (data['status'] == 'running') {
    out.write(
      '\n  等结果：fushi_cli task get ${data['id']} --wait 60'
      '${data['cancellable'] == true ? '；取消：fushi_cli task cancel ${data['id']}' : ''}',
    );
  }
  return out.toString();
}

String renderCtlTaskList(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('ID', 'id'),
    ('种类', 'kind'),
    ('状态', 'status'),
    ('阶段', 'phase'),
    ('进度%', 'progress'),
    ('错误', 'error'),
  ],
  listKey: 'tasks',
  empty: '（没有任务）',
);

/// `config run` 应答里的 result（动作执行体的返回值）。
Object? _actionResult(Object? data) => data is Map ? data['result'] : data;

String _renderActionTask(Object? data) => renderCtlTask(_actionResult(data));

String _renderActionResult(Object? data) {
  final Object? result = _actionResult(data);
  if (result is Map && result['task'] is Map) {
    return '取消：${result['outcome']}\n${renderCtlTask(result['task'])}';
  }
  return renderCtlJson(result);
}

String _renderUpdateCheck(Object? data) {
  final Object? result = _actionResult(data);
  if (result is! Map) return renderCtlJson(result);
  final StringBuffer out = StringBuffer()
    ..write('当前 ${result['currentVersion']}（${result['channel']} 通道）');
  if (result['updateAvailable'] != true) {
    out.write('：已是最新');
    return out.toString();
  }
  out.write('\n新版本：${result['version']}');
  if (result['installable'] == true) {
    out.write('\n可应用内安装：fushi_cli update download → update install --yes');
  } else if (result['downloadPage'] != null) {
    out.write('\n本平台不能应用内安装，下载页：${result['downloadPage']}');
  }
  final Object? notes = result['releaseNotes'];
  if (notes is String && notes.trim().isNotEmpty) {
    out.write('\n\n${notes.trim()}');
  }
  return out.toString();
}

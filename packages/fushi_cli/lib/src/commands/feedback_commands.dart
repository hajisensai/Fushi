import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli feedback …`：应用内反馈（app 侧路由见 `fushi/lib/src/ops/ctl_feedback_routes.dart`）。
///
/// - `submit <标题>`：与反馈中心「提交」同一个方法，把一条反馈发给开发者。发出去撤不回，
///   必须加 `--yes`；日志默认值跟类别走（只有 bug 默认附带，与提交页
///   `feedbackDefaultIncludeLogs` 一致），`--logs` / `--no-logs` 显式改；设备信息默认附带，
///   `--no-device-info` 关掉。回执落进 app 的「我的反馈」，进度在反馈中心看。
const List<CtlCommandGroup> feedbackCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'feedback',
    summary: '应用内反馈（提交给开发者）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'submit',
        summary: '提交一条反馈（与反馈中心「提交」同一路径；发出后不可撤回）',
        usage: '<标题>',
        configure: _configureSubmit,
        build: _buildSubmit,
        render: renderFeedbackSubmitted,
      ),
    ],
  ),
];

const String _root = '/api/admin/feedback';

const List<String> _categories = <String>['bug', 'suggestion', 'other'];

void _configureSubmit(ArgParser parser) {
  parser
    ..addOption(
      'category',
      abbr: 'c',
      allowed: _categories,
      defaultsTo: 'bug',
      help: '类别',
    )
    ..addOption('body', abbr: 'b', help: '详情')
    ..addFlag(
      'logs',
      defaultsTo: null,
      help: '附带错误 / 调试日志（不指定时：bug 附带，suggestion / other 不附带）',
    )
    ..addFlag('device-info', defaultsTo: true, help: '附带版本 / 平台 / 系统信息')
    ..addFlag(
      'link-account',
      defaultsTo: true,
      help: '已登录 Fushi 账户时以账户身份提交（开发者能看到昵称）',
    )
    ..addFlag('yes', abbr: 'y', negatable: false, help: '确认发送（发出后不可撤回）');
}

CtlRequestSpec _buildSubmit(CtlCommandContext c) {
  final String title = c.positional(0, '标题').trim();
  if (title.isEmpty) throw CtlUsageError('标题不能为空');
  if (!c.flag('yes')) {
    throw CtlUsageError('反馈发给开发者后不可撤回，确认请加 --yes');
  }
  final String? body = c.option('body')?.trim();
  final String category = c.option('category') ?? 'bug';
  return CtlRequestSpec.post(
    _root,
    body: <String, Object?>{
      'category': category,
      'title': title,
      if (body != null && body.isNotEmpty) 'body': body,
      'includeLogs': c.explicitFlag('logs') ?? _defaultIncludeLogs(category),
      'includeDeviceInfo': c.flag('device-info'),
      'linkAccount': c.flag('link-account'),
      'confirm': true,
    },
  );
}

/// 没指定 `--logs` / `--no-logs` 时附不附日志：只有 bug 附带（反馈 SDN2yTecu9 /
/// LmIRnau_Fa，与提交页 `feedbackDefaultIncludeLogs` 同一口径）。
bool _defaultIncludeLogs(String category) => category == 'bug';

String renderFeedbackSubmitted(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..writeln('已提交反馈 #${data['id']}：${data['title']}')
    ..writeln(
      '附带：${data['logsAttached'] == true ? '日志' : '无日志'}，'
      '${data['deviceInfoAttached'] == true ? '设备信息' : '无设备信息'}',
    );
  final Object? failed = data['failedAttachments'];
  if (failed is int && failed > 0) {
    out.writeln('$failed 个附件没传上去，可在 app 的反馈中心详情页重试上传');
  }
  out.write('进度与开发者回复在 app 的反馈中心查看');
  return out.toString();
}

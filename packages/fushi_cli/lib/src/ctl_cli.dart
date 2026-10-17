/// `fushi_cli` 命令行：驱动本机正在运行的 Fushi 桌面 app。
///
/// ```
/// fushi_cli status            # app 是否在运行、是否初始化完成（不拉起 app）
/// fushi_cli start             # 确保 app 在运行并就绪
/// fushi_cli open <路径|URL>   # 打开视频 / fushi:// 深链 / 卡片来源 URL
/// fushi_cli lookup <词>       # 弹出查词
/// fushi_cli quit              # 落库后退出 app
/// ```
///
/// 全局选项：`--json`、`--app <路径>`、`--timeout <秒>`、`--no-launch`。
/// app 没在运行时，除 `status` / `quit` 外的命令都会自动拉起 app 并等它就绪。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'ctl_client.dart';
import 'ctl_command_registry.dart';
import 'ctl_commands.dart';
import 'ctl_endpoint.dart';
import 'ctl_launcher.dart';
import 'ctl_paths.dart';
import 'ctl_protocol.dart';

/// 退出码：沿用 `fushi_server ctl` 的 sysexits 约定，两个 CLI 在脚本里同一套判断。
const int kCliExitOk = 0;

/// app 拒绝了请求（不支持的目标 / 文件不存在 / 模块关闭）或其它 4xx/5xx。
const int kCliExitFailed = 1;

/// 用法错误（EX_USAGE）。
const int kCliExitUsage = 64;

/// app 没在运行 / 找不到或起不来 app（EX_UNAVAILABLE）。`status` 未运行时也是它，
/// 便于脚本 `if fushi_cli status; then …`。
const int kCliExitUnavailable = 69;

/// 拉起后等不到就绪 / app 还在初始化（EX_TEMPFAIL，稍后重试）。
const int kCliExitTempFail = 75;

/// 控制通道鉴权失败（EX_NOPERM）。
const int kCliExitNoPerm = 77;

/// 解析不出控制通道目录（EX_CONFIG）。
const int kCliExitConfig = 78;

const Duration _defaultTimeout = Duration(seconds: 90);

ArgParser _buildParser(List<CtlCommandGroup> groups) {
  final ArgParser parser = ArgParser()
    ..addFlag('json', negatable: false, help: '输出 JSON（便于脚本解析）')
    ..addOption(
      'app',
      help: 'Fushi app 可执行文件路径（缺省查 FUSHI_APP / CLI 同级目录 / 默认安装位置）',
    )
    ..addOption(
      'timeout',
      help: '等待 app 就绪的秒数',
      defaultsTo: '${_defaultTimeout.inSeconds}',
    )
    ..addFlag('launch', defaultsTo: true, help: 'app 没在运行时自动拉起（--no-launch 关闭）')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');
  parser.addCommand('status');
  parser.addCommand('start');
  parser.addCommand('open');
  parser.addCommand('lookup');
  parser.addCommand('quit');
  for (final CtlCommandGroup group in groups) {
    final ArgParser groupParser = parser.addCommand(group.name)
      ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');
    for (final CtlCommandSpec spec in group.commands) {
      final ArgParser commandParser = groupParser.addCommand(spec.name)
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');
      spec.configure?.call(commandParser);
    }
  }
  return parser;
}

void _groupUsage(CtlCommandGroup group, StringSink sink) {
  sink
    ..writeln(
      'fushi_cli ${group.name} <command> [options]  —— ${group.summary}',
    )
    ..writeln()
    ..writeln('commands:');
  for (final CtlCommandSpec spec in group.commands) {
    final String head = '${spec.name} ${spec.usage}'.trim();
    sink.writeln('  ${head.padRight(28)} ${spec.summary}');
  }
}

void _commandUsage(
  CtlCommandGroup group,
  CtlCommandSpec spec,
  ArgParser parser,
  StringSink sink,
) {
  sink
    ..writeln('fushi_cli ${group.name} ${spec.name} ${spec.usage}'.trimRight())
    ..writeln('  ${spec.summary}')
    ..writeln()
    ..writeln(parser.usage);
}

void _usage(ArgParser parser, List<CtlCommandGroup> groups, StringSink sink) {
  sink
    ..writeln('fushi_cli <command> [options]')
    ..writeln()
    ..writeln('commands:')
    ..writeln(
      '  status              app 是否在运行（不拉起 app；未运行退出码 $kCliExitUnavailable）',
    )
    ..writeln('  start               确保 app 在运行并就绪')
    ..writeln('  open <路径|URL>     打开视频文件 / fushi:// 深链 / 卡片来源 URL')
    ..writeln('  lookup <词>         弹出查词')
    ..writeln('  quit                落库后退出 app');
  if (groups.isNotEmpty) {
    sink
      ..writeln()
      ..writeln('domains（fushi_cli <domain> --help 看子命令）:');
    for (final CtlCommandGroup group in groups) {
      sink.writeln('  ${group.name.padRight(18)} ${group.summary}');
    }
  }
  sink
    ..writeln()
    ..writeln(parser.usage);
}

/// CLI 入口。所有外部依赖都可注入，便于测试。
Future<int> runFushiCli(
  List<String> args, {
  Map<String, String>? environment,
  String? operatingSystem,
  String? cliExecutable,
  StringSink? out,
  StringSink? err,
  CtlProcessStarter starter = startDetachedProcess,
  Duration pollInterval = const Duration(milliseconds: 250),
  List<CtlCommandGroup> groups = kCtlCommandGroups,
}) async {
  final StringSink stdoutSink = out ?? stdout;
  final StringSink stderrSink = err ?? stderr;
  final ArgParser parser = _buildParser(groups);
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderrSink.writeln(e.message);
    _usage(parser, groups, stderrSink);
    return kCliExitUsage;
  }
  final ArgResults? command = results.command;
  if (results['help'] as bool || command == null) {
    _usage(parser, groups, results['help'] as bool ? stdoutSink : stderrSink);
    return results['help'] as bool ? kCliExitOk : kCliExitUsage;
  }
  final int? timeoutSeconds = int.tryParse(results['timeout'] as String);
  if (timeoutSeconds == null || timeoutSeconds <= 0) {
    stderrSink.writeln('--timeout 必须是正整数秒');
    return kCliExitUsage;
  }

  final Map<String, String> env = environment ?? Platform.environment;
  final String os = operatingSystem ?? Platform.operatingSystem;
  final _Cli cli = _Cli(
    json: results['json'] as bool,
    out: stdoutSink,
    err: stderrSink,
    environment: env,
    operatingSystem: os,
    cliExecutable: cliExecutable ?? Platform.resolvedExecutable,
    explicitApp: results['app'] as String?,
    allowLaunch: results['launch'] as bool,
    timeout: Duration(seconds: timeoutSeconds),
    starter: starter,
    pollInterval: pollInterval,
    stateDir: resolveCtlStateDir(environment: env, operatingSystem: os),
    groups: groups,
    parser: parser,
  );
  try {
    return await cli.run(command);
  } finally {
    cli.close();
  }
}

class _CliFailure implements Exception {
  const _CliFailure(this.exitCode, this.message);
  final int exitCode;
  final String message;
}

class _Cli {
  _Cli({
    required this.json,
    required this.out,
    required this.err,
    required this.environment,
    required this.operatingSystem,
    required this.cliExecutable,
    required this.explicitApp,
    required this.allowLaunch,
    required this.timeout,
    required this.starter,
    required this.pollInterval,
    required this.stateDir,
    required this.groups,
    required this.parser,
  });

  final List<CtlCommandGroup> groups;
  final ArgParser parser;

  final bool json;
  final StringSink out;
  final StringSink err;
  final Map<String, String> environment;
  final String operatingSystem;
  final String cliExecutable;
  final String? explicitApp;
  final bool allowLaunch;
  final Duration timeout;
  final CtlProcessStarter starter;
  final Duration pollInterval;
  final String? stateDir;

  CtlClient? _client;

  void close() => _client?.close();

  Future<int> run(ArgResults command) async {
    try {
      switch (command.name) {
        case 'status':
          return await _status();
        case 'start':
          final CtlAppStatus status = await _ensureReady();
          _emit(
            status.toJson(),
            '就绪：Fushi ${status.version ?? ''}（pid ${status.pid}）',
          );
          return kCliExitOk;
        case 'open':
          return await _open(command.rest);
        case 'lookup':
          return await _lookup(command.rest);
        case 'quit':
          return await _quit();
      }
      for (final CtlCommandGroup group in groups) {
        if (group.name == command.name) return await _runGroup(group, command);
      }
      throw _CliFailure(kCliExitUsage, '未知命令：${command.name}');
    } on _CliFailure catch (failure) {
      _fail(failure.message, failure.exitCode);
      return failure.exitCode;
    } on CtlException catch (error) {
      final int code = switch (error.code) {
        kCtlErrorUnauthorized => kCliExitNoPerm,
        kCtlErrorNotReady || 'conflict' => kCliExitTempFail,
        kCtlErrorUnreachable => kCliExitUnavailable,
        _ => kCliExitFailed,
      };
      _fail(_describe(error), code);
      return code;
    }
  }

  Future<int> _runGroup(CtlCommandGroup group, ArgResults groupArgs) async {
    final ArgResults? sub = groupArgs.command;
    if (sub == null) {
      _groupUsage(group, groupArgs['help'] as bool ? out : err);
      return groupArgs['help'] as bool ? kCliExitOk : kCliExitUsage;
    }
    final CtlCommandSpec spec = group.find(sub.name!)!;
    final ArgParser commandParser =
        parser.commands[group.name]!.commands[spec.name]!;
    if (sub['help'] as bool) {
      _commandUsage(group, spec, commandParser, out);
      return kCliExitOk;
    }
    final CtlRequestSpec request;
    try {
      request = spec.build(CtlCommandContext(sub));
    } on CtlUsageError catch (error) {
      err.writeln(error.message);
      _commandUsage(group, spec, commandParser, err);
      return kCliExitUsage;
    }
    await _ensureReady();
    final Object? data = await _client!.call(
      request.method,
      request.path,
      query: request.query,
      body: request.body,
    );
    if (json) {
      out.writeln(jsonEncode(data));
    } else {
      out.writeln((spec.render ?? renderCtlJson)(data));
    }
    if (data is Map && data['ok'] == false) return kCliExitFailed;
    return kCliExitOk;
  }

  Future<int> _status() async {
    final CtlAppStatus? status = await _probe();
    if (status == null) {
      _emit(const <String, Object?>{'running': false}, 'Fushi 没有在运行');
      return kCliExitUnavailable;
    }
    _emit(<String, Object?>{
      'running': true,
      ...status.toJson(),
    }, 'Fushi 正在运行（pid ${status.pid}，${status.initialised ? '已就绪' : '初始化中'}）');
    return kCliExitOk;
  }

  Future<int> _open(List<String> rest) async {
    if (rest.length != 1)
      throw const _CliFailure(kCliExitUsage, '用法：fushi_cli open <路径|URL>');
    final String target = ctlAbsolutePath(rest.single);
    await _ensureReady();
    final CtlOpenKind? kind = await _client!.open(target);
    _emit(<String, Object?>{
      'ok': true,
      'target': target,
      'kind': kind?.wireName,
    }, '已交给 Fushi 打开：$target');
    return kCliExitOk;
  }

  Future<int> _lookup(List<String> rest) async {
    final String word = rest.join(' ').trim();
    if (word.isEmpty)
      throw const _CliFailure(kCliExitUsage, '用法：fushi_cli lookup <词>');
    await _ensureReady();
    await _client!.lookup(word);
    _emit(<String, Object?>{'ok': true, 'word': word}, '已弹出查词：$word');
    return kCliExitOk;
  }

  Future<int> _quit() async {
    final CtlAppStatus? status = await _probe();
    if (status == null) {
      _emit(const <String, Object?>{
        'ok': true,
        'running': false,
      }, 'Fushi 没有在运行');
      return kCliExitOk;
    }
    await _client!.quit();
    _emit(<String, Object?>{'ok': true, 'pid': status.pid}, '已请求 Fushi 退出');
    return kCliExitOk;
  }

  String _requireStateDir() {
    final String? dir = stateDir;
    if (dir == null) {
      throw const _CliFailure(
        kCliExitConfig,
        '无法确定控制通道目录（缺 HOME / LOCALAPPDATA），可用 $kCtlDirEnv 指定',
      );
    }
    return dir;
  }

  /// 连上正在运行的 app 并取状态；没在运行（无发现文件 / 端口没人听 / token 不对）返回 null。
  Future<CtlAppStatus?> _probe() async {
    final CtlEndpoint? endpoint = await readCtlEndpoint(_requireStateDir());
    if (endpoint == null) return null;
    final CtlClient client = _replaceClient(endpoint);
    try {
      return await client.status();
    } on CtlException catch (error) {
      // 残留的发现文件：端口已没人听，或被别的进程复用。本 app 对带对 token、不带
      // Origin 的 status 只会回 200；任何 4xx（token 对不上、别的服务的 404/403、
      // 同机 fushi_server 管理接口的鉴权失败……）都说明对面不是这次的 app。
      // 5xx 仍上抛：那更像是本 app 自己出错，不该再拉起第二个实例掩盖它。
      if (error.isUnreachable || error.code == 'protocol') return null;
      final int? status = error.statusCode;
      if (status != null && status >= 400 && status < 500) return null;
      rethrow;
    }
  }

  CtlClient _replaceClient(CtlEndpoint endpoint) {
    final CtlClient? current = _client;
    if (current != null &&
        current.endpoint.port == endpoint.port &&
        current.endpoint.token == endpoint.token) {
      return current;
    }
    current?.close();
    return _client = CtlClient(endpoint);
  }

  /// 确保 app 在运行且初始化完成；没在运行就拉起。
  Future<CtlAppStatus> _ensureReady() async {
    final DateTime deadline = DateTime.now().add(timeout);
    CtlAppStatus? status = await _probe();
    if (status == null) {
      if (!allowLaunch) {
        throw const _CliFailure(
          kCliExitUnavailable,
          'Fushi 没有在运行（已指定 --no-launch）',
        );
      }
      final String? app = await locateFushiApp(
        environment: environment,
        operatingSystem: operatingSystem,
        cliExecutable: cliExecutable,
        explicitPath: explicitApp,
      );
      if (app == null) {
        throw const _CliFailure(
          kCliExitUnavailable,
          '找不到 Fushi app，请用 --app <路径> 或环境变量 $kFushiAppEnv 指定',
        );
      }
      if (!json) err.writeln('正在启动 Fushi：$app');
      try {
        await launchFushiApp(
          app,
          operatingSystem: operatingSystem,
          starter: starter,
        );
      } on ProcessException catch (error) {
        throw _CliFailure(kCliExitUnavailable, '启动 Fushi 失败：${error.message}');
      }
    }
    while (status == null || !status.initialised) {
      if (DateTime.now().isAfter(deadline)) {
        throw _CliFailure(
          kCliExitTempFail,
          status == null
              ? '等待 Fushi 控制通道超时（${timeout.inSeconds}s）。若 app 已打开，可能是不带控制通道的旧版本'
              : '等待 Fushi 初始化完成超时（${timeout.inSeconds}s）',
        );
      }
      await Future<void>.delayed(pollInterval);
      status = await _probe();
    }
    return status;
  }

  void _emit(Map<String, Object?> payload, String human) {
    out.writeln(json ? jsonEncode(payload) : human);
  }

  void _fail(String message, int exitCode) {
    if (json) {
      out.writeln(
        jsonEncode(<String, Object?>{
          'ok': false,
          'exitCode': exitCode,
          'error': message,
        }),
      );
    } else {
      err.writeln(message);
    }
  }

  static String _describe(CtlException error) => switch (error.code) {
    'not_found' ||
    'bad_request' ||
    'conflict' ||
    'unsupported' => error.message ?? error.code,
    kCtlErrorRejected => 'Fushi 拒绝：${error.message ?? '不支持的目标'}',
    kCtlErrorUnauthorized => '控制通道鉴权失败（token 不匹配）',
    kCtlErrorUnreachable => 'Fushi 已断开连接',
    _ => '请求失败：$error',
  };
}

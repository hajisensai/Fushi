/// 顶层子命令模块的契约：`cli.dart` 只做分发，各功能域的命令各住一个文件。
///
/// 新增一组命令 = 新建一个 [CliModule] 实现并加进 `kCliModules`（cli_modules.dart），
/// 不要再往 `cli.dart` 里堆 switch 分支。
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_server/src/server_runtime.dart';

/// 一次命令调用的上下文。
class CliContext {
  const CliContext({required this.configFile, required this.verbose, this.commandLabel});

  final File configFile;
  final bool verbose;

  /// 命令链摘要（`audiobook align`），写进数据目录锁文件给被拒的进程看。
  final String? commandLabel;

  /// 离线命令的标准前置（打开配置 / 数据库 / 宿主装配；数据目录被占 → 75），见 [withServerRuntime]。
  Future<int> withRuntime(Future<int> Function(ServerRuntime rt) body) =>
      withServerRuntime(configFile, verbose, body, command: commandLabel);
}

/// 一组顶层子命令。
abstract class CliModule {
  const CliModule();

  /// 本模块拥有的顶层命令名（如 `import`、`subs`）。
  List<String> get commands;

  /// 给每个顶层命令登记参数表（`parser.addCommand(name, …)`）。
  void register(ArgParser parser);

  /// 用法说明（并入 `fushi_server --help`）。
  String get usage;

  /// 执行 [name] 命令。返回进程退出码。
  Future<int> run(String name, ArgResults command, CliContext ctx);
}

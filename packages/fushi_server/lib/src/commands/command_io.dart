/// 离线命令模块共用的输出与退出码约定（缺口盘点第 7 节）。
///
/// - 退出码：0 成功、1 业务失败、64 用法错误、66 找不到输入 / 配置、69 依赖不可用
///   （缺原生库 / 模型 / 凭据）、75 冲突（数据目录被 serve 或另一条离线命令占着，
///   与 `ctl` 的 409 → 75 同义）。
/// - `--json` 的 stdout 隔离在 CLI 入口整体做（json_stdout_isolation.dart）：后台
///   isolate 的 `print`、原生库的 `printf` 一律改道 stderr，命令只管把结果写 stdout。
/// - `--json`：机器可读结果整段打到 stdout；进度与诊断一律走 stderr，不混进 JSON。
///
/// 输出流可注入（测试捕获 stdout 而不必起子进程）；缺省就是进程的 stdout / stderr。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

const int kExitOk = 0;
const int kExitFailure = 1;
const int kExitUsage = 64;
const int kExitNoInput = 66;
const int kExitUnavailable = 69;
const int kExitConflict = 75;

/// 一个命令模块的输出端。
class CommandIo {
  const CommandIo({StringSink? out, StringSink? err}) : _out = out, _err = err;

  final StringSink? _out;
  final StringSink? _err;

  StringSink get out => _out ?? stdout;
  StringSink get err => _err ?? stderr;

  /// `--json` 结果（缩进两格，便于人眼复查；脚本照样能 `jq`）。
  void json(Object? value) => out.writeln(const JsonEncoder.withIndent('  ').convert(value));

  /// 用法错误：消息 + 用法行打到 stderr，返回 64。
  int usage(String message, String usageLine) {
    err.writeln(message);
    err.writeln('用法: $usageLine');
    return kExitUsage;
  }
}

/// 子命令（`import epub` 里的 `epub`）的叶子参数表上都挂同一个 `--json`。
ArgParser addJsonFlag(ArgParser parser) => parser..addFlag('json', negatable: false, help: '输出机器可读 JSON（stdout）');

/// 叶子命令有没有要 `--json`。
bool wantsJson(ArgResults leaf) => leaf.options.contains('json') && leaf['json'] as bool;

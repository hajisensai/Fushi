/// `subs` / `video` 两个命令模块共用的小工具：退出码、输出通道、`--json` 渲染、
/// 时间参数解析。
///
/// 退出码与缺口盘点第 7 节的约定一致：0 成功、1 业务失败、64 用法错误、
/// 66 找不到输入 / 缺配置、69 依赖不可用（缺凭据 / 原生程序 / 网络服务）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

/// 成功。
const int kExitOk = 0;

/// 业务失败（查无结果、对齐被拒、ffmpeg 跑失败……）。
const int kExitFailure = 1;

/// 用法错误（EX_USAGE）。
const int kExitUsage = 64;

/// 找不到输入文件 / 缺配置（EX_NOINPUT）。
const int kExitNoInput = 66;

/// 依赖不可用：缺凭据、缺 ffmpeg、外部服务不可达（EX_UNAVAILABLE）。
const int kExitUnavailable = 69;

/// 一次命令的输出通道。生产走 stdout / stderr，测试注入 [StringBuffer]。
class CliIo {
  CliIo({StringSink? out, StringSink? err, this.json = false}) : out = out ?? stdout, err = err ?? stderr;

  /// 结果（人读文本或 `--json` 的 JSON）。
  final StringSink out;

  /// 进度与诊断。
  final StringSink err;

  /// 是否以 JSON 输出结果。
  final bool json;

  /// 换一个 json 开关的同通道副本。
  CliIo withJson(bool value) => CliIo(out: out, err: err, json: value);

  /// 打印一份 JSON 结果（缩进两格，便于人读也便于 `jq`）。
  void writeJson(Object? value) => out.writeln(const JsonEncoder.withIndent('  ').convert(value));

  /// 统一的错误出口：`--json` 时同时在 stdout 给一个 `{"ok":false,...}`，脚本不用
  /// 解析 stderr 也能拿到原因；返回 [code] 便于 `return io.fail(...)`。
  int fail(int code, String message, {Map<String, Object?> extra = const <String, Object?>{}}) {
    err.writeln(message);
    if (json) {
      writeJson(<String, Object?>{'ok': false, 'exitCode': code, 'error': message, ...extra});
    }
    return code;
  }
}

/// 给子命令参数表加上公共的 `--json`。
ArgParser addJsonFlag(ArgParser parser) => parser..addFlag('json', negatable: false, help: '机器可读的 JSON 输出');

/// 读子命令上的 `--json`（未登记时按 false）。
bool jsonFlag(ArgResults results) => results.options.contains('json') && results['json'] as bool;

/// 解析时间参数：`90` / `90.5`（秒）、`1:30`、`01:02:03.250`、`1500ms`。返回毫秒；
/// 解不出返回 null。
int? parseClockArgToMs(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return null;
  if (value.endsWith('ms')) {
    final int? ms = int.tryParse(value.substring(0, value.length - 2).trim());
    return ms == null || ms < 0 ? null : ms;
  }
  final List<String> parts = value.split(':');
  if (parts.length > 3) return null;
  double total = 0;
  for (int i = 0; i < parts.length; i++) {
    final String part = parts[i];
    // 只有最后一段允许小数；中间段必须是非负整数且 < 60（首段不限）。
    final double? number = i == parts.length - 1 ? double.tryParse(part) : int.tryParse(part)?.toDouble();
    if (number == null || number < 0 || number.isNaN || number.isInfinite) return null;
    if (i > 0 && number >= 60) return null;
    total = total * 60 + number;
  }
  return (total * 1000).round();
}

/// 毫秒 → `HH:MM:SS.mmm`（人读输出用）。
String formatClockMs(int ms) {
  final Duration d = Duration(milliseconds: ms);
  final String hh = d.inHours.toString().padLeft(2, '0');
  final String mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final String mmm = d.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  return '$hh:$mm:$ss.$mmm';
}

/// 测试辅助进程：在 `--json` 的 stdout 隔离下，模拟引擎各路「往 fd 1 打字」的来源
/// （后台 isolate 的 `print`、根 isolate 的 `print`），最后经 `stdout` 写一个 JSON。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_server/src/json_stdout_isolation.dart';

Future<void> main() async {
  exitCode = await runWithJsonStdoutIsolation(() async {
    // ignore: avoid_print
    await Isolate.run(() => print('noise from background isolate'));
    // ignore: avoid_print
    print('noise from root isolate print');
    stderr.writeln('diagnostic on stderr');
    stdout.writeln(jsonEncode(<String, Object?>{'ok': true}));
    return 0;
  });
}

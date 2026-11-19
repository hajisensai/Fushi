@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/reader/reader_seamless_chapters_script.dart';
import 'package:test/test.dart';

/// BUG-4836：连续模式章节无缝衔接启动失败后，这一章里翻不到下一章。
///
/// 根因：`S.start` 在 `_starting = true` 之后的章节 / 样式表请求 reject（或解析抛异常）
/// 时不复位，`claimBoundaryTurn` 的「正在启动 → 这一侧归本模块」从此恒真，三条边界换章
/// 通道全部让路。这里把生产安装脚本放进真 Chrome（真 DOMParser / shadow DOM / 样式改写，
/// 只有 `fetch` 与引擎是替身），断言：章节请求 reject 后不再认领边界、错误上报控制台、
/// 没有未处理的 rejection；单张样式表请求 reject 只丢这一张，启动与邻章挂载照常完成。
void main() {
  test(
    'seamless start failure releases the boundary; one failed stylesheet only '
    'drops that sheet',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final ({int exitCode, String stdout, String stderr}) result =
          await _runNodeHarness(
            nodeExe,
            'test/reader/seamless_start_failure_harness.mjs',
            <String, String>{'seamless': kSeamlessChaptersInstallJs},
          );
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS seamless start failure'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// Runs a Node harness with [payload] piped as JSON on stdin (no file path
/// crosses the process boundary) and returns its exit code, stdout and stderr.
Future<({int exitCode, String stdout, String stderr})> _runNodeHarness(
  String nodeExe,
  String harness,
  Map<String, String> payload,
) async {
  final Process process = await Process.start(nodeExe, <String>[harness]);
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(jsonEncode(payload)));
  await process.stdin.close();
  return (
    exitCode: await process.exitCode,
    stdout: await stdout,
    stderr: await stderr,
  );
}

/// Resolve Node before launching the browser harness so missing CI tools skip.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}

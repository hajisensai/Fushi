import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用户 10-23：查词弹窗词头的元数据列（频率 / 音调 / 词形标签）换到词头下方时铺满整行，
/// 不再被按钮组那一截宽度挤成一枚 chip 一行。判据在 popup.js 的
/// `updateEntryHeaderMetaLayout`，本 wrapper 驱动 node 真执行它——用例与分层说明写在
/// 同名 `.js` 里。无 node 时 skip。
void main() {
  test(
    'header meta column stacks full-width only when it no longer fits beside '
    'the headword (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/dictionary/popup_header_meta_stacked_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(nodeExe, <String>[
        jsTest.path,
      ], workingDirectory: Directory.current.path);

      expect(
        result.exitCode,
        0,
        reason:
            'popup header meta layout behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

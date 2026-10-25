import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用户 10-24「查词偶发一直闪」的同类排查：M3E 暗色下词典浅底的调色不能因为滚动指示类 /
/// nudge 等无关写入而先复原、下一帧才重调，露出一帧词典原色。判据在 popup.js 的
/// `__fushiM3eToneSignature` / `__fushiRetoneDictColors`，本 wrapper 驱动 node 真执行
/// 它们——用例与分层说明写在同名 `.js` 里。无 node 时 skip。
void main() {
  test('dark dictionary retone ignores transient writes and never exposes the '
      'original colours for a frame (executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      'test/dictionary/popup_dark_retone_no_flash_test.js',
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
          'popup dark retone behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });
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

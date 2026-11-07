import 'dart:io';

import 'package:test/test.dart';

/// BUG-4227（反馈 ArXVzMKmM5）：popup.js 制卡 payload 必须带逐词典频率，Yomitan 的
/// `{single-frequency-number-<词典>}` / `{single-frequency-<词典>}` 才有数据可渲染。
/// node 真执行 popup.js 抽出的取数函数（见同名 .js）。Dart 渲染侧见
/// `packages/fushi_anki/test/handlebar_single_frequency_test.dart`。无 node 时 skip。
void main() {
  test('popup.js ships per-dictionary frequencies in the mining payload '
      '(executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/anki/single_frequency_mining_test.js');
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
          'single frequency mining behavior test failed.\n'
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

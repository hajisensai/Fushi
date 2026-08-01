import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1342：macOS/Precision Touchpad 会把一次物理滑动拆成持续一秒以上的
/// wheel 惯性流。
/// 本守卫通过 Node 真执行 reader 注入的分页 wheel 聚合器，确保一段惯性 burst 只产生
/// 一次语义翻页；静默结束后的下一次手势才允许再次翻页。
void main() {
  test('paged wheel gesture emits one page turn per momentum burst via node',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest =
        File('test/reader/reader_paged_wheel_gesture_behavior_test.js');
    expect(jsTest.existsSync(), isTrue);
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'paged wheel JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      if (Process.runSync(name, <String>['--version']).exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词「按句意挑词条」：AI 回来时宿主只换词条顺序，弹窗必须走 popup.js 的
/// `fushiReorderPopupEntries` 只挪卡片，而不是全量 renderPopup——后者会滚回顶、清
/// 已选释义、把句子上下文镜像归 0，而宿主的制卡草稿没清，于是界面 0/0、卡片却带着
/// 旧前后句（BUG-297 型错位）。判据与分层说明写在同名 `.js` 里。无 node 时 skip。
void main() {
  test(
    'order-only popup update moves cards without re-render / scroll / selection '
    '/ sentence-mirror reset (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File('test/dictionary/popup_entry_reorder_test.js');
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
            'popup entry reorder behavior test failed.\n'
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

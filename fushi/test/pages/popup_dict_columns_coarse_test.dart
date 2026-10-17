import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3139：触屏（coarse 指针）上词典弹窗的有效列数。手机横屏的视频查词弹窗约
/// 620 逻辑 px 宽，用户「最多三列」时必须排出两列；竖屏手机弹窗（~380 px）仍是
/// 单列。旧门槛是每列 2×170=340 px，横屏手机永远只有一列。
///
/// 用 Node 真执行 popup.js 的 `effectiveDictColumns()`（见同名 .js），无 node 时 skip。
void main() {
  test(
    'coarse landscape popup lays out two columns (executes popup.js)',
    () async {
      final String? node = _resolveNode();
      if (node == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final ProcessResult result = await Process.run(node, <String>[
        'test/pages/popup_dict_columns_coarse_test.js',
      ], workingDirectory: Directory.current.path);
      expect(
        result.exitCode,
        0,
        reason:
            'popup columns JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

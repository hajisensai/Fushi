import 'dart:io';

import 'package:test/test.dart';

/// BUG-4499：查词弹窗里点开的放大图跨查词残留（Node 真执行 popup.js，见同名 .js）。
///
/// 灯箱挂在词条容器之外，换词重渲染 / 新查词会话复位都必须把它关掉。无 node 时 skip
/// （与 popup_pending_scroll_restore_test.dart 同款约定）。
void main() {
  test(
    'popup image lightbox closes across lookups (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File(
        'test/pages/popup_image_lightbox_session_test.js',
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
            'popup image-lightbox JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // try next candidate
    }
  }
  return null;
}

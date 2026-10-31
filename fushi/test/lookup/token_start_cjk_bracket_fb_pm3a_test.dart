import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// 反馈 pm3A75D5xZ：『テンパリング〖tempering〗』点 t，高亮从『〖』开始。词首回退必须
/// 停在日文字符与 Unicode 开/闭括号、引号上。node 真执行浮窗 / 扩展的 selection.js 与
/// 阅读器注入脚本（`ReaderSelectionScripts.source()` 落临时文件）。无 node 时 skip。
void main() {
  test('token-start back-off stops at CJK brackets / Japanese chars '
      '(executes both selection engines via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest = File(
      'test/lookup/token_start_cjk_bracket_fb_pm3a_test.js',
    );
    expect(jsTest.existsSync(), isTrue);
    final Directory tmp = Directory.systemTemp.createTempSync('fushi_pm3a_');
    final File readerJs = File('${tmp.path}/reader_selection.js');
    readerJs.writeAsStringSync(ReaderSelectionScripts.source());
    try {
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
        environment: <String, String>{
          'FUSHI_READER_SELECTION_JS': readerJs.path,
        },
      );
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      final String stdout = result.stdout.toString();
      expect(stdout, contains('all assertions passed'));
      expect(
        stdout,
        isNot(contains('reader selection script not provided')),
        reason: '阅读器注入脚本必须被 harness 真执行（真值来自 source()）',
      );
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
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
      // try next
    }
  }
  return null;
}

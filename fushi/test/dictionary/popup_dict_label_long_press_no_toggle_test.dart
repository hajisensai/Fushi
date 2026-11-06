import 'dart:io';

import 'package:test/test.dart';

/// ZdghRxjVCm：查词弹窗里长按词典标题（选它作制卡词典）松开后，分组同时被折叠/展开。
///
/// 根因：`<details>` 的开合是 `<summary>` 上 click 的 activation behavior；鼠标长按
/// 触发选词典后松开照样派发 click，`popup.js` 只在触屏 touchend 上掐了合成 click，
/// 鼠标路径没有任何一步认领这次 click。修复：长按计时器触发时记下「本次按下已被长按
/// 消费」，click 上据此 preventDefault 并复位；键盘 / 手柄长按入口不置位。
///
/// 本 wrapper 只负责驱动 node 真执行 popup.js 里的 `createGlossarySection` 并拿它
/// 实际挂上去的监听派发事件——判据写在同名 `.js` 里。无 node 时 skip。
void main() {
  test('dict <summary> long-press does not also toggle the group on release '
      '(executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      'test/dictionary/popup_dict_label_long_press_no_toggle_test.js',
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
          'popup dict-label long-press/click behavior test failed.\n'
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

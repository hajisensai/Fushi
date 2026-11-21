import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

import '../helpers/node_runtime.dart';

/// 墨水屏「每 N 页全刷」（拍板台 oF0jVdOTIE）：连续滚动模式下点击区 / 音量键 / 键盘 /
/// 手柄 / 翻页按钮的一步翻页必须计一页。
///
/// 回归：连续 shell 的 `paginate` 同步推进滚动快照，随后的 scroll 事件看不到位移，
/// Dart 连续分支又不计——按键翻页一次都不计。这里在 `flutter test` 内用 Node 真执行
/// 连续 shell 对象（假 window / document），断言每步恰好回传一次 `onEinkScrollPage`、
/// 拖动仍按满一屏计、到尽头不计。没有 node 的环境自动 skip。
void main() {
  test('continuous paginate reports one e-ink page per step', () async {
    final String? nodeExe = resolveNodeExecutable();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest = File(
      'test/reader/eink_continuous_page_turn_behavior_test.js',
    );
    expect(jsTest.existsSync(), isTrue);
    final Map<String, String> payload = <String, String>{
      'continuous': ReaderPaginationScripts.continuousShellSource(),
    };
    final NodeHarnessResult result = await runNodeHarness(
      nodeExe,
      jsTest.path,
      payload,
    );
    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });
}

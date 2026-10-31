// BUG-3887：查词弹窗里拖选词头文字后 Ctrl+C 复制不了。松手补发的 click 被词头点击
// 处理器当成「点词头」原地重查，DOM 重建、选区丢失。行为断言在 node 真跑 popup.js 的
// test/utils/misc/popup_asset_behavior_test.js（testHeadwordClickEndingDragSelectionKeepsSelection）；
// 本文件把整份 harness 接进 flutter test，CI 上缺 node 直接失败而不是零执行。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/node_runtime.dart';

void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe();

  test(
    'popup.js behavior harness passes, incl. headword drag-selection keeps the selection',
    () async {
      final String node = runtime.requireNode();
      final ProcessResult result = await Process.run(node, <String>[
        'test/utils/misc/popup_asset_behavior_test.js',
      ], workingDirectory: Directory.current.path);
      expect(
        result.exitCode,
        0,
        reason:
            'popup_asset_behavior_test.js failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('headword drag-selection tests passed'),
        reason: 'the BUG-3887 case must actually execute',
      );
    },
    skip: runtime.skipReason,
  );
}

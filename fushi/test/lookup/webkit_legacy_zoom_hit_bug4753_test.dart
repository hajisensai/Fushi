import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/node_runtime.dart';

/// BUG-4753（反馈 lfbYCEfnt7）：macOS 查词页点释义里的「昼」查到「間」、点「訪」查到「問」。
///
/// 旧 WebKit 的 `Range.getClientRects` 按节点有效 CSS zoom 缩过（弹窗把界面大小 × 词典字号
/// 写成 `documentElement.style.zoom`），事件坐标却是客户区坐标；`selection.js` 拿客户区的点
/// 直接比字框，命中的是邻字或落空。修复：命中前把点换进字框坐标系（引擎类型探测一次）。
///
/// 行为级：node 在 fake DOM 里真执行 `assets/popup/selection.js`，分别按旧 WebKit 与标准
/// 引擎的规则产出字框，断言点每个字的左 / 中 / 右都命中它本身。沙箱 iframe 取字的半字偏移
/// 由 `test/pages/popup_dict_sandbox_test.dart` 的场景 11 在真 Chrome 里覆盖。
void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe();

  test('selection.js hit-tests characters in the rect coordinate space under '
      'legacy WebKit CSS zoom (executes selection.js via node)', () async {
    final String node = runtime.requireNode();
    final ProcessResult result = await Process.run(node, <String>[
      'test/lookup/webkit_legacy_zoom_hit_bug4753_test.js',
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  }, skip: runtime.skipReason);

  test(
    'the browser-extension copies stay byte-identical to the popup asset',
    () {
      for (final String asset in <String>['selection.js', 'popup.js']) {
        final List<int> popup = File('assets/popup/$asset').readAsBytesSync();
        for (final String copy in <String>[
          'assets/browser_extension/vendor/$asset',
          '../tools/browser-extension/vendor/$asset',
        ]) {
          expect(File(copy).readAsBytesSync(), popup, reason: '$copy drifted');
        }
      }
    },
  );
}

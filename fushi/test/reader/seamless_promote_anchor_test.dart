@Tags(<String>['chrome'])
library;

import 'package:fushi/src/reader/reader_seamless_chapters_script.dart';
import 'package:test/test.dart';

import '../helpers/node_runtime.dart';

/// 反馈 cdWxWwe-iz：连续模式无缝衔接在章节交界慢拖，一下跳过整章。
///
/// 根因：晋升时视口锚点落在被晋升的宿主本身（视口中心在章首标题上方的空白里），宿主被
/// 移除后不补偿，卸掉的上上章高度整段丢失，视口被钳到刚晋升那章的章末。这里把生产安装
/// 脚本放进真 Chrome（真 shadow DOM / 布局 / 滚动，fetch 与引擎是替身），断言这种中心
/// 位置下晋升前后视口纹丝不动。
void main() {
  test('seamless promotion keeps the viewport still when the centre sits in '
      'blank space above the next chapter title', () async {
    final String? nodeExe = resolveNodeExecutable();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS execution');
      return;
    }
    final NodeHarnessResult result = await runNodeHarness(
      nodeExe,
      'test/reader/seamless_promote_anchor_harness.mjs',
      <String, String>{'seamless': kSeamlessChaptersInstallJs},
    );
    if (result.exitCode == 77) {
      markTestSkipped('Chrome unavailable: ${result.stdout}');
      return;
    }
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS seamless promote anchor'));
  }, timeout: const Timeout(Duration(seconds: 90)));
}

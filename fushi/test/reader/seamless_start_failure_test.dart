@Tags(<String>['chrome'])
library;

import 'package:fushi/src/reader/reader_seamless_chapters_script.dart';
import 'package:test/test.dart';

import '../helpers/node_runtime.dart';

/// BUG-4836：连续模式章节无缝衔接启动失败后，这一章里翻不到下一章。
///
/// 根因：`S.start` 在 `_starting = true` 之后的章节 / 样式表请求 reject（或解析抛异常）
/// 时不复位，`claimBoundaryTurn` 的「正在启动 → 这一侧归本模块」从此恒真，三条边界换章
/// 通道全部让路。这里把生产安装脚本放进真 Chrome（真 DOMParser / shadow DOM / 样式改写，
/// 只有 `fetch` 与引擎是替身），断言：章节请求 reject 后不再认领边界、错误上报控制台、
/// 没有未处理的 rejection；单张样式表请求 reject 只丢这一张，启动与邻章挂载照常完成。
void main() {
  test(
    'seamless start failure releases the boundary; one failed stylesheet only '
    'drops that sheet',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final NodeHarnessResult result = await runNodeHarness(
        nodeExe,
        'test/reader/seamless_start_failure_harness.mjs',
        <String, String>{'seamless': kSeamlessChaptersInstallJs},
      );
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS seamless start failure'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

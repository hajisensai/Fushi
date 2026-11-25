@Tags(<String>['chrome'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

import '../helpers/node_runtime.dart';

/// BUG-5015：分页 progress 落点只由章节排版决定，与调用前停在哪一页、度量缓存
/// （`paginationMetrics`）刚被作废与否都无关。真 Chrome 跑生产分页 shell，横排 / 竖排单条 /
/// 竖排对开（生产 `verticalSpreadCss`）× 三种字号，每个 progress 从章首 / 中段 / 章末三个起点
/// 作废度量后各落两次，再走 `restoreProgress` 与作废度量后的 `reapplyImageLateAnchor`，
/// 所有落点必须相同且在页网格上。
///
/// 没有 node / Chrome 时 skip；Chrome 不支持 column-wrap（< 145）时 harness 只跳过对开一例。
void main() {
  test(
    'paged progress landing does not depend on the start page or the '
    'metrics cache, in real Chrome',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Map<String, String> payload = <String, String>{
        'engine': ReaderPaginationScripts.engineShell(
          vnMode: false,
          continuousMode: false,
        ),
        'continuousEngine': ReaderPaginationScripts.engineShell(
          vnMode: false,
          continuousMode: true,
        ),
        'spreadCss': ReaderContentStyles.verticalSpreadCss(
          marginLeftCss: '20px',
          marginRightCss: '28px',
          gapPx: 40,
        ),
      };
      final NodeHarnessResult result = await runNodeHarness(
        nodeExe,
        'test/reader/paged_progress_landing_invariant_harness.mjs',
        payload,
        timeout: const Duration(seconds: 80),
      );
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS paged progress landing invariant'));
    },
    // 起真 Chrome 的套件在机器忙时会互相饿死；外层 90s，内层进程 80s。
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

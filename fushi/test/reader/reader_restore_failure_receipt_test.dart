import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

import '../helpers/node_runtime.dart';

/// gap-readerjs1-2：阅读器引擎初始化 / 初次恢复链没有失败出口。
///
/// 旧实现里 `Promise.all(imagePromises).then(...)` 没有 catch：建偏移表、有声书 cue
/// 应用、恢复函数任一同步抛出，链就成了无人处理的 rejected promise，onRestoreComplete
/// 永远不来，Dart 只能等 8 秒内容就绪兜底才摘遮罩；initialize 自身抛出被 boot 包住
/// （BUG-1017）后同样不通知。修复后：cue 应用单独隔离照常恢复；其余失败发带代际的
/// `onRestoreFailed`，Dart 立刻走与兜底同一条收尾。
///
/// JS 行为在 Node 里真执行三种 shell 的生产文本（断言见 `.js` 文件头 A～E）；Dart 侧
/// 接线用掩码后的源码守住。撤掉修复，Node 断言失败、本守卫转红。没有 node 时 JS 部分 skip。
void main() {
  test(
    'init / initial-restore failures send a failure receipt (Node)',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final NodeHarnessResult result = await runNodeHarness(
        nodeExe,
        'test/reader/reader_restore_failure_receipt_behavior_test.js',
        <String, String>{
          'paged': ReaderPaginationScripts.paginatedShellSource(),
          'continuous': ReaderPaginationScripts.continuousShellSource(),
          'vn': ReaderVisualNovelScripts.vnShellScript(),
        },
      );
      expect(
        result.exitCode,
        0,
        reason:
            'restore failure receipt JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout, contains('all assertions passed'));
    },
  );

  group('Dart side of onRestoreFailed', () {
    late String src;
    setUpAll(() {
      src = maskCommentsAndScriptLines(readReaderPageSource());
    });

    test('handler is registered and routed through the generation check', () {
      expect(src, contains("handlerName: 'onRestoreFailed'"));
      final String accept = methodBody(src, 'void _acceptRestoreFailed(');
      expect(
        containsCodeLine(accept, 'isCurrentReaderRestoreCompletion('),
        isTrue,
        reason: '晚到的旧文档失败回执不能中止当前导航',
      );
      expect(containsCodeLine(accept, '_clearContentReadyTimeout();'), isTrue);
      expect(containsCodeLine(accept, '_abortStalledRestore();'), isTrue);
    });

    test('failure receipt and 8 s fallback share one abort path', () {
      final String abort = methodBody(src, 'void _abortStalledRestore(');
      expect(containsCodeLine(abort, '_failNavigation();'), isTrue);
      expect(containsCodeLine(abort, '_readerContentReady = true;'), isTrue);
      final String timeout = methodBody(src, 'void _startContentReadyTimeout(');
      expect(containsCodeLine(timeout, '_abortStalledRestore();'), isTrue);
    });
  });
}

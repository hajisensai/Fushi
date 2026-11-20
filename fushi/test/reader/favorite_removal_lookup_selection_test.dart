@Tags(<String>['chrome'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/highlight_bridge.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/node_runtime.dart';
import '../helpers/source_guard.dart';

/// BUG-3328：删除收藏 / 标注高亮后查词选区丢失。
///
/// 无 CSS Custom Highlight 的引擎（iOS / macOS Safari 17.2 之前）上，高亮桥拆收藏的
/// `<span>` 后对父节点 `normalize()`，把查词选区「文本节点 + 偏移」指向的节点并掉。
/// 真 Chrome 里跑生产脚本，分页 / 连续 / VN 三种 shell × 两种高亮引擎各走一遍。
void main() {
  test(
    'deleting a favourite keeps the lookup selection in all three view modes',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      // 跑手自己的期限（75s）短于用例超时：挂住时杀掉 node / Chrome，失败里带着已有输出。
      final NodeHarnessResult run = await runNodeHarness(
        nodeExe,
        'test/reader/favorite_removal_lookup_selection_harness.mjs',
        <String, String>{
          'paginated': ReaderPaginationScripts.paginatedShellSource(),
          'continuous': ReaderPaginationScripts.continuousShellSource(),
          'vn': ReaderVisualNovelScripts.vnShellScript(),
          'selection': ReaderSelectionScripts.source(),
          // 与生产 engineShell 同序：study units 之后注入句子音频标点归属模块。
          'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
          'bridge': HighlightBridge.debugScriptSource,
        },
        timeout: const Duration(seconds: 75),
      );
      if (run.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${run.stdout}');
        return;
      }
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(run.stdout, contains('PASS 6 favourite removal scenarios'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'reader DOM surgery merges / cuts text only through __fushiLiveRanges',
    () {
      final Map<String, String> sources = <String, String>{
        'selection': ReaderSelectionScripts.source(),
        'bridge': HighlightBridge.debugScriptSource,
        'paginated': ReaderPaginationScripts.paginatedShellSource(),
        'continuous': ReaderPaginationScripts.continuousShellSource(),
        'vn': ReaderVisualNovelScripts.vnShellScript(),
      };
      for (final MapEntry<String, String> entry in sources.entries) {
        // 剥 // 与 /* */（等长掩码，串里的 // 不误伤），只留代码。
        final String code = maskJsComments(entry.value);
        final int normalizeCalls = '.normalize()'.allMatches(code).length;
        // 只有 __fushiLiveRanges.normalize 自己调 node.normalize()（定义在选区脚本）。
        expect(
          normalizeCalls,
          entry.key == 'selection' ? 1 : 0,
          reason:
              '${entry.key}: merge text nodes via '
              '__fushiLiveRanges.normalize, not a bare .normalize()',
        );
        expect(
          code,
          isNot(contains('surroundContents(')),
          reason: '${entry.key}: wrap via __fushiLiveRanges.wrapText',
        );
        expect(
          code,
          isNot(contains('extractContents(')),
          reason: '${entry.key}: wrap via __fushiLiveRanges.wrapText',
        );
      }
      expect(
        maskJsComments(ReaderSelectionScripts.source()),
        contains('node.normalize();'),
      );
    },
  );
}

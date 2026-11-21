@Tags(<String>['chrome'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_sentence_audio_relocation_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/node_runtime.dart';

/// VN 模式有声书句子定位按 cue 原文重定位（拍板台 `design-nmv-reader-vn-cue-projects`）。
///
/// 测量组 m1（PR #3830 gap-readerjs2-8）量出：提示坐标偏 3 个字时分页 / 连续模式 0 错，
/// VN 每句都错——VN 直接拿下发的 start / length 当权威坐标，没有像另两种模式那样用原文
/// 在章节文本里就近重定位。现在 VN 在拿到 cue 数据时经共用的
/// `window.fushiSentenceAudioRelocation.resolveSpans` 在整章源文本里解析一次，切屏归属、
/// 当前句高亮、中键反查都读解析结果。这里在真 Chrome 里跑生产 VN shell：提示偏 0 / ±3 / +30
/// 时每句都切到正确的屏、高亮恰为该句、反查回到该句。
void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe(needsChrome: true);

  test(
    'VN relocates sentence audio cues by text, like paginated / continuous',
    () async {
      final String node = runtime.requireNode();
      final Map<String, String> payload = <String, String>{
        'shell': ReaderVisualNovelScripts.vnShellScript(),
        'selection': ReaderSelectionScripts.source(),
        'units':
            '$kStudyUnitJs\n$kSentenceAudioOwnershipJs\n'
            '$kSentenceAudioRelocationJs',
      };
      final NodeHarnessResult result = await runNodeHarness(
        node,
        'test/reader/vn_sentence_audio_cue_relocation_harness.mjs',
        payload,
        timeout: const Duration(seconds: 80),
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS 48 VN cue relocations'));
    },
    skip: runtime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

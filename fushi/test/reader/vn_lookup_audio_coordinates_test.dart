@Tags(<String>['chrome'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_sentence_audio_relocation_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/node_runtime.dart';

void main() {
  test(
    'VN lookup and audio follow use chapter coordinates in real Chrome DOM',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Map<String, String> payload = <String, String>{
        'shell': ReaderVisualNovelScripts.vnShellScript(),
        'selection': ReaderSelectionScripts.source(),
        // 与生产 engineShell 同序：study units 之后注入句子音频标点归属
        // 模块（collectMatchableCueRanges 依赖它）。
        'units':
            '$kStudyUnitJs\n$kSentenceAudioOwnershipJs\n$kSentenceAudioRelocationJs',
      };
      final NodeHarnessResult result = await runNodeHarness(
        nodeExe,
        'test/reader/vn_lookup_audio_coordinates_harness.mjs',
        payload,
      );
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS 5 VN lookup/audio targets'));
      expect(result.stdout, contains('PASS 1 VN cross-screen merge'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

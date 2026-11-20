@Tags(<String>['chrome'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/node_runtime.dart';

/// BUG-3630：视觉小说模式把一句话切到两屏时（量尺装不下、按字切，ruby 是原子单元），
/// 查词 / 制卡的句子必须仍是源章节里的整句，而不是当前屏那半句。真 Chrome 跑完整 VN
/// 工厂 + 选区脚本，断言点按查词、原生选区、上一句三条路径。
void main() {
  test(
    'VN lookup takes the whole sentence when a screen split cuts it',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Map<String, String> payload = <String, String>{
        'shell': ReaderVisualNovelScripts.vnShellScript(),
        'selection': ReaderSelectionScripts.source(),
        'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
      };
      final NodeHarnessResult result = await runNodeHarness(
        nodeExe,
        'test/reader/vn_sentence_across_screen_split_bug3630_harness.mjs',
        payload,
      );
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS VN sentence across screen split'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

@Tags(<String>['chrome'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_sentence_audio_relocation_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

import '../helpers/node_runtime.dart';

/// 查词卡顿的三处加速（音频坐标前缀表、cue 反查索引、逐字命中兜底的行盒剪枝）必须与
/// 各自保留的旧实现逐位一致：在真 Chrome DOM 上对分页 / 连续两个 shell 逐节点逐偏移比对。
/// VN shell 有自己的 `fushiReader.getMatchableOffset`（克隆屏的章内映射），不经这几条路径。
void main() {
  test(
    'lookup offset caches match the original walks in real Chrome DOM',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Map<String, Object> payload = <String, Object>{
        'shells': <String>[
          ReaderPaginationScripts.paginatedShellSource(),
          ReaderPaginationScripts.continuousShellSource(),
        ],
        'selection': ReaderSelectionScripts.source(),
        'units':
            '$kStudyUnitJs\n$kSentenceAudioOwnershipJs\n$kSentenceAudioRelocationJs',
      };
      // 内层进程超时（75s）小于外层测试超时（90s），挂住时报出进程输出而不是被外层硬杀。
      final NodeHarnessResult run = await runNodeHarness(
        nodeExe,
        'test/reader/lookup_offset_index_harness.mjs',
        payload,
        timeout: const Duration(seconds: 75),
      );
      final int exitCode = run.exitCode;
      final String out = run.stdout;
      final String err = run.stderr;
      if (exitCode == 77) {
        markTestSkipped('Chrome unavailable: $out');
        return;
      }
      expect(exitCode, 0, reason: '$out\n$err');
      expect(out, contains('PASS $_expectedCases browser cases'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// 每个 shell 的 check 条数 × 2 个 shell。
const int _expectedCases = 2 * 26;

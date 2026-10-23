@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// 查词卡顿的三处加速（音频坐标前缀表、cue 反查索引、逐字命中兜底的行盒剪枝）必须与
/// 各自保留的旧实现逐位一致：在真 Chrome DOM 上对分页 / 连续两个 shell 逐节点逐偏移比对。
/// VN shell 有自己的 `fushiReader.getMatchableOffset`（克隆屏的章内映射），不经这几条路径。
void main() {
  test(
    'lookup offset caches match the original walks in real Chrome DOM',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Directory temp = Directory.systemTemp.createTempSync(
        'reader-lookup-index-',
      );
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object>{
              'shells': <String>[
                ReaderPaginationScripts.paginatedShellSource(),
                ReaderPaginationScripts.continuousShellSource(),
              ],
              'selection': ReaderSelectionScripts.source(),
              'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
            }),
          );
        // 内层进程超时（75s）小于外层测试超时（90s），挂住时报出进程输出而不是被外层硬杀。
        final Process process = await Process.start(nodeExe, <String>[
          'test/reader/lookup_offset_index_harness.mjs',
          payload.path,
        ]);
        final Future<String> stdoutText = process.stdout
            .transform(utf8.decoder)
            .join();
        final Future<String> stderrText = process.stderr
            .transform(utf8.decoder)
            .join();
        final int exitCode = await process.exitCode.timeout(
          const Duration(seconds: 75),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        final String out = await stdoutText;
        final String err = await stderrText;
        if (exitCode == 77) {
          markTestSkipped('Chrome unavailable: $out');
          return;
        }
        expect(exitCode, 0, reason: '$out\n$err');
        expect(out, contains('PASS $_expectedCases browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// 每个 shell 的 check 条数 × 2 个 shell。
const int _expectedCases = 2 * 26;

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}

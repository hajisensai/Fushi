@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// chj2rZn89F：点 ruby 词的后半个基字时，查词起点与高亮范围必须一致——查词从 ruby 基字段
/// 开头起，高亮只在完整覆盖 ruby 全部基字时整元素加类，部分覆盖按字符范围画。
/// 在真 Chrome DOM 上对分页 / 连续两个 shell 跑生产脚本。
void main() {
  test(
    'chj2rZn89F: ruby tail tap looks up and highlights the same range',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Directory temp = Directory.systemTemp.createTempSync(
        'reader-ruby-tail-tap-',
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
          'test/reader/ruby_tail_tap_selection_harness.mjs',
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
const int _expectedCases = 2 * 10;

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

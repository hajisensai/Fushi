@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

void main() {
  test(
    'lookup retains rendered cue identity in real Chrome DOM',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Directory temp = Directory.systemTemp.createTempSync('reader-cue-');
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object>{
              'shells': <String>[
                ReaderPaginationScripts.paginatedShellSource(),
                ReaderPaginationScripts.continuousShellSource(),
              ],
              'selection': ReaderSelectionScripts.source(),
              // 与生产 engineShell 同序：study units 之后注入句子音频标点归属
              // 模块（collectSentenceAudioCueRanges 依赖它）。
              'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
            }),
          );
        final ProcessResult result = await Process.run(nodeExe, <String>[
          'test/reader/reader_audio_cue_identity_harness.mjs',
          payload.path,
        ]);
        if (result.exitCode == 77) {
          markTestSkipped('Chrome unavailable: ${result.stdout}');
          return;
        }
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 28 browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'browser launch failure reports the process exit and stderr (BUG-2803)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      // Stand-in "browser" that dies at once: node rejects Chrome's flags on
      // stderr and exits non-zero. The driver must surface that immediately
      // instead of waiting out a startup deadline.
      final String nodePath =
          (Process.runSync(nodeExe, <String>['-p', 'process.execPath']).stdout
                  as String)
              .trim();
      final Directory temp = Directory.systemTemp.createTempSync('reader-cue-');
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync('{}');
        final ProcessResult result = await Process.run(
          nodeExe,
          <String>[
            'test/reader/reader_audio_cue_identity_harness.mjs',
            payload.path,
          ],
          environment: <String, String>{'CHROME_PATH': nodePath},
        );
        expect(result.exitCode, isNot(anyOf(0, 77)));
        final String stderr = result.stderr as String;
        expect(stderr, contains('chrome exited before DevTools was ready'));
        expect(stderr, contains('--- chrome stderr (tail) ---'));
        expect(stderr, contains('--remote-debugging-port=0'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// Resolve Node before launching the browser harness so missing CI tools skip.
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

@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/highlight_bridge.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

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
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Directory temp = Directory.systemTemp.createTempSync(
        'favorite-removal-lookup-',
      );
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'paginated': ReaderPaginationScripts.paginatedShellSource(),
              'continuous': ReaderPaginationScripts.continuousShellSource(),
              'vn': ReaderVisualNovelScripts.vnShellScript(),
              'selection': ReaderSelectionScripts.source(),
              // 与生产 engineShell 同序：study units 之后注入句子音频标点归属模块。
              'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
              'bridge': HighlightBridge.debugScriptSource,
            }),
          );
        final _HarnessRun run = await _runHarness(nodeExe, payload.path);
        if (run.exitCode == 77) {
          markTestSkipped('Chrome unavailable: ${run.stdout}');
          return;
        }
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        expect(run.stdout, contains('PASS 6 favourite removal scenarios'));
      } finally {
        temp.deleteSync(recursive: true);
      }
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

typedef _HarnessRun = ({int exitCode, String stdout, String stderr});

/// Runs the harness with its own deadline below the test timeout, killing the
/// node / Chrome tree when it hangs so the failure carries the output so far.
Future<_HarnessRun> _runHarness(String nodeExe, String payloadPath) async {
  final Process process = await Process.start(nodeExe, <String>[
    'test/reader/favorite_removal_lookup_selection_harness.mjs',
    payloadPath,
  ]);
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  final int exitCode = await process.exitCode.timeout(
    const Duration(seconds: 75),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  return (exitCode: exitCode, stdout: await stdout, stderr: await stderr);
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

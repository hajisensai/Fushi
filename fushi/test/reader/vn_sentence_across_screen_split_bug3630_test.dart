@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-3630：视觉小说模式把一句话切到两屏时（量尺装不下、按字切，ruby 是原子单元），
/// 查词 / 制卡的句子必须仍是源章节里的整句，而不是当前屏那半句。真 Chrome 跑完整 VN
/// 工厂 + 选区脚本，断言点按查词、原生选区、上一句三条路径。
void main() {
  test(
    'VN lookup takes the whole sentence when a screen split cuts it',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Directory temp = Directory.systemTemp.createTempSync(
        'vn-sentence-split-',
      );
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'shell': ReaderVisualNovelScripts.vnShellScript(),
              'selection': ReaderSelectionScripts.source(),
              'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
            }),
          );
        final ProcessResult result = await Process.run(nodeExe, <String>[
          'test/reader/vn_sentence_across_screen_split_bug3630_harness.mjs',
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
        expect(result.stdout, contains('PASS VN sentence across screen split'));
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

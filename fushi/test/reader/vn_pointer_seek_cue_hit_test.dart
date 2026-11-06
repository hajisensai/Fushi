@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3738：VN 模式中键「跳到点击句」。
///
/// 用户原始失败（Windows，七つの魔剣が支配するII，竖排 VN + 有声书）：中键点句子
/// 没有任何反应。Dart `_seekToClickedSentence` 调 `fushiReader.cueIdAtPoint`，VN 的
/// fushiReader 此前没有这个方法，恒回 null。这里用生产 VN shell + 生产 VN CSS 在真
/// Chrome 里按字形坐标点，断言反查到所属句子（含逐字配对 ruby 的基字与注音、跟随
/// 包裹之后、换屏之后）。
void main() {
  test(
    'VN middle-click resolves the clicked sentence on the cloned screen',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('vn');
      await settings.setWritingMode('vertical-rl');
      final String css = ReaderContentStyles.css(settings: settings);

      final Directory temp = Directory.systemTemp.createTempSync(
        'vn-pointer-seek-',
      );
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'shell': ReaderVisualNovelScripts.vnShellScript(),
              'selection': ReaderSelectionScripts.source(),
              'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
              'css': css,
            }),
          );
        final ProcessResult result = await Process.run(nodeExe, <String>[
          'test/reader/vn_pointer_seek_cue_hit_harness.mjs',
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
        expect(result.stdout, contains('PASS VN pointer seek cue hit-test'));
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

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

/// BUG-3741：VN 模式有声书高亮推进时排版变化。
///
/// 用户原始失败（Windows WebView2，七つの魔剣が支配するII，竖排 VN）：当前句换到同段
/// 下一句时，带注音那一列的行盒窄了 6px，VN 居中把整屏平移 3px。根因是 VN 播放到哪句
/// 才把哪句的文本节点切进 wrapper，Blink 随之重排出不同的行盒。这里用生产 VN shell +
/// 生产 VN CSS 在真 Chrome 里断言：播放推进时屏上 DOM 一字不改、当前句由 CSS Highlight
/// 承载（不含注音）、所有字形坐标不动。
void main() {
  test(
    'VN read-along never rewrites the on-screen text, so no glyph moves',
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
        'vn-live-text-',
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
          'test/reader/vn_sentence_audio_live_text_harness.mjs',
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
        expect(result.stdout, contains('PASS VN sentence audio live text'));
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

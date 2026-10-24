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

/// BUG-3770：VN 逐字显现推进到带注音的词时整屏平移。
///
/// 用户原始失败（Windows WebView2，竖排 VN，逐字显现开着）：翻到下一屏后显现推进到
/// 「明後日」那一刻整屏左移 3px，显现结束又移回来。根因是显现把文本节点切成「已显现文本 +
/// 隐藏 span」并逐 tick 挪字，Blink 对含 ruby 的段落按不同切分排出不同行盒（与 BUG-3741
/// 同一机制）。这里用生产 VN shell + 生产 VN CSS 在真 Chrome 里断言：显现全程屏上 DOM
/// 一字不改、所有字形坐标不动，未显现部分由 CSS Highlight 承载、点不中，注音随基字显现。
void main() {
  test(
    'VN reveal never rewrites the on-screen text, so no glyph moves',
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
        'vn-reveal-live-text-',
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
          'test/reader/vn_reveal_live_text_harness.mjs',
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
        expect(result.stdout, contains('PASS VN reveal live text'));
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

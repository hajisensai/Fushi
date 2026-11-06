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

/// BUG-3395：VN 插图屏 / 句子屏的真 Chrome 几何与有声书跟随。
///
/// 用户原始失败（iOS，やはり俺の青春ラブコメはまちがっている。6，竖排 VN）：
/// 插图章被并进下一章章首，BUG-1244 又把插图和首段「……さすがだ、由比ヶ浜。よく人を
/// 見ている。」并成一屏，插图按整屏上限铺满，这句被挤到屏左外侧——有声书正读这句，屏上
/// 只看得见图；右边距调大时插图本身也被推出左边缘。现在插图独占一屏铺满、句子屏完整
/// 可见；跟随跨过插图屏时按图片暂停开关先停在图上。这里用生产 VN shell + 生产 VN CSS
/// 在 iPhone 尺寸视口里量。
void main() {
  test(
    'VN illustration gets a full screen and the following sentence stays visible',
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
      final String cssVertical = ReaderContentStyles.css(settings: settings);
      // 用户原始设置之一：右边距 9%（插图曾按 border-box 定宽，往左溢出被裁）。
      final double marginLeft = settings.marginLeft;
      await settings.setMarginRight(9);
      final String cssVerticalWideRight = ReaderContentStyles.css(
        settings: settings,
      );
      await settings.setMarginRight(marginLeft);
      await settings.setWritingMode('horizontal-tb');
      final String cssHorizontal = ReaderContentStyles.css(settings: settings);

      final Directory temp = Directory.systemTemp.createTempSync(
        'vn-illustration-screen-',
      );
      try {
        final File payload = File('${temp.path}/scripts.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'shell': ReaderVisualNovelScripts.vnShellScript(),
              'selection': ReaderSelectionScripts.source(),
              'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
              'cssVertical': cssVertical,
              'cssVerticalWideRight': cssVerticalWideRight,
              'cssHorizontal': cssHorizontal,
            }),
          );
        final ProcessResult result = await Process.run(nodeExe, <String>[
          'test/reader/vn_illustration_screen_harness.mjs',
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
        expect(
          result.stdout,
          contains('PASS 6 VN illustration/sentence screens'),
        );
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

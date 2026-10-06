import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-2905：VN 模式同一段落被切成两屏。
///
/// ① WebKit（iOS / macOS）下正文 `hanging-punctuation: allow-end` 让行尾「、」悬挂出
/// 列底，而 VN 屏盒在那条边上 `overflow: hidden` 且没有余量，切屏量尺如实判溢出——
/// 一屏本装得下的段落被切在「、」前。VN 的内容盒必须关掉悬挂标点。
/// ② 段落真装不下时，切点不得让下一屏以行首禁则字（。、」！…；与正文 `line-break: normal` 同表，小假名与长音 ー 可起首）开头、也不得让
/// 本屏以开括号收尾——切点逻辑丢进 node 真跑（范式同 `vn_style_reanchor_behavior_test`）。
void main() {
  test('VN 内容盒关掉悬挂标点（正文仍保留）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode('vertical-rl');
    await settings.setViewMode('vn');
    final String css = ReaderContentStyles.css(settings: settings);
    expect(css, contains('hanging-punctuation: allow-end !important;'));
    final RegExp vnRule = RegExp(
      r'\.fushi-vn-content, \.fushi-vn-content \* \{\s*'
      r'hanging-punctuation: none !important;',
    );
    expect(css, matches(vnRule));
    // 必须排在正文规则之后，层叠上才压得住（同为 !important，后者胜）。
    expect(
      css.indexOf(vnRule),
      greaterThan(css.indexOf('hanging-punctuation: allow-end !important;')),
    );
  });

  test('正文行首禁则用 line-break: normal，小假名与长音可起首', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode('vertical-rl');
    for (final String mode in <String>['paginated', 'continuous', 'vn']) {
      await settings.setViewMode(mode);
      final String css = ReaderContentStyles.css(settings: settings);
      // strict 会把「たった」的っ、「コート」的ー当行首禁则字，落在列尾时前一个字被
      // 一起推到下一列、本列留空，看起来像错误换行。
      expect(css, contains('line-break: normal !important;'), reason: mode);
      expect(css, isNot(contains('line-break: strict')), reason: mode);
    }
  });

  test('VN 切屏切点遵守禁则（node 行为级）', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final Directory temp = Directory.systemTemp.createTempSync(
      'hibiki-bug2888-vn-js-',
    );
    final File payload = File('${temp.path}/payload.json')
      ..writeAsStringSync(jsonEncode(<String, String>{'shell': shell}));
    final File runner = File('test/reader/vn_split_kinsoku_behavior_test.js');
    expect(runner.existsSync(), isTrue);
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>[runner.path, payload.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason:
          'VN split kinsoku runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

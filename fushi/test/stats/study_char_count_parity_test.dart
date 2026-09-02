import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/stats/study_char_count.dart';

/// Dart ↔ JS 学习单位计数**对拍**。
///
/// 为什么必须有这条：JS 侧算出的 `charOffset` 会写进 DB 的 `char_offset` 列，并在
/// `computeCharWatermark`（`reader_fushi_page.dart`）与 `computeBookProgress`
/// （`reader_fushi_source.dart`，注释原文「charOffset 与 characters **同单位**」）
/// 里与 Dart 算出的每章 `characters` **直接相加**。此前两侧各有一份手写白名单，
/// 只靠互相引用的注释维持「逐区间对齐」，**没有任何测试会在两者分叉时报红**——
/// 分叉的表现是续读位置和书架进度静默偏移，不会崩、不会报错。
///
/// 本测试用 node 真执行 [kStudyUnitJs]（与真机注入的是同一个 Dart 常量），拿同一
/// 批语料逐条比对：
/// ① `window.fushiStudyUnits.count(s)` == Dart [countStudyChars]`(s)`；
/// ② 逐位置 `isUnitEnd` 累加的总数 == `count(s)`——调用点用的是 `isUnitEnd`、
///    整节点总数用的是 `count`，两个入口自相矛盾同样会让偏移错位。
void main() {
  // 语料刻意覆盖两侧判据的每一条分支与每一个已知陷阱。
  const List<String> corpus = <String>[
    '',
    '   \n\t',
    '素晴らしい世界',
    'こんにちは、世界。',
    '私は学生です',
    'コーヒーを飲む',
    '人々の〆切',
    'ｶﾀｶﾅ ｱｲｳｴｵ',
    '你好世界',
    '\u{20BB7}野家',
    '안녕하세요 여러분',
    'สวัสดีชาวโลก',
    'I do not know',
    "I don't know",
    'I don\u2019t know',
    "John's book",
    "rock 'n' roll",
    'café au lait',
    'Grüße über Straße',
    'Привет мир',
    'Καλημέρα κόσμε',
    '\u0645\u0631\u062D\u0628\u0627 \u0628\u0643',
    '\u0643\u0650\u062A\u064E\u0627\u0628',
    '\u05E9\u05DC\u05D5\u05DD \u05E2\u05D5\u05DC\u05DD',
    '\u0928\u092E\u0938\u094D\u0924\u0947 \u0926\u0941\u0928\u093F\u092F\u093E',
    '2026年7月25日',
    'ＡＢＣ　ｄｅｆ',
    '\u3007',
    '\u3002',
    '\u30071\u30072',
    'これは Hello World です',
    '彼はHelloと言った',
    '（）【】「」『』、。！？\u3000',
    '！？…—',
    'The quick brown fox jumps over the lazy dog.',
    '「ねえ、」と彼女は言った。──そして、笑った！',
    'Mixed 日本語 and English 混在 текст ここ',
    'a  b',
    ' leading and trailing ',
    '\u200Czwnj\u200Dinside',
  ];

  test('JS fushiStudyUnits 与 Dart countStudyChars 逐条同口径（node 真执行）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping Dart/JS parity');
      return;
    }
    final File harness = File('test/stats/study_char_count_parity_test.js');
    expect(harness.existsSync(), isTrue,
        reason: 'parity harness ${harness.path} must exist');

    final Directory tmp = Directory.systemTemp.createTempSync('fushi_parity_');
    try {
      // 真值：与真机注入 WebView 的是同一个常量，不抄副本。
      final File jsFile = File('${tmp.path}/study_units.js');
      jsFile.writeAsStringSync(kStudyUnitJs);
      final File corpusFile = File('${tmp.path}/corpus.json');
      corpusFile.writeAsStringSync(jsonEncode(corpus));

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[harness.path, jsFile.path, corpusFile.path],
        workingDirectory: Directory.current.path,
      );
      expect(result.exitCode, 0,
          reason: 'parity harness failed.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');

      final Map<String, dynamic> out =
          jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
      final List<dynamic> counts = out['counts'] as List<dynamic>;
      final List<dynamic> prefixTotals = out['prefixTotals'] as List<dynamic>;
      expect(counts.length, corpus.length);

      for (int i = 0; i < corpus.length; i++) {
        final int dartCount = countStudyChars(corpus[i]);
        expect(counts[i], dartCount,
            reason: 'JS count 与 Dart countStudyChars 分叉，语料 #$i: '
                '${jsonEncode(corpus[i])}');
        expect(prefixTotals[i], dartCount,
            reason: '逐位置 isUnitEnd 累加与整段 count 分叉，语料 #$i: '
                '${jsonEncode(corpus[i])}');
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

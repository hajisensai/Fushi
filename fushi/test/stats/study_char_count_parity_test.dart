import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/stats/study_char_count.dart';

/// Dart ↔ JS 学习单位计数**对拍**。
///
/// 为什么必须有这条：JS 侧算出的 `charOffset` 会写进 DB 的 `char_offset` 列，并在
/// `absoluteCharOffsetOf`（`reader_fushi_page.dart`）与 `computeBookProgress`
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
      // 「守卫存在却可能零执行」是已知的假绿形状：本例是 Dart↔JS 口径分叉的
      // **唯一**报警器，在 CI 上静默跳过等于没有它。本机缺 node 只是环境问题，
      // 允许 skip；CI 上缺 node 是**镜像坏了**，必须红。
      if (Platform.environment['CI'] == 'true') {
        fail('CI 上找不到 node —— Dart↔JS 口径对拍是分叉的唯一报警器，'
            '它静默跳过等于没有它。修构建镜像，别把这条改回 skip。');
      }
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

  // ── 可加性（BUG-2058 复审 P2）──
  //
  // 旧口径逐码点，`count(a) + count(b) == count(a + b)` **恒成立**；新口径把空格
  // 分词文字的连续串计 1，于是在**词内**切开时不成立。这不是 bug，是新口径的
  // 定义得出的结果；但它**必须被写下来**，因为全仓有两个地方在隐含地依赖可加性：
  //
  //   · Dart `chapterCharacterCount` = `countStudyChars(chapterPlainText(i))`
  //     —— 整章**拼接后**的一个字符串（`epub_book.dart`）；
  //   · JS `buildNodeOffsets` = Σ `countChars(node.textContent)`
  //     —— **逐文本节点**求和（`reader_pagination_scripts.dart`）。
  //
  // 拉丁系文字 + 压缩过的 XHTML（`</p><p>` 无空白、`<i>` 切在词中）会让后者
  // 比前者**大** ≈每个词内切点 1 个单位；日文/中文免疫（无空格文字逐码点计）。
  //
  // **影响面（已沿真实代码路径核过）**：
  //   · 恢复路的越界判据 `charOffsetInRange`
  //     （`reader_pagination_scripts.dart` 里 `runningOffset += this.countChars(...)`）
  //     用的是**同一套逐节点求和**，与写入端口径自洽 → 不会因此判越界、
  //     不会回退章首，续读位置不丢；
  //   · 真正拿 Dart `characters` 与 JS `charOffset` 相加的是 `computeBookProgress`
  //     （`reader_fushi_source.dart`，`charOffset.clamp(0, sectionSize)`）与
  //     `absoluteCharOffsetOf` —— 两者都 **clamp**，所以后果是「本章进度提前封顶 /
  //     章尾若干单位不计字数」，量级 ≈ 该章词内切点数，不崩、不丢位置、换章自愈。
  //
  // 所以不改任一侧（改哪一侧都是动 restore 关键路径，且本轮无法真机验证），
  // 而是把「它不可加」钉成断言：将来谁再假设可加性，这里会先红。
  group('学习单位口径在文本节点边界上不可加', () {
    // (a, b, 逐节点求和, 拼接后整体计数)
    const List<List<Object>> splitCases = <List<Object>>[
      // minified XHTML：`</p><p>` 之间没有空白，两个段落的首尾词被拼成一个。
      <Object>['The end of paragraph one', 'Start of paragraph two', 9, 8],
      // 行内 <i>/<b>/<a> 切在词中。
      <Object>['un', 'likely  to happen', 4, 3],
    ];
    for (final List<Object> c in splitCases) {
      final String a = c[0] as String;
      final String b = c[1] as String;
      test('逐节点求和 != 拼接整体：${jsonEncode(a)} + ${jsonEncode(b)}', () {
        expect(countStudyChars(a) + countStudyChars(b), c[2],
            reason: '逐文本节点求和（JS buildNodeOffsets 的做法）');
        expect(countStudyChars(a + b), c[3],
            reason: '拼接后整体计数（Dart chapterCharacterCount 的做法）');
        expect(countStudyChars(a) + countStudyChars(b),
            greaterThan(countStudyChars(a + b)),
            reason: '词内切开时逐节点求和恒不小于整体——方向错了就不是'
                '「进度提前封顶」而是「永远到不了 100%」，症状完全不同。');
      });
    }

    // 反向：这些形状可加性**仍然成立**，別把不可加当成普遍现象。
    const List<List<String>> additiveCases = <List<String>>[
      // 无空格文字：逐码点计，切在哪都一样。
      <String>['日本語の', '文章です'],
      <String>['你好', '世界'],
      // 切点落在空白上：词已经写完了。
      <String>['a normal paragraph ', 'with whitespace'],
      // 切点落在标点上。
      <String>['He said,', ' and left.'],
    ];
    for (final List<String> c in additiveCases) {
      test('可加性仍成立：${jsonEncode(c[0])} + ${jsonEncode(c[1])}', () {
        expect(countStudyChars(c[0]) + countStudyChars(c[1]),
            countStudyChars(c[0] + c[1]));
      });
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

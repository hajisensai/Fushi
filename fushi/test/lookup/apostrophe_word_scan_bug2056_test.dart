import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

import '../helpers/source_guard.dart';

/// BUG-2056：英文正文/字幕里点 `don’t` 的 don 只查到 "don"，点 t 只查到 "t"；
/// `it’s` / `John’s` / `we’ve` 这类**缩合形与所有格**整类匹配不到词条。
///
/// 根因：撇号是否词边界取决于**上下文**，不是字符本身，但 `scanDelimiters`
/// （四份实现逐字节相同）把 ASCII `'` 与排版撇号 `’`（U+2019，真实 EPUB 的主流
/// 写法）当成无条件扫描终点，于是 `selectFromPosition` 的前向扫描一撞上就 break。
///
/// 修复：加一条上下文判据 `isIntraWordApostrophe(text, index)`——撇号两侧都是
/// **空格分词类字母**时它是词内字符，前向扫描跨过去。字母集与
/// `native/fushidicts/fushidicts_src/scan/word_scan.cpp` 的
/// `is_space_delimited_letter` 逐区间对齐（全仓一个模型）。
///
/// **刻意不改词首回退。** 回退跨撇号会把法语/意大利语省音写法（l’homme、
/// dell’arte）的锚点从 homme 拖回 l’，反而查不到 homme；而前向跨过是纯增益——
/// C++ `scan_candidates` 会生成 `don’t` / `don’` / `don` 三级前缀，短词不会被
/// 挤掉。行为测试 ⑥⑦ 与本文件的源码守卫一起把这个取舍钉死。
///
/// 两层守护：
/// ① 行为级——用 node 真执行两份实现（浮窗/扩展的 selection.js + 阅读器注入脚本
///    `ReaderSelectionScripts.source()`）的 `selectFromPosition`，12 条断言覆盖
///    三种撇号、所有格+空格桥接叠加、引号语义、法语省音、跨节点、日文不回归。
///    无 node 时 skip。
/// ② 源码级——四份实现都必须在**终点判定之前**跨词内撇号，且词首回退保持原样。
void main() {
  const List<String> selectionCopies = <String>[
    'assets/popup/selection.js',
    'assets/browser_extension/vendor/selection.js',
    '../tools/browser-extension/vendor/selection.js',
  ];

  /// 四份实现的**真值**：三份 selection.js 从盘上读，阅读器那份来自
  /// `ReaderSelectionScripts.source()`（与真机注入的是同一个字符串）。
  ///
  /// 读进来就先过 [maskJsComments]：四份都是 **JS**，两处修复的说明注释里都写着
  /// isIntraWordApostrophe / isScanStop 这些标识符，不掩的话下面的顺序判据会先
  /// 命中注释、退化成恒真；被注释掉的旧 `scanDelimiters:` 行同样能骗过字面量提取。
  /// 掩码等长（下标不错位）且保留串 / 模板串 / 正则字面量的内容，所以
  /// `intraWordApostrophePattern: /[…]/` 与 `scanDelimiters: '…'` 照常提得出来。
  ///
  /// 用 JS 版而不是 [maskComments]：后者不认正则字面量，正则里的 `//` 会被读成
  /// 「除号 + 行注释」，从正则处到行尾整段凭空消失。
  final Map<String, String> sources = <String, String>{
    for (final String path in selectionCopies)
      path: maskJsComments(File(path).readAsStringSync()),
    'reader_selection_scripts.dart (source())':
        maskJsComments(ReaderSelectionScripts.source()),
  };

  test(
    'BUG-2056: forward scan bridges an intra-word apostrophe so English '
    'contractions stay reachable (executes both selection engines via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/lookup/apostrophe_word_scan_bug2056_test.js',
      );
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      // 阅读器注入脚本活在 Dart 的 raw string 里，node 读不到文件。把**真值**
      // （ReaderSelectionScripts.source()，与真机注入的是同一份字符串）落到临时
      // 文件再交给 harness，避免测试对着一份手抄副本自娱自乐。
      final Directory tmp =
          Directory.systemTemp.createTempSync('fushi_bug2056_');
      final File readerJs = File('${tmp.path}/reader_selection.js');
      readerJs.writeAsStringSync(ReaderSelectionScripts.source());

      try {
        final ProcessResult result = await Process.run(
          nodeExe,
          <String>[jsTest.path],
          workingDirectory: Directory.current.path,
          environment: <String, String>{
            'FUSHI_READER_SELECTION_JS': readerJs.path,
          },
          // harness 的断言文案是中文 + 各脚本代表字符。默认 systemEncoding 在中文
          // Windows 上是 GBK，失败时整段变乱码（实测），诊断价值归零。
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );

        expect(
          result.exitCode,
          0,
          reason: 'BUG-2056 intra-word apostrophe behavior test failed.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final String stdout = result.stdout.toString();
        expect(stdout, contains('all assertions passed'),
            reason: 'behavior harness must reach its success marker');
        // 阅读器那一套必须真的跑到，否则这个测试只守住了一半实现。
        expect(stdout, isNot(contains('reader selection script not provided')),
            reason: '阅读器注入脚本必须被 harness 真执行（真值来自 source()）');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
  );

  test(
      'intra-word apostrophe is bridged before the scan-stop test, and the '
      'word-start back-off stays untouched', () {
    sources.forEach((String label, String code) {
      // `code` 在 sources 构造处已过 maskJsComments：顺序判据必须在**掩掉注释**的
      // 代码上算，否则裸 indexOf 会先命中说明注释、顺序断言退化成恒真
      // （见 docs/agent 的顺序守卫纪律）。

      const String bridge =
          'if (this.isIntraWordApostrophe(content, scanOffset)) {';
      const String stop = 'if (this.isScanStop(char)) break;';

      expect(code.contains(bridge), isTrue, reason: '[$label] 前向扫描必须带词内撇号桥接');
      expect(code.contains(stop), isTrue,
          reason: '[$label] 终点判定必须仍在（BUG-1773 的锚点）');
      expect(code.indexOf(bridge) < code.indexOf(stop), isTrue,
          reason: '[$label] 撇号桥接必须**先于** isScanStop，否则撇号照旧 break');

      // 判据本身必须是「两侧都是空格分词类字母」，不是无条件跨过——无条件跨过会
      // 把 `‘hello’ world` 的收尾引号也吃掉、把日文里的引号粘进查询串。
      expect(code.contains('this.isSpaceDelimitedLetter(text[index - 1]) &&'),
          isTrue,
          reason: '[$label] 词内判据必须要求撇号**左**侧是空格分词类字母');
      expect(code.contains('this.isSpaceDelimitedLetter(text[index + 1]);'),
          isTrue,
          reason: '[$label] 词内判据必须要求撇号**右**侧是空格分词类字母');

      // 词首回退必须保持原样（整条 while 条件逐字不变）：把桥接加进回退会让
      // l’homme 点 homme 退回 l’，是净损失。行为测试 ⑥⑦ 守行为，这里守写法。
      expect(
          code.contains('while (startOffset > 0 && '
              '!this.isScanBoundary(hitContent[startOffset - 1])) {'),
          isTrue,
          reason: '[$label] 词首回退不得被改动（不得跨撇号）');
    });
  });

  test('apostropheClassInvariant: 撇号类字符集与 scanDelimiters 的耦合不得漂移', () {
    // 撇号有四个码点写法，但它们在扫描器里的**角色不同**，别当成一视同仁的白名单：
    //   ' U+0027 / ‘ U+2018 / ’ U+2019 —— 在 scanDelimiters 里，会 break 前向扫描，
    //     所以必须出现在 intraWordApostrophePattern 里才救得回来；
    //   ʼ U+02BC —— 不在 scanDelimiters 里，本来就不截断。它在 pattern 里是**未来
    //     保险**，不是本 bug 的战果（JS 行为断言 ③ 已经写明这一点）。
    // 这条守卫钉的是两者的耦合：pattern 必须盖住整个撇号类；三个真终点必须仍在
    // scanDelimiters 里（不然 ③b/① 的行为断言变成恒真）；U+02BC 必须仍不在里面。
    // 最后一条只能由**源码守卫**来钉：实测把 ʼ 加进 scanDelimiters 之后，JS 行为
    // 断言 ③ 照样绿（桥接接住了它），行为层根本区分不出来——所以这里不是可有可无
    // 的重复，而是唯一的探测点。
    const Map<String, String> apostropheClass = <String, String>{
      "'": 'U+0027 ASCII 撇号',
      '\u2018': 'U+2018 左单引号（OCR 常把 ’ 认成它）',
      '\u2019': 'U+2019 排版撇号（真实 EPUB 的主流写法）',
      '\u02BC': 'U+02BC MODIFIER LETTER APOSTROPHE',
    };
    const List<String> apostropheStops = <String>["'", '\u2018', '\u2019'];

    sources.forEach((String label, String src) {
      final RegExpMatch? patternMatch =
          RegExp(r'intraWordApostrophePattern: /\[(.*?)\]/').firstMatch(src);
      expect(patternMatch, isNotNull,
          reason: '[$label] 找不到 intraWordApostrophePattern 字面量');
      final String klass = patternMatch!.group(1)!;

      final RegExpMatch? delimiterMatch =
          RegExp("scanDelimiters: '(.*)',").firstMatch(src);
      expect(delimiterMatch, isNotNull,
          reason: '[$label] 找不到 scanDelimiters 字面量');
      final String delimiters = delimiterMatch!.group(1)!;

      apostropheClass.forEach((String ch, String why) {
        expect(klass.contains(ch), isTrue,
            reason: '[$label] intraWordApostrophePattern 必须含 $why；'
                '缺一个就是一整类写法重新被截断（或未来加进 scanDelimiters 时没兜底）');
      });

      for (final String ch in apostropheStops) {
        expect(delimiters.contains(ch), isTrue,
            reason: '[$label] ${apostropheClass[ch]} 必须仍在 scanDelimiters 里——'
                '它不再是扫描终点的话，桥接的行为断言就退化成恒真，得重写测试');
      }
      expect(delimiters.contains('\u02BC'), isFalse,
          reason: '[$label] U+02BC 不得进 scanDelimiters：它本来就不截断，'
              '加进去会让 `canʼt` 从「天然完整」变成「靠桥接才完整」，而行为层探测'
              '不到这个变化（实测 ③ 仍绿），只有这条源码守卫拦得住');
    });
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

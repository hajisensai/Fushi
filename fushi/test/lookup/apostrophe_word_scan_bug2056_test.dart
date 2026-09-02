import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

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
    final Map<String, String> sources = <String, String>{
      for (final String path in selectionCopies)
        path: File(path).readAsStringSync(),
      'reader_selection_scripts.dart (source())':
          ReaderSelectionScripts.source(),
    };

    sources.forEach((String label, String src) {
      // 顺序判据必须在**剥掉注释**的代码上算：两处修复的说明注释里都写着
      // isIntraWordApostrophe / isScanStop 这些标识符，裸 indexOf 会先命中注释，
      // 顺序断言就变成恒真（见 docs/agent 的顺序守卫纪律）。
      final String code = _stripLineComments(src);

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
}

/// 去掉 `//` 行注释（保留换行，偏移仍然单调），供顺序判据使用。
String _stripLineComments(String src) {
  return src.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx < 0 ? line : line.substring(0, idx);
  }).join('\n');
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

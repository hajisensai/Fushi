import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-1773：英文正文/字幕里点 "listen" 只查到 listen，`listen to` 这类**空格分词
/// 短语**的词条永远匹配不到；而点它前面的空格反而能查出短语。
///
/// 根因：取词的前向扫描把空白当**终点**。`isScanBoundary` 把三件事混成一坨——
/// 空白、句读标点、「只扫日文」门控——而前向扫描直接拿它当 break 条件，于是喂给
/// 引擎的查询串被截在第一个空格前。C++ `scan_candidates` 本来就按空格分词生成
/// `listen to music` / `listen to` / `listen` 三级候选（明确禁止在单词中间切，见
/// native/fushidicts/fushidicts_src/scan/word_scan.cpp），拿不到空格就等于把短语
/// 整类排除在匹配之外。
///
/// 修复：拆成两个语义不同的谓词——
/// - `isScanBoundary`（**词边界**：点击命中判定 + 词首回退用，含空白，语义不变）
/// - `isScanStop`（**扫描终点**：标点 / 门控，不含空白）
/// 空白能否跨过去由桥接规则单独决定：只在同一文本节点内部跨、且只跨一个（左边必须
/// 已有本节点扫入的内容，右边必须紧跟一个可扫字符）。
///
/// 两层守护：
/// ① 行为级——用 node 真执行两份实现（浮窗/扩展的 selection.js + 阅读器注入脚本
///    `ReaderSelectionScripts.source()`）的 `selectFromPosition`，断言跨空格短语、
///    以及连续空白/末尾空白/空白接标点/跨节点开头空白四条终止规则。无 node 时 skip。
/// ② 源码级——两份实现的前向扫描都必须用 `isScanStop` + 空白桥接，不得退回
///    `isScanBoundary`（那正是 BUG-1773 的写法）。
void main() {
  const List<String> selectionCopies = <String>[
    'assets/popup/selection.js',
    'assets/browser_extension/vendor/selection.js',
    '../tools/browser-extension/vendor/selection.js',
  ];

  test(
    'BUG-1773: forward scan bridges a single space so phrases stay reachable '
    '(executes both selection engines via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/lookup/phrase_lookup_whitespace_bridge_bug1773_test.js',
      );
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      // 阅读器注入脚本活在 Dart 的 raw string 里，node 读不到文件。把**真值**
      // （ReaderSelectionScripts.source()，与真机注入的是同一份字符串）落到临时
      // 文件再交给 harness，避免测试对着一份手抄副本自娱自乐。
      final Directory tmp =
          Directory.systemTemp.createTempSync('fushi_bug1773_');
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
          reason: 'BUG-1773 whitespace-bridge behavior test failed.\n'
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

  test('forward scan uses isScanStop + whitespace bridge, not isScanBoundary',
      () {
    final Map<String, String> sources = <String, String>{
      for (final String path in selectionCopies)
        path: File(path).readAsStringSync(),
      'reader_selection_scripts.dart (source())':
          ReaderSelectionScripts.source(),
    };

    // 断言一律锚在**可执行代码片段**上，不能是裸的标识符名——两份实现的注释里都
    // 写着 isScanStop / isScanBoundary / `scanOffset === start`，裸 contains 会被
    // 自己的注释假阳性满足，变异测试实测过（把桥接条件换成 `!text` 时裸断言照样绿）。
    sources.forEach((String label, String src) {
      // 前向扫描的 break 条件必须是 isScanStop。BUG-1773 的写法是 isScanBoundary，
      // 它把空白也当终点 → 短语被截断。
      expect(src.contains('if (this.isScanStop(char)) break;'), isTrue,
          reason: '[$label] 前向扫描必须以 isScanStop 为终点');
      expect(src.contains('if (this.isScanBoundary(char)) break;'), isFalse,
          reason: '[$label] 前向扫描不得退回 isScanBoundary（BUG-1773 的根因写法）');

      // 桥接规则的三条终止条件必须齐：本节点开头 / 后无字符 / 后接空白或终点。
      // 两份实现缩进不同，故锚在去缩进的完整条件表达式上。
      expect(
          src.contains('if (scanOffset === start || nextChar === undefined ||'),
          isTrue,
          reason: '[$label] 空白桥接必须要求左边已有本节点扫入的内容（跨节点不粘空白）'
              '、且节点末尾的空白终止扫描');
      expect(
          src.contains('this.isScanWhitespace(nextChar) || '
              'this.isScanStop(nextChar)) break;'),
          isTrue,
          reason: '[$label] 连续空白 / 空白后接终点必须终止扫描');

      // 词首回退仍必须用词边界语义（含空白），否则回退会越过空格吃进上一个词。
      expect(src.contains('!this.isScanBoundary(hitContent[startOffset - 1])'),
          isTrue,
          reason: '[$label] 词首回退必须继续用 isScanBoundary（含空白）');
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

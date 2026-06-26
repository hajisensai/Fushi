import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-865 (BUG-419 sibling): a dictionary disabled in 词典管理 (its show/hide
/// switch off) must not have its definitions written into the Anki mining payload.
///
/// 根因：term 词典即使被隐藏（disabled）也仍注册进 FFI 引擎——`AppModel.bucketDictPaths`
/// 的 term 分支故意不按 hidden 过滤（注释「term 在渲染期按 hidden 过滤，故隐藏仍进桶」），
/// 因此 `entry.glossaries` 仍含被禁用词典的义项。BUG-419 只堵了可视查词弹窗
/// （`createGlossarySectionWrapper`）；制卡走另一条独立的字段组装路径
/// （`constructGlossaryHtml` / `constructSingleGlossaryHtml`，由 `buildMinePayload` 消费），
/// 此前没有消费 `window.hiddenDictionaryNames`，把隐藏词典义项原样塞进卡片 glossary 字段。
/// 修复：两函数各加一行 `hiddenDictionaryNames.includes(g.dictionary)) return;`，与
/// `createGlossarySectionWrapper`（popup.js:1679-1682）完全同款、同源谓词。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `constructGlossaryHtml` /
///    `constructSingleGlossaryHtml`，断言隐藏词典被排除、且仅隐藏词典的词条产出空
///    `<ol></ol>` / `{}`。无 node 时 skip。
/// ② 源码级——静态扫描 popup.js 两函数体内各含 hidden 过滤行（即便无 node 也守得住）。
void main() {
  test(
    'mining payload excludes disabled dictionaries '
    '(executes constructGlossaryHtml / constructSingleGlossaryHtml via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/pages/popup_mining_hidden_dictionary_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason:
            'popup mining hidden-dictionary filter JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test(
    'popup.js drops hidden dictionaries in both mining glossary builders',
    () {
      final String js = File('assets/popup/popup.js').readAsStringSync();

      // constructSingleGlossaryHtml must consult the hidden names list and skip
      // those dictionaries inside its glossary forEach.
      _assertHiddenFilterInFunction(js, 'constructSingleGlossaryHtml');

      // constructGlossaryHtml must do the same.
      _assertHiddenFilterInFunction(js, 'constructGlossaryHtml');
    },
  );
}

/// Asserts that the body of [functionName] (between its `function <name>(` and the
/// next top-level `function ` declaration) reads `window.hiddenDictionaryNames` and
/// skips hidden dictionaries via `hiddenDictionaryNames.includes(g.dictionary)) return;`
/// inside `entry.glossaries.forEach(`.
void _assertHiddenFilterInFunction(String js, String functionName) {
  final int start = js.indexOf('function $functionName(');
  expect(start, greaterThanOrEqualTo(0), reason: '$functionName must exist');

  final int next = js.indexOf('\nfunction ', start + 1);
  final String body =
      next >= 0 ? js.substring(start, next) : js.substring(start);

  expect(
    body.contains('window.hiddenDictionaryNames'),
    isTrue,
    reason: '$functionName must read window.hiddenDictionaryNames',
  );

  final int forEach = body.indexOf('entry.glossaries.forEach(');
  final int skip =
      body.indexOf('hiddenDictionaryNames.includes(g.dictionary)) return;');
  expect(forEach, greaterThanOrEqualTo(0),
      reason: '$functionName must iterate entry.glossaries');
  expect(skip, greaterThan(forEach),
      reason: 'hidden dictionaries must be skipped inside the glossary forEach '
          'of $functionName');
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

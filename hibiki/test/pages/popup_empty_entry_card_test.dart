import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-833: 隐藏词典过滤后正文为空的词条不得渲染成「标题+频率徽章但正文空白」的壳卡。
///
/// 根因：popup.js 的 `buildEntryElement` 旧实现先无条件 append 词条 header（+频率/音高
/// 徽章），再「有则 append」glossary。`createGlossarySectionWrapper` 在该词条所有词典都被
/// hiddenDictionaryNames 剔除（或本就无 glossary）时返回 null → 正文消失但 header + 频率
/// 壳卡仍在 = 空壳卡。同 expression 不同 reading 会拆成两张卡，其一即此空壳。这是 BUG-419
/// （隐藏词典过滤）的下游遗留缺口（BUG-419 只剥正文没删壳）。
///
/// 修复（方案A，仅改 WebView popup.js）：`buildEntryElement` 在 glossaryWrapper === null 时
/// 整卡跳过（return null）；`renderPopup` / `updatePopupIncremental` 跳过 null 卡，并维护
/// `_entryDomIndex` 映射，使稀疏的 DOM `.entry` 节点与 `entries` 数组保持对齐——否则 load-more
/// 的 incremental 会把 A 词条的释义灌进 B 卡。native 弹窗（dictionary_popup_native.dart）是
/// 独立渲染路径，不在本次范围。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `buildEntryElement` / `renderPopup` /
///    `updatePopupIncremental`，断言空壳卡被跳过、正常卡不受影响、incremental 灌对卡。无 node
///    时 skip。
/// ② 源码级——静态扫描 popup.js，保证「glossaryWrapper === null → return null」判据与
///    `_entryDomIndex` 对齐机制都在位（即便无 node 也守得住）。
void main() {
  test(
    'popup skips empty (all-hidden) entry cards and keeps incremental alignment '
    '(executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File('test/pages/popup_empty_entry_card_test.js');
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
        reason: 'popup empty-entry-card JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.js skips an entry whose glossary wrapper is null', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    final int build = js.indexOf('function buildEntryElement(');
    expect(build, greaterThanOrEqualTo(0),
        reason: 'buildEntryElement must exist');

    // The skip judgement must be exactly "glossary wrapper is null → return null",
    // computed before the header is appended so no shell is ever built.
    final int wrapperCall =
        js.indexOf('entryGlossaryWrapperOrNull(entry)', build);
    expect(wrapperCall, greaterThanOrEqualTo(0),
        reason: 'buildEntryElement must consult the shared wrapper predicate');

    final int returnNull = js.indexOf('return null;', wrapperCall);
    final int headerAppend = js.indexOf('createEntryHeader(entry, idx)', build);
    expect(returnNull, greaterThanOrEqualTo(0));
    expect(returnNull, lessThan(headerAppend),
        reason: 'the null-skip must precede the header append so no empty '
            'header+freq shell card is ever built');
  });

  test('popup.js keeps DOM/entries alignment via _entryDomIndex', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // renderPopup must build and store the dom-index map, and updatePopupIncremental
    // must read it instead of indexing the live .entry NodeList by raw entries idx.
    expect(js.contains('window._entryDomIndex'), isTrue,
        reason: 'the dom-index alignment map must be stored on window');

    final int incremental = js.indexOf('window.updatePopupIncremental =');
    expect(incremental, greaterThanOrEqualTo(0));
    final int mapRead = js.indexOf('window._entryDomIndex', incremental);
    expect(mapRead, greaterThanOrEqualTo(0),
        reason: 'updatePopupIncremental must consult the dom-index map so a '
            'skipped entry does not misalign existingEntries[idx]');
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

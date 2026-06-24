import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-812: 明鏡国語辞典 第三版 (and any Yomitan dictionary whose `styles.css`
/// contains at-rules) must render correctly in the lookup popup. The legacy
/// `constructDictCss` in `assets/popup/dict-media.js` is a hand-written CSS
/// scoper that prefixed every comma-separated selector with
/// `[data-dictionary="X"]`. For an `@media (max-width: 500px) { ... }` block it
/// treated `@media (max-width: 500px)` as a selector list, emitting the illegal
/// `[data-dictionary="X"] @media (...) { ... }`, so the whole @media block was
/// dropped by the browser — the meikyo responsive image sizing vanished.
///
/// 根因：`dict-media.js` `constructDictCss` 把 at-rule 前言当成选择器逐个加前缀。
/// 修复：识别 at-rule —— 条件组 (@media/@supports/@container/@layer/@scope) 前言
/// 原样保留、对内部规则递归加前缀；其它 at-rule (@font-face/@keyframes/@page) 整块
/// 透传；语句型 at-rule (@import/@charset/...) 原样输出。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 `constructDictCss` 喂明鏡真实 styles.css 片段，断言
///    @media 前言不被前缀污染、内部规则仍作用域化、普通选择器不受影响、
///    @keyframes/@font-face 体不被前缀。无 node 时 skip。
/// ② 源码级——静态扫描 dict-media.js，保证 at-rule 识别分支在位（CI 无 node 也守住）。
void main() {
  test(
    'constructDictCss scopes at-rules correctly (executes via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/utils/misc/popup_dict_css_atrule_scope_test.js');
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
        reason: 'dict CSS at-rule scoping JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('dict-media.js constructDictCss recognizes at-rules', () {
    final String js = File('assets/popup/dict-media.js').readAsStringSync();

    // The at-rule detection branch must exist and not be a no-op.
    expect(
      js,
      contains(r'const atRuleMatch = selectorPrelude.match(/^@([a-z-]+)/i);'),
      reason: 'constructDictCss must detect at-rule preludes',
    );
    // Conditional-group at-rules must recurse to keep inner rules scoped.
    final int atBranch = js.indexOf('const atRuleMatch');
    expect(atBranch, greaterThanOrEqualTo(0));
    final int isCond = js.indexOf('isConditionalGroup', atBranch);
    expect(
      isCond,
      greaterThan(atBranch),
      reason: 'at-rule branch must split conditional groups from the rest',
    );
    final int recurse = js.indexOf(
        'constructDictCss(atBlockContent, dictName, scopePrefix)', atBranch);
    expect(
      recurse,
      greaterThan(atBranch),
      reason: 'conditional-group at-rules must recurse to scope inner rules',
    );
    // @media must be listed as a conditional group.
    final int mediaListed = js.indexOf("atName === 'media'", atBranch);
    expect(
      mediaListed,
      greaterThan(atBranch),
      reason: '@media must be treated as a conditional group',
    );
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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词弹窗性能：`assets/popup/dict-media.js` 的 `constructDictCss` 现在是**带 memo
/// 的入口**，真正的扫描实现是 `constructDictCssUncached`。
///
/// 为什么要 memo：它的调用点是 `createGlossarySection`，即「每条词条的每个词典块」
/// 各调一次。N 条词条 × M 本词典 = N×M 次对同一本词典那份（Yomitan 词典动辄几十 KB
/// 的）CSS 做完全相同的逐字符扫描（实现里对空白字符是一个字符 push 一次数组）。查一
/// 次词就白烧几十上百遍相同的解析，全部压在首屏渲染路径上。
///
/// memo 的正确性风险只有一个方向——**串味**：把 A 词典的作用域化结果发给 B 词典，或
/// 者词典集换了以后还发旧内容。缓存 key 必须覆盖 `(css, dictName, scopePrefix)` 三
/// 元组的全部三项，缺一项就会串。
///
/// 两层守护（与 popup_dict_css_atrule_scope_test.dart 同款）：
/// ① 行为级——用 Node 真执行 memo 入口与未 memo 实现，断言两者对同一输入逐字节相同、
///    交叉输入不串味、缓存桶被撑爆 clear() 之后结果依旧正确。无 node 时 skip。
/// ② 源码级——静态扫描 dict-media.js，保证 memo 结构与「key 含 scopePrefix」在位
///    （CI 无 node 也守住这条最容易被"顺手简化"掉的不变量）。
void main() {
  test(
    'constructDictCss memo never cross-contaminates (executes via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File('test/utils/misc/popup_dict_css_memo_test.js');
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(nodeExe, <String>[
        jsTest.path,
      ], workingDirectory: Directory.current.path);

      expect(
        result.exitCode,
        0,
        reason:
            'dict CSS memo JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('dict-media.js keeps the memo split and a full cache key', () {
    final String js = File('assets/popup/dict-media.js').readAsStringSync();

    expect(
      js,
      contains('function constructDictCssUncached('),
      reason:
          'the un-memoised implementation must stay separately callable, '
          'otherwise the recursion would populate the cache with at-block '
          'substrings',
    );
    expect(
      js,
      contains('function constructDictCss('),
      reason:
          'the memoised entry point must keep the original name so every '
          'existing call site is cached without being touched',
    );

    // 缓存 key 必须同时含 dictName 与 scopePrefix。只用 dictName 会让
    // `.yomitan-glossary [data-dictionary="X"]` 作用域的结果覆盖裸作用域的结果
    // （反之亦然）——即同一本词典在弹窗与词条内联两种上下文之间串味。
    final int keyLine = js.indexOf('const key =');
    expect(
      keyLine,
      greaterThanOrEqualTo(0),
      reason: 'memo entry must build a cache key',
    );
    final int keyLineEnd = js.indexOf('\n', keyLine);
    final String keyExpr = js.substring(keyLine, keyLineEnd);
    expect(
      keyExpr,
      contains('dictName'),
      reason: 'cache key must include dictName',
    );
    expect(
      keyExpr,
      contains('scopePrefix'),
      reason:
          'cache key must include scopePrefix — dropping it makes the '
          'scoped and bare variants of the same dictionary collide',
    );

    // 外层按 css 串本身分桶：内容变了自然落到新桶，所以不需要（也不存在）失效钩子。
    expect(
      js,
      contains('__dictCssCache.get(css)'),
      reason:
          'the outer cache must be keyed by the css string itself so a '
          'changed dictionary stylesheet cannot return a stale scoping',
    );
    // 桶数必须封顶，否则换词典集/反复导入会让缓存无界增长。
    expect(
      js,
      contains('__dictCssCache.clear()'),
      reason: 'the cache must be bounded',
    );
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
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

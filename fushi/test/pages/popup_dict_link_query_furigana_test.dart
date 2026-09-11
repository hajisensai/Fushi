import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2456：词典正文里的链接（惯用句 / 交叉引用）带振假名时，点击发出的查询词
/// 必须是**基字**，不能混入 `<rt>` 读音。
///
/// 根因：popup.js 两条链接路径都拿 `textContent` 当查询词——结构化内容 `<a>`
/// 没有 `?query=` 时的回退，以及 MDX 原始 HTML 锚点（handleGlossaryAnchorClick）。
/// `<ruby>足<rt>あし</rt></ruby>が<ruby>棒<rt>ぼう</rt></ruby>になる` 因此变成
/// 「足あしが棒ぼうになる」；postProcessRuby 还会把每个读音克隆成一份 `.ruby-reserve`
/// 插在基字**前面**，实际串是「あし足あしが棒ぼうになる」。Dart 侧 searchDictionary 是
/// 从串首由长到短的前缀扫描，能命中的最长前缀只剩「あし」/「足」→ 用户看到的是首字
/// 那个汉字的词条，而不是惯用句。
///
/// 修复：`linkVisibleBaseText(el)` 只收基字文本节点（跳过 rt / rp / .ruby-rt /
/// .ruby-reserve），两处调用点改用它。
///
/// 两层守卫：
/// 1) 行为——node 真执行 popup.js 的 renderStructuredContent + postProcessRuby +
///    链接 onclick / handleGlossaryAnchorClick，断言到达 onLinkClick 的查询词
///    （`popup_dict_link_query_furigana_test.js`，含「裸 textContent 确实被污染」的
///    反向对照，防空壳）。node 缺席时跳过。
/// 2) 源码——两处调用点都经 linkVisibleBaseText、不再直接拿 textContent 当查询词；
///    浏览器扩展的两份 vendor 镜像带同一 helper。没有 node 也成立。
void main() {
  test('dict-body link with furigana sends base text as the query (node)',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest =
        File('test/pages/popup_dict_link_query_furigana_test.js');
    expect(jsTest.existsSync(), isTrue,
        reason: 'behavior harness ${jsTest.path} must exist');

    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'BUG-2456 link query JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });

  test('both link query sites go through linkVisibleBaseText (source)', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js.contains('function linkVisibleBaseText('), isTrue,
        reason: 'popup.js must define the base-text extractor');

    final String anchorHandler = _functionBody(js, 'handleGlossaryAnchorClick');
    expect(anchorHandler.contains('linkVisibleBaseText(anchor)'), isTrue,
        reason: 'MDX anchor path must take the query from linkVisibleBaseText');
    expect(anchorHandler.contains('anchor.textContent'), isFalse,
        reason: 'MDX anchor path must not use raw textContent as the query '
            '(it carries <rt> readings and the .ruby-reserve twin)');

    // 结构化内容链接：定位 onclick 里的 query 计算段。
    final int hrefIdx = js.indexOf('if (node.href) {');
    expect(hrefIdx, greaterThanOrEqualTo(0));
    final int queryIdx = js.indexOf('const query = node.href.indexOf', hrefIdx);
    expect(queryIdx, greaterThan(hrefIdx),
        reason: 'structured-content link must still compute query from href');
    final String querySite = js.substring(queryIdx, js.indexOf(';', queryIdx));
    expect(querySite.contains("get('query')"), isTrue,
        reason: '?query= stays authoritative');
    expect(querySite.contains('linkVisibleBaseText(element)'), isTrue,
        reason: 'fallbacks must come from linkVisibleBaseText');
    expect(querySite.contains('element.textContent'), isFalse,
        reason: 'no raw textContent fallback for the query');

    // 过滤集必须与 wrapExpressionInlineKanji 的 walker 一致。
    final String helper = _functionBody(js, 'linkVisibleBaseText');
    for (final String needle in <String>[
      "'RT'",
      "'RP'",
      "'ruby-rt'",
      "'ruby-reserve'",
    ]) {
      expect(helper.contains(needle), isTrue,
          reason: 'linkVisibleBaseText must skip $needle');
    }

    for (final String vendor in <String>[
      'assets/browser_extension/vendor/popup.js',
      '../tools/browser-extension/vendor/popup.js',
    ]) {
      final String vendorJs = File(vendor).readAsStringSync();
      expect(vendorJs.contains('function linkVisibleBaseText('), isTrue,
          reason: '$vendor must carry the same helper (byte-locked mirror)');
    }
  });
}

/// `function <name>(...) {` 起、按大括号配平取到函数收尾。
String _functionBody(String src, String name) {
  final int sig = src.indexOf('function $name(');
  expect(sig, greaterThanOrEqualTo(0), reason: 'function $name not found');
  final int open = src.indexOf('{', sig);
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    final String c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(sig, i + 1);
    }
  }
  fail('unbalanced braces scanning $name');
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

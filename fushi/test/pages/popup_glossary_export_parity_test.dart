import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1062 / BUG-1061：制卡（Anki mining）产出的 glossary 字段必须与上游 Yomitan
/// 导出的卡片一致，用户在两处看到了差异。
///
/// **BUG-1061 — `{glossary}` 词典名前多一个自造序号。**
/// 上游 Yomitan 的 anki 模板 `glossary-single` 标签是
/// `(definitionTags…, dictionaryAlias)`，**没有序号**；本仓 `constructSingleGlossaryHtml`
/// （`{glossary-first}` / `{single-glossary-*}` 用）也一直是这个格式。只有
/// `constructGlossaryHtml`（`{glossary}` 用）自增了一个 `index` 塞进标签，卡片上就成了
/// 「(1, 词典名)」。修复：删掉 index，两个 builder 标签格式统一。
///
/// **BUG-1062 — 导出图片被钉成物理像素，比 Yomitan 卡片小一个字号的倍数。**
/// 上游 `structured-content-generator.js` 导出时容器**永远**写 `width: {usedWidth}em`，
/// 1em 具体多大交给 CSS：Yomitan 弹窗自带
/// `.gloss-image-container{font-size:calc(1em/var(--font-size-no-units))}`（≈1px），
/// 而 Anki 卡片上没有这份 CSS，em 按卡片正文字号解析——这就是 Yomitan 卡片图「大」的原因。
/// popup.js 导出时却把它折算成 `width:{usedWidth}px` 且内联 `font-size:1px`（内联优先级
/// 最高，note type 的 CSS 也压不动），于是卡片图小了约一个字号的倍数。修复：导出保留 em
/// 语义、不再钉 font-size；弹窗路径维持 px（弹窗自己带那份 CSS，px 在那里才是对的）。
///
/// 三层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `constructGlossaryHtml` /
///    `constructSingleGlossaryHtml` / `createDefinitionImage`（见同名 .js）。无 node 时 skip。
/// ② 源码级——静态断言导出分支用 em、不再内联 `font-size:1px`，标签里没有序号。
/// ③ 三镜像——app 内弹窗 / 扩展 vendor 两份镜像与主文件在这些点上必须一致
///    （`tools/browser-extension/vendor/popup.js` 由 browser_extension_popup_parity_guard
///    另行守全量一致性，这里只保证本修复不漏改镜像）。
void main() {
  test(
    'mining glossary matches Yomitan (no ordinal, em-sized images) '
    '(executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/pages/popup_glossary_export_parity_test.js');
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
        reason: 'glossary export parity JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.js mirrors keep the Yomitan-shaped mining glossary', () {
    for (final String relative in _mirrors) {
      final File file = File(relative);
      expect(file.existsSync(), isTrue, reason: '$relative must exist');
      final String js = file.readAsStringSync();

      // BUG-1061: neither mining builder may prefix an ordinal to the label.
      expect(
        RegExp(r'label = tags \? `\(\$\{index\}').hasMatch(js),
        isFalse,
        reason: '$relative: the {glossary} label must not carry an ordinal '
            '(BUG-1061)',
      );
      expect(
        js.contains(r'let index = 0;'),
        isFalse,
        reason: '$relative: the self-invented glossary ordinal counter must be '
            'gone (BUG-1061)',
      );

      // BUG-1062: the export branch sizes in em; the popup branch keeps px.
      expect(
        js.contains(
            r'imageContainer.style.width = exporting ? `${usedWidth}em` : `${usedWidth}px`;'),
        isTrue,
        reason: '$relative: exported definition images must keep Yomitan em '
            'sizing while the popup keeps px (BUG-1062)',
      );
      expect(
        js.contains('font-size:1px'),
        isFalse,
        reason:
            '$relative: the exported image container must not pin an inline '
            'font-size:1px — it outranks note-type CSS and shrinks the card '
            'image (BUG-1062)',
      );
    }
  });
}

const List<String> _mirrors = <String>[
  'assets/popup/popup.js',
  'assets/browser_extension/vendor/popup.js',
  '../tools/browser-extension/vendor/popup.js',
];

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

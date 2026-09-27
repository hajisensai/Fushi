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
/// **BUG-1062 / BUG-2742 — 导出图片的盒子要与 Yomitan 卡片一致。**
/// Yomitan 导入词典时把 JSON 里的 `width`/`height` 存成 `preferredWidth`/`preferredHeight`，
/// `width`/`height` 换成媒体文件的**真实像素尺寸**；`structured-content-generator.js`
/// 导出时容器写 `width: {usedWidth}em`，并把 `structured-content-style.json` 内联进卡片：
/// 容器 `font-size:1px`，只有 `[data-size-units=em]` 才覆盖成 `1em`（用户库里 Yomitan
/// 真卡逐条核对过）。本仓库里没有真实尺寸，只声明一维的图（語彙力：`height:10` em）
/// 缺的宽度回落到 100，导出成 100em × 10em 的扁盒子，图被缩小、居中、各占一行。
/// 修复：`buildMinePayload` 制卡前先量真实尺寸，导出按 Yomitan 的算法定盒子；容器字号
/// 恢复 Yomitan 的 1px / 1em 规则（BUG-1062 曾一律钉成 1em，把非 em 图放大到卡片满宽）。
/// 弹窗路径维持 px（弹窗自己带那份 CSS，px 在那里才是对的）。
///
/// 三层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `constructGlossaryHtml` /
///    `constructSingleGlossaryHtml` / `createDefinitionImage` / `buildMinePayload`
///    （见同名 .js）。无 node 时 skip。
/// ② 源码级——静态断言制卡前先量尺寸、导出走 Yomitan 几何与字号规则，标签里没有序号。
/// ③ 三镜像——app 内弹窗 / 扩展 vendor 两份镜像与主文件在这些点上必须一致
///    （`tools/browser-extension/vendor/popup.js` 由 browser_extension_popup_parity_guard
///    另行守全量一致性，这里只保证本修复不漏改镜像）。
void main() {
  test(
    'mining glossary matches Yomitan (no ordinal, Yomitan-sized images) '
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

      // BUG-2742: the export box follows Yomitan's algorithm, fed with the real
      // image size measured before the glossary is rendered.
      final int probe = js.indexOf(
          'currentExportImageSizes = await probeExportImageSizes(idx);');
      expect(
        probe,
        isNonNegative,
        reason: '$relative: buildMinePayload must measure real image sizes '
            'before exporting (BUG-2742)',
      );
      expect(
        probe < js.indexOf('const glossary = constructGlossaryHtml(idx);'),
        isTrue,
        reason: '$relative: image sizes must be measured before the glossary '
            'is rendered (BUG-2742)',
      );
      expect(
        js.contains('resolveExportImageGeometry(data, currentExportImageSizes'),
        isTrue,
        reason: '$relative: exported images must use the Yomitan geometry '
            '(BUG-2742)',
      );
      // BUG-1062 / BUG-2742: Yomitan's inline container rule — 1em only for
      // em images (and the unsized SVG gaiji box), 1px otherwise.
      expect(
        js.contains(
            "const containerFontSize = useEmUnits || svgWithoutDimensions ? '1em' : '1px';"),
        isTrue,
        reason: '$relative: the exported image container font-size must follow '
            "Yomitan's structured-content-style.json (BUG-1062 / BUG-2742)",
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

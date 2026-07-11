import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-732：词典弹窗释义正文里 ruby 基字是**元素节点**（`<rb>` / `<span>` /
/// 嵌套 structured-content，明鏡等单语词典就这么写）时，振假名塌到基字上重叠。
///
/// 根因：`popup.js` 的 `postProcessRuby` 旧实现只包裹 `<ruby>` 的**裸文本节点**基字
/// （`node.nodeType !== Node.TEXT_NODE → continue`），元素基字被跳过 → 不生成
/// `.ruby-unit`；`popup.css` 的 `rt{position:absolute; top:0}` 只能锚到裸 `<ruby>`
/// （`line-height:1`、无 `padding-top` 预留）→ 读音塌到基字正上方重叠。回归引入点是
/// BUG-363：把纵向预留从 `ruby{line-height:2}`（所有 `<ruby>` 天然都有）迁到
/// `.ruby-unit{padding-top}`（只有裸文本基字才被生成）。
///
/// 修复（纯 JS）：`postProcessRuby` 对任意基字（裸文本 *或* 元素）都生成 `.ruby-unit`
/// 并把其 `<rt>` 移进去——裸文本原地 `textContent`，元素基字整体移入（保住划词选区
/// BUG-110/123/125/129）。三份镜像字节相同。
///
/// 两层守护：
/// ① 行为级——用 node 真执行 `popup.js` 的 `renderStructuredContent`+`postProcessRuby`，
///    断言 `<rb>`/`<span>`/嵌套基字的 `<rt>` 落进 `.ruby-unit`、不再直挂 `<ruby>`，且裸文本
///    与多汉字词（BUG-722）不回退。无 node 时 skip。
/// ② 源码级——静态扫描 popup.js，保证 `postProcessRuby` 不再用「`nodeType !== TEXT_NODE`
///    → continue」这个单一判据把元素基字整类跳过。
void main() {
  test(
    'element-base glossary ruby (<rb>/<span>/nested) still gets a per-base '
    '.ruby-unit so furigana never collapses onto the base (executes popup.js '
    'via node, BUG-732)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/pages/popup_glossary_ruby_element_base_test.js');
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
        reason: 'element-base ruby JS behavior test failed.\n'
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
      'postProcessRuby no longer skips element bases via a TEXT_NODE-only '
      'discriminator (BUG-732)', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    final int fn = js.indexOf('function postProcessRuby(');
    expect(fn, greaterThanOrEqualTo(0),
        reason: 'popup.js must define postProcessRuby');
    final int fnEnd = js.indexOf('\n}', fn);
    expect(fnEnd, greaterThan(fn));
    final String body = js.substring(fn, fnEnd);

    // The regression was a single `node.nodeType !== Node.TEXT_NODE` skip that
    // dropped EVERY element base (<rb>/<span>) out of the per-base wrapping. That
    // exact discriminator must be gone.
    expect(
      body.contains('node.nodeType !== Node.TEXT_NODE'),
      isFalse,
      reason: 'postProcessRuby must not skip element bases with a '
          'TEXT_NODE-only continue — element bases (明鏡 <rb>/<span>) need a '
          '.ruby-unit too (BUG-732)',
    );
    // Element bases are wrapped by MOVING the base element into the unit.
    expect(
      body.contains('unit.appendChild(node)'),
      isTrue,
      reason: 'postProcessRuby must move an element base INTO its .ruby-unit '
          '(unit.appendChild(node)) so the reading anchors per-base (BUG-732)',
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

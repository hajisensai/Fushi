import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-753 横排亚像素 pageStep 守卫（双保险：源码 + 真实 headless 几何）。
///
/// 根因（另一 agent 真机取证）：`getScrollContext` 横排分支用整数化的
/// `scrollEl.clientWidth` 算 `contentBox/pageStep`，但浏览器按亚像素布局多列
/// （真实列宽 1265.33，clientWidth 整数化成 1265），故 `pageStep` 比真实列周期短
/// δ≈0.33px/页 → paginate 的 `N×pageStep` 网格与浏览器真实列周期失配 → 第 N 页
/// 文字相对页框右移 N×δ 线性累积（长章数十 px = 「越翻越偏、边被切」）。
/// 修复：横排 contentBox 改取 `getComputedStyle(scrollEl).columnWidth`（浏览器
/// 解析后的亚像素 used column-width，与 column-gap 一起就是真实列周期）。
///
/// 现有 `reader_content_styles_test` / `reader_vertical_pitch_invariant_test`
/// 只断言 CSS 字符串结构 / 竖排代数，抓不到本 bug（横排在 headless 下整数与亚像素
/// 天然一致除非视口宽是小数）。这里两层守住：
///  ① 源码守卫：横排分支必须取亚像素 columnWidth 而非整数 clientWidth（撤掉即红）。
///  ② headless 几何守卫（有 node + Chrome 时真跑）：构造小数视口宽复现整数化损失，
///     断言旧 pageStep 残差随页数线性发散、新（亚像素）pageStep 残差恒 0，且用
///     真实 getClientRects 测得的列周期 == 亚像素 pageStep（非整数 pageStep）。
void main() {
  group('TODO-753 横排亚像素 pageStep 源码守卫', () {
    late String source;

    setUpAll(() {
      source = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();
    });

    test('横排 contentBox 取自亚像素 getComputedStyle().columnWidth（非整数 clientWidth）',
        () {
      // getScrollContext 必须解析 cs.columnWidth 并优先用它作横排 contentBox。
      expect(
        source
            .contains('var resolvedColumnWidth = parseFloat(cs.columnWidth);'),
        isTrue,
        reason: '横排必须读 getComputedStyle(scrollEl).columnWidth 的亚像素 used 列宽',
      );
      expect(
        source.contains('if (resolvedColumnWidth > 0) {') &&
            source.contains('contentBox = resolvedColumnWidth;'),
        isTrue,
        reason: 'columnWidth 解析成功时横排 contentBox 必须取亚像素列宽（消除 δ）',
      );
    });

    test('整数 clientWidth 仅作 columnWidth 解析失败时的兜底（不是横排默认路径）', () {
      // 只在 else 分支保留旧 clientWidth 兜底，绝不让它当横排主路径回归 bug。
      final int colWidthIdx = source
          .indexOf('var resolvedColumnWidth = parseFloat(cs.columnWidth);');
      final int fallbackIdx = source.indexOf(
        'contentBox = (scrollEl.clientWidth || this.pageWidth || window.innerWidth) - pl - pr;',
      );
      expect(colWidthIdx, greaterThan(0));
      expect(fallbackIdx, greaterThan(colWidthIdx),
          reason: 'clientWidth 兜底必须排在 columnWidth 主路径之后（else 分支）');
      // 兜底必须包在 else 里（columnWidth 不可用才走）。
      final String between = source.substring(colWidthIdx, fallbackIdx);
      expect(between.contains('} else {'), isTrue,
          reason: '整数 clientWidth 只能是 columnWidth 失败时的 else 兜底');
    });

    test('竖排路径未被改动（仍用注入 viewportHeight，不引入 columnWidth）', () {
      // 横排修复绝不能动竖排（TODO-734/773）：竖排 contentBox 仍由注入 V 推。
      expect(
        source.contains(
            'contentBox = (this.viewportHeight || scrollEl.clientHeight || window.innerHeight) - pt - pb;'),
        isTrue,
        reason: '竖排 contentBox 必须保持注入 viewportHeight 基准不变',
      );
    });

    test('pageStep/maxScroll 同源亚像素（无新双量纲）', () {
      // pageStep = contentBox + gap；maxScroll = totalSize - pageStep，二者同源。
      expect(source.contains('var pageStep = contentBox + gap;'), isTrue);
      expect(
          source.contains('var maxScroll = Math.max(0, totalSize - pageStep);'),
          isTrue,
          reason: 'maxScroll 必须用同一亚像素 pageStep，避免量纲分裂');
    });
  });

  group('TODO-753 横排残差 headless 几何守卫（真实 multicol getClientRects）', () {
    test('旧整数 pageStep 残差随页数线性发散；新亚像素 pageStep 残差恒 0', () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node 不在 PATH；跳过 headless 几何复测');
        return;
      }
      final File harness = File(
        'test/reader/reader_horizontal_pitch_harness.mjs',
      );
      expect(harness.existsSync(), isTrue,
          reason: 'headless harness ${harness.path} 必须存在');

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[harness.path],
        workingDirectory: Directory.current.path,
      );

      // 退出码 2 = 本机无 Chrome（headless 复测条件不满足），优雅跳过。
      if (result.exitCode == 2) {
        markTestSkipped('本机无 Chrome；跳过 headless 几何复测（源码守卫仍生效）');
        return;
      }

      expect(
        result.exitCode,
        0,
        reason: '横排 pitch harness 失败。\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('[HARNESS] all assertions passed'),
        reason: 'harness 必须达到成功标记（旧残差发散 + 新残差 0 + 测得列周期==亚像素 pageStep）',
      );
    });
  });
}

/// 解析可用的 `node` 可执行文件，找不到返回 null。
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
      // 继续尝试下一个候选名。
    }
  }
  return null;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 分段控件的段宽分配只走共用分宽一处（BUG-4205）。
///
/// 「页面里不许直接构造原生 SegmentedButton / CupertinoSlidingSegmentedControl /
/// CupertinoSegmentedControl / 框架 TabBar」已改由 analyzer 插件规则
/// `fushi_no_raw_design_controls`（packages/fushi_lints/lib/src/rules/
/// no_raw_design_controls.dart）按构造调用的静态类型判定。这里只剩那条规则表达
/// 不了的布局形状启发式（等宽再缩放、Expanded 等分、自绘胶囊不接 FushiSegmentRow），
/// 它们应在后续批次改成组件 API 层面的约束，而不是继续扩文本匹配。
void main() {
  // BUG-4205（反馈 GaI5uPQEbF「还有好多这种地方，根本性修复」）：横排分段的段宽
  // 只走 `fushiSegmentWidths` / `FushiSegmentRow` 一处。以前 MD3 连接式按钮组、
  // 墨水屏原生 SegmentedButton、Apple 退回形态、原生 CupertinoSlidingSegmentedControl
  // 各自「等宽取最宽段、放不下整体等比缩窄」，最长段先被截断。
  test('segment widths come from the single shared allocator', () {
    const String allocator =
        'lib/src/utils/components/fushi_segment_widths.dart';
    final List<File> files =
        Directory('lib/src')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'))
            .toList(growable: false)
          ..sort((File a, File b) => a.path.compareTo(b.path));
    expectScanScale(
      files.length,
      what: 'lib/src 下的 .dart',
      atLeast: 750,
      measured: 930,
    );
    // 「每段 = 最宽段」再整体缩放的另一份实现，或已删掉的等宽挤压参数。
    final RegExp equalWidest = RegExp(
      r'List<double>\.filled\([^;]*widest|(?<![A-Za-z0-9_])_?equalExtents\b',
    );
    // 最常见的手写等宽：循环生成段 / 页签，每个包一层 Expanded 等分整行（再配
    // ellipsis 或 FittedBox 兜底）——最长段先被省略或单独缩字号。审查实例：
    // 旧 MangaCropChoiceSegments、Apple 分段式页签 _FushiGlassTabBar 的铺满档。
    final RegExp equalSplit = RegExp(
      r'for\s*\([^\n]*\)\s*Expanded\(\s*child:\s*_?\w*(?:[sS]egment|[tT]ab)\w*\(',
    );
    // 自绘胶囊分段用的选中色只该出现在接了共用分宽的实现里：另写一份胶囊分段
    // 却不走 FushiSegmentRow，就是又一套段宽分配。
    final RegExp pillSegmentVisual = RegExp(
      r'(?<![A-Za-z0-9_])fushiPillSegmentSelected(?:Fill|Foreground)\(',
    );
    for (final String sample in <String>[
      'for (final MangaCropChoice choice in choices)\n'
          '              Expanded(child: segment(choice)),',
      'for (int i = 0; i < tabs.length; i++) Expanded(child: segment(i)),',
      'for (final T v in values) Expanded(child: _buildTab(v)),',
    ]) {
      expect(
        equalSplit.hasMatch(sample),
        isTrue,
        reason: 'equal-split guard must catch: $sample',
      );
    }
    final List<String> offenders = <String>[];
    for (final File file in files) {
      final String path = file.path.replaceAll(r'\', '/');
      final String source = maskComments(file.readAsStringSync());
      if (path != allocator && equalWidest.hasMatch(source)) {
        offenders.add('$path: equal-width-then-shrink segment layout');
      }
      if (equalSplit.hasMatch(source)) {
        offenders.add('$path: Expanded equal-split segment / tab row');
      }
      if (pillSegmentVisual.hasMatch(source) &&
          !source.contains('FushiSegmentRow(')) {
        offenders.add(
          '$path: hand-rolled pill segments without FushiSegmentRow',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Lay out segments with FushiSegmentRow / fushiSegmentWidths '
          '($allocator):\n${offenders.join('\n')}',
    );

    // 每条横排分段实现都确实接在共用分宽上。
    const Map<String, String> wired = <String, String>{
      'lib/src/utils/components/fushi_pill_segmented_button.dart':
          'FushiSegmentRow(',
      'lib/src/utils/components/glass/fushi_expressive.dart':
          'FushiSegmentRow(',
      'lib/src/utils/components/glass/fushi_glass_toggles.dart':
          'FushiSegmentRow(',
      // Apple 分段式页签（_FushiGlassTabBar）的铺满档。
      'lib/src/utils/components/glass/fushi_glass_bars.dart':
          'FushiSegmentRow(',
    };
    for (final MapEntry<String, String> e in wired.entries) {
      expect(
        maskComments(File(e.key).readAsStringSync()),
        contains(e.value),
        reason: '${e.key} must lay out its segments with ${e.value}',
      );
    }
    expect(
      maskComments(
        File(
          'lib/src/utils/components/glass/fushi_glass_toggles.dart',
        ).readAsStringSync(),
      ),
      contains('fushiSegmentWidths('),
      reason: 'FushiAppleSegmentedControl must allocate via fushiSegmentWidths',
    );
  });
}

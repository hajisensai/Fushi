import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 分段选择一律用设计系统组件（用户 2026-10-16：「分段选择器还是老样式，用 m3e，写进规则吧都用
/// 新的」）。页面里直接构造 Flutter 原生 [SegmentedButton] 会绕过设计系统分派，在 Material 下画出
/// 旧版 MD3 的描边分段，而不是 M3E 胶囊分段；Apple 设计系统下也拿不到 iOS 分段控件。
///
/// 该用的入口：
/// - `adaptiveSegmentedButton(...)`（`lib/src/utils/adaptive/adaptive_widgets.dart`）：Material =
///   M3E 胶囊分段（`FushiPillSegmentedButton`）、Apple = iOS 分段；设置行用
///   `AdaptiveSettingsSegmentedRow`，它内部也走这条。
/// - `FushiSegmentedButton`（多选、竖排、允许空选等 `SegmentedButton` 同参需求）：Material =
///   M3E 连接式按钮组（`FushiConnectedButtonGroup`）。
///
/// 只有组件实现自己可以碰原生 `SegmentedButton`（下面的豁免表，每条写明理由）。
void main() {
  const Map<String, String> allowed = <String, String>{
    'lib/src/utils/components/fushi_pill_segmented_button.dart':
        'The M3E capsule segmented control is implemented as a SegmentedButton '
        'subclass (extends / State<SegmentedButton<T>>).',
  };
  // `SegmentedButton(` / `SegmentedButton<`，前面不是标识符字符（排除 FushiSegmentedButton、
  // FushiPillSegmentedButton 等）；`SegmentedButton.styleFrom` 这类静态成员不算构造。
  final RegExp raw = RegExp(r'(?<![A-Za-z0-9_])SegmentedButton\s*[<(]');

  test(
    'pages build segmented controls through the design-system components',
    () {
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
      final List<String> offenders = <String>[];
      final Set<String> usedAllowances = <String>{};
      for (final File file in files) {
        final String path = file.path.replaceAll(r'\', '/');
        final String source = maskComments(file.readAsStringSync());
        if (!raw.hasMatch(source)) continue;
        if (allowed.containsKey(path)) {
          usedAllowances.add(path);
          continue;
        }
        final int line =
            '\n'
                .allMatches(source.substring(0, raw.firstMatch(source)!.start))
                .length +
            1;
        offenders.add('$path:$line');
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Use adaptiveSegmentedButton (M3E capsule / iOS segmented) or '
            'FushiSegmentedButton (M3E connected button group) instead of a raw '
            'SegmentedButton:\n${offenders.join('\n')}',
      );
      expect(
        usedAllowances,
        allowed.keys.toSet(),
        reason:
            'stale allowance: the file no longer builds a raw SegmentedButton',
      );
    },
  );

  // BUG-4130（反馈 GaI5uPQEbF「还有好多这种地方，根本性修复」）：横排分段的段宽
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
    // 原生 Cupertino 分段：等宽、不接共用分宽（adaptiveSegmentedButton 的
    // Cupertino 平台分支以前就是它）。
    final RegExp cupertinoSegments = RegExp(
      r'(?<![A-Za-z0-9_])Cupertino(Sliding)?SegmentedControl\s*[<(]',
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
      if (cupertinoSegments.hasMatch(source)) {
        offenders.add('$path: CupertinoSlidingSegmentedControl');
      }
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

  // BUG-4130 未收口的那条路径（PR #2987 审查）：MD3 的 FushiTabBar 页签（含分段
  // 胶囊 _FushiM3eSegmentedTabs）用框架 TabBar 的非滚动铺满档，框架
  // （material_ui 1.10.0 tabs.dart:2180）把每个页签包一层 Expanded 等分，不走
  // fushiSegmentWidths，最长页签仍会先显示不全。根治要把 MD3 页签换成自绘
  // （推翻「MD3 用框架 TabBar」），待拍板。在那之前把框架 TabBar 钉死在
  // FushiTabBar 这一处已知豁免：别处新写的框架 TabBar 一律判红；这里的个数
  // 变了（换成自绘 / 删掉）就同步更新本条与 BUG-4130。
  test('framework TabBar (equal-split fill) stays confined to FushiTabBar', () {
    const String exemption =
        'lib/src/utils/components/glass/fushi_glass_bars.dart';
    const int exemptionCount = 4;
    final RegExp frameworkTabBar = RegExp(
      r'(?<![A-Za-z0-9_.])TabBar(?:\.secondary)?\(',
    );
    expect(frameworkTabBar.hasMatch('return TabBar('), isTrue);
    expect(frameworkTabBar.hasMatch('=> TabBar.secondary('), isTrue);
    expect(frameworkTabBar.hasMatch('FushiTabBar('), isFalse);
    expect(frameworkTabBar.hasMatch('FushiTabBar.secondary('), isFalse);
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
    final List<String> offenders = <String>[];
    int exempted = 0;
    for (final File file in files) {
      final String path = file.path.replaceAll(r'\', '/');
      final int hits = frameworkTabBar
          .allMatches(maskComments(file.readAsStringSync()))
          .length;
      if (hits == 0) continue;
      if (path == exemption) {
        exempted = hits;
      } else {
        offenders.add('$path: $hits framework TabBar construction(s)');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use FushiTabBar; framework TabBar fill splits tabs equally '
          '(BUG-4130):\n${offenders.join('\n')}',
    );
    expect(
      exempted,
      exemptionCount,
      reason:
          '$exemption: framework TabBar construction count changed; if MD3 '
          'tabs no longer use the framework TabBar, drop this exemption and '
          'update BUG-4130',
    );
  });
}

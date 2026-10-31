import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:fushi/src/utils/components/fushi_segment_widths.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 GaI5uPQEbF：音乐「信号路径」弹窗的睡眠定时分段把「播完本曲」截成
/// 「播完…」，旁边「15 分钟」段里还空着留白。根因是两套设计系统的分段都
/// 「各段等宽、放不下时等比缩窄」——最长段先被省略。现在段宽统一走
/// [fushiSegmentWidths]：等宽 → 按内容分宽 → 收内边距 → 削峰（MD3 折行）。
void main() {
  double sum(List<double> v) => v.fold(0, (double a, double b) => a + b);

  group('fushiSegmentWidths', () {
    const List<double> content = <double>[44, 72, 86, 86, 86];
    const List<double> extra = <double>[16, 16, 16, 16, 16];

    test('放得下等宽：各段取最宽段的自然宽，不撑满', () {
      final List<double> w = fushiSegmentWidths(
        content: content,
        extra: extra,
        available: 1000,
      );
      expect(w, everyElement(102));
    });

    test('fill：放得下时等分可用宽度', () {
      final List<double> w = fushiSegmentWidths(
        content: content,
        extra: extra,
        available: 1000,
        fill: true,
      );
      expect(w, everyElement(200));
    });

    test('无界宽：按等宽自然宽', () {
      final List<double> w = fushiSegmentWidths(
        content: content,
        extra: extra,
        available: double.infinity,
      );
      expect(w, everyElement(102));
    });

    test('等宽放不下、自然宽放得下：窄段抬平，宽段保持自然宽，总宽 = 可用宽', () {
      // 自然宽 60 / 88 / 102×3 = 454。
      final List<double> w = fushiSegmentWidths(
        content: content,
        extra: extra,
        available: 480,
      );
      expect(sum(w), closeTo(480, 1e-9));
      for (int i = 0; i < w.length; i++) {
        expect(w[i], greaterThanOrEqualTo(content[i] + extra[i] - 1e-9));
      }
      // 水位 86：只有最窄段（60）被抬起，88 / 102 保持自然宽。
      expect(w, <double>[86, 88, 102, 102, 102]);
    });

    test('自然宽也放不下：按比例收内边距，内容一律不截断', () {
      final List<double> w = fushiSegmentWidths(
        content: content,
        extra: extra,
        available: 400,
      );
      expect(sum(w), closeTo(400, 1e-9));
      for (int i = 0; i < w.length; i++) {
        expect(w[i], greaterThanOrEqualTo(content[i] - 1e-9));
      }
    });

    test('最小内边距都放不下：只削最宽的段，短段保持完整', () {
      final List<double> w = fushiSegmentWidths(
        content: content,
        extra: extra,
        available: 300,
      );
      expect(sum(w), closeTo(300, 1e-9));
      // 削峰水位 64：44 完整保留，其余（72 / 86）削到 64。
      expect(w[0], 44);
      for (int i = 1; i < w.length; i++) {
        expect(w[i], closeTo(64, 1e-9));
      }
    });
  });

  // flutter_test 字体每字 1em：「15 分钟」= 5em。
  const List<String> sleepLabels = <String>[
    '关闭',
    '播完本曲',
    '15 分钟',
    '30 分钟',
    '60 分钟',
  ];

  Future<void> pumpStrip(
    WidgetTester tester, {
    required double width,
    required bool glass,
    bool loose = false,
  }) async {
    Widget strip(BuildContext context) => adaptiveSegmentedButton<int>(
      context: context,
      segments: <ButtonSegment<int>>[
        for (int i = 0; i < sleepLabels.length; i++)
          ButtonSegment<int>(value: i, label: Text(sleepLabels[i])),
      ],
      selected: const <int>{0},
      onSelectionChanged: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: glass,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: loose
                    ? Align(child: Builder(builder: strip))
                    : Builder(builder: strip),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<RenderParagraph> labelParagraphs(WidgetTester tester, Finder root) {
    return <RenderParagraph>[
      for (final String label in sleepLabels)
        tester.renderObject<RenderParagraph>(
          find.descendant(of: root, matching: find.text(label)),
        ),
    ];
  }

  testWidgets('MD3 胶囊分段：放不下等宽时按内容分宽，「播完本曲」完整单行', (WidgetTester tester) async {
    await pumpStrip(tester, width: 400, glass: false);
    final Finder root = find.byType(FushiPillSegmentedButton<int>);
    expect(root, findsOneWidget);
    for (final RenderParagraph p in labelParagraphs(tester, root)) {
      expect(
        p.didExceedMaxLines,
        isFalse,
        reason: '「${p.text.toPlainText()}」被截断',
      );
      // 单行：高度不超过一行（labelLarge 14 × 行高 1.2）。
      expect(p.size.height, lessThan(14 * 1.2 * 1.5));
    }
    expect(tester.getSize(root).width, lessThanOrEqualTo(400));
  });

  testWidgets('MD3 胶囊分段：极窄时最长段折成两行而不是省略号', (WidgetTester tester) async {
    await pumpStrip(tester, width: 300, glass: false);
    final Finder root = find.byType(FushiPillSegmentedButton<int>);
    for (final RenderParagraph p in labelParagraphs(tester, root)) {
      expect(
        p.didExceedMaxLines,
        isFalse,
        reason: '「${p.text.toPlainText()}」被截断',
      );
    }
    expect(tester.takeException(), isNull);
    expect(tester.getSize(root).width, lessThanOrEqualTo(300));
  });

  testWidgets('MD3 胶囊分段：放得下时仍等宽（选中胶囊切换不跳宽）', (WidgetTester tester) async {
    await pumpStrip(tester, width: 800, glass: false, loose: true);
    final List<double> widths = <double>[
      for (final String label in sleepLabels)
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .width,
    ];
    expect(widths.toSet(), hasLength(1));
  });

  testWidgets('MD3 胶囊分段：紧约束宿主下等分撑满（与旧行为一致）', (WidgetTester tester) async {
    await pumpStrip(tester, width: 800, glass: false);
    final List<double> widths = <double>[
      for (final String label in sleepLabels)
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .width,
    ];
    expect(widths.toSet(), hasLength(1));
    expect(
      sum(widths),
      closeTo(800 - 2 * FushiPillSegmentedButton.trackPadding, 0.01),
    );
  });

  testWidgets('Apple 分段：放不下等宽时按内容分宽，「播完本曲」不被截断', (WidgetTester tester) async {
    await pumpStrip(tester, width: 400, glass: true);
    final Finder root = find.byType(FushiAppleSegmentedControl);
    expect(root, findsOneWidget);
    for (final RenderParagraph p in labelParagraphs(tester, root)) {
      expect(
        p.didExceedMaxLines,
        isFalse,
        reason: '「${p.text.toPlainText()}」被截断',
      );
    }
  });
}

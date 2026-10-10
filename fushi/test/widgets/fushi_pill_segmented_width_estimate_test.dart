import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 审查遗留：MD3 分段（[FushiPillSegmentedButton]）实际每段 = 文案 + 2×16（纯图标
/// 段 18 + 2×12），再加轨道 2×4；而 [FushiSegmentedStrip] 按 Material
/// SegmentedButton 的「每段 +28」估宽、并把条钉在估宽上——每段少算 4、整条少算 8，
/// 短拉丁文标签的段被钳窄后省略号截断。估宽与绘制必须出自同一组常量。
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  List<RenderParagraph> paragraphsUnder(WidgetTester tester, Finder root) =>
      tester
          .renderObjectList<RenderParagraph>(
            find.descendant(of: root, matching: find.byType(RichText)),
          )
          .toList();

  testWidgets('FushiSegmentedStrip（MD3）：短标签不被估宽钳窄截断', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        FushiSegmentedStrip<int>(
          // flutter_test 字体每字 1em，与估宽对 CJK 的 1em 一致——用 CJK
          // 文案把误差隔离到「每段外框」这一项上。
          segments: const <ButtonSegment<int>>[
            ButtonSegment<int>(value: 0, label: Text('开')),
            ButtonSegment<int>(value: 1, label: Text('关')),
            ButtonSegment<int>(value: 2, label: Text('自动')),
          ],
          selected: 0,
          onChanged: (_) {},
        ),
      ),
    );
    final Finder pill = find.byType(FushiPillSegmentedButton<int>);
    expect(pill, findsOneWidget);
    final List<RenderParagraph> labels = paragraphsUnder(tester, pill);
    expect(labels, hasLength(3));
    for (final RenderParagraph p in labels) {
      expect(
        p.didExceedMaxLines,
        isFalse,
        reason: '「${p.text.toPlainText()}」被截断：条宽被钉在偏小的估宽上',
      );
    }
  });

  testWidgets('估宽 = 胶囊分段的真实固有宽（同一组几何常量）', (WidgetTester tester) async {
    late double estimated;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (BuildContext context) {
            estimated = estimateSegmentedStripWidth(
              segmentLabels: const <String?>[null, null, null],
              fontSize: 14,
              textScaleFactor: 1,
              metrics: SegmentedStripMetrics.of(context),
            );
            return adaptiveSegmentedButton<int>(
              context: context,
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, icon: Icon(Icons.light_mode)),
                ButtonSegment<int>(value: 1, icon: Icon(Icons.brightness_auto)),
                ButtonSegment<int>(value: 2, icon: Icon(Icons.dark_mode)),
              ],
              selected: const <int>{1},
              onSelectionChanged: (_) {},
            );
          },
        ),
      ),
    );
    final double actual = tester
        .getSize(find.byType(FushiPillSegmentedButton<int>))
        .width;
    expect(estimated, moreOrLessEquals(actual, epsilon: 0.01));
  });

  test('胶囊几何：带图标的文字段计入图标与间距', () {
    const SegmentedStripMetrics m = SegmentedStripMetrics.pill;
    final double plain = segmentedStripCellWidth(
      segmentLabels: const <String?>['Auto'],
      fontSize: 14,
      textScaleFactor: 1,
      metrics: m,
    );
    final double withIcon = segmentedStripCellWidth(
      segmentLabels: const <String?>['Auto'],
      segmentHasIcon: const <bool>[true],
      fontSize: 14,
      textScaleFactor: 1,
      metrics: m,
    );
    expect(
      withIcon - plain,
      FushiPillSegmentedButton.iconSize + FushiPillSegmentedButton.iconLabelGap,
    );
  });
}

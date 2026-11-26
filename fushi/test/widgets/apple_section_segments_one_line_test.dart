import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';

/// 用户 2026-11-26：阅读设置面板（Apple 设计）顶部五个分区只显示三个，其余收进
/// 「⌄」，而 MD3 同宽下五个都摆得下。根因：Apple 分段只按「等宽段」估宽，等宽
/// 放不下就直接溢出；控件本身早有「按内容分宽 → 收内边距」的退让
/// （fushiSegmentWidths），没被用上。
///
/// 同一天的第二条：Apple 表单行里的数值设置（词典字号）是一整行宽的输入框、
/// 单位写在框里，不像系统设置；改成左标题 + 右侧窄框右对齐、单位在框外。
void main() {
  ThemeData theme() => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: true,
  );

  const List<String> readerTabs = <String>[
    '歌词模式',
    '主题与字体',
    '翻页与手势',
    '有声书',
    '查词',
  ];

  Future<void> pumpSegments(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: FushiGlassScope(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: LibrarySectionTabs<int>(
                  tabs: <LibrarySectionTab<int>>[
                    for (int i = 0; i < readerTabs.length; i++)
                      LibrarySectionTab<int>(value: i, label: readerTabs[i]),
                  ],
                  selected: 0,
                  onChanged: (int _) {},
                  focusIdPrefix: 'apple-one-line-test',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('等宽放不下但按内容放得下：五段全排一行、文字完整、无「更多」', (WidgetTester tester) async {
    // 400：五个等宽段（最宽 5 字 + 28）放不下，按各自文字 + 最小内边距放得下。
    await pumpSegments(tester, 400);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(CupertinoIcons.chevron_down), findsNothing);
    for (final String label in readerTabs) {
      final Finder text = find.text(label);
      expect(text, findsOneWidget, reason: '「$label」被收起');
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        text,
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: '「$label」被省略截断');
      final Rect rect = tester.getRect(text);
      expect(rect.right, lessThanOrEqualTo(400.5), reason: '「$label」出界');
    }
  });

  testWidgets('按内容也放不下时仍收进「更多」', (WidgetTester tester) async {
    await pumpSegments(tester, 200);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(CupertinoIcons.chevron_down), findsOneWidget);
  });

  testWidgets('Apple 表单行的数值字段：窄框右对齐、单位在框外', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final TextEditingController controller = TextEditingController(
      text: '17.0',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: FushiGlassScope(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 480,
                child: FushiAppleFormRowScope(
                  label: '词典字号',
                  child: FushiTextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    suffixText: '像素',
                    labelText: '词典字号',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final Finder editable = find.byType(EditableText);
    final EditableText widget = tester.widget<EditableText>(editable);
    expect(widget.textAlign, TextAlign.end);
    final Rect field = tester.getRect(editable);
    expect(field.width, lessThanOrEqualTo(100), reason: '数值框不应撑满整行');

    final Rect unit = tester.getRect(find.text('像素'));
    expect(unit.left, greaterThanOrEqualTo(field.right), reason: '单位应在框外右侧');
    final Rect title = tester.getRect(find.text('词典字号'));
    expect(title.right, lessThan(field.left));
  });
}

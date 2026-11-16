import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadPanel;
import 'package:material_ui/material_ui.dart';

/// 设计稿 V3：页头与嵌套工具行（库页标签条）是同一块吸顶面。只有根层底板开
/// 背景模糊；嵌套层（`backdropBlur: false`）画不透明同色填充，不再自己开一块
/// `ClipRect + BackdropFilter`——两块磨砂的模糊边界会在接缝处叠出一条分隔线。
void main() {
  Future<void> pump(WidgetTester tester, {required bool backdropBlur}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: FushiMastheadPanel(
                  height: 80,
                  progress: 1,
                  backdropBlur: backdropBlur,
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('根层底板开背景模糊', (WidgetTester tester) async {
    await pump(tester, backdropBlur: true);
    expect(
      find.descendant(
        of: find.byType(FushiMastheadPanel),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
  });

  testWidgets('嵌套层底板不开背景模糊、整块不透明同色', (WidgetTester tester) async {
    await pump(tester, backdropBlur: false);
    expect(
      find.descendant(
        of: find.byType(FushiMastheadPanel),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    final ColoredBox fill = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(FushiMastheadPanel),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(fill.color.a, 1);
    expect(tester.getSize(find.byType(FushiMastheadPanel)).height, 80);
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadSegmentedTabs;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:material_ui/material_ui.dart';

/// 设计稿 V4：页头二级连体按钮组（视频库「首页 / 系列 / 全部视频 / 媒体服务器」、
/// 书架 / 漫画 / 游戏的二级页签）四项同形同高，只靠颜色区分选中——选中项不再
/// 变成全圆药丸，按压也不改变宽高。
void main() {
  const List<String> labels = <String>['A', 'B', 'C', 'D'];

  Future<void> pump(WidgetTester tester, String selected) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FushiMastheadSegmentedTabs<String>(
              tabs: <LibrarySectionTab<String>>[
                for (final String l in labels)
                  LibrarySectionTab<String>(value: l, label: l),
              ],
              selected: selected,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder face(String label) => find
      .ancestor(of: find.text(label), matching: find.byType(DecoratedBox))
      .first;

  ShapeBorder shapeOf(WidgetTester tester, String label) =>
      (tester.widget<DecoratedBox>(face(label)).decoration as ShapeDecoration)
          .shape;

  testWidgets('选中的中间项与未选中的中间项同形同高', (WidgetTester tester) async {
    await pump(tester, 'B');
    expect(shapeOf(tester, 'B'), shapeOf(tester, 'C'));
    expect(tester.getSize(face('B')).height, tester.getSize(face('C')).height);
    expect(tester.getSize(face('A')).height, tester.getSize(face('D')).height);
    expect(tester.getSize(face('A')).height, tester.getSize(face('B')).height);
  });

  testWidgets('按压不改变按钮的布局宽高', (WidgetTester tester) async {
    await pump(tester, 'A');
    final Size rest = tester.getSize(face('C'));
    final TestGesture pointer = await tester.startGesture(
      tester.getCenter(find.text('C')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(face('C')), rest);
    await pointer.up();
    await tester.pumpAndSettle();
  });
}

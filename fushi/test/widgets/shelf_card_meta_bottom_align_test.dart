import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 库页网格同一行的卡片：标题一行与两行的卡，副行与进度条必须落在同一高度
/// （用户 2026-10-27 截图：单行标题的卡底部整体上移、与两行标题的卡错位）。
void main() {
  testWidgets('short and wrapped titles keep subtitle and progress aligned', (
    WidgetTester tester,
  ) async {
    Widget card(String title, Key key) => SizedBox(
      width: 160,
      child: ShelfCardMeta(
        key: key,
        title: title,
        subtitle: 'sub $title',
        progress: 0.5,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              card('Short', const ValueKey<String>('short')),
              card(
                'A much longer title that certainly wraps onto a second line',
                const ValueKey<String>('long'),
              ),
            ],
          ),
        ),
      ),
    );

    final double shortSub = tester.getTopLeft(find.text('sub Short')).dy;
    final double longSub = tester
        .getTopLeft(find.textContaining('sub A much longer'))
        .dy;
    expect(shortSub, longSub);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('short'))).height,
      tester.getSize(find.byKey(const ValueKey<String>('long'))).height,
    );
  });
}

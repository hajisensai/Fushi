import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';

enum _Status { unread, reading, finished }

/// 库页搜索栏下拉筛选：null = 全部。[PopupMenuButton] 把 null 结果当「取消」，
/// 「全部」项若直接用 null 当菜单值就永远选不中——筛过一次再也回不到全部。
void main() {
  Future<List<_Status?>> pumpDropdown(
    WidgetTester tester, {
    required _Status? value,
  }) async {
    final List<_Status?> selected = <_Status?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LibraryFilterDropdown<_Status>(
              value: value,
              options: _Status.values,
              labelOf: (_Status s) => 'label-${s.name}',
              title: 'Status',
              allLabel: 'All',
              onSelected: selected.add,
            ),
          ),
        ),
      ),
    );
    return selected;
  }

  testWidgets('未筛选时 chip 显示维度名，选中某档回调该值', (WidgetTester tester) async {
    final List<_Status?> selected = await pumpDropdown(tester, value: null);
    expect(find.text('Status'), findsOneWidget);

    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
    await tester.tap(find.text('label-finished'));
    await tester.pumpAndSettle();

    expect(selected, <_Status?>[_Status.finished]);
  });

  testWidgets('已筛选时 chip 显示当前档，选「全部」回调 null', (WidgetTester tester) async {
    final List<_Status?> selected = await pumpDropdown(
      tester,
      value: _Status.reading,
    );
    expect(find.text('label-reading'), findsOneWidget);
    expect(find.text('Status'), findsNothing);

    await tester.tap(find.text('label-reading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(selected, <_Status?>[null]);
  });
}

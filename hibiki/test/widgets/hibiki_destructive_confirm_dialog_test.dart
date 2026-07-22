import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_destructive_confirm_dialog.dart';

void main() {
  Future<HibikiDestructiveConfirmResult?>? dialogResult;

  Future<void> openDialog(
    WidgetTester tester, {
    String? checkboxLabel,
  }) async {
    dialogResult = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () {
              dialogResult = showDialog<HibikiDestructiveConfirmResult>(
                context: context,
                builder: (_) => HibikiDestructiveConfirmDialog(
                  title: '删除书籍',
                  message: '此操作不可撤销。',
                  checkboxLabel: checkboxLabel,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('取消 pop null', (WidgetTester tester) async {
    await openDialog(tester);
    expect(find.text('删除书籍'), findsOneWidget);
    expect(find.text('此操作不可撤销。'), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(await dialogResult, isNull);
  });

  testWidgets('确认 pop 结果（无勾选项时 checked=false）', (WidgetTester tester) async {
    await openDialog(tester);
    await tester.tap(find.text('DELETE'));
    await tester.pumpAndSettle();
    final HibikiDestructiveConfirmResult? value = await dialogResult;
    expect(value, isNotNull);
    expect(value!.checked, isFalse);
  });

  testWidgets('勾选行整行可点，确认后 checked 随之', (WidgetTester tester) async {
    await openDialog(tester, checkboxLabel: '连同本体删除');
    expect(find.text('连同本体删除'), findsOneWidget);

    await tester.tap(find.text('连同本体删除'));
    await tester.pumpAndSettle();
    final Checkbox checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(checkbox.value, isTrue);

    await tester.tap(find.text('DELETE'));
    await tester.pumpAndSettle();
    expect((await dialogResult)!.checked, isTrue);
  });
}

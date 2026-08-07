import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';

void main() {
  Future<FushiDestructiveConfirmResult?>? dialogResult;

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
              dialogResult = showDialog<FushiDestructiveConfirmResult>(
                context: context,
                builder: (_) => FushiDestructiveConfirmDialog(
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
    final FushiDestructiveConfirmResult? value = await dialogResult;
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

  // BUG-1291：勾选文案是整句解释而非标题短语，被 [FushiListItem] 默认的
  // titleMaxLines: 1 + ellipsis 切成「…保留你的原始视…」，括号里的免责说明
  // （最需要看清的那半句）整段看不到。
  //
  // 断言分两半，缺一不可：
  // ① didExceedMaxLines == false —— 文案没有被省略号截断；
  // ② 长文案比短文案更高 —— 证明在这个宽度下**确实发生了换行**。少了 ②，
  //    哪天对话框变宽到一行放得下，maxLines 退回 1 也照样绿（假绿）。
  testWidgets('BUG-1291 长勾选文案换行显示完整，不被省略号截断', (WidgetTester tester) async {
    const String longLabel = '同时删除其中的视频（保留你的原始视频文件）';
    await openDialog(tester, checkboxLabel: longLabel);

    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(find.text(longLabel));
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '勾选文案被截断了，用户看不到括号里的免责说明',
    );
    final double longHeight = tester.getSize(find.text(longLabel)).height;

    // 同一个 [MaterialApp] element 会被复用，上一个 dialog route 仍压在
    // Navigator 栈上会挡住 open 按钮，先关掉再开第二个。
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    const String shortLabel = '删除';
    await openDialog(tester, checkboxLabel: shortLabel);
    final double shortHeight = tester.getSize(find.text(shortLabel)).height;

    expect(
      longHeight,
      greaterThan(shortHeight),
      reason: '此宽度下长文案没有换行，本用例已失去守卫意义，需重新挑选文案或宽度',
    );
  });
}

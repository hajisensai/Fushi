import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import '../helpers/glass_unwrap.dart';

void main() {
  Future<FushiDestructiveConfirmResult?>? dialogResult;

  Future<void> openDialog(
    WidgetTester tester, {
    String? checkboxLabel,
    String? statisticsSubtitle,
    DeletionDisclosure? checkedDisclosure,
    String? deleteSubscriptionsLabel,
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
                  statisticsSubtitle: statisticsSubtitle,
                  checkedDisclosure: checkedDisclosure,
                  deleteSubscriptionsLabel: deleteSubscriptionsLabel,
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
    final Checkbox checkbox = tester.widget<Checkbox>(glassUnwrap<Checkbox>(find.byType(Checkbox)));
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

  // 防呆闸（2026-09-10 起的共享能力，首个消费者是统计页「清除全部会话」）。与默认
  // 的「可选项」勾选是两种语义：可选项决定**删多少**（不勾也能删），防呆闸决定
  // **能不能删**（不勾按钮真禁用）。别把两者的断言混在一起写。
  group('requireCheckboxToConfirm 防呆闸', () {
    Future<void> open(
      WidgetTester tester, {
      required bool gate,
      String? checkboxLabel = '我确认删除这 37 条记录',
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
                    title: '清除全部会话记录',
                    message: '此操作不可撤销。',
                    checkboxLabel: checkboxLabel,
                    requireCheckboxToConfirm: gate,
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

    Finder confirm() => find.widgetWithText(FilledButton, 'DELETE');

    test('开闸却没给勾选项 = 一颗永远点不动的按钮，构造期就 assert', () {
      expect(
        () => FushiDestructiveConfirmDialog(
          title: 't',
          message: 'm',
          requireCheckboxToConfirm: true,
        ),
        throwsAssertionError,
      );
    });

    testWidgets('开闸：未勾选时确认按钮真禁用（onPressed == null），勾上才可点', (
      WidgetTester tester,
    ) async {
      await open(tester, gate: true);
      expect(
        tester.widget<FilledButton>(glassUnwrap<FilledButton>(confirm())).onPressed,
        isNull,
        reason: '不是「点了没反应」，是按钮本身禁用',
      );

      await tester.tap(find.text('我确认删除这 37 条记录'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(glassUnwrap<FilledButton>(confirm())).onPressed, isNotNull);

      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect((await dialogResult)!.checked, isTrue);
    });

    testWidgets('不开闸（默认）：有勾选项也照样能直接确认，checked 如实回传 false', (
      WidgetTester tester,
    ) async {
      await open(tester, gate: false);
      expect(
        tester.widget<FilledButton>(glassUnwrap<FilledButton>(confirm())).onPressed,
        isNotNull,
        reason: '可选项决定删多少，不决定能不能删',
      );
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect((await dialogResult)!.checked, isFalse);
    });
  });

  group('「同时删除统计数据」无主勾选时独立成行（游戏库移除游戏）', () {
    testWidgets('默认不勾：直接确认 deleteStatistics=false', (
      WidgetTester tester,
    ) async {
      await openDialog(tester, statisticsSubtitle: '游戏统计口径');
      expect(find.text(t.delete_statistics), findsOneWidget,
          reason: '没有主勾选也要摆出统计行');

      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      final FushiDestructiveConfirmResult value = (await dialogResult)!;
      expect(value.checked, isFalse);
      expect(value.deleteStatistics, isFalse);
    });

    testWidgets('勾上后确认 deleteStatistics=true', (WidgetTester tester) async {
      await openDialog(tester, statisticsSubtitle: '游戏统计口径');
      await tester.tap(find.text(t.delete_statistics));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      expect((await dialogResult)!.deleteStatistics, isTrue);
    });

    testWidgets('有主勾选时仍挂在主勾选之下：主勾选未勾就不出现', (
      WidgetTester tester,
    ) async {
      await openDialog(tester,
          checkboxLabel: '连同本体删除', statisticsSubtitle: '统计口径');
      expect(find.text(t.delete_statistics), findsNothing);
      await tester.tap(find.text('连同本体删除'));
      await tester.pumpAndSettle();
      expect(find.text(t.delete_statistics), findsOneWidget);
    });

    testWidgets('合集删除：勾「同时删除统计数据」后披露把「阅读统计」翻到会被删除', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.reset);
      await openDialog(
        tester,
        checkboxLabel: '连同其中的书一起删除',
        statisticsSubtitle: '统计口径',
        checkedDisclosure: buildDeletionDisclosure(
          target: DeletionDisclosureTarget.shelfBook,
        ),
      );
      await tester.tap(find.text('连同其中的书一起删除'));
      await tester.pumpAndSettle();
      DeletionDisclosure shown() => tester
          .widget<DeletionDisclosureView>(find.byType(DeletionDisclosureView))
          .disclosure;
      expect(shown().willKeep, contains(t.delete_disclosure_stats_kept));
      expect(
          shown().willDelete, isNot(contains(t.delete_disclosure_stats_kept)));

      await tester.tap(find.text(t.delete_statistics));
      await tester.pumpAndSettle();
      expect(shown().willDelete, contains(t.delete_disclosure_stats_kept));
      expect(shown().willKeep, isNot(contains(t.delete_disclosure_stats_kept)),
          reason: '勾了删统计还把它列在「会被保留」就是在说反话（BUG-1305 同型）');

      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      final FushiDestructiveConfirmResult value = (await dialogResult)!;
      expect(value.checked, isTrue);
      expect(value.deleteStatistics, isTrue);
    });
  });

  group('删合集连带订阅', () {
    testWidgets('没传文案就不摆这一行，结果恒为 false', (WidgetTester tester) async {
      await openDialog(tester);
      expect(
        find.byKey(
          const ValueKey<String>('destructive-confirm-delete-subscriptions'),
        ),
        findsNothing,
      );
      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      expect((await dialogResult)!.deleteSubscriptions, isFalse);
    });

    testWidgets('默认勾上、与主勾选无关；点一下取消', (WidgetTester tester) async {
      await openDialog(
        tester,
        checkboxLabel: '连同本体删除',
        deleteSubscriptionsLabel: '同时删除 2 个下载订阅',
      );
      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      FushiDestructiveConfirmResult value = (await dialogResult)!;
      expect(value.checked, isFalse, reason: '主勾选没勾');
      expect(value.deleteSubscriptions, isTrue, reason: '订阅勾选默认勾上且独立');

      await openDialog(tester, deleteSubscriptionsLabel: '同时删除 2 个下载订阅');
      await tester.tap(find.text('同时删除 2 个下载订阅'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      value = (await dialogResult)!;
      expect(value.deleteSubscriptions, isFalse);
    });
  });
}

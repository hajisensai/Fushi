import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/pages/implementations/sentence_context_dialog.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// BUG-763/766：「制卡·选择句子上下文」原生顶层对话框（[SentenceContextDialog]）行为测试。
/// 旧模态画在查词弹窗 WebView 内、无头测试照不到；改原生对话框后可用 widget 测试钉死行为。
void main() {
  // 可变的宿主草稿桩：+/- 调用 setContext 后改变返回的上下文预览（模拟宿主整体重解析）。
  late int stubPrev;
  late int stubNext;
  late List<List<int>> setCalls; // 记录 (prev,next) 调用
  late int confirmCalls;
  // BUG-2627：onConfirm 现在回传「有没有真的点到那颗制卡按钮」。桩可切 false 模拟
  // 「回点时弹窗层已经不在了」。confirmOrder 记录关窗相对于制卡的先后。
  late bool confirmResult;
  late Completer<bool>? confirmGate;
  // 手改句子文本：记录 (slot,index,text) 调用，并把改动落进桩，让下一次 preview
  // 像真宿主那样吐出改后的文本。
  late List<List<Object>> editCalls;
  late Map<int, String> prevEdits;
  late Map<int, String> nextEdits;
  late String? currentEdit;
  // 该表面是否支持编辑（false = 宿主没接回调，编辑入口整颗不该渲染）。
  late bool supportsEdit;

  Map<String, Object?> preview() {
    final List<String> prev = <String>[
      for (int i = 0; i < stubPrev; i++) prevEdits[i] ?? '前文$i。',
    ];
    final List<String> next = <String>[
      for (int i = 0; i < stubNext; i++) nextEdits[i] ?? '后文$i。',
    ];
    return <String, Object?>{
      'prev': prev,
      'current': currentEdit ?? '俺に対する同情。',
      // 当前句被手改后偏移失效（宿主置空，见 buildSentenceContextPreview）。
      'currentOffset': currentEdit == null ? 2 : null, // 「対する」在偏移 2
      'next': next,
      'total': prev.length + next.length,
    };
  }

  // BUG-2627：失败提示走 FushiToast 的桌面自绘 overlay，它要经 navigatorKey 找
  // overlay；不接这把钥匙 toast 会**静默丢掉**（正是这条修复要消灭的那种静默）。
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  Future<Widget> harness() async {
    FushiToast.navigatorKey = navKey;
    return MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => SentenceContextDialog(
                  matched: '対する',
                  fetchPreview: () async => preview(),
                  setContext: (int p, int n) async {
                    setCalls.add(<int>[p, n]);
                    stubPrev = p;
                    stubNext = n;
                    return p + n;
                  },
                  onConfirm: () async {
                    confirmCalls++;
                    if (confirmGate != null) return confirmGate!.future;
                    return confirmResult;
                  },
                  editSentence: supportsEdit
                      ? (SentenceContextSlot slot, int index,
                          String text) async {
                          editCalls.add(<Object>[slot, index, text]);
                          if (slot == SentenceContextSlot.prev) {
                            prevEdits[index] = text;
                          } else if (slot == SentenceContextSlot.next) {
                            nextEdits[index] = text;
                          } else {
                            currentEdit = text;
                          }
                        }
                      : null,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    stubPrev = 0;
    stubNext = 0;
    setCalls = <List<int>>[];
    confirmCalls = 0;
    confirmResult = true;
    confirmGate = null;
    editCalls = <List<Object>>[];
    prevEdits = <int, String>{};
    nextEdits = <int, String>{};
    currentEdit = null;
    supportsEdit = true;
  });

  // 用 IconButton finder（不是 byTooltip）：byTooltip 命中的是 RawTooltip 包装层，
  // 拿不到 IconButton.onPressed 判禁用。
  Finder editButtons() =>
      find.widgetWithIcon(IconButton, Icons.edit_outlined);

  Future<void> open(WidgetTester tester) async {
    // 放大测试视口，保证对话框全部按钮在屏可点（默认 800x600 会把按钮区挤出屏）。
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(await harness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('打开显示当前句 + 计数，词高亮切成三段富文本', (WidgetTester tester) async {
    await open(tester);
    expect(find.text(t.popup_ctx_modal_title), findsOneWidget);
    // 计数「Selected 0」（初始无上下文）。
    expect(find.text(t.popup_ctx_modal_count.replaceAll('%d', '0')),
        findsOneWidget);
    // 当前句用 Text.rich（三段：対する 高亮）。
    final Finder rich = find.byWidgetPredicate(
      (Widget w) =>
          w is RichText &&
          w.text is TextSpan &&
          (w.text as TextSpan).toPlainText().contains('俺に対する同情。'),
    );
    expect(rich, findsWidgets);
  });

  testWidgets('点「后加一句」调 setContext(0,1) 并刷新出后文', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, t.popup_ctx_next_plus));
    await tester.pumpAndSettle();
    // contains 矩阵器对元素做深比较（List.contains 是引用等价，会误判）。
    expect(setCalls, contains(equals(<int>[0, 1])),
        reason: '后加一句必须以整体替换语义调 setContext(prev=0, next=1)');
    // 计数涨到 1，后文出现。
    expect(find.text(t.popup_ctx_modal_count.replaceAll('%d', '1')),
        findsOneWidget);
    expect(find.textContaining('后文0。'), findsOneWidget);
  });

  testWidgets('确认制卡回调 onConfirm 并关窗', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_confirm));
    await tester.pumpAndSettle();
    expect(confirmCalls, 1);
    // 对话框已关（标题消失）。
    expect(find.text(t.popup_ctx_modal_title), findsNothing);
  });

  testWidgets('BUG-2627：制卡往返跑完之前对话框不许关（保护窗口内完成回点）',
      (WidgetTester tester) async {
    // 把 onConfirm 卡住，模拟「Dart → 弹窗 WebView → 回点」这次往返还在路上。
    confirmGate = Completer<bool>();
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_confirm));
    await tester.pump();
    expect(confirmCalls, 1);
    // 往返未回：对话框必须还开着——宿主的 runWithLookupPopupHidden 正是靠它还开着
    // 才保证那层弹窗活着（barrier 不渲染、悬停离开自动关栈被 hiddenByDialog 挡住）。
    expect(find.text(t.popup_ctx_modal_title), findsOneWidget,
        reason: '先 pop 再回点 = 把往返丢进保护已撤的窗口，正是 BUG-2627 的根因');
    // 期间不能再按第二次，也不能改上下文（整屏进 busy）。
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, t.popup_ctx_confirm))
          .onPressed,
      isNull,
    );
    confirmGate!.complete(true);
    await tester.pumpAndSettle();
    expect(confirmCalls, 1, reason: '一次确认只回点一次');
    expect(find.text(t.popup_ctx_modal_title), findsNothing);
  });

  testWidgets('BUG-2627：往返未回时 Esc 不关窗（保护不能被提前撤掉，回点结果也不能没人接）',
      (WidgetTester tester) async {
    confirmGate = Completer<bool>();
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_confirm));
    await tester.pump();
    expect(confirmCalls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text(t.popup_ctx_modal_title), findsOneWidget,
        reason: '忙时 pop 掉对话框 = 弹窗保护提前撤 + 回点结果无论真假都不弹提示');
    confirmGate!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text(t.popup_ctx_modal_title), findsNothing,
        reason: '往返回来后照常关窗');
  });

  testWidgets('BUG-2627：没点到制卡按钮时关窗并如实提示，不再静默',
      (WidgetTester tester) async {
    confirmResult = false; // 弹窗层已被关栈 / 词条没了 / 按钮 disabled
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_confirm));
    await tester.pumpAndSettle();
    expect(confirmCalls, 1);
    expect(find.text(t.popup_ctx_modal_title), findsNothing);
    expect(find.text(t.popup_ctx_confirm_failed), findsOneWidget,
        reason: '制卡没落地必须有可见反馈，否则用户只看到「点了没反应」');
    // toast 自带 2s 自动消失表；不等它到期，teardown 会因「widget 树已销毁仍有
    // pending timer」而红——那是 harness 噪声，不是被测行为。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('BUG-2627：制卡落地时不弹失败提示', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_confirm));
    await tester.pumpAndSettle();
    expect(find.text(t.popup_ctx_confirm_failed), findsNothing);
  });

  testWidgets('取消还原到打开时的上下文快照并关窗', (WidgetTester tester) async {
    // 打开时已有上 1/下 1 上下文。
    stubPrev = 1;
    stubNext = 1;
    await open(tester);
    // 先加一句后文（改成 下 2）。
    await tester.tap(find.widgetWithText(OutlinedButton, t.popup_ctx_next_plus));
    await tester.pumpAndSettle();
    expect(setCalls, contains(equals(<int>[1, 2])));
    // 取消 → 还原到快照 (1,1)。
    await tester.tap(find.text(t.popup_ctx_cancel));
    await tester.pumpAndSettle();
    expect(setCalls.last, <int>[1, 1],
        reason: '取消必须调 setContext 还原到打开时的快照 (prev=1, next=1)');
    expect(find.text(t.popup_ctx_modal_title), findsNothing);
    expect(confirmCalls, 0);
  });

  testWidgets('宿主没接编辑回调时一个编辑入口都不渲染', (WidgetTester tester) async {
    supportsEdit = false;
    stubPrev = 1;
    await open(tester);
    expect(editButtons(), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('每张有句子的卡各一个编辑按钮，「(无)」空卡没有', (WidgetTester tester) async {
    stubPrev = 2; // 前文两句 + 当前句 = 3 个入口；后文是「(无)」卡，不给入口。
    await open(tester);
    expect(editButtons(), findsNWidgets(3));
    expect(find.text(t.popup_ctx_box_empty), findsOneWidget);
  });

  testWidgets('编辑前文某句：改文本 → 确认修改 → 落回宿主并显示改后文本',
      (WidgetTester tester) async {
    stubPrev = 2;
    await open(tester);
    // 第 0 个入口 = 前文第 0 句。
    await tester.tap(editButtons().first);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    // 进入编辑态时输入框里就是那一句的原文。
    expect(find.widgetWithText(TextField, '前文0。'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '前文0（改）。');
    await tester.tap(find.text(t.popup_ctx_edit_confirm));
    await tester.pumpAndSettle();

    expect(editCalls, hasLength(1));
    expect(editCalls.single[0], SentenceContextSlot.prev);
    expect(editCalls.single[1], 0);
    expect(editCalls.single[2], '前文0（改）。');
    // 退出编辑态，卡上显示宿主吐回来的新文本；另一句没被动。
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('前文0（改）。'), findsOneWidget);
    expect(find.textContaining('前文1。'), findsOneWidget);
  });

  testWidgets('编辑当前句：slot=current，改后整句重画（旧偏移作废不再高亮原位）',
      (WidgetTester tester) async {
    await open(tester);
    await tester.tap(editButtons().first); // 无上下文时唯一入口 = 当前句
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '書き換えた文。');
    await tester.tap(find.text(t.popup_ctx_edit_confirm));
    await tester.pumpAndSettle();

    expect(editCalls.single[0], SentenceContextSlot.current);
    expect(editCalls.single[2], '書き換えた文。');
    final Finder rich = find.byWidgetPredicate(
      (Widget w) =>
          w is RichText &&
          w.text is TextSpan &&
          (w.text as TextSpan).toPlainText().contains('書き換えた文。'),
    );
    expect(rich, findsWidgets);
  });

  testWidgets('放弃修改：不落回宿主，退出编辑态，原文不变', (WidgetTester tester) async {
    stubPrev = 1;
    await open(tester);
    await tester.tap(editButtons().first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不要这个改动。');
    await tester.tap(find.text(t.popup_ctx_edit_cancel));
    await tester.pumpAndSettle();

    expect(editCalls, isEmpty);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('前文0。'), findsOneWidget);
    expect(find.textContaining('不要这个改动。'), findsNothing);
  });

  testWidgets('编辑态下 ±上下文 / 试听 / 取消 / 确认制卡 全部禁用',
      (WidgetTester tester) async {
    stubPrev = 1;
    await open(tester);
    await tester.tap(editButtons().first);
    await tester.pumpAndSettle();

    // ±上下文四颗（此时前文有 1 句，「前退一句」本来是可点的）。
    for (final String label in <String>[
      t.popup_ctx_prev_minus,
      t.popup_ctx_prev_plus,
      t.popup_ctx_next_plus,
    ]) {
      final OutlinedButton b =
          tester.widget(find.widgetWithText(OutlinedButton, label));
      expect(b.onPressed, isNull, reason: '编辑态下「$label」必须禁用');
    }
    // 底部主/次按钮。
    expect(
      tester.widget<FilledButton>(find.widgetWithText(
        FilledButton,
        t.popup_ctx_confirm,
      )).onPressed,
      isNull,
      reason: '编辑态下「确认制卡」必须禁用——改到一半不该被制卡带走',
    );
    expect(
      tester.widget<TextButton>(find.widgetWithText(
        TextButton,
        t.popup_ctx_cancel,
      )).onPressed,
      isNull,
    );
    // 编辑器自己的两颗按钮反过来必须是活的。
    expect(
      tester.widget<FilledButton>(find.widgetWithText(
        FilledButton,
        t.popup_ctx_edit_confirm,
      )).onPressed,
      isNotNull,
    );
    // 同时只允许一句在编辑：其余卡的编辑入口也被禁。
    for (final Widget w in tester.widgetList(editButtons())) {
      expect((w as IconButton).onPressed, isNull);
    }
  });

  testWidgets('改完一句还能接着加上下文，改动跟着那一句不丢',
      (WidgetTester tester) async {
    stubPrev = 1;
    await open(tester);
    await tester.tap(editButtons().first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '前文0（改）。');
    await tester.tap(find.text(t.popup_ctx_edit_confirm));
    await tester.pumpAndSettle();
    // 编辑落地后 ±按钮重新可点。
    await tester.tap(find.widgetWithText(OutlinedButton, t.popup_ctx_next_plus));
    await tester.pumpAndSettle();
    expect(setCalls, contains(equals(<int>[1, 1])));
    expect(find.textContaining('前文0（改）。'), findsOneWidget);
    expect(find.textContaining('后文0。'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/sentence_context_dialog.dart';

/// BUG-763/766：「制卡·选择句子上下文」原生顶层对话框（[SentenceContextDialog]）行为测试。
/// 旧模态画在查词弹窗 WebView 内、无头测试照不到；改原生对话框后可用 widget 测试钉死行为。
void main() {
  // 可变的宿主草稿桩：+/- 调用 setContext 后改变返回的上下文预览（模拟宿主整体重解析）。
  late int stubPrev;
  late int stubNext;
  late List<List<int>> setCalls; // 记录 (prev,next) 调用
  late int confirmCalls;

  Map<String, Object?> preview() {
    final List<String> prev = <String>[
      for (int i = 0; i < stubPrev; i++) '前文$i。',
    ];
    final List<String> next = <String>[
      for (int i = 0; i < stubNext; i++) '后文$i。',
    ];
    return <String, Object?>{
      'prev': prev,
      'current': '俺に対する同情。',
      'currentOffset': 2, // 「対する」在偏移 2
      'next': next,
      'total': prev.length + next.length,
    };
  }

  Future<Widget> harness() async {
    return MaterialApp(
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
                  onConfirm: () => confirmCalls++,
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
  });

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
}

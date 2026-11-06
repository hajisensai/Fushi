import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:material_ui/material_ui.dart';

/// 查词弹窗点复习标记 / ↗ 跳到卡片：桥调用在 push 发出后就返回，连点同一个词以前会
/// 叠出好几页同一条笔记的编辑页（每页各跑一遍加载）。[srsPushNoteEditor] 的防重入：
/// 同一条笔记的编辑页开着时再请求 = 视为已打开、不叠页；出栈后可以再开；不同笔记互不挡。
void main() {
  setUp(debugResetSrsNoteEditorLock);

  Widget page(String id) =>
      Scaffold(body: Text('editor:$id', key: ValueKey<String>('editor-$id')));

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const Scaffold(body: Text('home')),
      ),
    );
    return key.currentState!;
  }

  testWidgets('同一条笔记连点只压一页；出栈后可以再开', (WidgetTester tester) async {
    final NavigatorState nav = await pumpApp(tester);

    final List<bool> results = <bool>[
      await srsPushNoteEditor(nav, 'n1', pageBuilder: page),
      await srsPushNoteEditor(nav, 'n1', pageBuilder: page),
      await srsPushNoteEditor(nav, 'n1', pageBuilder: page),
    ];
    await tester.pumpAndSettle();

    expect(results, <bool>[true, true, true], reason: '已开着也算「打开了」');
    expect(
      find.byKey(const ValueKey<String>('editor-n1'), skipOffstage: false),
      findsOneWidget,
      reason: '连点三次只能叠出一页编辑页',
    );

    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    expect(await srsPushNoteEditor(nav, 'n1', pageBuilder: page), isTrue);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('editor-n1')),
      findsOneWidget,
      reason: '出栈后登记已摘掉，能再次打开',
    );
  });

  testWidgets('不同笔记互不挡', (WidgetTester tester) async {
    final NavigatorState nav = await pumpApp(tester);
    await srsPushNoteEditor(nav, 'n1', pageBuilder: page);
    await srsPushNoteEditor(nav, 'n2', pageBuilder: page);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('editor-n2')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('editor-n1'), skipOffstage: false),
      findsOneWidget,
    );
  });

  test('导航器不可用时回 false 且不留登记', () async {
    expect(await srsPushNoteEditor(null, 'n1'), isFalse);
  });
}

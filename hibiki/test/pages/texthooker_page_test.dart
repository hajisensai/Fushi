import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/pages/implementations/texthooker_page.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());
  tearDown(() => TexthookerService.instance.clear());

  testWidgets('renders incoming lines reactively', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TexthookerPage())),
    );
    await tester.pump();

    expect(find.text('第'), findsNothing);

    TexthookerService.instance.appendLine('第一行');
    await tester.pump();
    // 分词后可能拆成多个 span，逐字降级时「第」是独立 span。
    expect(find.textContaining('第'), findsWidgets);

    TexthookerService.instance.appendLine('第二行');
    await tester.pump();
    expect(find.textContaining('二'), findsWidgets);
  });

  testWidgets('clear button empties the list', (WidgetTester tester) async {
    TexthookerService.instance.appendLine('行X');
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TexthookerPage())),
    );
    await tester.pump();
    expect(find.textContaining('行'), findsWidgets);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('行'), findsNothing);
  });

  testWidgets('Luna-style text thread selector filters mixed hook output',
      (WidgetTester tester) async {
    TexthookerService.instance.appendLine(
      '坏线程文本',
      textThreadKey: 'luna:bad',
      textThreadLabel: 'Luna 0x1000',
      textHookCode: 'HS932@1000',
    );
    TexthookerService.instance.appendLine(
      '干净台词',
      textThreadKey: 'luna:clean',
      textThreadLabel: 'SiglusEngine 0x2000',
      textHookCode: 'HS932@2000',
    );
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TexthookerPage())),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
      findsOneWidget,
    );
    expect(find.textContaining('坏'), findsWidgets);
    expect(find.textContaining('干'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('SiglusEngine 0x2000').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('干'), findsWidgets);
    expect(find.textContaining('坏'), findsNothing);
  });

  testWidgets('thread selector lists discovered TextRender before any output',
      (WidgetTester tester) async {
    TexthookerService.instance.registerTextThread(
      key: 'luna:textrender',
      label: 'TextRender · 0xf94600',
      hookCode: 'HS932@f94600',
      nativeThreadId: 0x9,
    );
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TexthookerPage())),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('TextRender · 0xf94600 · 0'), findsWidgets);
  });

  testWidgets('embedded mode reuses parent scaffold and exposes back action',
      (WidgetTester tester) async {
    bool returned = false;
    TexthookerService.instance.appendLine('嵌入行');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TexthookerPage(
              embedded: true,
              onShowLibrary: () => returned = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget,
        reason: '嵌入工作台不得再创建第二层 Scaffold');
    expect(find.byType(AppBar), findsNothing);
    expect(find.textContaining('嵌'), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(returned, isTrue);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('嵌'), findsNothing);
  });

  for (final Size size in <Size>[
    const Size(520, 760),
    const Size(1000, 760),
    const Size(1440, 850),
  ]) {
    testWidgets('capture console lays out at ${size.width.toInt()}px',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TexthookerService.instance.appendLine('レスポンシブ確認');
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: TexthookerPage())),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Live lines'), findsOneWidget);
      if (size.width >= 840) {
        expect(find.text('Latest line'), findsOneWidget);
        expect(find.text('Health status'), findsOneWidget);
      } else {
        expect(find.text('Latest line'), findsNothing);
        expect(find.text('Health status'), findsNothing);
      }
    });
  }

  testWidgets('选中线程被行上限淘汰后重建下拉不触发断言（BUG-952）', (WidgetTester tester) async {
    // 把 session 选到一个 service 里并不存在的线程 key —— 等价于该线程被 500 行上限
    // 淘汰/清空后 value 落在 items 之外。修复前 DropdownButton 会断言红屏。
    await GalHookSessionController.instance
        .selectTextThread(0x1, threadKey: 'luna:evicted');
    addTearDown(
      () => GalHookSessionController.instance
          .selectTextThread(null, threadKey: null),
    );
    TexthookerService.instance.appendLine(
      '别的线程行',
      textThreadKey: 'luna:other',
      textThreadLabel: 'Other 0x2',
      textHookCode: 'HS932@2',
    );
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TexthookerPage())),
    );
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '选中线程被淘汰后 value 应回退占位「全部」，不得触发 DropdownButton 断言');
    expect(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
      findsOneWidget,
    );
  });

  group('injectActiveSentence（BUG-954：fallback 制卡带上活跃台词）', () {
    test('fields 无 sentence + 有活跃台词 → 注入活跃台词，其它字段不变', () {
      final Map<String, String> r = injectActiveSentence(
        <String, String>{'expression': '語'},
        'これは台詞です。',
      );
      expect(r['sentence'], 'これは台詞です。');
      expect(r['expression'], '語');
    });

    test('fields 已有非空 sentence → 不覆盖调用方句子', () {
      final Map<String, String> r = injectActiveSentence(
        <String, String>{'sentence': '既存の文'},
        '活跃台詞',
      );
      expect(r['sentence'], '既存の文');
    });

    test('无活跃台词 / 空串 → 原样返回', () {
      expect(injectActiveSentence(<String, String>{'a': 'b'}, null),
          <String, String>{'a': 'b'});
      expect(injectActiveSentence(<String, String>{'a': 'b'}, ''),
          <String, String>{'a': 'b'});
    });
  });
}

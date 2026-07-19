import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

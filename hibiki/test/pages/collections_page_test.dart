import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collections_pp');
    // AppModel 构造会惰性触碰 DefaultCacheManager → getApplicationSupportDirectory；
    // 不 mock 该 channel 会抛 MissingPluginException 异步泄漏到下一条测试。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: child),
    );
  }

  testWidgets('collection delete dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        CollectionDeleteDialog(
          message:
              '${t.collection_bookmark}: Very long collected sentence or bookmark label used to test compact Windows delete confirmation layout',
          onConfirm: _noop,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.dialog_delete), findsOneWidget);
  });

  testWidgets('collection item dialog shows all actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        CollectionItemDialogFrame(
          title: const SelectableText(
            'Very long favorite sentence used to test compact Windows collection item dialog layout',
            maxLines: 3,
          ),
          content: const Text(
            'Very long book title used to test compact collection dialog content',
          ),
          actions: const [
            TextButton(onPressed: null, child: Text('Play')),
            TextButton(onPressed: null, child: Text('Copy')),
            TextButton(onPressed: null, child: Text('Delete')),
            FilledButton(onPressed: null, child: Text('Read')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
  });

  // ── TODO-633 W1: 清空制卡历史按钮 ─────────────────────────────────────────
  // 这组测试 pump 真 CollectionsPage（BasePage 子类），用 AppModel.wireDatabaseForTesting
  // 注入内存库（跳过完整 initialise），验证清空按钮的显示条件与点击副作用真生效，
  // 而非仅看源码。

  group('TODO-633 W1 clear mined history button', () {
    late HibikiDatabase db;
    late AppModel appModel;

    setUp(() async {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      appModel = AppModel(testPlatformServices())..wireDatabaseForTesting(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedMinedSentence(String sentence) {
      // source='book' + bookKey=null：可跳转无关，_load 不会把它加入 allBookKeys，
      // 因此不触发 SrtBook/Audiobook/Video 音频解析路径——足以驱动按钮显示逻辑。
      return db.addMinedSentence(
        source: 'book',
        dateKey: '2026-06-21',
        expression: sentence,
        sentence: sentence,
        documentTitle: 'Some Book',
      );
    }

    Widget buildPage() => ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((ref) => appModel),
          ],
          child: TranslationProvider(
            child: const MaterialApp(home: CollectionsPage()),
          ),
        );

    Finder clearButton() => find.widgetWithIcon(
          HibikiIconButton,
          Icons.delete_sweep_outlined,
        );

    testWidgets('shows the clear button when mined sentences exist',
        (WidgetTester tester) async {
      await seedMinedSentence('これはテスト文です。');

      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();

      // 制卡句条目渲染出来。
      expect(find.text('これはテスト文です。'), findsOneWidget);
      // 清空按钮出现（tooltip = dialog_clear）。
      expect(clearButton(), findsOneWidget);
    });

    testWidgets('hides the clear button when no mined sentences exist',
        (WidgetTester tester) async {
      // 不种任何制卡句（空集合）。
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();

      expect(clearButton(), findsNothing);
    });

    testWidgets('tapping clear and confirming clears all mined sentences',
        (WidgetTester tester) async {
      await seedMinedSentence('一つ目の文。');
      await seedMinedSentence('二つ目の文。');
      expect((await db.getAllMinedSentences()).length, 2);

      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();

      // 点清空按钮 → 弹确认对话框（文案 = collection_mined_clear_confirm）。
      await tester.tap(clearButton());
      await tester.pumpAndSettle();
      expect(find.text(t.collection_mined_clear_confirm), findsOneWidget);

      // 确认（CollectionDeleteDialog 的销毁动作 = dialog_delete）。
      await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete).last);
      await tester.pumpAndSettle();

      // DB 真清空 + 列表里制卡句消失 + 按钮随之隐藏。
      expect(await db.getAllMinedSentences(), isEmpty);
      expect(find.text('一つ目の文。'), findsNothing);
      expect(find.text('二つ目の文。'), findsNothing);
      expect(clearButton(), findsNothing);
    });

    testWidgets('tapping clear and cancelling keeps mined sentences',
        (WidgetTester tester) async {
      await seedMinedSentence('残す文。');

      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();

      await tester.tap(clearButton());
      await tester.pumpAndSettle();

      // 取消（CollectionDeleteDialog 的关闭动作 = dialog_close）。
      await tester.tap(find.widgetWithText(TextButton, t.dialog_close).last);
      await tester.pumpAndSettle();

      expect((await db.getAllMinedSentences()).length, 1);
      expect(find.text('残す文。'), findsOneWidget);
      expect(clearButton(), findsOneWidget);
    });
  });
}

void _noop() {}

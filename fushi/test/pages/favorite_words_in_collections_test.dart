import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-462（TODO-983）：弹窗 ☆ 收藏的词（FavoriteWords 表）写库正常，但收藏列表
/// （CollectionsPage）此前只读书签 / 收藏句 / 制卡句，从不读 getAllFavoriteWords →
/// 用户「收藏里面没有收藏的单词」。本测试用真内存 DB 写一条收藏词，pump 收藏页，断言
/// 词形 + 读音 + 释义 + 「单词」类型标签都真渲染进列表（写→读→显示全链贯通的回归守卫）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_fav_words_collections_pp');
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

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedWord({
    required String expression,
    required String reading,
    required String glossary,
    String sourceType = 'book',
  }) async {
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: glossary,
      sourceType: sourceType,
      dateKey: '2026-06-30',
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

  testWidgets('收藏的单词在收藏列表里真渲染（词形 + 读音 + 释义 + 类型标签）',
      (WidgetTester tester) async {
    await seedWord(
      expression: '邂逅',
      reading: 'かいこう',
      glossary: 'chance meeting',
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // 词形（标题行）。
    expect(find.text('邂逅'), findsOneWidget, reason: '收藏的单词词形必须出现在收藏列表');
    // 类型标签「单词」（leading 列）。
    expect(find.text(t.collection_word), findsWidgets,
        reason: '收藏词行必须标注「单词」类型');
    // 副标题包含读音 + 释义（用 textContaining，因副标题还拼了日期）。
    expect(find.textContaining('かいこう'), findsOneWidget);
    expect(find.textContaining('chance meeting'), findsOneWidget);
  });

  testWidgets('收藏词带上收藏时的原句：列表行显示原句，详情显示释义与原句',
      (WidgetTester tester) async {
    await db.addFavoriteWord(
      expression: 'normie',
      reading: '',
      glossary: '【Wiktionary】a normal person',
      sourceType: 'book',
      dateKey: '2026-09-28',
      sentence: 'She could be described as a normie.',
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    expect(find.text('normie'), findsOneWidget);
    expect(find.text('She could be described as a normie.'), findsOneWidget,
        reason: '收藏词行必须显示收藏时所在的原句（此前只剩词形）');
    expect(find.textContaining('a normal person'), findsOneWidget);

    await tester.longPress(find.text('normie'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('【Wiktionary】a normal person'),
      ),
      findsOneWidget,
      reason: '详情必须显示释义',
    );
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('She could be described as a normie.'),
      ),
      findsOneWidget,
      reason: '详情必须显示原句',
    );
  });

  testWidgets('顶栏 ★ 收藏的句子旁显示当时查的词', (WidgetTester tester) async {
    await FavoriteSentenceRepository(db).add(
      FavoriteSentence(
        text: 'She could be described as a normie.',
        bookTitle: 'Book',
        createdAt: DateTime(2026, 9, 28),
        expression: 'normie',
        reading: '',
      ),
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    expect(find.text('She could be described as a normie.'), findsOneWidget);
    expect(find.text('normie'), findsOneWidget,
        reason: '句子收藏必须显示对应的单词（用户报：收藏了句子却看不到单词）');
  });

  testWidgets('分类筛选：只看单词时隐藏收藏句', (WidgetTester tester) async {
    await seedWord(
      expression: '邂逅',
      reading: 'かいこう',
      glossary: 'chance meeting',
    );
    await FavoriteSentenceRepository(db).add(
      FavoriteSentence(
        text: '一期一会の邂逅だった。',
        bookTitle: 'Book',
        createdAt: DateTime(2026, 9, 28),
      ),
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(find.text('一期一会の邂逅だった。'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(ChoiceChip, t.collection_word),
    );
    await tester.pumpAndSettle();
    expect(find.text('邂逅'), findsOneWidget);
    expect(find.text('一期一会の邂逅だった。'), findsNothing);

    await tester.tap(
      find.widgetWithText(ChoiceChip, t.collection_filter_all),
    );
    await tester.pumpAndSettle();
    expect(find.text('一期一会の邂逅だった。'), findsOneWidget);
  });

  testWidgets('无任何收藏时收藏列表显示空占位（收藏词不误造空集）', (WidgetTester tester) async {
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(find.text(t.no_collections), findsOneWidget);
  });

  test('收藏词写库后 getAllFavoriteWords 能读回（写→读契约）', () async {
    await seedWord(
      expression: '森羅万象',
      reading: 'しんらばんしょう',
      glossary: 'all of creation',
      sourceType: 'video',
    );
    final List<FavoriteWordRow> rows = await db.getAllFavoriteWords();
    expect(rows, hasLength(1));
    expect(rows.single.expression, '森羅万象');
    expect(rows.single.reading, 'しんらばんしょう');
    expect(rows.single.sourceType, 'video');
  });
}

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
import 'package:hibiki_core/hibiki_core.dart';

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

  late HibikiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
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

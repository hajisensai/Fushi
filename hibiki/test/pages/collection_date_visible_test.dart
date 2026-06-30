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
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-469：窄屏（12.4" 平板横向空间不足）下收藏行的收藏日期被超长书名+章节挤出
/// 可见区，用户看不到后面还有日期。修后副标题拆成 Row（元数据 Flexible+ellipsis 让位，
/// 日期定宽尾随永不被裁）。本测试在窄屏 pump 真 CollectionsPage，种入超长书名+章节的
/// 收藏句，断言日期文本真渲染且宽度 > 0（未被省略号截没）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collection_date');
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

  // 收藏句不带 bookKey → _load 不会触发 SrtBook/Audiobook/Video 音频解析路径，
  // 只驱动列表渲染逻辑。createdAt 固定到一个可预测的日期，便于断言日期文本。
  Future<void> seedLongMetadataFavorite() async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    await repo.add(
      FavoriteSentence(
        id: 'fav_date_test',
        text: 'これはテスト用の収集された文章です。',
        bookTitle: 'とても長い本のタイトルでありこれは画面の横幅を完全に埋め尽くすために'
            '意図的に長くしてあります十二点四インチのタブレットでも収まらないほど長い',
        chapterLabel: '第一章 これもまた非常に長い章のタイトルであり日付を画面外へ押し出すための'
            'もの',
        source: kFavoriteSentenceSourceBook,
        createdAt: DateTime(2026, 6, 30, 14, 5),
      ),
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

  // 期望的日期文本，与 CollectionsPage 内部 DateFormat('MM/dd HH:mm') 一致。
  const String expectedDate = '06/30 14:05';

  testWidgets(
      'collection date stays visible on a narrow screen with long book/chapter',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    // 窄屏：模拟 12.4" 平板横向空间不足的极端窄宽度。
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.reset);

    await seedLongMetadataFavorite();
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // 收藏句条目渲染出来。
    expect(find.text('これはテスト用の収集された文章です。'), findsOneWidget);

    // 关键断言：收藏日期是独立、未被截断的文本，窄屏下仍然可见且有正的渲染宽度。
    final Finder dateFinder = find.text(expectedDate);
    expect(dateFinder, findsOneWidget);
    final Size dateSize = tester.getSize(dateFinder);
    expect(dateSize.width, greaterThan(0));
  });

  testWidgets('collection date also visible on a wide screen (no regression)',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);

    await seedLongMetadataFavorite();
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    expect(find.text(expectedDate), findsOneWidget);
  });
}

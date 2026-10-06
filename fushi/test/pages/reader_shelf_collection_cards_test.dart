import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/collections/collection_shelf_row.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/pages/implementations/series_shelf_card.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 书架「合集以单个格子显示」（偏好 `shelf_collection_layout`）+ 两个书架 bug 的
/// 页面级回归：
///  - 格子模式：合集渲染成 [SeriesShelfCard]（叠层封面），与散书在**同一个网格、
///    同一套排序**里混排（名称排序下夹在两本散书中间），不再固定排前面；
///  - 默认整行展开（现状零变化）；「排序与显示」菜单切换后落偏好；
///  - BUG-2968：书打了标签、所在合集没打 → 按标签筛选时这本书仍可见；
///  - BUG-2969：合集详情页成员右键弹的是与书架书卡同一个菜单（含「标签」）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_shelf_cards_pp');
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
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;
  late List<MediaItem> epubItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_shelf_cards');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    epubItems = <MediaItem>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> seedEpub(String bookKey, String title) async {
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      epubPath: '${pathProviderDir.path}/$bookKey.epub',
      extractDir: pathProviderDir.path,
      chapterCount: 1,
      chaptersJson: '["a"]',
      importedAt: 0,
    ));
    epubItems.add(MediaItem(
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
      title: title,
      mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    ));
  }

  /// 「Alpha」（散）/「M 系列」{Zeta 1, Zeta 2} /「Omega」（散）。名称排序下合集
  /// 应夹在两本散书中间。返回合集 id。
  Future<int> seedLibrary() async {
    await seedEpub('alphaKey', 'Alpha');
    await seedEpub('zeta1Key', 'Zeta 1');
    await seedEpub('zeta2Key', 'Zeta 2');
    await seedEpub('omegaKey', 'Omega');
    final int cid = await db.createMediaCollection('M Series');
    for (final String key in <String>['zeta1Key', 'zeta2Key']) {
      await db.addToCollection(
        cid,
        MediaKind.epub,
        (await db.resolveEpubBookUid(key))!,
      );
    }
    await prefs.setShelfSortModeName('title');
    return cid;
  }

  Widget buildApp({Set<int> selectedTags = const <int>{}}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(epubItems),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
          selectedTagIdsProvider.overrideWith((ref) => selectedTags),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                remoteBookClientLoader: () async => null,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpPage(
    WidgetTester tester, {
    Set<int> selectedTags = const <int>{},
  }) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(selectedTags: selectedTags));
    await tester.pumpAndSettle();
  }

  Finder epubCard(String bookKey) => find.byKey(ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}'));
  Finder collectionCard(int cid) =>
      find.byKey(ValueKey<String>('reader_shelf_collection_card_$cid'));

  /// 网格阅读序：按 (行, 列) 排。
  int readingOrder(WidgetTester tester, Finder a, Finder b) {
    final Offset pa = tester.getTopLeft(a);
    final Offset pb = tester.getTopLeft(b);
    if ((pa.dy - pb.dy).abs() > 1) return pa.dy.compareTo(pb.dy);
    return pa.dx.compareTo(pb.dx);
  }

  testWidgets('默认单个格子：合集是叠层格子，没有横排行（a55fc1382bb）',
      (WidgetTester tester) async {
    final int cid = await seedLibrary();
    await pumpPage(tester);
    expect(prefs.shelfCollectionLayoutName, 'cards');
    expect(find.byType(CollectionShelfRow), findsNothing);
    expect(collectionCard(cid), findsOneWidget);
  });

  testWidgets('整行展开：合集是横排行，没有合集格子', (WidgetTester tester) async {
    final int cid = await seedLibrary();
    await prefs.setShelfCollectionLayoutName('rows');
    await pumpPage(tester);
    expect(find.byType(CollectionShelfRow), findsOneWidget);
    expect(collectionCard(cid), findsNothing);
  });

  testWidgets('单个格子：合集与散书同一网格、同一排序（名称序夹在中间）',
      (WidgetTester tester) async {
    final int cid = await seedLibrary();
    await prefs.setShelfCollectionLayoutName('cards');
    await pumpPage(tester);

    expect(find.byType(CollectionShelfRow), findsNothing,
        reason: '格子模式不得再渲染全宽横排行');
    expect(collectionCard(cid), findsOneWidget);
    expect(tester.widget(collectionCard(cid)), isA<SeriesShelfCard>(),
        reason: '合集格子是共享的叠层系列卡');
    // 合集成员不再单独成卡（折进格子）。
    expect(epubCard('zeta1Key'), findsNothing);
    expect(epubCard('zeta2Key'), findsNothing);
    // 名称序：Alpha < M Series < Omega——合集参与同一排序，不再固定排最前。
    expect(readingOrder(tester, epubCard('alphaKey'), collectionCard(cid)),
        lessThan(0));
    expect(readingOrder(tester, collectionCard(cid), epubCard('omegaKey')),
        lessThan(0));
    // 角标：「2 册」+「系列」。
    expect(find.text(t.shelf_collection_volume_count(n: 2)), findsOneWidget);
    expect(find.text(t.shelf_collection_series_label), findsOneWidget);
  });

  testWidgets('「排序与显示」菜单切换合集显示并落偏好', (WidgetTester tester) async {
    final int cid = await seedLibrary();
    await pumpPage(tester);

    await tester.tap(find.byTooltip(t.shelf_sort_and_view));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('shelf_collection_layout_cards')),
    );
    await tester.pumpAndSettle();

    expect(prefs.shelfCollectionLayoutName, 'cards');
    expect(collectionCard(cid), findsOneWidget);
    expect(find.byType(CollectionShelfRow), findsNothing);
  });

  testWidgets('格子点击进合集详情；成员右键弹与书架同一个菜单（BUG-2969）',
      (WidgetTester tester) async {
    final int cid = await seedLibrary();
    await prefs.setShelfCollectionLayoutName('cards');
    await pumpPage(tester);

    await tester.tap(collectionCard(cid));
    await tester.pumpAndSettle();
    final Finder member = epubCard('zeta1Key');
    expect(member, findsOneWidget, reason: '详情页渲染成员卡');

    final TestGesture right = await tester.startGesture(
      tester.getCenter(member),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await right.up();
    await tester.pumpAndSettle();

    expect(find.text(t.tag_label), findsOneWidget,
        reason: '合集内成员菜单必须含「标签」（与书架书卡同一个菜单）');
    expect(find.text(t.book_rename), findsOneWidget);
    expect(find.text(t.collection_remove_member), findsOneWidget,
        reason: '合集语境额外补「移出合集」');
    expect(find.text(t.collection_open), findsNothing,
        reason: '不再是详情页自绘的「打开 / 移出」精简菜单');
  });

  testWidgets('BUG-2968：书打了标签、合集没打 → 按标签筛选仍能找到这本书',
      (WidgetTester tester) async {
    await seedLibrary();
    final int tagId = await db.createTag('fav', 0xFF2196F3);
    await db.addTagToBook('zeta1Key', tagId);
    await prefs.setShelfCollectionLayoutName('rows');

    await pumpPage(tester, selectedTags: <int>{tagId});

    // 横排行模式下合集行仍在，行里只剩打了标签的那本。
    expect(find.byType(CollectionShelfRow), findsOneWidget,
        reason: '组内有成员命中标签，合集组不得被整组删掉');
    expect(epubCard('zeta1Key'), findsOneWidget,
        reason: '打了标签的书必须可见（旧逻辑随未打标签的合集一起消失）');
    expect(epubCard('zeta2Key'), findsNothing, reason: '未命中标签的成员照常隐藏');
    expect(epubCard('alphaKey'), findsNothing);
  });
}

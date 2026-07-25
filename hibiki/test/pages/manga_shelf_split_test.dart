import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// 漫画独立成页：书架与漫画 tab 共用 [ReaderHibikiHistoryPage]，靠 `mangaShelf`
/// 按 `mediaSourceIdentifier`（[MangaHibikiSource.kUniqueKey]）把同一张 EpubBooks
/// 表的行分流成两页——书架剔除漫画、漫画书架只留漫画。本测试守住：
/// 1. 双向分流（同一批 MediaItem 在两个 shelf 各只出现自己那半）。
/// 2. 页头身份（标题 + 导入入口 + 「管理来源」仅书架有）。
///
/// 渲染层说明（与 reader_shelf_tag_filter_empty_state_test 同源）：真实
/// [hibikiBooksProvider] 会 `await` 封面 File.exists() 真 I/O，假时钟下不完成，
/// 故覆写成受控列表；分流谓词在页面 build 内，正是被测物。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_manga_shelf_pp');
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

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;
  late List<MediaItem> items;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_manga_shelf');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    items = <MediaItem>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  MediaItem seedItem({required String bookKey, required bool manga}) {
    final MediaItem item = MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
      title: bookKey,
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: manga
          ? MangaHibikiSource.kUniqueKey
          : ReaderHibikiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );
    items.add(item);
    return item;
  }

  Widget buildApp({required bool mangaShelf}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(items),
          ),
          // 真实 srtBooksProvider 是 drift watch，widget 测试假时钟下 teardown 挂
          // pending timer（与 reader_shelf_tag_filter_empty_state_test 同源做法）。
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: Scaffold(
              body: ReaderHibikiHistoryPage(
                mangaShelf: mangaShelf,
                remoteBookClientLoader: () async => null,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpShelf(WidgetTester tester,
      {required bool mangaShelf}) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(mangaShelf: mangaShelf));
    await tester.pumpAndSettle();
  }

  Finder bookCard(String bookKey) => find.byKey(ValueKey<String>(
      'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}'));

  testWidgets('书架剔除漫画：只渲染 EPUB 卡，漫画卡不出现', (WidgetTester tester) async {
    seedItem(bookKey: 'epubA', manga: false);
    seedItem(bookKey: 'mangaB', manga: true);

    await pumpShelf(tester, mangaShelf: false);

    expect(bookCard('epubA'), findsOneWidget, reason: 'EPUB 卡必须留在书架');
    expect(bookCard('mangaB'), findsNothing, reason: '漫画行必须从书架剔除（漫画独立成页）');
    expect(find.text(t.books), findsOneWidget, reason: '书架页头标题是「书籍」');
    expect(find.text(t.srt_import), findsOneWidget,
        reason: '书架页头仍是书籍导入入口（宽窗外显文字药丸）');
    expect(find.text(t.manga_import_title), findsNothing,
        reason: '书架不得出现漫画导入入口');
  });

  testWidgets('漫画书架只留漫画：EPUB 卡不出现，页头是漫画身份', (WidgetTester tester) async {
    seedItem(bookKey: 'epubA', manga: false);
    seedItem(bookKey: 'mangaB', manga: true);

    await pumpShelf(tester, mangaShelf: true);

    expect(bookCard('mangaB'), findsOneWidget, reason: '漫画卡必须渲染在漫画书架');
    expect(bookCard('epubA'), findsNothing, reason: 'EPUB 行不得漏进漫画书架');
    expect(find.text(t.nav_manga), findsOneWidget, reason: '漫画书架页头标题是「漫画」');
    expect(find.text(t.manga_import_title), findsOneWidget,
        reason: '漫画书架页头是漫画专属导入入口（宽窗外显文字药丸）');
  });
}

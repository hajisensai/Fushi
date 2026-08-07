import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1008：标签筛选下的矛盾空态回归。
///
/// 旧实现的 `hasActiveFilter && epubBooks.isEmpty` 特殊分支在「筛选命中若干 SRT
/// 有声书、EPUB 零命中」时已把 SRT 卡渲染成网格，却仍无条件叠一条
/// `tag_no_books_for_filter`（「没有符合筛选的书」）空态文案，且该分支丢
/// RefreshIndicator / 合集横排行 / 书库概览。修复 = 消灭特殊分支，筛选态走主分支
/// 组装；只有整体为空（无任何可渲染卡）时才显示空态。
///
/// 渲染层说明（与 reader_shelf_batch_collection_ops_test 同源）：书架
/// [hibikiBooksProvider] 的真实实现会 `await` 封面 `File.exists()` 真 I/O，假时钟
/// 下永不完成，故「读」provider 覆写成受控列表；标签筛选走**真 DB**（createTag /
/// addTagToSrtBook + filteredSrtBookIdsProvider 真实推导），只覆写选中标签集。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_shelf_filter_pp');
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
  late List<MediaItem> epubItems;
  late List<SrtBook> srtItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_shelf_filter');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    epubItems = <MediaItem>[];
    srtItems = <SrtBook>[];
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
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
      title: title,
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    ));
  }

  Future<SrtBook> seedSrt(String uid, String title) async {
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = '${pathProviderDir.path}/$uid.srt'
      ..importedAt = 0
      ..bookKey = '';
    await SrtBookRepository(db).save(book);
    final SrtBook? saved = await SrtBookRepository(db).findByUid(uid);
    srtItems.add(saved ?? book);
    return saved ?? book;
  }

  Widget buildApp({required Set<int> selectedTagIds}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(epubItems),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(srtItems),
          ),
          // 选中标签集直接覆写（真 UI 入口是标签栏 chip，这里只测筛选渲染分支）；
          // filtered*Provider 用真实实现，从真 DB 的标签映射推导命中集。
          selectedTagIdsProvider.overrideWith((ref) => selectedTagIds),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: Scaffold(
              body: ReaderHibikiHistoryPage(
                remoteBookClientLoader: () async => null,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpPage(WidgetTester tester,
      {required Set<int> selectedTagIds}) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(selectedTagIds: selectedTagIds));
    await tester.pumpAndSettle();
  }

  testWidgets('BUG-1008：筛选命中 1 本 SRT + 0 本 EPUB → 渲染网格，无矛盾空态、保留下拉刷新',
      (WidgetTester tester) async {
    final SrtBook tagged = await seedSrt('srtHit', '命中的有声书');
    await seedEpub('epubMiss', '未命中的书');
    final int tagId = await db.createTag('日语', 0xFF112233);
    await db.addTagToSrtBook(tagged.id!, tagId);

    await pumpPage(tester, selectedTagIds: <int>{tagId});

    // 命中的 SRT 卡在网格里；未命中的 EPUB 卡被筛掉。
    expect(
        find.byKey(const ValueKey<String>('srt_entry_srtHit')), findsOneWidget,
        reason: '命中的 SRT 卡必须渲染');
    expect(
      find.byKey(ValueKey<String>(
          'book_entry_${ReaderHibikiSource.mediaIdentifierFor('epubMiss')}')),
      findsNothing,
      reason: '未命中的 EPUB 卡必须被筛掉',
    );
    // 有结果时绝不能再叠「没有符合筛选的书」（旧特殊分支的矛盾空态）。
    expect(find.text(t.tag_no_books_for_filter), findsNothing,
        reason: '有命中结果时不得显示空态文案（BUG-1008）');
    // 筛选态不再丢下拉刷新（旧特殊分支没有 RefreshIndicator）。
    expect(find.byType(RefreshIndicator), findsOneWidget,
        reason: '筛选态必须保留下拉刷新（BUG-1008）');
  });

  testWidgets('BUG-1008：筛选全不命中 → 显示 tag_no_books_for_filter 空态',
      (WidgetTester tester) async {
    await seedSrt('srtMiss', '有声书');
    await seedEpub('epubMiss', '书');
    final int tagId = await db.createTag('无人命中', 0xFF445566);

    await pumpPage(tester, selectedTagIds: <int>{tagId});

    expect(find.text(t.tag_no_books_for_filter), findsOneWidget,
        reason: '整体为空时才显示空态文案');
    expect(
        find.byKey(const ValueKey<String>('srt_entry_srtMiss')), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
  });
}

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
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 书架侧（EPUB + SRT 混合库）批量合集三档组合 / 解散 widget 测试。
///
/// 与 [test/pages/home_video_batch_collection_ops_test.dart] 骨架同源，覆盖书架页
/// [_batchCombineIntoSeries] / [_batchDeleteConfirm] 三条路径，且断言全部真写穿内存 DB：
///  - 档1：epub + srt 混合散卡 → 命名弹窗新建合集，真写穿 media_collections/items；
///  - 档2：恰 1 合集 + 散卡 → 并入该合集（不弹命名）；
///  - 块4：选中合集 → 解散（deleteMediaCollection 只解组，绝不删 EPUB 本体行）。
///
/// 渲染层说明：书架 [hibikiBooksProvider] 的真实实现 `getBooksFromDb` 会 `await` 封面
/// `File.exists()` 真 I/O，这类真异步在 widget 测试的假时钟下永不完成、把书架卡住在
/// loading 态（连带 pumpAndSettle 永不收敛）。故照既有书架 widget 测试（如
/// reader_remote_collection_membership_test）的做法，把两个「读」provider 覆写成受控
/// 列表（无 File I/O）——但组合 / 解散的「写」仍打真 DB，断言只看真 DB 结果。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_shelf_batch_ops_pp');
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
  // 覆写给 hibikiBooksProvider / srtBooksProvider 的受控渲染列表（与真 DB seed 同源）。
  late List<MediaItem> epubItems;
  late List<SrtBook> srtItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_shelf_batch_ops');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
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

  // seed 一本真 EPUB（写穿 epub_books，供解散后本体保留断言），并登记受控渲染项。
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

  // seed 一本真 standalone SRT 字幕书（bookKey 空 = 非 EPUB 配对），并登记受控渲染项。
  Future<void> seedSrt(String uid, String title) async {
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = '${pathProviderDir.path}/$uid.srt'
      ..importedAt = 0
      ..bookKey = '';
    await SrtBookRepository(db).save(book);
    // 回读带上 id（书架 SRT 卡渲染需要 book.id）。
    final SrtBook? saved = await SrtBookRepository(db).findByUid(uid);
    srtItems.add(saved ?? book);
  }

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          // 覆写「读」provider 为受控列表：避免 getBooksFromDb 的封面 File.exists 真 I/O
          // 在假时钟下卡死书架加载态。「写」路径（组合 / 解散）仍打真 DB。
          hibikiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(epubItems),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(srtItems),
          ),
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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
  }

  Finder epubCard(String bookKey) => find.byKey(ValueKey<String>(
      'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}'));
  Finder srtCard(String uid) => find.byKey(ValueKey<String>('srt_entry_$uid'));

  testWidgets('触屏书卡长按保留菜单；点明确选择后才能勾选', (WidgetTester tester) async {
    await seedEpub('epubKey1', 'Epub One');
    await pumpPage(tester);

    await tester.longPress(epubCard('epubKey1'));
    await tester.pumpAndSettle();

    expect(find.text(t.dialog_delete), findsOneWidget,
        reason: '未进入选择态时，触屏长按书卡必须继续打开上下文菜单');
    expect(find.text(t.batch_selected_count(n: 1)), findsNothing,
        reason: '长按不能暗中进入多选');

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await enterSelectionMode(tester);
    await tester.tap(epubCard('epubKey1'));
    await tester.pump();

    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget,
        reason: '点明确「选择」入口后，书卡才能参与多选');
  });

  testWidgets('档1：epub + srt 混合散卡 → 命名弹窗新建合集（真写穿 DB）',
      (WidgetTester tester) async {
    await seedEpub('epubKey1', 'Epub One');
    await seedSrt('srtUid1', 'Srt One');

    await pumpPage(tester);
    // 两张散卡都渲染（EPUB + 标准 SRT 字幕书混排）。
    expect(epubCard('epubKey1'), findsOneWidget, reason: '散 EPUB 卡必须渲染');
    expect(srtCard('srtUid1'), findsOneWidget, reason: '散 SRT 卡必须渲染');

    await enterSelectionMode(tester);
    await tester.tap(epubCard('epubKey1'));
    await tester.pump();
    await tester.tap(srtCard('srtUid1'));
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey<String>('reader_shelf_batch_combine')));
    await tester.pumpAndSettle();
    // 档1（仅散卡）→ 弹命名框，确认。
    expect(find.text(t.dialog_ok), findsOneWidget, reason: '仅散卡应弹命名框');
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.length, 1, reason: '新建一个合集');
    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(collections.single.id);
    // EPUB entryKey = 裸 bookKey；SRT entryKey = 裸 uid（见 shelfSelectionToEntry）。
    expect(
      members
          .map((MediaCollectionItemRow m) => '${m.mediaType}|${m.entryKey}')
          .toSet(),
      <String>{'epub|epubKey1', 'srt|srtUid1'},
      reason: 'epub + srt 两张散卡都写进新合集',
    );
  });

  testWidgets('档2：1 合集 + 散卡 → 并入该合集（不弹命名，真写穿 DB）', (WidgetTester tester) async {
    // 合集含一个 EPUB 成员（折进合集横排行），另有一张散 EPUB 卡待并入。
    await seedEpub('memberKey', '成员书');
    await seedEpub('looseKey', '散书');
    final int cid = await db.createMediaCollection('合集乙');
    await db.addToCollection(cid, MediaKind.epub, 'memberKey');

    await pumpPage(tester);
    final Finder row =
        find.byKey(ValueKey<String>('reader_shelf_collection_row_$cid'));
    expect(row, findsOneWidget, reason: '合集横排行必须渲染');
    expect(epubCard('looseKey'), findsOneWidget, reason: '散卡必须渲染');

    await enterSelectionMode(tester);
    await tester.tap(find.text('合集乙')); // 行头整选合集
    await tester.pumpAndSettle();
    await tester.tap(epubCard('looseKey'));
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey<String>('reader_shelf_batch_combine')));
    await tester.pumpAndSettle();
    // 档2 不弹命名框。
    expect(find.text(t.dialog_ok), findsNothing, reason: '并入不应弹命名框');

    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(cid);
    expect(
      members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
      <String>{'memberKey', 'looseKey'},
      reason: '散卡并入现有合集',
    );
    expect((await db.getAllMediaCollections()).length, 1, reason: '不新建合集');
  });

  testWidgets('块4：选中合集 → 解散（deleteMediaCollection 不删 EPUB 本体）',
      (WidgetTester tester) async {
    await seedEpub('bodyKey', '正文书');
    final int cid = await db.createMediaCollection('待解散');
    await db.addToCollection(cid, MediaKind.epub, 'bodyKey');

    await pumpPage(tester);
    final Finder row =
        find.byKey(ValueKey<String>('reader_shelf_collection_row_$cid'));
    expect(row, findsOneWidget, reason: '合集横排行必须渲染');

    await enterSelectionMode(tester);
    await tester.tap(find.text('待解散'));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('reader_shelf_batch_delete')));
    await tester.pumpAndSettle();
    // 纯合集 → 解散确认文案。
    expect(find.text(t.batch_dissolve_confirm(m: 1)), findsOneWidget);
    // ReaderHistoryDeleteDialog 的确认键是 Material 破坏性 FilledButton（非 TextButton）。
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    await tester.pumpAndSettle();

    expect(await db.getMediaCollectionById(cid), isNull, reason: '合集被解散');
    // 关键：解散只解除分组，EPUB 本体行必须保留。
    expect(await db.getEpubBook('bodyKey'), isNotNull,
        reason: '解散不删 EPUB 本体（deleteMediaCollection 只删合集容器 + 成员引用）');
  });
}

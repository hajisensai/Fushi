import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/focus/hibiki_focus_target.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1009（预防性）：合集详情页成员卡的手柄/键盘焦点 id 不得与书架同名。
///
/// 详情页 push 在书架路由之上、两条路由的 FushiFocusTarget 同时存活；焦点注册表
/// 按 id 覆盖（hibiki_focus_controller.dart `_targets[id] = entry`），同名即撞号
/// ——后注册者赢、owner unregister 时另一方失联。修复 = 详情页渲染路径
/// （[_buildCollectionMemberCard]）给成员卡 focusId 加 'collection-detail-' 路由
/// 前缀，书架前缀不动（快捷键/方向锚点语义零变化）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collection_focus_pp');
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
  late List<SrtBook> srtItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_collection_focus');
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

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(epubItems),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(srtItems),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            // 焦点根置于 Navigator 之上：书架与 push 出的详情页共用同一注册表，
            // 复刻生产的「两条路由同时注册」环境。
            builder: (BuildContext context, Widget? child) =>
                FushiFocusRoot(child: child ?? const SizedBox.shrink()),
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                remoteBookClientLoader: () async => null,
              ),
            ),
          ),
        ),
      );

  testWidgets('BUG-1009：详情页成员卡 focusId 带 collection-detail- 前缀，与书架不撞号',
      (WidgetTester tester) async {
    await seedEpub('memberKey', '成员书');
    final int cid = await db.createMediaCollection('系列甲');
    await db.addToCollection(cid, MediaKind.epub, 'memberKey');
    final String mediaId = ReaderFushiSource.mediaIdentifierFor('memberKey');

    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 书架合集行内的成员卡：无前缀 id（既有语义不变）。
    List<String> onstageIds() => tester
        .widgetList<FushiFocusTarget>(find.byType(FushiFocusTarget))
        .map((FushiFocusTarget w) => w.id.value)
        .toList();
    expect(onstageIds(), contains('reader-shelf-book-$mediaId'),
        reason: '书架成员卡保持既有无前缀 focusId');

    // 进详情页。
    await tester.tap(find.text(t.collection_view_all));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCollectionGridDetailPage), findsOneWidget);

    // 详情页成员卡：带路由前缀，且不再出现与书架同名的 id。
    final List<String> detailIds = onstageIds();
    expect(detailIds, contains('collection-detail-reader-shelf-book-$mediaId'),
        reason: '详情页成员卡必须带 collection-detail- 前缀（BUG-1009）');
    expect(detailIds, isNot(contains('reader-shelf-book-$mediaId')),
        reason: '详情页（onstage）不得复用书架同名 focusId');

    // 书架路由仍在其下存活（offstage），其无前缀 id 未被改动——两条路由并存时
    // 注册表里是两个不同 id，不再互相覆盖。
    final List<String> allIds = tester
        .widgetList<FushiFocusTarget>(
            find.byType(FushiFocusTarget, skipOffstage: false))
        .map((FushiFocusTarget w) => w.id.value)
        .toList();
    expect(allIds, contains('reader-shelf-book-$mediaId'));
    expect(allIds, contains('collection-detail-reader-shelf-book-$mediaId'));
  });
}

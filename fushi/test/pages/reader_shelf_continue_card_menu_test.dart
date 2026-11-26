// BUG-5173（反馈 jhUN7a4f0j）：书架「继续阅读」行的卡只能点开，长按 / 右键没有任何
// 菜单——构造 FushiContinueEntry 时漏接 onLongPress。修复后与书架网格书卡同一个
// 书条目菜单（_showEpubItemMenu）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/shell_layout.dart';
import '../helpers/test_platform_services.dart';

class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  final List<String> opened = <String>[];

  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    opened.add(item?.mediaIdentifier ?? '');
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_continue_menu_pp',
    );
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
  late _RecordingAppModel appModel;
  late Directory storeDir;
  late List<MediaItem> epubItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_shelf_continue_menu');
    appModel = _RecordingAppModel()
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

  Future<void> seedEpub(
    String bookKey,
    String title, {
    int position = 0,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey.epub',
        extractDir: pathProviderDir.path,
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: 0,
      ),
    );
    epubItems.add(
      MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
        position: position,
        duration: 10,
        canDelete: false,
        canEdit: true,
      ),
    );
  }

  /// 两本读到一半的书：一本进「继续阅读」主卡，一本进并列卡。
  Future<void> seedLibrary() async {
    await seedEpub('heroKey', 'Hero', position: 5);
    await seedEpub('sideKey', 'Side', position: 3);
    await prefs.setShelfSortModeName('title');
  }

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(epubItems),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
      selectedTagIdsProvider.overrideWith((ref) => const <int>{}),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: gridShellTheme(),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
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

  /// 右键 [card]，断言弹出的是书条目菜单（菜单里的「详情」），点卡本身不开书。
  Future<void> expectBookMenuOnRightClick(
    WidgetTester tester,
    Finder card,
  ) async {
    expect(card, findsOneWidget);
    expect(find.text(t.book_detail_open_action), findsNothing);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final TestGesture right = await tester.startGesture(
      tester.getCenter(card),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await right.up();
    await tester.pumpAndSettle();
    expect(
      find.text(t.book_detail_open_action),
      findsOneWidget,
      reason: '右键继续卡要弹出与书架书卡同一个书条目菜单',
    );
    expect(appModel.opened, isEmpty);
  }

  testWidgets('继续阅读主卡：右键弹出书条目菜单', (WidgetTester tester) async {
    await seedLibrary();
    await pumpPage(tester);
    await expectBookMenuOnRightClick(
      tester,
      find.byKey(const ValueKey<String>('reader_shelf_continue_hero')),
    );
  });

  testWidgets('继续阅读并列卡：右键弹出书条目菜单', (WidgetTester tester) async {
    await seedLibrary();
    await pumpPage(tester);
    await expectBookMenuOnRightClick(
      tester,
      find.byKey(
        ValueKey<String>(
          'reader_shelf_continue_side/'
          '${ReaderFushiSource.mediaIdentifierFor('sideKey')}',
        ),
      ),
    );
  });

  testWidgets('继续阅读主卡：长按弹出书条目菜单', (WidgetTester tester) async {
    await seedLibrary();
    await pumpPage(tester);
    final Finder hero = find.byKey(
      const ValueKey<String>('reader_shelf_continue_hero'),
    );
    await tester.ensureVisible(hero);
    await tester.pumpAndSettle();
    await tester.longPress(hero);
    await tester.pumpAndSettle();
    expect(find.text(t.book_detail_open_action), findsOneWidget);
    expect(appModel.opened, isEmpty);
  });
}

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
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2259：书架搜索只裁 EPUB 列表，SRT 有声书卡与远端占位卡走的是未过滤源，
/// 用户实报「书架搜索不生效」——挂了有声书的书本身就以 SRT 卡渲染，等于整批
/// 搜不到。修复 = 搜索在 [_buildBodyWithSrtBooks] 内对 SRT / 远端 EPUB / 远端
/// SRT 三路同口径过滤（[matchesMediaSearch]）。
///
/// 渲染层说明（与 reader_shelf_tag_filter_empty_state_test 同源）：
/// [fushiBooksProvider] 真实实现会 `await` 封面 `File.exists()`，假时钟下永不
/// 完成，故覆写成受控列表；远端占位走 [RemoteBookClient] 假实现。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_shelf_search_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_shelf_search');
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

  Widget buildApp(RemoteBookClient? client) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
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
              body: ReaderFushiHistoryPage(
                remoteBookClientLoader: () async => client,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpPage(WidgetTester tester, {RemoteBookClient? client}) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(
      find.byKey(const ValueKey<String>('shelf_search_field')),
      query,
    );
    await tester.pumpAndSettle();
  }

  String safeKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Finder epubCard(String bookKey) => find.byKey(ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}'));
  Finder srtCard(String uid) => find.byKey(ValueKey<String>('srt_entry_$uid'));
  Finder remoteBookCard(String title) =>
      find.byKey(ValueKey<String>('remote_book_card_${safeKey(title)}'));
  Finder remoteSrtCard(String title) =>
      find.byKey(ValueKey<String>('remote_srt_card_${safeKey(title)}'));

  testWidgets('BUG-2259：搜索同口径裁掉不命中的 SRT 有声书卡，EPUB 与 SRT 命中都保留',
      (WidgetTester tester) async {
    await seedSrt('srtHit', '坂本ですが');
    await seedSrt('srtMiss', '無関係の本');
    await seedEpub('epubHit', '坂本 第二巻');
    await seedEpub('epubMiss', '別の本');

    await pumpPage(tester);
    expect(srtCard('srtMiss'), findsOneWidget, reason: '空查询不过滤');

    await search(tester, '坂本');

    expect(srtCard('srtHit'), findsOneWidget, reason: '命中的 SRT 卡保留');
    expect(epubCard('epubHit'), findsOneWidget, reason: '命中的 EPUB 卡保留');
    expect(srtCard('srtMiss'), findsNothing, reason: '不命中的 SRT 卡必须被搜索裁掉');
    expect(epubCard('epubMiss'), findsNothing, reason: '不命中的 EPUB 卡被裁掉');
  });

  testWidgets('BUG-2259：搜索全不命中 → 空态而非渲染全部 SRT 卡', (WidgetTester tester) async {
    await seedSrt('srtOnly', '有声書だけ');

    await pumpPage(tester);
    await search(tester, 'zzz-no-such-title');

    expect(srtCard('srtOnly'), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing,
        reason: '零命中走空态分支，不再渲染网格');
  });

  testWidgets('BUG-2259：远端 EPUB / 纯 SRT 占位卡同样随搜索过滤',
      (WidgetTester tester) async {
    await pumpPage(
      tester,
      client: _ListFakeRemoteBookClient(
        const <RemoteBookInfo>[
          RemoteBookInfo(title: 'Remote Sakamoto', hasContent: true),
          RemoteBookInfo(title: 'Remote Other', hasContent: true),
        ],
        const <RemoteAudiobookInfo>[
          RemoteAudiobookInfo(
              bookKey: '', uid: 'rsHit', title: 'Audio Sakamoto'),
          RemoteAudiobookInfo(bookKey: '', uid: 'rsMiss', title: 'Audio Other'),
        ],
      ),
    );
    expect(remoteBookCard('Remote Other'), findsOneWidget);
    expect(remoteSrtCard('Audio Other'), findsOneWidget);

    await search(tester, 'sakamoto');

    expect(remoteBookCard('Remote Sakamoto'), findsOneWidget);
    expect(remoteSrtCard('Audio Sakamoto'), findsOneWidget);
    expect(remoteBookCard('Remote Other'), findsNothing,
        reason: '不命中的远端 EPUB 占位卡必须被裁掉');
    expect(remoteSrtCard('Audio Other'), findsNothing,
        reason: '不命中的远端 SRT 占位卡必须被裁掉');
  });
}

/// 互联后端假实现：standalone SRT 占位卡只对 [InterconnectSyncBackend] 类型开放，
/// 普通 [RemoteBookClient] fake 进不了这条路（与 reader_remote_download_failure_badge_test 同源）。
class _ListFakeRemoteBookClient extends InterconnectSyncBackend {
  _ListFakeRemoteBookClient(this._books, this._audiobooks)
      : super.withProbe((String url, String token) async => true);
  final List<RemoteBookInfo> _books;
  final List<RemoteAudiobookInfo> _audiobooks;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => _books;

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async => _audiobooks;
}

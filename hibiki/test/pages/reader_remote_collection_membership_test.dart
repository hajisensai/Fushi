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
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 多端库联合视图 §2.3 任务10：远端书占位卡的合集归属。host 下发的
/// [RemoteBookInfo.collection]（自然键 name+type）解析到本地合集 → 远端占位折进该合集
/// 横排行；解析不到本地合集 → 散卡降级（进散卡网格，不硬造行）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_coll_book_pp');
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

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_coll_book_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp(RemoteBookClient client) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) =>
                Future<List<MediaItem>>.value(const <MediaItem>[]),
          ),
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
                remoteBookClientLoader: () async => client,
              ),
            ),
          ),
        ),
      );

  String safeKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  testWidgets('远端书归属命中本地合集 → 占位卡折进该合集横排行', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int cid =
        await db.createMediaCollection('MyShow', collectionType: 'collection');

    await tester.pumpWidget(buildApp(_ListFakeRemoteBookClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(
          title: 'Remote Vol2',
          hasContent: true,
          collection: RemoteCollectionMembership(
            collectionName: 'MyShow',
            collectionType: 'collection',
            sortIndex: 1,
          ),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    final Finder collectionRow =
        find.byKey(ValueKey<String>('reader_shelf_collection_row_$cid'));
    expect(collectionRow, findsOneWidget, reason: '本地合集横排行必须渲染');
    final Finder remoteCard = find
        .byKey(ValueKey<String>('remote_book_card_${safeKey('Remote Vol2')}'));
    expect(remoteCard, findsOneWidget, reason: '远端占位书卡必须渲染');
    expect(
      find.ancestor(of: remoteCard, matching: collectionRow),
      findsOneWidget,
      reason: '远端书归属命中本地合集 → 必须折进该合集横排行（非散卡）',
    );
  });

  testWidgets('合集行计数计入折进来的远端占位卡（旧口径只数本地成员显示 0）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 本地合集为空（0 本地成员），只有一本 host 下发、折进该合集的远端占位书。
    await db.createMediaCollection('MyShow', collectionType: 'collection');

    await tester.pumpWidget(buildApp(_ListFakeRemoteBookClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(
          title: 'Remote Vol1',
          hasContent: true,
          collection: RemoteCollectionMembership(
            collectionName: 'MyShow',
            collectionType: 'collection',
            sortIndex: 0,
          ),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    // 行头计数须诚实反映行体渲染的卡片数（含远端占位）：1 本，不是本地 0 本。
    // 旧 localCount 口径会显示 '0 items'，与眼前 1 张远端卡割裂（BUG-790 书籍侧同款）。
    expect(find.text('1 items'), findsOneWidget, reason: '合集行计数须计入折进来的远端占位卡');
    expect(find.text('0 items'), findsNothing,
        reason: '只数本地成员会显示 0，与所见 1 张远端卡割裂');
  });

  testWidgets('远端书归属解析不到本地合集 → 散卡降级（进散卡网格）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 本地无 'Ghost' 合集。
    await tester.pumpWidget(buildApp(_ListFakeRemoteBookClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(
          title: 'Orphan Book',
          hasContent: true,
          collection: RemoteCollectionMembership(
            collectionName: 'Ghost',
            collectionType: 'collection',
            sortIndex: 0,
          ),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    final Finder remoteCard = find
        .byKey(ValueKey<String>('remote_book_card_${safeKey('Orphan Book')}'));
    expect(remoteCard, findsOneWidget);
    expect(
      find.ancestor(of: remoteCard, matching: find.byType(SliverGrid)),
      findsOneWidget,
      reason: '归属解析不到本地合集 → 占位卡落散卡网格（散卡降级）',
    );
  });
}

class _ListFakeRemoteBookClient implements RemoteBookClient {
  _ListFakeRemoteBookClient(this._books);
  final List<RemoteBookInfo> _books;

  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => _books;

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await destination.writeAsBytes(<int>[1]);
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

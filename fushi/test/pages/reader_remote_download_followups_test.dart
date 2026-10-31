// BUG-3452（反馈 FvgH1f3vZ_ 追加）：从互联对端下载书之后——
// ① 下载完的书在合集外多出一张「未下载」占位卡；
// ② 合集册数逐渐涨到两倍，很久后或重启才恢复；
// ④ 「最近阅读」排序下刚下载的书排最前，而不是按它在对端的阅读时间。
// ⑤（审查补记）沿用对端入库时刻后，第三台设备在「对端入库 < 删除 < 本机下载」之间
//    做的「从所有设备删除」让本机下载完就弹删除确认——仲裁改读本机拥有时刻（v118）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_book_identity_index.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

import '../helpers/test_platform_services.dart';
import '../sync/fake_asset_store.dart';

void main() {
  group('去重与收养（数据层）', () {
    test('host bookKey 与书名不同源：按别名里的对端键也能去重', () {
      const RemoteBookInfo book = RemoteBookInfo(
        title: 'Some Title',
        bookKey: 'host-key-from-filename',
        hasContent: true,
      );
      expect(
        dedupeRemoteBooks(
          remote: const <RemoteBookInfo>[book],
          // 本机落地键与书名键都对不上，只有下载时记下的别名（= 对端键）在集合里。
          localBookKeys: <String>{'Local (2)', 'host-key-from-filename'},
          keyOf: sanitizeTtuFilename,
        ),
        isEmpty,
        reason: '下载完的书不能继续以「未下载」占位卡挂在书架上',
      );
    });

    test('清单收养用的身份快照过期时，不把已提升的占位成员插回合集', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      const RemoteBookInfo vol = RemoteBookInfo(
        title: 'Vol1',
        hasContent: true,
        collection: RemoteCollectionMembership(
          collectionName: 'Series',
          collectionType: 'collection',
          sortIndex: 0,
        ),
      );
      final RemoteCollectionAdoptionService adoption =
          RemoteCollectionAdoptionService(db);
      // 目录刷新先写下对端键的占位成员。
      await adoption.adoptBooks(const <RemoteBookInfo>[vol]);
      // 下一轮目录刷新开始：身份快照在下载落地之前取的。
      final CollectionBookIdentityIndex stale =
          await CollectionBookIdentityIndex.load(db);
      // 这一轮循环期间下载落地：入库（本机键带后缀）+ 占位成员提升成本地 uid。
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Vol1 (2)',
          title: 'Vol1',
          epubPath: 'x.epub',
          extractDir: 'x',
          chapterCount: 1,
          chaptersJson: '["a"]',
          importedAt: 1,
        ),
      );
      final EpubBookRow local = (await db.getEpubBook('Vol1 (2)'))!;
      await adoption.adoptBook(vol, localBook: local);
      // 循环走到这本书，拿着过期快照收养。
      await adoption.adoptBook(vol, identities: stale);

      final List<MediaCollectionItemRow> members = await db
          .getAllCollectionItems();
      expect(members.map((MediaCollectionItemRow m) => m.entryKey), <String>[
        local.uid,
      ], reason: '对端键的占位行被插回来 = 合集里同一本书两行（册数翻倍）');
    });
  });

  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_remote_followups_pp',
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
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp.createTempSync(
          'fushi_remote_followups_store',
        ),
      );
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  int extractSeq = 0;

  /// 注入的导入器：按落地文件名（= 书名）建一行真 EpubBooks，返回本机 bookKey。
  Future<String?> importAs(File file) async {
    final String title = file.uri.pathSegments.last.replaceAll('.epub', '');
    final Directory extract = Directory(
      '${pathProviderDir.path}/extract_${extractSeq++}',
    )..createSync();
    final String key = sanitizeTtuFilename(title);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: title,
        epubPath: file.path,
        extractDir: extract.path,
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return key;
  }

  /// 书列表 provider 用真的（订阅书集合流），与生产同路径。
  Widget buildApp(RemoteBookClient client) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            remoteBookClientLoader: () async => client,
            remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                File('${pathProviderDir.path}/${book.title}.epub'),
            remoteBookImporter: importAs,
          ),
        ),
      ),
    ),
  );

  /// 真 DB IO 与防抖定时器交替推进。
  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 网格里那张卡上的书名（书架顶部「继续阅读」条也会显示书名）。
  // 按卡片文字块（ShelfCardMeta）的标题找，而不是 find.text：副行状态文案
  // （如「Unread」）可能与书名撞字。
  Finder inGrid(String title) => find
      .descendant(
        of: find.byType(SliverGrid),
        matching: find.byWidgetPredicate(
          (Widget w) => w is ShelfCardMeta && w.title == title,
        ),
      )
      .first;

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('①② 合集成员落地后、任务收尾前：占位卡不再出现，册数不变', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    RemoteBookInfo member(String title, int index) => RemoteBookInfo(
      title: title,
      hasContent: true,
      collection: RemoteCollectionMembership(
        collectionName: 'Series',
        collectionType: 'collection',
        sortIndex: index,
      ),
    );
    final _ProgressGatedClient client = _ProgressGatedClient(<RemoteBookInfo>[
      member('Vol1', 0),
      member('Vol2', 1),
      member('Vol3', 2),
    ]);
    await tester.pumpWidget(buildApp(client));
    await settle(tester);
    expect(
      find.textContaining(t.shelf_collection_volume_count(n: 3)),
      findsOneWidget,
    );
    final int cid = (await db.getAllMediaCollections()).single.id;

    // 合集详情页里点 Vol1 下载：EPUB 落地，任务停在「拉对端进度」这一步（真机上
    // 后面还有有声书包，可以很久）。
    await tester.tap(
      find.byKey(ValueKey<String>('reader_shelf_collection_card_$cid')),
    );
    await settle(tester, rounds: 5);
    await tester.tap(
      find.byKey(const ValueKey<String>('remote_book_card_Vol1')).last,
      warnIfMissed: false,
    );
    await settle(tester);
    expect(
      client.progressRequested,
      contains('Vol1'),
      reason: '前置：Vol1 已入库，任务卡在拉进度',
    );
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('remote_book_card_Vol1')),
      findsNothing,
      reason: '已落地的书不能再以占位卡挂在书架上（合集外的「未下载」卡）',
    );
    expect(
      find.textContaining(t.shelf_collection_volume_count(n: 3)),
      findsOneWidget,
      reason: '本地卡 + 旧占位卡同在合集里 = 册数翻倍',
    );

    client.releaseProgress();
    await settle(tester);
    expect(
      find.textContaining(t.shelf_collection_volume_count(n: 3)),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote_book_card_Vol1')),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets('③ 散本下载完：滚动位置不动，书留在占位卡原位不跳到顶部', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _ProgressGatedClient client = _ProgressGatedClient(<RemoteBookInfo>[
      for (int i = 0; i < 40; i++)
        RemoteBookInfo(
          title: 'Cloud${i.toString().padLeft(2, '0')}',
          hasContent: true,
          // 目录序 = 入库时刻倒序：Cloud00 最新。
          importedAt: 100000 - i,
        ),
    ], gated: false);
    await tester.pumpWidget(buildApp(client));
    await settle(tester);

    ScrollController shelf() => tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await settle(tester, rounds: 5);
    final double offset = shelf().offset;
    expect(offset, greaterThan(300), reason: '前置：书架已经滚下去了');

    // 挑一张此刻完整可见的占位卡（按几何现挑，不钉死书名：页头 / 网格尺寸
    // 一变，滚 900 后落在屏上的那排就不同）。
    final double viewportBottom = tester
        .getRect(find.byType(CustomScrollView))
        .bottom;
    final String title =
        <String>[
          for (int i = 10; i < 40; i++) 'Cloud${i.toString().padLeft(2, '0')}',
        ].firstWhere((String name) {
          final Finder card = find.byKey(
            ValueKey<String>('remote_book_card_$name'),
          );
          if (card.hitTestable().evaluate().isEmpty) return false;
          final Rect rect = tester.getRect(card);
          return rect.top >= 0 && rect.bottom <= viewportBottom;
        });
    final Finder target = find.byKey(
      ValueKey<String>('remote_book_card_$title'),
    );
    final Offset before = tester.getTopLeft(inGrid(title));

    await tester.tap(target);
    await settle(tester);

    expect(
      find.byKey(ValueKey<String>('remote_book_card_$title')),
      findsNothing,
      reason: '前置：已下载成本地卡',
    );
    expect(shelf().offset, offset, reason: '下载完成不能把书架滚回顶部');
    // 本地卡与占位卡的文字块排版略有差异，比较的是它落在哪一格。
    final Offset after = tester.getTopLeft(inGrid(title));
    expect(
      (after - before).distance,
      lessThan(48),
      reason: '对端没读过的书按未读排：留在占位卡原来的格子，不因下载时刻顶到最前',
    );
    await unmount(tester);
  });

  testWidgets('④ 「最近阅读」下载下来的书按对端阅读时间排，对端没读过的按未读排', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 本机已有一本，最后阅读时刻 1500。
    final Directory localExtract = Directory(
      '${pathProviderDir.path}/local_extract',
    )..createSync(recursive: true);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Local',
        title: 'Local',
        epubPath: '${localExtract.path}/x.epub',
        extractDir: localExtract.path,
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: 10,
      ),
    );
    final String localUid = (await db.getEpubBook('Local'))!.uid;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value<String>(localUid),
        sectionIndex: const Value<int>(0),
        normCharOffset: const Value<int>(10),
        charOffset: const Value<int>(10),
        updatedAt: const Value<int>(1500),
      ),
    );

    final _ProgressGatedClient client = _ProgressGatedClient(
      const <RemoteBookInfo>[
        // 对端读过（2000，比本机那本新）。
        RemoteBookInfo(
          title: 'ReadOnPeer',
          hasContent: true,
          importedAt: 100,
          progressUpdatedAtMs: 2000,
        ),
        // 对端没读过，入库时刻 1000（比本机那本的阅读时刻旧）。
        RemoteBookInfo(title: 'Unread', hasContent: true, importedAt: 1000),
      ],
      progress: <String, RemoteBookProgress>{
        'ReadOnPeer': const RemoteBookProgress(
          sectionIndex: 0,
          normCharOffset: 20,
          charOffset: 20,
          updatedAtMs: 2000,
        ),
      },
      gated: false,
    );
    await tester.pumpWidget(buildApp(client));
    await settle(tester);

    for (final String title in <String>['ReadOnPeer', 'Unread']) {
      await tester.tap(find.byKey(ValueKey<String>('remote_book_card_$title')));
      await settle(tester);
    }
    expect(
      find.byKey(const ValueKey<String>('remote_book_card_ReadOnPeer')),
      findsNothing,
      reason: '前置：两本都已下载成本地卡',
    );
    expect(
      find.byKey(const ValueKey<String>('remote_book_card_Unread')),
      findsNothing,
    );
    expect(
      (await db.getEpubBook('Unread'))!.importedAt,
      1000,
      reason: '刚落地的书沿用它在对端的入库时刻，而不是下载那一刻',
    );

    double x(String title) => tester.getTopLeft(inGrid(title)).dx;
    expect(
      x('ReadOnPeer') < x('Local') && x('Local') < x('Unread'),
      isTrue,
      reason:
          '最近阅读：对端 2000 > 本机 1500 > 对端未读（入库 1000）；'
          '下载时刻不能把它们顶到最前',
    );
    await unmount(tester);
  });

  testWidgets('⑤ 第三台设备在对端入库后、本机下载前「从所有设备删除」：本机下载后不弹删除确认', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 对端很早以前入库（1000）；第三台设备在 5000 删了它（经云通道发布墓碑），
    // 本机此刻（远晚于 5000）才从对端把它下载下来。
    const String title = 'DeletedElsewhere';
    final _ProgressGatedClient client = _ProgressGatedClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(title: title, hasContent: true, importedAt: 1000),
      ],
      gated: false,
    );
    await tester.pumpWidget(buildApp(client));
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('remote_book_card_$title')),
    );
    await settle(tester);
    final EpubBookRow landed = (await tester.runAsync<EpubBookRow?>(
      () => db.getEpubBook(sanitizeTtuFilename(title)),
    ))!;
    expect(landed.importedAt, 1000, reason: '前置：沿用对端入库时刻（BUG-3452）');
    await unmount(tester);

    final _TombstoneBackend backend = _TombstoneBackend(FakeAssetStore());
    final Directory tmp = Directory.systemTemp.createTempSync(
      'fushi_remote_followups_sync',
    );
    addTearDown(() => tmp.deleteSync(recursive: true));
    final SyncRunReport report = SyncRunReport();
    await tester.runAsync(() async {
      final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
      await backend.putJsonAsset(
        ns,
        deletionTombstoneAssetName(
          SyncTombstoneKind.book.dbValue,
          landed.bookKey,
        ),
        deletionTombstoneJson(
          SyncTombstoneKind.book.dbValue,
          landed.bookKey,
          5000,
        ),
      );
      await SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      ).syncDeletionTombstones(report);
    });

    expect(
      report.deletionCandidates,
      isEmpty,
      reason:
          '删除发生在本机拥有之前：用户是之后才从对端取回的，'
          '不能一下完就问「其他设备已删除，本地也删？」',
    );
  });
}

/// 只实现删除墓碑消费路径走到的成员（同 deletion_tombstone_rearm_orchestrator_test）。
class _TombstoneBackend implements SyncBackend {
  _TombstoneBackend(this._store);
  final FakeAssetStore _store;

  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);

  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_TombstoneBackend.${invocation.memberName}');
}

/// 下载体立即写盘；[gated] 时「拉对端进度」挂起，模拟落地后任务还没收尾的空窗。
class _ProgressGatedClient implements RemoteBookClient {
  _ProgressGatedClient(
    this._books, {
    this.progress = const <String, RemoteBookProgress>{},
    this.gated = true,
  });

  final List<RemoteBookInfo> _books;
  final Map<String, RemoteBookProgress> progress;
  final bool gated;
  final List<String> progressRequested = <String>[];
  final Completer<void> _gate = Completer<void>();

  void releaseProgress() {
    if (!_gate.isCompleted) _gate.complete();
  }

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
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async {
    progressRequested.add(bookKey);
    if (gated) await _gate.future;
    return progress[bookKey] ?? RemoteBookProgress.empty;
  }

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

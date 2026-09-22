import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_conflict_prompter.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// One chapter of 1000 characters keeps fraction math simple.
const String _chaptersJson = '[{"characters":1000}]';

/// Backend test double for the conflict-resolution surface presented by
/// [SyncConflictPrompter.present] → [SyncCompareDialog] (conflictsOnly). Same
/// shape as the compare-dialog test's fake: the `_load` path reads listBooks →
/// listSyncFiles → getProgressFile; members off that path throw.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.remoteBooks});

  final Map<String, _RemoteBook> remoteBooks;
  final Map<String, TtuProgress> exportedByFolder = <String, TtuProgress>{};

  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      <SyncFileRef>[
        for (final MapEntry<String, _RemoteBook> e in remoteBooks.entries)
          SyncFileRef(id: e.value.folderId, name: e.key),
      ];
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  void evictFolderId(String folderId) {}
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final _RemoteBook? book = _byFolder(folderId);
    if (book == null) return const SyncFileTrio();
    return SyncFileTrio(progress: book.progressFile);
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    for (final _RemoteBook b in remoteBooks.values) {
      if (b.progressFile?.id == fileId) return b.payload!;
    }
    throw StateError('no remote progress payload for $fileId');
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exportedByFolder[folderId] = progress;
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async =>
      remoteBooks[bookTitle]?.folderId ?? 'folder-$bookTitle';

  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      const <AssetEntry>[];

  _RemoteBook? _byFolder(String folderId) {
    for (final _RemoteBook b in remoteBooks.values) {
      if (b.folderId == folderId) return b;
    }
    return null;
  }

  String? _cachedRoot;
  final Map<String, String> _cachedFolders = <String, String>{};
  @override
  void clearCache() {
    _cachedRoot = null;
    _cachedFolders.clear();
  }

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {
    _cachedRoot = rootFolderId;
    if (titleToFolderId != null) _cachedFolders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _cachedRoot;
  @override
  Map<String, String> get cachedFolderIds => _cachedFolders;
  @override
  Future<bool> get isAuthenticated async => true;

  @override
  Future<String?> get currentEmail async => throw UnimplementedError();
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async =>
      throw UnimplementedError();
  @override
  Future<void> refreshAuth() async => throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<SyncFileRef?> findContentFile(
          String folderId, String fileName) async =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
}

class _RemoteBook {
  _RemoteBook({required this.folderId, this.progressFile, this.payload});

  final String folderId;
  final SyncFileRef? progressFile;
  final TtuProgress? payload;

  factory _RemoteBook.withProgress({
    required String folderId,
    required int timestampMs,
    required double fraction,
  }) {
    final int exploredChars = (fraction * 1000).round();
    return _RemoteBook(
      folderId: folderId,
      progressFile: SyncFileRef(
        id: 'progress-$folderId',
        name: progressFileName(timestampMs, fraction),
      ),
      payload: TtuProgress(
        dataId: 0,
        exploredCharCount: exploredChars,
        progress: fraction,
        lastBookmarkModified: timestampMs,
      ),
    );
  }
}

Future<EpubBookRow> _seedBook(FushiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: _chaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
}

Future<void> _seedPosition(
  FushiDatabase db,
  String bookUid, {
  required int updatedAt,
  required double fraction,
}) async {
  final int normOffset = (fraction * 10000).round();
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookUid: Value(bookUid),
    sectionIndex: const Value(0),
    normCharOffset: Value(normOffset),
    updatedAt: Value(updatedAt),
  ));
}

/// One genuine fork (both sides off baseline) → SyncCompareDialog renders it as
/// a conflict.
List<SyncConflict> _oneConflict() => <SyncConflict>[
      SyncConflict(
        assetKey: sanitizeTtuFilename('BookA'),
        dimension: 'progress',
        title: 'BookA',
        localVersion: 120,
        remoteVersion: 100,
      ),
    ];

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Seeds a forked BookA (both sides off baseline 50) so the conflictsOnly
  /// dialog has a real conflict row to render.
  Future<(FushiDatabase, _FakeSyncBackend)> seedForkedLibrary() async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);
    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'BookA': _RemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: 100,
          fraction: 0.4,
        ),
      },
    );
    return (db, fake);
  }

  /// Pumps a real app with an attached navigatorKey, then fires
  /// `prompter.present(...)` over that key and settles. The MaterialApp must be
  /// pumped (navigator attached) before present runs so
  /// `navigatorKey.currentContext` is non-null.
  ///
  /// [body] is started but NOT awaited to completion: when present DOES show the
  /// conflict dialog, its future only resolves once the (barrier-undismissible)
  /// dialog is popped, so awaiting it here would deadlock pumpAndSettle. The
  /// caller pops the dialog after asserting (see showing tests). When present
  /// suppresses the dialog, its future completes immediately and there is
  /// nothing left pending.
  Future<void> pumpAndPresent(
    WidgetTester tester, {
    required SyncConflictPrompter prompter,
    required GlobalKey<NavigatorState> navKey,
    required Future<void> Function() body,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(body());
    await tester.pumpAndSettle();
  }

  /// Pops the open conflict dialog with a null result (user cancelled) and
  /// settles, letting the pending `present` future resolve so no work is left
  /// dangling after the test body returns.
  Future<void> dismissDialog(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey,
  ) async {
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('manual source presents the conflict resolution dialog',
      (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.manual,
        inBook: true, // manual ignores in-book.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);

    await dismissDialog(tester, navKey);
  });

  // 用户报告 2026-09-22：一次手动同步跑两条通道（云备份 + 互联），同一本书在两条
  // 通道上都分叉时逐通道各弹一次同样的弹窗——用户点完「立即同步」它紧接着又弹。
  // 现在两条通道共用一本裁决簿：第一条通道里用户裁决过的书，第二条通道直接按同一
  // 裁决应用并关闭，不再问。
  testWidgets(
      'resolving through the dialog records the decision on the '
      'shared ledger', (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final Map<String, SyncChoice> decisions = <String, SyncChoice>{};

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.manual,
        inBook: false,
        decisions: decisions,
      ),
    );
    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(decisions, isEmpty, reason: '裁决簿只在用户真的裁决后才写');

    await tester.tap(find.text(t.sync_compare_use_local).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    expect(find.byType(SyncCompareDialog), findsNothing);
    expect(fake.exportedByFolder['folderA']?.lastBookmarkModified, 120);
    expect(decisions, <String, SyncChoice>{
      sanitizeTtuFilename('BookA'): SyncChoice.useLocal,
    });
  });

  testWidgets(
      'a book already decided on the ledger is applied on the next '
      'channel without prompting again', (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    // 第一条通道已裁决「用本地」；这里模拟第二条通道的 present。
    final Map<String, SyncChoice> decisions = <String, SyncChoice>{
      sanitizeTtuFilename('BookA'): SyncChoice.useLocal,
    };
    bool presented = false;

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter
          .present(
            navigatorKey: navKey,
            db: db,
            backend: fake,
            conflicts: _oneConflict(),
            source: ConflictSource.manual,
            inBook: false,
            decisions: decisions,
          )
          .then((_) => presented = true),
    );

    // 没等用户：弹窗已自行应用并关闭，present 也已经返回。
    expect(find.byType(SyncCompareDialog), findsNothing,
        reason: '同一本书用户只裁决一次，第二条通道不再弹');
    expect(presented, isTrue);
    expect(fake.exportedByFolder['folderA']?.lastBookmarkModified, 120,
        reason: '第二条通道按同一裁决真的应用了（本机推过去）');
    expect(await db.getSyncBaseline(sanitizeTtuFilename('BookA'), 'progress'),
        120);
  });

  // 簿上记的是用户的真实选择。第一条通道用户选了「用远端」——本机被写成云盘那
  // 份；第二条通道（互联 host）的远端若自己也动过，那是用户从没见过的第三个值，
  // 按簿自动「把本机推过去」就是把 host 更新的进度盖掉——PC 既是互联 host 又往云
  // 盘导出的用户会在这里丢进度。真分叉必须照旧弹给用户看。
  testWidgets(
      'a book decided "use remote" on the ledger still prompts on the next '
      'channel when that channel has its own fork',
      (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final Map<String, SyncChoice> decisions = <String, SyncChoice>{
      sanitizeTtuFilename('BookA'): SyncChoice.useRemote,
    };

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.manual,
        inBook: false,
        decisions: decisions,
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget,
        reason: '本通道远端自己动过，用户没裁决过这个值，必须弹');
    expect(fake.exportedByFolder, isEmpty, reason: '不得按簿自动把本机推给这条通道');
    // 用户在这里真的裁决后，簿上记的也是这一次的真实选择。
    await tester.tap(find.text(t.sync_compare_use_remote).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();
    expect(find.byType(SyncCompareDialog), findsNothing);
    expect(decisions[sanitizeTtuFilename('BookA')], SyncChoice.useRemote);
  });

  testWidgets('a book skipped on the ledger is not prompted again either',
      (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final Map<String, SyncChoice> decisions = <String, SyncChoice>{
      sanitizeTtuFilename('BookA'): SyncChoice.skip,
    };

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.manual,
        inBook: false,
        decisions: decisions,
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
    expect(fake.exportedByFolder, isEmpty, reason: '跳过 = 两端都不动');
  });

  testWidgets('auto source while in-book does NOT present',
      (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: true, // auto + in-book is suppressed.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
  });

  testWidgets('background source never presents', (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.background,
        inBook: false,
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
  });

  testWidgets('auto source out-of-book presents the dialog',
      (WidgetTester tester) async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: false, // out of book → auto can prompt.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);

    await dismissDialog(tester, navKey);
  });
}

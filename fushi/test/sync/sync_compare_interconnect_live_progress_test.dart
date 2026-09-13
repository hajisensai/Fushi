import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2497：互联通道的冲突对比弹窗此前只看 host 上的 WebDAV 文件箱
/// （`progress_*.json`，client 自己写、host 从不读回），永远看不到「host DB 与本机
/// 的分歧」，也解决不了它。现在互联 live 行按 host DB 进度 + 位置基线三方判定，
/// Apply 经 live 端点落地。本测试用一个只实现 live 端点的假互联后端驱动真弹窗。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 一章 1000 字：normCharOffset 0..10000 线性对应阅读分数。
const String _chaptersJson = '[{"characters":1000}]';

class _FakeInterconnectBackend extends InterconnectSyncBackend {
  _FakeInterconnectBackend({required this.hostProgress})
      : super.withProbe((String url, String token) async => true);

  /// host DB 里各书的进度（bookKey → 进度；不在表里 = host 无记录）。
  final Map<String, RemoteBookProgress> hostProgress;

  /// client PUT 上来的进度（bookKey → 最后一次）。
  final Map<String, RemoteBookProgress> putProgress =
      <String, RemoteBookProgress>{};

  /// 文件箱写入（SyncManager 手动导出仍会走到这里；对互联是 dead weight）。
  final Map<String, TtuProgress> exportedByFolder = <String, TtuProgress>{};

  // ── live 端点（本测试的主角）──────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
        for (final String key in hostProgress.keys)
          RemoteBookInfo(title: key, hasContent: true, bookKey: key),
      ];

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      hostProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    putProgress[bookKey] = progress;
    // 与真 host 同语义：取较新落库。
    final RemoteBookProgress current =
        hostProgress[bookKey] ?? RemoteBookProgress.empty;
    hostProgress[bookKey] = resolveBookProgressSync(
      local: current,
      remote: progress,
    );
  }

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async =>
      const <RemoteAudiobookInfo>[];

  // ── 弹窗 _load / Apply 路径会碰到的 WebDAV 文件箱面（全部就地 no-op）──
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      const <SyncFileRef>[];
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}
  @override
  void evictFolderId(String folderId) {}
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async =>
      'folder-$bookTitle';
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exportedByFolder[folderId] = progress;
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {}
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {}
  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      const <AssetEntry>[];

  String? _cachedRoot;
  final Map<String, String> _cachedFolders = <String, String>{};
  @override
  void clearCache() {
    _cachedRoot = null;
    _cachedFolders.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _cachedRoot = rootFolderId;
    if (titleToFolderId != null) _cachedFolders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _cachedRoot;
  @override
  Map<String, String> get cachedFolderIds => _cachedFolders;
}

Future<EpubBookRow> _seedBook(FushiDatabase db, String title) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '/fake/$title.epub',
      extractDir: '/fake/$title',
      chapterCount: 1,
      chaptersJson: _chaptersJson,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
}

Future<void> _seedPosition(
  FushiDatabase db,
  String bookUid, {
  required int norm,
  required int updatedAt,
}) =>
    db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(bookUid),
        sectionIndex: const Value(0),
        normCharOffset: Value(norm),
        charOffset: const Value(-1),
        updatedAt: Value(updatedAt),
      ),
    );

Future<void> _seedBaseline(FushiDatabase db, String bookKey, int norm) =>
    db.setSyncBaseline(
      bookKey,
      kInterconnectBookProgressDimension,
      BookProgressBaseline(sectionIndex: 0, normCharOffset: norm).encode(),
    );

RemoteBookProgress _host(int norm, int updatedAt) => RemoteBookProgress(
      sectionIndex: 0,
      normCharOffset: norm,
      charOffset: -1,
      updatedAtMs: updatedAt,
    );

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<void> pumpDialog(
    WidgetTester tester,
    FushiDatabase db,
    _FakeInterconnectBackend fake, {
    bool conflictsOnly = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(
              db: db,
              backend: fake,
              conflictsOnly: conflictsOnly,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'both sides moved off the position baseline -> conflict row '
      'with host DB progress in the remote column', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
    await _seedBaseline(db, 'BookA', 1000);
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(9000, 5000)},
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);
    // 远端列是 host DB 的 90.0%，不是文件箱（这里根本没有文件箱数据）。
    expect(find.text('90.0%'), findsOneWidget);
    expect(find.text('30.0%'), findsOneWidget);
  });

  testWidgets(
      'host merely reopened (position on baseline) while local read '
      'on -> not a conflict', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, norm: 5000, updatedAt: 2000);
    await _seedBaseline(db, 'BookA', 1000);
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(1000, 9000)},
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    // conflictsOnly 模式下没有冲突 → 空态，而不是把「host 时间戳更新」当分叉。
    expect(find.text(t.sync_compare_conflicts), findsNothing);
    expect(find.text('BookA'), findsNothing);
  });

  testWidgets('no baseline yet and both differ -> conflict (no silent LWW)', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(9000, 5000)},
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
  });

  testWidgets(
      'Apply "use local" pushes local progress to host DB with a '
      'strictly newer timestamp and records the baseline', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
    await _seedBaseline(db, 'BookA', 1000);
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(9000, 5000)},
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);

    // 英文下 sync_compare_local（列头）与 sync_compare_use_local（分段按钮）同为
    // "Local"：列头在前、分段按钮在后，取 last 才是可点的那个。
    await tester.tap(find.text(t.sync_compare_use_local).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    final RemoteBookProgress? pushed = fake.putProgress['BookA'];
    expect(pushed, isNotNull, reason: '选本机必须经 live 端点推给 host');
    expect(pushed!.normCharOffset, 3000);
    expect(
      pushed.updatedAtMs,
      greaterThan(5000),
      reason: 'host 端仍取较新，时间戳不严格新于 host 会被静默丢弃',
    );
    expect(
      fake.hostProgress['BookA']!.normCharOffset,
      3000,
      reason: 'host DB 真的换成了本机位置',
    );
    // 本机行与 host 对齐到同一时刻，基线推进到本机位置。
    final ReaderPositionRow? local = await db.getReaderPosition(book.uid);
    expect(local!.normCharOffset, 3000);
    expect(local.updatedAt, pushed.updatedAtMs);
    expect(
      BookProgressBaseline.decode(
        await db.getSyncBaseline('BookA', kInterconnectBookProgressDimension),
      ),
      isA<BookProgressBaseline>().having((b) => b.normCharOffset, 'norm', 3000),
    );
  });

  testWidgets(
      'Apply "use remote" lands host DB progress locally and records '
      'the baseline', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
    await _seedBaseline(db, 'BookA', 1000);
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(9000, 5000)},
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);

    await tester.tap(find.text(t.sync_compare_use_remote).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    final ReaderPositionRow? local = await db.getReaderPosition(book.uid);
    expect(local!.normCharOffset, 9000, reason: '选远端 → host 位置落回本机');
    expect(local.updatedAt, 5000);
    expect(fake.putProgress, isEmpty, reason: '选远端不该往 host 推任何东西');
    expect(
      BookProgressBaseline.decode(
        await db.getSyncBaseline('BookA', kInterconnectBookProgressDimension),
      ),
      isA<BookProgressBaseline>().having((b) => b.normCharOffset, 'norm', 9000),
    );
  });
}

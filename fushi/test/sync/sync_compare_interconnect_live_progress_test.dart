import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2506：互联通道的冲突对比弹窗此前只看 host 上的 WebDAV 文件箱
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

  /// 让接下来 N 次 live 进度 GET 抛错（模拟加载期一次网络失败）。
  int failRemoteProgressReads = 0;

  /// host 文件箱里 client 自己上次导出的 `progress_*.json`（按书名）；null = 空箱。
  final Map<String, TtuProgress> fileBoxProgress = <String, TtuProgress>{};

  // ── live 端点（本测试的主角）──────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
    for (final String key in hostProgress.keys)
      RemoteBookInfo(title: key, hasContent: true, bookKey: key),
  ];

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async {
    if (failRemoteProgressReads > 0) {
      failRemoteProgressReads -= 1;
      throw StateError('host unreachable');
    }
    return hostProgress[bookKey] ?? RemoteBookProgress.empty;
  }

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

  /// host 有声书清单与断点（bookKey → 断点）。
  final List<RemoteAudiobookInfo> hostAudiobooks = <RemoteAudiobookInfo>[];
  final Map<String, ({int positionMs, int updatedAtMs})> hostAudioPositions =
      <String, ({int positionMs, int updatedAtMs})>{};
  final Map<String, ({int positionMs, int updatedAtMs})> putAudioPositions =
      <String, ({int positionMs, int updatedAtMs})>{};

  /// host 聚合快照（null = 老 host 无端点）；PUT 上来的合并结果。
  AggregateSnapshot? hostAggregate;
  int aggregatePuts = 0;
  int aggregateGets = 0;

  /// 文件箱被列举的次数（互联对比不得再碰文件箱，反馈 kM-Gb_Xnu-）。
  int listBooksCalls = 0;

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async =>
      hostAudiobooks;

  @override
  Future<({int positionMs, int updatedAtMs})> remoteAudiobookPosition(
    String bookKey,
  ) async => hostAudioPositions[bookKey] ?? (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    putAudioPositions[bookKey] = (
      positionMs: positionMs,
      updatedAtMs: updatedAtMs,
    );
    hostAudioPositions[bookKey] = putAudioPositions[bookKey]!;
  }

  @override
  Future<Map<String, dynamic>?> getRemoteAggregate() async {
    aggregateGets++;
    final AggregateSnapshot? snapshot = hostAggregate;
    return snapshot == null
        ? null
        : Map<String, dynamic>.from(snapshot.toJson());
  }

  @override
  Future<void> putRemoteAggregate(Object? json) async {
    aggregatePuts++;
  }

  // ── 弹窗 _load / Apply 路径会碰到的 WebDAV 文件箱面（全部就地 no-op）──
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async {
    listBooksCalls++;
    return <SyncFileRef>[
      for (final String title in fileBoxProgress.keys)
        SyncFileRef(id: 'folder-$title', name: title),
    ];
  }

  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}
  @override
  void evictFolderId(String folderId) {}
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final String title = folderId.replaceFirst('folder-', '');
    final TtuProgress? boxed = fileBoxProgress[title];
    if (boxed == null) return const SyncFileTrio();
    return SyncFileTrio(
      progress: SyncFileRef(
        id: 'boxed-$title',
        name: progressFileName(boxed.lastBookmarkModified, boxed.progress),
      ),
    );
  }

  @override
  Future<Object?> readJsonById(String fileId) async =>
      fileBoxProgress[fileId.replaceFirst('boxed-', '')]!.toJson();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => 'folder-$bookTitle';
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
}) => db.upsertReaderPosition(
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

  testWidgets('both sides moved off the position baseline -> conflict row '
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

  testWidgets('host merely reopened (position on baseline) while local read '
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

  testWidgets('Apply "use local" pushes local progress to host DB with a '
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

  // 用户报告 2026-09-22：互联通道跑的 SyncManager（host 上的 WebDAV 文件箱）此前
  // 与云通道共用同一行 `(assetKey, 'progress')` 基线；两条通道并存时互相把对方的
  // 基线抬走，文件箱旧进度倒灌回本机、同一本书每轮都报冲突。现在互联通道的文件箱
  // 基线是自己的一行。
  test(
    'interconnect channel keeps its file-box baseline in its own row',
    () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBook(db, 'BookA');
      await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
      final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
        hostProgress: <String, RemoteBookProgress>{},
      );
      expect(progressBaselineDimensionOf(fake), 'progress__fushiServer');
      // 云通道那一行已有值：互联通道的导出不得碰它。
      await db.setSyncBaseline('BookA', 'progress', 42);

      final SyncBookResult result = await SyncManager(db: db, backend: fake)
          .syncBook(
            book: book,
            direction: SyncDirection.exportToTtu,
            syncStats: false,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
          );

      expect(result.direction, SyncResult.exported);
      expect(fake.exportedByFolder['folder-BookA']?.lastBookmarkModified, 1000);
      expect(
        await db.getSyncBaseline('BookA', 'progress__fushiServer'),
        1000,
        reason: '互联文件箱基线记在自己的行',
      );
      expect(
        await db.getSyncBaseline('BookA', 'progress'),
        42,
        reason: '云通道的基线行原样不动',
      );
    },
  );

  // 升级路径：互联通道换了新基线行之后，存量用户只有旧行 `'progress'`、新行为空。
  // 文件箱里躺着本 client 升级前最后一次导出（ts 500），之后本机又读过（ts 1000）
  // ——两边不等、无基线。云盘口径这是「真分叉」；但互联文件箱只有本 client 写、
  // host 从不读回，这里的「远端」就是自己上次的导出，只能按导出处理并落下第一条
  // 基线。判成冲突的后果是永久幻象（冲突弹窗对互联行只看 live、不显示这一行；
  // 自动 sweep 遇冲突早退不写基线 → 每轮都报、每次「立即同步」后都弹空弹窗）。
  test(
    'legacy baseline row + empty new row: interconnect auto sweep exports '
    'and seeds the new row instead of reporting a phantom conflict',
    () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBook(db, 'BookA');
      await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
      final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
        hostProgress: <String, RemoteBookProgress>{},
      );
      fake.fileBoxProgress['BookA'] = TtuProgress(
        dataId: 0,
        exploredCharCount: 500,
        progress: 0.5,
        lastBookmarkModified: 500,
      );
      // 升级前两条通道共用的旧行；新行 `progress__fushiServer` 不存在。
      await db.setSyncBaseline('BookA', 'progress', 500);
      expect(
        await db.getSyncBaseline('BookA', 'progress__fushiServer'),
        isNull,
      );

      // direction 不传 = 自动 sweep 的三方判定路径。
      final SyncBookResult result = await SyncManager(db: db, backend: fake)
          .syncBook(
            book: book,
            syncStats: false,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
          );

      expect(
        result.direction,
        SyncResult.exported,
        reason: '文件箱是本 client 自己写的，无基线不等只能是本机又读了',
      );
      expect(fake.exportedByFolder['folder-BookA']?.lastBookmarkModified, 1000);
      expect(
        await db.getSyncBaseline('BookA', 'progress__fushiServer'),
        1000,
        reason: '第一条新维度基线落下，下一轮才有 base 可比',
      );
      expect(
        await db.getSyncBaseline('BookA', 'progress'),
        500,
        reason: '云通道那一行原样不动',
      );
    },
  );

  testWidgets(
    'live GET failing at load: no file-box fallback, Apply "use local" still '
    'pushes to host DB and never writes the file box',
    (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBook(db, 'BookA');
      await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
      final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
        hostProgress: <String, RemoteBookProgress>{'BookA': _host(9000, 5000)},
      );
      // 文件箱里 client 自己上次导出的旧进度：反馈 kM-Gb_Xnu- 之后互联对比完全不看它。
      fake.fileBoxProgress['BookA'] = TtuProgress(
        dataId: 0,
        exploredCharCount: 900,
        progress: 0.9,
        lastBookmarkModified: 500,
      );
      // 加载期那一次 live GET 失败 → 这一行没有 liveAction，远端显示无数据。
      fake.failRemoteProgressReads = 1;
      await pumpDialog(tester, db, fake);
      expect(find.text('BookA'), findsOneWidget);
      expect(fake.listBooksCalls, 0, reason: '互联不列文件箱');

      await tester.tap(find.text(t.sync_compare_apply(count: 1)));
      await tester.pumpAndSettle();

      // 只要 host 有这本书就推（门槛是 remoteLiveTitle，不是加载期 GET 成功）。
      final RemoteBookProgress? pushed = fake.putProgress['BookA'];
      expect(pushed, isNotNull, reason: '选本机必须推到 host DB');
      expect(pushed!.normCharOffset, 3000);
      expect(fake.hostProgress['BookA']!.normCharOffset, 3000);
      expect(
        fake.exportedByFolder,
        isEmpty,
        reason: '互联「应用」不再经 SyncManager 写 host 上没人读的文件箱',
      );
    },
  );

  test('互联对比：统计数与有声书断点取 host 真相，不读文件箱（反馈 kM-Gb_Xnu-）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await _seedBook(db, 'BookA');
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(9000, 5000)},
    );
    // 文件箱里有一本 host 书库没有的「书」：以前会被当成远端独有书列出来。
    fake.fileBoxProgress['Ghost'] = TtuProgress(
      dataId: 0,
      exploredCharCount: 1,
      progress: 0.1,
      lastBookmarkModified: 1,
    );
    fake.hostAggregate = const AggregateSnapshot(
      readingStats: <ReadingStatRecord>[
        ReadingStatRecord(
          title: 'BookA',
          dateKey: '2026-11-01',
          charactersRead: 10,
          readingTimeMs: 1,
          lastStatisticModified: 1,
        ),
        ReadingStatRecord(
          title: 'BookA',
          dateKey: '2026-11-02',
          charactersRead: 10,
          readingTimeMs: 1,
          lastStatisticModified: 1,
        ),
        ReadingStatRecord(
          title: 'Other',
          dateKey: '2026-11-02',
          charactersRead: 10,
          readingTimeMs: 1,
          lastStatisticModified: 1,
        ),
      ],
    );
    fake.hostAudiobooks.add(
      const RemoteAudiobookInfo(
        bookKey: 'BookA',
        title: 'BookA',
        positionMs: 12500,
        positionUpdatedAtMs: 777,
      ),
    );

    final List<SyncCompareEntry> entries = await fetchCompareDataForTest(
      db,
      fake,
    );
    expect(fake.listBooksCalls, 0);
    expect(entries.map((SyncCompareEntry e) => e.title), <String>['BookA']);
    final SyncCompareEntry row = entries.single;
    expect(row.remoteStatsCount, 2, reason: 'host reading_statistics 里这本书的行数');
    expect(row.remoteAudioPosSec, 12.5);
    expect(row.remoteLiveAudiobookKey, 'BookA');
    expect(row.remoteFolderId, isNull);
  });

  test('互联「应用」：有声书断点按选择经 live 端点落地，统计与 host 合并', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, norm: 3000, updatedAt: 1000);
    await SyncRepository(db).setInterconnectSyncStatsEnabled(true);
    await db.setPrefTyped<int>(audiobookPositionPrefKey('BookA'), 4000);
    await db.setPrefTyped<int>(audiobookPositionAtPrefKey('BookA'), 2000);
    final _FakeInterconnectBackend fake = _FakeInterconnectBackend(
      hostProgress: <String, RemoteBookProgress>{'BookA': _host(3000, 1000)},
    );
    fake.hostAggregate = const AggregateSnapshot();
    fake.hostAudiobooks.add(
      const RemoteAudiobookInfo(bookKey: 'BookA', title: 'BookA'),
    );
    fake.hostAudioPositions['BookA'] = (positionMs: 9000, updatedAtMs: 5000);

    final List<SyncCompareEntry> entries = await fetchCompareDataForTest(
      db,
      fake,
    );
    final SyncCompareEntry row = entries.single;
    expect(row.remoteAudioPosSec, 9, reason: '老 host 清单不内联断点时逐本 GET');

    // 选「用远端」：host 断点落回本机。
    final Directory tmp = Directory.systemTemp.createTempSync('cmp_live_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final int getsBeforeApply = fake.aggregateGets;
    SyncCompareApplyResult result = await applySyncCompareChoices(
      db: db,
      backend: fake,
      actionable: entries,
      choices: <String, SyncChoice>{'BookA': SyncChoice.useRemote},
      tempDir: tmp,
    );
    expect(result.errors, isEmpty);
    expect(
      await db.getPrefTyped<int>(audiobookPositionPrefKey('BookA'), 0),
      9000,
    );
    // 两端都没有统计：合并结果为空不 PUT（syncOverClient 的空合并短路），但必须向
    // host 取过一次聚合做并集。
    expect(fake.aggregateGets, getsBeforeApply + 1, reason: '统计按并集与 host 合并一次');
    expect(fake.aggregatePuts, 0);

    // 本机又听到 15000，选「用本地」：推给 host。
    await db.setPrefTyped<int>(audiobookPositionPrefKey('BookA'), 15000);
    await db.setPrefTyped<int>(audiobookPositionAtPrefKey('BookA'), 9000);
    result = await applySyncCompareChoices(
      db: db,
      backend: fake,
      actionable: entries,
      choices: <String, SyncChoice>{'BookA': SyncChoice.useLocal},
      tempDir: tmp,
    );
    expect(result.errors, isEmpty);
    expect(fake.putAudioPositions['BookA']?.positionMs, 15000);
    expect(fake.exportedByFolder, isEmpty, reason: '文件箱一次都没写');
  });

  testWidgets('Apply "use remote" lands host DB progress locally and records '
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

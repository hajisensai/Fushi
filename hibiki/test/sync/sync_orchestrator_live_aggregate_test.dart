/// TODO-1056 phase C: 互联（LAN server）聚合（统计 + 收藏）live 双向合并端到端测试。
///
/// 真 server（HibikiSyncServer + AppModelLibraryHostService + host DB）+ 真 client
/// backend（client DB）+ orchestrator，验证：
///   1. GET/PUT round-trip：client materialize → GET host → 并集折叠 → 写回本地 →
///      PUT 回 host，两端收敛到并集（统计 MAX、收藏词并集）。
///   2. never-shrinks / 幂等：连跑两次不翻倍、不缩小。
///   3. 老 server 降级：host 未接 libraryService（`/api/library/aggregate` 返 404）→
///      client 只推不拉、不崩（无 report.errors）。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<void> _seedReading(
  HibikiDatabase db, {
  required String title,
  required String dateKey,
  required int chars,
  required int timeMs,
  required int modified,
}) =>
    db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: title,
      dateKey: dateKey,
      charactersRead: chars,
      readingTimeMs: timeMs,
      lastStatisticModified: modified,
    ));

Future<HibikiClientSyncBackend> _buildClientBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator({
  required HibikiDatabase db,
  required SyncBackend backend,
  required Directory tmp,
}) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: true,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
      syncLocalAudio: false,
    );

void main() {
  late Directory work;
  late HibikiSyncServer server;
  late HibikiDatabase hostDb;
  late String base;
  const String token = 'orch-live-aggregate-token';

  /// 起一台带/不带 libraryService 的 server（不带 → aggregate 端点 404，模拟老 host）。
  Future<void> startServer({required bool withLibraryService}) async {
    hostDb = _memDb();
    AppModelLibraryHostService? libSvc;
    if (withLibraryService) {
      libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
    }
    server = HibikiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  }

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_live_aggregate_');
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('round-trip: 两端收敛到并集（统计 MAX + 收藏词并集）', () async {
    await startServer(withLibraryService: true);

    // host 有 Book A(chars=40, time=5000) + wHost；且有独立 Book B。
    await _seedReading(hostDb,
        title: 'Book A',
        dateKey: '2026-06-01',
        chars: 40,
        timeMs: 5000,
        modified: 2);
    await _seedReading(hostDb,
        title: 'Book B',
        dateKey: '2026-06-01',
        chars: 10,
        timeMs: 100,
        modified: 1);
    await hostDb.addFavoriteWord(
      expression: 'wHost',
      reading: 'r',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-06-01',
    );

    // client 有 Book A(chars=100, time=1000) + wLocal。
    final HibikiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedReading(localDb,
        title: 'Book A',
        dateKey: '2026-06-01',
        chars: 100,
        timeMs: 1000,
        modified: 1);
    await localDb.addFavoriteWord(
      expression: 'wLocal',
      reading: 'r',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-06-01',
    );

    final Directory tmp = Directory(p.join(work.path, 't1'))..createSync();
    final HibikiClientSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncOrchestrator orch =
        _orchestrator(db: localDb, backend: backend, tmp: tmp);

    final SyncRunReport report = SyncRunReport();
    await orch.syncAggregateLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');

    // client 端 Book A = MAX(100, 40)=100 chars, MAX(1000,5000)=5000 time；
    // 且拉回 host 独有 Book B + wHost。
    final Map<String, ReadingStatisticRow> localByTitle =
        <String, ReadingStatisticRow>{
      for (final ReadingStatisticRow r
          in await localDb.getAllReadingStatistics())
        r.title: r,
    };
    expect(localByTitle['Book A']!.charactersRead, 100);
    expect(localByTitle['Book A']!.readingTimeMs, 5000);
    expect(localByTitle.containsKey('Book B'), isTrue);
    final Set<String> localWords = (await localDb.getAllFavoriteWords())
        .map((FavoriteWordRow w) => w.expression)
        .toSet();
    expect(localWords, <String>{'wLocal', 'wHost'});

    // host 端也收敛：Book A chars=MAX(40,100)=100, time=5000；且拿到 client 的 wLocal。
    final Map<String, ReadingStatisticRow> hostByTitle =
        <String, ReadingStatisticRow>{
      for (final ReadingStatisticRow r
          in await hostDb.getAllReadingStatistics())
        r.title: r,
    };
    expect(hostByTitle['Book A']!.charactersRead, 100);
    expect(hostByTitle['Book A']!.readingTimeMs, 5000);
    final Set<String> hostWords = (await hostDb.getAllFavoriteWords())
        .map((FavoriteWordRow w) => w.expression)
        .toSet();
    expect(hostWords, <String>{'wHost', 'wLocal'});
  });

  test('幂等：连跑两次不缩小、不翻倍', () async {
    await startServer(withLibraryService: true);
    await hostDb.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 5);

    final HibikiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await localDb.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 3);

    final Directory tmp = Directory(p.join(work.path, 't2'))..createSync();
    final HibikiClientSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncOrchestrator orch =
        _orchestrator(db: localDb, backend: backend, tmp: tmp);

    await orch.syncAggregateLiveForTest(SyncRunReport(), backend);
    await orch.syncAggregateLiveForTest(SyncRunReport(), backend);

    // MAX(3,5)=5，跑两次仍是 5（非 SUM，never-shrinks）。
    expect((await localDb.getMiningStatisticsBySource('book')).single.count, 5);
    expect((await hostDb.getMiningStatisticsBySource('book')).single.count, 5);
  });

  test('老 server（无 libraryService）→ aggregate 404 → client 只推不崩', () async {
    await startServer(withLibraryService: false);

    final HibikiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await localDb.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 7);

    final Directory tmp = Directory(p.join(work.path, 't3'))..createSync();
    final HibikiClientSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncOrchestrator orch =
        _orchestrator(db: localDb, backend: backend, tmp: tmp);

    final SyncRunReport report = SyncRunReport();
    // 老 host GET 返 404 → getRemoteAggregate 返 null → push-only；不崩、不产生 error。
    await orch.syncAggregateLiveForTest(report, backend);

    // client 本地统计不受影响（无回灌，无崩溃）。
    expect((await localDb.getMiningStatisticsBySource('book')).single.count, 7);
  });
}

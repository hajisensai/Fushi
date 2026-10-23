/// 互联进度 sweep 的稳态 DB 开销回归（视频 / 有声书 / 书籍）。
///
/// 根因：`_syncPositionsLive` / `_syncBookProgressLive` 对每个条目逐条读本端位置、
/// 读基线与「待确认」基线，两端已一致时仍经 `alignSynced` 无条件 `recordBaseline`
/// （写一遍同值基线 + 删一条不存在的待确认行）；视频播放偏好再逐视频读 8 个偏好。
/// 99 个视频的稳态一轮是 1487 条 SQL，随条目数线性增长。
///
/// 修复后：整轮一次读齐偏好 / 基线，两端已收敛的条目在内存判定后跳过。本测试
/// 钉住两件事——稳态第二轮基线零写入；SQL 条数与条目数无关。另验收敛后再有一端
/// 移动 / 两端分叉时，推送、落地与冲突上报照旧。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// 记下 client DB 上执行的每条语句（`S|I|U|D|C|B <sql>`）。
class _CountingInterceptor extends QueryInterceptor {
  bool recording = false;
  final List<String> statements = <String>[];

  void _note(String kind, String sql) {
    if (recording) statements.add('$kind $sql');
  }

  void reset() => statements.clear();

  int countWhere(bool Function(String s) test) => statements.where(test).length;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note('S', statement);
    return executor.runSelect(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note('I', statement);
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note('U', statement);
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note('D', statement);
    return executor.runDelete(statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note('C', statement);
    return executor.runCustom(statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    _note('B', 'batch');
    return executor.runBatched(statements);
  }
}

bool _isBaselineWrite(String s) =>
    !s.startsWith('S ') && s.contains('"sync_baselines"');

FushiDatabase _memDb([QueryInterceptor? interceptor]) {
  QueryExecutor ex = NativeDatabase.memory();
  if (interceptor != null) ex = ex.interceptWith(interceptor);
  return FushiDatabase.forTesting(DatabaseConnection(ex));
}

Future<void> _seedBook(FushiDatabase db, String title) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/tmp/$title.epub',
    extractDir: '/tmp/$title',
    chapterCount: 1,
    chaptersJson: '["ch1"]',
    importedAt: 1,
  ),
);

Future<void> _seedPosition(
  FushiDatabase db,
  String bookKey, {
  required int section,
  required int norm,
  required int updatedAt,
}) async {
  final String bookUid = (await db.resolveEpubBookUid(bookKey))!;
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value(bookUid),
      sectionIndex: Value(section),
      normCharOffset: Value(norm),
      charOffset: Value(norm),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<ReaderPositionRow?> _positionOf(FushiDatabase db, String bookKey) async {
  final String? uid = await db.resolveEpubBookUid(bookKey);
  return uid == null ? null : db.getReaderPosition(uid);
}

Future<void> _seedHostAudiobook(FushiDatabase db, String bookKey) async {
  await db.upsertAudiobook(
    AudiobooksCompanion.insert(
      bookKey: bookKey,
      alignmentFormat: 'srt',
      alignmentPath: '/tmp/$bookKey.srt',
    ),
  );
  await db.upsertSrtBook(
    SrtBooksCompanion.insert(
      uid: 'srt-$bookKey',
      title: bookKey,
      bookKey: Value(bookKey),
      srtPath: '/tmp/$bookKey.srt',
      importedAt: 0,
    ),
  );
}

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late _CountingInterceptor counter;
  late FushiDatabase localDb;
  late InterconnectSyncBackend backend;
  late SyncOrchestrator orch;
  const String token = 'progress-sweep-db-ops-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('progress_sweep_ops_');
    hostDb = _memDb();
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: LocalLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      ),
    );
    await server.start();

    final FushiDatabase authDb = _memDb();
    final SyncRepository repo = SyncRepository(authDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(token);
    backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    await authDb.close();

    counter = _CountingInterceptor();
    localDb = _memDb(counter);
    final Directory tmp = Directory(p.join(work.path, 'tmp'))..createSync();
    orch = SyncOrchestrator(
      db: localDb,
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
    );
  });

  tearDown(() async {
    await server.stop();
    await localDb.close();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  /// 种 [n] 个两端一致的视频（一半有书架行，一半只有流式 prefs）。
  Future<void> seedVideos(int n, {int from = 0}) async {
    for (int i = from; i < from + n; i++) {
      final String uid = 'vid-$i';
      final File f = File(p.join(work.path, '$uid.mp4'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      await hostDb.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: 'Video $i',
          videoPath: f.path,
        ),
      );
      await hostDb.setPrefTyped<int>(videoRemotePositionPrefKey(uid), 60000);
      await hostDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 8000);
      await hostDb.setPrefTyped<int>(videoRemoteDelayPrefKey(uid), 120);
      await hostDb.setPrefTyped<int>(videoRemoteDelayAtPrefKey(uid), 3000);
      if (i.isEven) {
        await localDb.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: uid,
            title: 'Video $i',
            videoPath: '/nonexistent/$uid.mp4',
            lastPositionMs: const Value(60000),
          ),
        );
      } else {
        await localDb.setPrefTyped<int>(videoRemotePositionPrefKey(uid), 60000);
      }
      await localDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 8000);
      await localDb.setPrefTyped<int>(videoRemoteDelayPrefKey(uid), 120);
      await localDb.setPrefTyped<int>(videoRemoteDelayAtPrefKey(uid), 3000);
    }
  }

  Future<SyncRunReport> videoRound() async {
    final SyncRunReport report = SyncRunReport();
    counter.reset();
    counter.recording = true;
    await orch.syncVideoProgressLiveForTest(report, backend);
    counter.recording = false;
    expect(report.errors, isEmpty, reason: '${report.errors}');
    return report;
  }

  group('video progress sweep', () {
    test(
      'steady state: zero baseline writes, SQL count independent of N',
      () async {
        await seedVideos(4);
        await videoRound(); // 首轮：两端一致但没有基线 → 记基线。
        expect(
          await localDb.getSyncBaseline(
            'vid-0',
            kInterconnectVideoPositionDimension,
          ),
          60000,
        );

        await videoRound();
        expect(
          counter.countWhere(_isBaselineWrite),
          0,
          reason: counter.statements.join('\n'),
        );
        final int smallRound = counter.statements.length;

        await seedVideos(16, from: 4);
        await videoRound(); // 新增的 16 个首轮记基线。
        await videoRound();
        expect(
          counter.countWhere(_isBaselineWrite),
          0,
          reason: counter.statements.join('\n'),
        );
        expect(
          counter.statements.length,
          smallRound,
          reason:
              '20 个视频的稳态 SQL 条数应与 4 个时相同：\n'
              '${counter.statements.join('\n')}',
        );
        // 视频行 + 偏好快照 + 基线 / 待确认基线，各一条。
        expect(
          smallRound,
          lessThanOrEqualTo(4),
          reason: counter.statements.join('\n'),
        );
      },
    );

    test(
      'after settling, one-sided moves still land and forks still conflict',
      () async {
        await seedVideos(4);
        await videoRound();
        await videoRound();

        // vid-0：只有本端动了 → 推给 host。
        await localDb.updateVideoBookPosition('vid-0', 90000, playedAt: 9000);
        await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('vid-0'),
          9000,
        );
        // vid-1：只有 host 动了 → 落回本端（流式，落 prefs）。
        await hostDb.setPrefTyped<int>(
          videoRemotePositionPrefKey('vid-1'),
          30000,
        );
        await hostDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('vid-1'),
          9500,
        );
        // vid-2：两端各自动了 → 冲突，谁都不覆盖。
        await localDb.updateVideoBookPosition('vid-2', 70000, playedAt: 9000);
        await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('vid-2'),
          9000,
        );
        await hostDb.setPrefTyped<int>(
          videoRemotePositionPrefKey('vid-2'),
          10000,
        );
        await hostDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('vid-2'),
          9100,
        );
        // vid-3：host 调轴更新 → 写回本端。
        await hostDb.setPrefTyped<int>(videoRemoteDelayPrefKey('vid-3'), -450);
        await hostDb.setPrefTyped<int>(
          videoRemoteDelayAtPrefKey('vid-3'),
          7000,
        );

        final SyncRunReport report = await videoRound();

        expect(
          await hostDb.getPrefTyped<int>(
            videoRemotePositionPrefKey('vid-0'),
            0,
          ),
          90000,
        );
        expect(
          await localDb.getPrefTyped<int>(
            videoRemotePositionPrefKey('vid-1'),
            0,
          ),
          30000,
        );
        expect(report.conflicts, hasLength(1));
        expect(report.conflicts.single.assetKey, 'vid-2');
        expect(
          report.conflicts.single.dimension,
          kInterconnectVideoPositionDimension,
        );
        expect(
          (await localDb.getVideoBookByBookUid('vid-2'))!.lastPositionMs,
          70000,
        );
        expect(
          await hostDb.getPrefTyped<int>(
            videoRemotePositionPrefKey('vid-2'),
            0,
          ),
          10000,
        );
        expect(
          await localDb.getPrefTyped<int>(videoRemoteDelayPrefKey('vid-3'), 0),
          -450,
        );
        expect(
          await localDb.getPrefTyped<int>(
            videoRemoteDelayAtPrefKey('vid-3'),
            0,
          ),
          7000,
        );
      },
    );
  });

  group('audiobook progress sweep', () {
    Future<void> seedAudiobooks(int n, {int from = 0}) async {
      for (int i = from; i < from + n; i++) {
        final String key = 'ab-$i';
        await _seedHostAudiobook(hostDb, key);
        await hostDb.setPrefTyped<int>(audiobookPositionPrefKey(key), 1000 + i);
        await hostDb.setPrefTyped<int>(audiobookPositionAtPrefKey(key), 7000);
        await localDb.setPrefTyped<int>(
          audiobookPositionPrefKey(key),
          1000 + i,
        );
        await localDb.setPrefTyped<int>(audiobookPositionAtPrefKey(key), 7000);
      }
    }

    Future<SyncRunReport> round() async {
      final SyncRunReport report = SyncRunReport();
      counter.reset();
      counter.recording = true;
      await orch.syncAudiobookProgressLiveForTest(report, backend);
      counter.recording = false;
      expect(report.errors, isEmpty, reason: '${report.errors}');
      return report;
    }

    test(
      'steady state: zero baseline writes, SQL count independent of N',
      () async {
        await seedAudiobooks(3);
        await round();
        await round();
        expect(
          counter.countWhere(_isBaselineWrite),
          0,
          reason: counter.statements.join('\n'),
        );
        final int small = counter.statements.length;

        await seedAudiobooks(9, from: 3);
        await round();
        await round();
        expect(
          counter.countWhere(_isBaselineWrite),
          0,
          reason: counter.statements.join('\n'),
        );
        expect(
          counter.statements.length,
          small,
          reason: counter.statements.join('\n'),
        );
      },
    );

    test('after settling, a host-side move still lands locally', () async {
      await seedAudiobooks(2);
      await round();
      await round();
      await hostDb.setPrefTyped<int>(audiobookPositionPrefKey('ab-1'), 5555);
      await hostDb.setPrefTyped<int>(audiobookPositionAtPrefKey('ab-1'), 9000);

      final SyncRunReport report = await round();
      expect(report.conflicts, isEmpty);
      expect(
        await localDb.getPrefTyped<int>(audiobookPositionPrefKey('ab-1'), 0),
        5555,
      );
      expect(
        await localDb.getSyncBaseline(
          'ab-1',
          kInterconnectAudiobookPositionDimension,
        ),
        5555,
      );
    });
  });

  group('book progress sweep', () {
    Future<void> seedBooks(int n, {int from = 0}) async {
      for (int i = from; i < from + n; i++) {
        final String key = 'Book$i';
        await _seedBook(hostDb, key);
        await _seedPosition(
          hostDb,
          key,
          section: 1,
          norm: 100 * i,
          updatedAt: 5000,
        );
        await _seedBook(localDb, key);
        await _seedPosition(
          localDb,
          key,
          section: 1,
          norm: 100 * i,
          updatedAt: 5000,
        );
      }
    }

    Future<SyncRunReport> round() async {
      final SyncRunReport report = SyncRunReport();
      counter.reset();
      counter.recording = true;
      await orch.syncBookProgressLiveForTest(report, backend);
      counter.recording = false;
      expect(report.errors, isEmpty, reason: '${report.errors}');
      return report;
    }

    test(
      'steady state: zero baseline writes, SQL count independent of N',
      () async {
        await seedBooks(3);
        await round(); // 首轮：位置一致、无基线 → 记基线。
        expect(
          await localDb.getSyncBaseline(
            'Book1',
            kInterconnectBookProgressDimension,
          ),
          BookProgressBaseline(sectionIndex: 1, normCharOffset: 100).encode(),
        );
        await round();
        expect(
          counter.countWhere(_isBaselineWrite),
          0,
          reason: counter.statements.join('\n'),
        );
        final int small = counter.statements.length;

        await seedBooks(9, from: 3);
        await round();
        await round();
        expect(
          counter.countWhere(_isBaselineWrite),
          0,
          reason: counter.statements.join('\n'),
        );
        expect(
          counter.statements.length,
          small,
          reason: counter.statements.join('\n'),
        );
      },
    );

    test(
      'after settling, one-sided moves still land and forks still conflict',
      () async {
        await seedBooks(3);
        await round();
        await round();

        await _seedPosition(
          localDb,
          'Book0',
          section: 4,
          norm: 40,
          updatedAt: 9000,
        );
        await _seedPosition(
          hostDb,
          'Book1',
          section: 6,
          norm: 60,
          updatedAt: 9000,
        );
        await _seedPosition(
          localDb,
          'Book2',
          section: 7,
          norm: 70,
          updatedAt: 9000,
        );
        await _seedPosition(
          hostDb,
          'Book2',
          section: 8,
          norm: 80,
          updatedAt: 9100,
        );

        final SyncRunReport report = await round();
        expect((await _positionOf(hostDb, 'Book0'))!.sectionIndex, 4);
        expect((await _positionOf(localDb, 'Book1'))!.sectionIndex, 6);
        expect(report.localBookProgressPulled, 1);
        expect(report.conflicts, hasLength(1));
        expect(report.conflicts.single.assetKey, 'Book2');
        expect((await _positionOf(localDb, 'Book2'))!.sectionIndex, 7);
        expect((await _positionOf(hostDb, 'Book2'))!.sectionIndex, 8);
      },
    );
  });
}

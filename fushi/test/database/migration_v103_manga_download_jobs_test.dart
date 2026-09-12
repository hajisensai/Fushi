import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v103：新表 `manga_download_jobs`（漫画章节 / mokuro 卷下载队列，设备本地）。
///
/// 纯新增表，无损：旧库升级后表为空 = 一个任务都没有 = 下载 worker 空转，与升级
/// 前逐字节一致。下面分别钉住「从真实 v102 库出发表 + 两条索引会建出来」「CHECK
/// 真的拒绝坏值」「DAO 往返」「启动复位与 worker claim 的语义」。
void main() {
  /// 造一个 v102 形态的库：建好全表后把 v103 的产物删掉、版本号写回 102。
  Future<String> seedV102Database(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.insertUpdateFeedEntry(
      UpdateFeedEntriesCompanion.insert(
        entryId: 'mangaChapter|book-1|ch-1',
        kind: 'mangaChapter',
        targetKey: 'book-1|ch-1',
        title: '某作品',
        discoveredAt: 111,
      ),
    );
    await original.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(path);
    try {
      raw.execute('DROP INDEX IF EXISTS idx_manga_download_jobs_identity');
      raw.execute(
          'DROP INDEX IF EXISTS idx_manga_download_jobs_status_created');
      raw.execute('DROP TABLE IF EXISTS manga_download_jobs');
      raw.execute('PRAGMA user_version = 102');
    } finally {
      raw.dispose();
    }
    return path;
  }

  Set<String> indexNames(sqlite3.Database db, String table) {
    return db
        .select(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            'AND tbl_name = ?',
            <Object>[table])
        .map((sqlite3.Row r) => r['name'] as String)
        .toSet();
  }

  bool hasTable(sqlite3.Database db, String table) {
    return db.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        <Object>[table]).isNotEmpty;
  }

  MangaDownloadJobsCompanion job(
    String id, {
    String kind = MangaDownloadJobKind.chapter,
    String bookKey = 'book-1',
    required String chapterKey,
    String status = MangaDownloadJobStatus.queued,
    required int createdAt,
  }) {
    return MangaDownloadJobsCompanion.insert(
      jobId: id,
      kind: kind,
      bookKey: bookKey,
      chapterKey: chapterKey,
      runtime: 'mihon',
      title: '某作品',
      chapterTitle: '第 $chapterKey 话',
      status: Value<String>(status),
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  late Directory directory;
  late String path;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('manga_download_jobs_v103');
    path = await seedV102Database(directory);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('v102 库确实没有 manga_download_jobs（前提自检）', () {
    final sqlite3.Database probe =
        sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 102);
      expect(hasTable(probe, 'manga_download_jobs'), isFalse,
          reason: '前提不成立的话下面的迁移断言测的是空气');
    } finally {
      probe.dispose();
    }
  });

  test('v102 → v103 建出表与两条索引，既有 device-local 行零丢失', () async {
    final FushiDatabase upgraded =
        FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(upgraded.close);

    expect(
      (await upgraded.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      upgraded.schemaVersion,
    );
    expect(upgraded.schemaVersion, 104);

    // 邻居表原样在（Never break userspace）。
    expect(await upgraded.updateFeedEntriesPage(), hasLength(1));
    // 新表存在且为空 —— 空 = worker 空转 = 升级前行为。
    expect(await upgraded.listMangaDownloadJobs(), isEmpty);
    await upgraded.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(hasTable(probe, 'manga_download_jobs'), isTrue);
      expect(
        indexNames(probe, 'manga_download_jobs'),
        containsAll(<String>[
          'idx_manga_download_jobs_identity',
          'idx_manga_download_jobs_status_created',
        ]),
      );
      final sqlite3.ResultSet unique = probe.select(
          "SELECT \"unique\" FROM pragma_index_list('manga_download_jobs') "
          "WHERE name = 'idx_manga_download_jobs_identity'");
      expect(unique.first.values.first, 1, reason: '身份索引必须是 UNIQUE');
    } finally {
      probe.dispose();
    }
  });

  test('fresh 库与升级库索引集合一致（_ensureIndexes 与 v103 步不能各说各话）', () async {
    final String freshPath = '${directory.path}/fresh.db';
    final FushiDatabase fresh =
        FushiDatabase.atFile(freshPath, isMainProcess: false);
    await fresh.listMangaDownloadJobs();
    await fresh.close();
    final FushiDatabase upgraded =
        FushiDatabase.atFile(path, isMainProcess: false);
    await upgraded.listMangaDownloadJobs();
    await upgraded.close();

    final sqlite3.Database a =
        sqlite3.sqlite3.open(freshPath, mode: sqlite3.OpenMode.readOnly);
    final sqlite3.Database b =
        sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      final Set<String> freshIdx = indexNames(a, 'manga_download_jobs');
      expect(freshIdx, contains('idx_manga_download_jobs_identity'));
      expect(freshIdx, equals(indexNames(b, 'manga_download_jobs')));
    } finally {
      a.dispose();
      b.dispose();
    }
  });

  test('CHECK 拒绝非法 kind / status / 负进度 / 空身份', () async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);

    Future<void> expectRejected(String sql) async {
      await expectLater(db.customStatement(sql), throwsA(anything),
          reason: sql);
    }

    const String prefix = 'INSERT INTO manga_download_jobs (job_id, kind, '
        'book_key, chapter_key, runtime, title, chapter_title, status, '
        'pages_done, pages_total, created_at, updated_at) VALUES ';
    await expectRejected(
        "$prefix ('j', 'volume', 'b', 'c', 'mihon', 't', 'ct', 'queued', 0, 0, 1, 1)");
    await expectRejected(
        "$prefix ('j', 'chapter', 'b', 'c', 'mihon', 't', 'ct', 'paused', 0, 0, 1, 1)");
    await expectRejected(
        "$prefix ('j', 'chapter', 'b', 'c', 'mihon', 't', 'ct', 'queued', -1, 0, 1, 1)");
    await expectRejected(
        "$prefix ('j', 'chapter', 'b', 'c', 'mihon', 't', 'ct', 'queued', 5, 3, 1, 1)");
    await expectRejected(
        "$prefix ('', 'chapter', 'b', 'c', 'mihon', 't', 'ct', 'queued', 0, 0, 1, 1)");
    await expectRejected(
        "$prefix ('j', 'chapter', 'b', '', 'mihon', 't', 'ct', 'queued', 0, 0, 1, 1)");
    // 合法行照常进。
    await db.customStatement(
        "$prefix ('j', 'mokuro_volume', 'mokuro:s', 'v1', 'mokuro_moe', 't', 'ct', 'queued', 0, 0, 1, 1)");
    expect(await db.listMangaDownloadJobs(), hasLength(1));
  });

  test('同一 (kind, book_key, chapter_key) 不同 job_id 被唯一索引拒绝', () async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    await db.upsertMangaDownloadJob(job('a', chapterKey: 'c1', createdAt: 1));
    await expectLater(
      db.upsertMangaDownloadJob(job('b', chapterKey: 'c1', createdAt: 2)),
      throwsA(anything),
    );
    // 同 job_id 重复入队是 upsert，不是第二行。
    await db.upsertMangaDownloadJob(job('a', chapterKey: 'c1', createdAt: 3));
    expect(await db.listMangaDownloadJobs(), hasLength(1));
    expect(
      (await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: 'book-1',
        chapterKey: 'c1',
      ))
          ?.jobId,
      'a',
    );
  });

  test('DAO 往返：进度 / 状态 / 删除 / 列表过滤', () async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    await db.upsertMangaDownloadJob(job('a', chapterKey: 'c1', createdAt: 1));
    await db.upsertMangaDownloadJob(job('b', chapterKey: 'c2', createdAt: 2));

    final MangaDownloadJobRow a = (await db.getMangaDownloadJob('a'))!;
    expect(a.status, MangaDownloadJobStatus.queued);
    expect(a.pagesDone, 0);
    expect(a.autoOcr, isFalse);
    expect(a.lastError, isNull);
    expect(a.completedAt, isNull);

    expect(
      await db.updateMangaDownloadJobProgress('a',
          pagesDone: 3, pagesTotal: 10, updatedAt: 5),
      1,
    );
    expect((await db.getMangaDownloadJob('a'))!.pagesDone, 3);
    expect((await db.getMangaDownloadJob('a'))!.updatedAt, 5);
    expect(
      await db.updateMangaDownloadJobProgress('nope',
          pagesDone: 1, pagesTotal: 1, updatedAt: 5),
      0,
    );

    await db.updateMangaDownloadJobStatus('a',
        status: MangaDownloadJobStatus.failed,
        updatedAt: 6,
        lastError: 'boom',
        attemptCount: 2);
    MangaDownloadJobRow row = (await db.getMangaDownloadJob('a'))!;
    expect(row.status, MangaDownloadJobStatus.failed);
    expect(row.lastError, 'boom');
    expect(row.attemptCount, 2);
    expect(row.completedAt, isNull);

    // 不给 lastError 就不动它；clearLastError 才清。
    await db.updateMangaDownloadJobStatus('a',
        status: MangaDownloadJobStatus.queued, updatedAt: 7);
    expect((await db.getMangaDownloadJob('a'))!.lastError, 'boom');
    await db.updateMangaDownloadJobStatus('a',
        status: MangaDownloadJobStatus.done,
        updatedAt: 8,
        completedAt: 8,
        clearLastError: true);
    row = (await db.getMangaDownloadJob('a'))!;
    expect(row.lastError, isNull);
    expect(row.completedAt, 8);

    expect(
      (await db.listMangaDownloadJobs(
              statuses: <String>{MangaDownloadJobStatus.queued}))
          .map((MangaDownloadJobRow r) => r.jobId),
      <String>['b'],
    );
    expect(
      (await db.listMangaDownloadJobs())
          .map((MangaDownloadJobRow r) => r.jobId),
      <String>['a', 'b'],
      reason: '按 created_at 升序',
    );

    expect(await db.deleteMangaDownloadJob('a'), 1);
    expect(await db.getMangaDownloadJob('a'), isNull);
    expect(await db.deleteMangaDownloadJob('a'), 0);
  });

  test('resetRunningMangaDownloadJobs 只动 running，进度保留', () async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    await db.upsertMangaDownloadJob(job('r',
        chapterKey: 'c1',
        status: MangaDownloadJobStatus.running,
        createdAt: 1));
    await db.upsertMangaDownloadJob(job('d',
        chapterKey: 'c2', status: MangaDownloadJobStatus.done, createdAt: 2));
    await db.upsertMangaDownloadJob(job('f',
        chapterKey: 'c3', status: MangaDownloadJobStatus.failed, createdAt: 3));
    await db.updateMangaDownloadJobProgress('r',
        pagesDone: 4, pagesTotal: 9, updatedAt: 4);

    expect(await db.resetRunningMangaDownloadJobs(updatedAt: 10), 1);
    final MangaDownloadJobRow r = (await db.getMangaDownloadJob('r'))!;
    expect(r.status, MangaDownloadJobStatus.queued);
    expect(r.pagesDone, 4, reason: '进度不清零，worker 按磁盘续跑');
    expect(r.updatedAt, 10);
    expect((await db.getMangaDownloadJob('d'))!.status,
        MangaDownloadJobStatus.done);
    expect((await db.getMangaDownloadJob('f'))!.status,
        MangaDownloadJobStatus.failed);
    expect(await db.resetRunningMangaDownloadJobs(updatedAt: 11), 0);
  });

  test('claimNextQueuedMangaDownloadJob 按 created_at 取最早并置 running', () async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.claimNextQueuedMangaDownloadJob(updatedAt: 1), isNull);

    await db
        .upsertMangaDownloadJob(job('late', chapterKey: 'c2', createdAt: 20));
    await db
        .upsertMangaDownloadJob(job('early', chapterKey: 'c1', createdAt: 10));
    await db.upsertMangaDownloadJob(job('done',
        chapterKey: 'c0', status: MangaDownloadJobStatus.done, createdAt: 1));

    final MangaDownloadJobRow? first =
        await db.claimNextQueuedMangaDownloadJob(updatedAt: 30);
    expect(first?.jobId, 'early');
    expect(first?.status, MangaDownloadJobStatus.running);
    expect(first?.updatedAt, 30);
    expect((await db.getMangaDownloadJob('early'))!.status,
        MangaDownloadJobStatus.running,
        reason: '返回值必须与库里一致');

    final MangaDownloadJobRow? second =
        await db.claimNextQueuedMangaDownloadJob(updatedAt: 31);
    expect(second?.jobId, 'late');
    expect(await db.claimNextQueuedMangaDownloadJob(updatedAt: 32), isNull,
        reason: 'running / done 都不再被 claim');
  });

  test('watchMangaDownloadJobs 在写入后发信号，取消不留 pending timer', () async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    int ticks = 0;
    final StreamSubscription<void> sub =
        db.watchMangaDownloadJobs().listen((_) => ticks++);
    await db.upsertMangaDownloadJob(job('a', chapterKey: 'c1', createdAt: 1));
    await Future<void>.delayed(Duration.zero);
    expect(ticks, greaterThan(0));
    await sub.cancel();
  });

  test('重复打开幂等：第二次开库不因表已存在而报错', () async {
    final FushiDatabase first =
        FushiDatabase.atFile(path, isMainProcess: false);
    await first
        .upsertMangaDownloadJob(job('a', chapterKey: 'c1', createdAt: 1));
    await first.close();
    final FushiDatabase second =
        FushiDatabase.atFile(path, isMainProcess: false);
    expect(await second.listMangaDownloadJobs(), hasLength(1));
    await second.close();
  });
}

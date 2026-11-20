import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v155：`manga_download_jobs.status` 值域加 `paused`（拍板台 7LwxAtJ6r0：漫画下载
/// 可暂停 / 恢复，暂停态跨重启保持）。内联 CHECK 只能重建表：升级后存量行原样、
/// 两条索引仍在、`paused` 能写进去、非法值照旧被拒；已是新 shape 的表幂等跳过。
void main() {
  const String insertPrefix =
      'INSERT INTO manga_download_jobs (job_id, kind, book_key, chapter_key, '
      'runtime, title, chapter_title, status, pages_done, pages_total, '
      'attempt_count, last_error, auto_ocr, created_at, updated_at) VALUES ';

  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  Set<String> indexNames(sqlite.Database raw) => raw
      .select(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'manga_download_jobs'",
      )
      .map((sqlite.Row r) => r['name'] as String)
      .toSet();

  String createSql(sqlite.Database raw) =>
      raw
              .select(
                "SELECT sql FROM sqlite_master WHERE type = 'table' "
                "AND name = 'manga_download_jobs'",
              )
              .single['sql']
          as String;

  test('v154 → v155：重建表，存量行原样、索引仍在，paused 可写、非法值仍被拒', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'mangadownloadv155',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v154 形状：status 的 CHECK 不认 paused。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE manga_download_jobs');
    raw.execute(
      'CREATE TABLE manga_download_jobs ('
      'job_id TEXT NOT NULL, kind TEXT NOT NULL, book_key TEXT NOT NULL, '
      'chapter_key TEXT NOT NULL, runtime TEXT NOT NULL, title TEXT NOT NULL, '
      'chapter_title TEXT NOT NULL, '
      "status TEXT NOT NULL DEFAULT 'queued', "
      'pages_done INTEGER NOT NULL DEFAULT 0, '
      'pages_total INTEGER NOT NULL DEFAULT 0, '
      'attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT NULL, '
      'auto_ocr INTEGER NOT NULL DEFAULT 0 CHECK ("auto_ocr" IN (0, 1)), '
      'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, '
      'completed_at INTEGER NULL, PRIMARY KEY (job_id), '
      "CHECK (job_id != '' AND book_key != '' AND chapter_key != '' "
      "AND runtime != ''), "
      "CHECK (kind IN ('chapter', 'mokuro_volume')), "
      "CHECK (status IN ('queued', 'running', 'done', 'failed', "
      "'cancelled')), "
      'CHECK (pages_done >= 0 AND pages_total >= 0 '
      'AND pages_done <= pages_total), '
      'CHECK (attempt_count >= 0))',
    );
    raw.execute(
      'CREATE UNIQUE INDEX idx_manga_download_jobs_identity '
      'ON manga_download_jobs (kind, book_key, chapter_key)',
    );
    raw.execute(
      'CREATE INDEX idx_manga_download_jobs_status_created '
      'ON manga_download_jobs (status, created_at)',
    );
    raw.execute(
      "$insertPrefix ('j1', 'chapter', 'b', 'c1', 'mihon', 'Title', 'Ch 1', "
      "'failed', 2, 5, 3, 'boom', 1, 10, 20)",
    );
    expect(
      () => raw.execute(
        "$insertPrefix ('j2', 'chapter', 'b', 'c2', 'mihon', 'T', 'C', "
        "'paused', 0, 0, 0, NULL, 0, 1, 1)",
      ),
      throwsA(anything),
      reason: 'v154 形状确实不认 paused（前提成立）',
    );
    raw.execute('PRAGMA user_version = 154');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 162);
    final MangaDownloadJobRow row = (await migrated.getMangaDownloadJob('j1'))!;
    expect(row.status, MangaDownloadJobStatus.failed);
    expect(row.pagesDone, 2);
    expect(row.pagesTotal, 5);
    expect(row.attemptCount, 3);
    expect(row.lastError, 'boom');
    expect(row.autoOcr, isTrue);
    expect(row.createdAt, 10);

    await migrated.updateMangaDownloadJobStatus(
      'j1',
      status: MangaDownloadJobStatus.paused,
      updatedAt: 30,
    );
    expect(
      (await migrated.getMangaDownloadJob('j1'))!.status,
      MangaDownloadJobStatus.paused,
    );
    await expectLater(
      migrated.customStatement(
        "$insertPrefix ('j3', 'chapter', 'b', 'c3', 'mihon', 'T', 'C', "
        "'bogus', 0, 0, 0, NULL, 0, 1, 1)",
      ),
      throwsA(anything),
      reason: '值域仍然收口，只多了 paused',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 162);
    expect(createSql(probe), contains("'paused'"));
    expect(
      indexNames(probe),
      containsAll(<String>[
        'idx_manga_download_jobs_identity',
        'idx_manga_download_jobs_status_created',
      ]),
    );
  });

  test('v155 步幂等：表已认 paused 时不重建，暂停的行原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'mangadownloadv155idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      "$insertPrefix ('j1', 'chapter', 'b', 'c1', 'mihon', 'T', 'C', "
      "'paused', 1, 4, 0, NULL, 0, 1, 1)",
    );
    raw.execute('PRAGMA user_version = 154');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final MangaDownloadJobRow row = (await migrated.getMangaDownloadJob('j1'))!;
    expect(row.status, MangaDownloadJobStatus.paused);
    expect(row.pagesDone, 1);
    await migrated.close();
  });
}

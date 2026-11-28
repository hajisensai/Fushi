import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        capFutureSyncStamp,
        capFutureSyncStampSql,
        kSyncFutureStampToleranceMs,
        trustedStoredSyncStamp,
        trustedStoredSyncStampSql;
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-5612：备份合并（merge 模式）的 LWW 比较没有毒戳防护。
///
/// 备份里一条时钟走快的设备写下的未来戳（> 现在 + [kSyncFutureStampToleranceMs]）
/// 在裸 `s.updated_at > t.updated_at` 下永远胜出：压住本机真实的较新进度，落地后
/// 还把毒戳带进本库，之后本机再怎么读都盖不过它。修复后两侧都按同步侧
/// [trustedStoredSyncStamp] 的 SQL 等价物比较（毒戳按 0），落地戳截到
/// [capFutureSyncStamp]。
void main() {
  const int year = 365 * 24 * 60 * 60 * 1000;
  int bookCounter = 0;

  EpubBooksCompanion book(String key, String uid) => EpubBooksCompanion.insert(
    bookKey: key,
    uid: Value(uid),
    title: key,
    epubPath: '/fake/$key.epub',
    extractDir: '/fake/$key-${bookCounter++}',
    chapterCount: 1,
    chaptersJson: '[]',
    importedAt: 1000,
  );

  ReaderPositionsCompanion position(
    String bookUid, {
    required int sectionIndex,
    required int updatedAt,
  }) => ReaderPositionsCompanion.insert(
    bookUid: bookUid,
    sectionIndex: sectionIndex,
    normCharOffset: sectionIndex * 1000,
    updatedAt: updatedAt,
  );

  Future<String> buildSrcDb(
    Future<void> Function(FushiDatabase src) seed,
  ) async {
    final Directory srcDir = await Directory.systemTemp.createTemp('ps_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    await seed(src);
    await src.close();
    return p.join(srcDir.path, 'fushi.db');
  }

  Future<FushiDatabase> buildTarget(
    Future<void> Function(FushiDatabase target) seed,
  ) async {
    final Directory dir = await Directory.systemTemp.createTemp('ps_tgt_');
    final FushiDatabase target = FushiDatabase(dir.path);
    addTearDown(() async {
      await target.close();
      await cleanupTempDir(dir);
    });
    await seed(target);
    return target;
  }

  Future<void> attach(FushiDatabase target, String srcDbPath) async {
    final String safe = srcDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
  }

  Future<void> attachAndMerge(
    FushiDatabase target,
    String srcDbPath, {
    bool fillMissingOnly = false,
  }) async {
    await attach(target, srcDbPath);
    await BackupMergeEngine(target, fillMissingOnly: fillMissingOnly).merge();
    await target.customStatement('DETACH DATABASE mergesrc');
  }

  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  test(
    'SQL 口径与 Dart 的 trustedStoredSyncStamp / capFutureSyncStamp 逐值一致',
    () async {
      final FushiDatabase db = await buildTarget((_) async {});
      final int now = nowMs();
      final List<int> samples = <int>[
        0,
        1,
        now - 1000,
        now,
        now + kSyncFutureStampToleranceMs - 1,
        now + kSyncFutureStampToleranceMs,
        now + kSyncFutureStampToleranceMs + 1,
        now + year,
      ];
      for (final int v in samples) {
        final QueryRow row = await db
            .customSelect(
              'SELECT ${trustedStoredSyncStampSql('?1', nowMs: now)} AS t, '
              '${capFutureSyncStampSql('?1', nowMs: now)} AS c',
              variables: <Variable<Object>>[Variable<int>(v)],
            )
            .getSingle();
        expect(row.read<int>('t'), trustedStoredSyncStamp(v, nowMs: now));
        expect(row.read<int>('c'), capFutureSyncStamp(v, nowMs: now));
      }
    },
  );

  test('备份带未来毒戳的阅读位置不压住本机较新的真实进度（预览也不计）', () async {
    final int now = nowMs();
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('shared', 'src-uid'));
      await src.upsertReaderPosition(
        position('src-uid', sectionIndex: 9, updatedAt: now + year),
      );
    });
    final FushiDatabase target = await buildTarget((FushiDatabase t) async {
      await t.insertEpubBook(book('shared', 'tgt-uid'));
      await t.upsertReaderPosition(
        position('tgt-uid', sectionIndex: 3, updatedAt: now - 1000),
      );
    });

    await attach(target, srcDbPath);
    final BackupMergePreview preview = await BackupMergeEngine(
      target,
    ).preview();
    expect(preview.updatedReaderPositions, 0);
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');

    final ReaderPositionRow? pos = await target.getReaderPosition('tgt-uid');
    expect(pos!.sectionIndex, 3);
    expect(pos.updatedAt, now - 1000);
  });

  test('本机已有的毒戳被备份里的正常进度盖掉（自愈）', () async {
    final int now = nowMs();
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('shared', 'src-uid'));
      await src.upsertReaderPosition(
        position('src-uid', sectionIndex: 5, updatedAt: now - 1000),
      );
    });
    final FushiDatabase target = await buildTarget((FushiDatabase t) async {
      await t.insertEpubBook(book('shared', 'tgt-uid'));
      await t.upsertReaderPosition(
        position('tgt-uid', sectionIndex: 1, updatedAt: now + year),
      );
    });

    await attachAndMerge(target, srcDbPath);

    final ReaderPositionRow? pos = await target.getReaderPosition('tgt-uid');
    expect(pos!.sectionIndex, 5);
    expect(pos.updatedAt, now - 1000);
  });

  test('本机没有的书：进度照插，但毒戳截到未来余量内、不扩散进本库', () async {
    final int now = nowMs();
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('only-src', 'src-uid'));
      await src.upsertReaderPosition(
        position('src-uid', sectionIndex: 4, updatedAt: now + year),
      );
    });
    final FushiDatabase target = await buildTarget((_) async {});

    await attachAndMerge(target, srcDbPath);

    final QueryRow row = await target
        .customSelect(
          'SELECT p.section_index AS s, p.updated_at AS u '
          'FROM reader_positions AS p JOIN epub_books AS b '
          "ON b.uid = p.book_uid WHERE b.book_key = 'only-src'",
        )
        .getSingle();
    expect(row.read<int>('s'), 4);
    expect(
      row.read<int>('u'),
      lessThanOrEqualTo(nowMs() + kSyncFutureStampToleranceMs),
    );
  });

  test('只补缺模式：既有行一律不动（毒戳 / 正常戳都一样）', () async {
    final int now = nowMs();
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('shared', 'src-uid'));
      await src.upsertReaderPosition(
        position('src-uid', sectionIndex: 5, updatedAt: now - 1000),
      );
    });
    final FushiDatabase target = await buildTarget((FushiDatabase t) async {
      await t.insertEpubBook(book('shared', 'tgt-uid'));
      await t.upsertReaderPosition(
        position('tgt-uid', sectionIndex: 1, updatedAt: now + year),
      );
    });

    await attachAndMerge(target, srcDbPath, fillMissingOnly: true);

    final ReaderPositionRow? pos = await target.getReaderPosition('tgt-uid');
    expect(pos!.sectionIndex, 1);
  });

  test('音乐断点 / 书自定义 CSS / 漫画覆盖设置 / 改名：备份毒戳都不压本机较新值', () async {
    final int now = nowMs();
    final int poison = now + year;
    final int real = now - 1000;
    const String titleKey = 'override_title://fushi://book/shared';
    Future<void> seed(FushiDatabase db, String uid, String tag, int at) async {
      await db.insertEpubBook(book('shared', uid));
      await db.customStatement(
        'INSERT INTO music_resume_points '
        '(track_uid, position_ms, duration_ms, updated_at) '
        "VALUES ('track-1', ?, NULL, ?)",
        <Object>[tag == 'src' ? 9000 : 3000, at],
      );
      await db.customStatement(
        'INSERT INTO book_custom_css '
        '(book_uid, relative_path, content, deleted, updated_at) '
        "VALUES (?, 'a.css', ?, 0, ?)",
        <Object>[uid, 'css-$tag', at],
      );
      await db.customStatement(
        'INSERT INTO manga_reader_overrides '
        '(book_uid, overrides_json, updated_at, deleted) '
        'VALUES (?, ?, ?, 0)',
        <Object>[uid, '{"tag":"$tag"}', at],
      );
      await db.customStatement(
        'INSERT INTO preferences ("key", "value", "updated_at") '
        'VALUES (?, ?, ?)',
        <Object>[titleKey, 'title-$tag', at],
      );
    }

    final String srcDbPath = await buildSrcDb(
      (FushiDatabase src) => seed(src, 'src-uid', 'src', poison),
    );
    final FushiDatabase target = await buildTarget(
      (FushiDatabase t) => seed(t, 'tgt-uid', 'tgt', real),
    );

    await attachAndMerge(target, srcDbPath);

    Future<Object?> one(String sql) async =>
        (await target.customSelect(sql).getSingle()).data.values.single;
    expect(await one('SELECT position_ms FROM music_resume_points'), 3000);
    expect(await one('SELECT content FROM book_custom_css'), 'css-tgt');
    expect(
      await one('SELECT overrides_json FROM manga_reader_overrides'),
      '{"tag":"tgt"}',
    );
    expect(
      await one(
        "SELECT \"value\" FROM preferences WHERE \"key\" = '$titleKey'",
      ),
      'title-tgt',
    );
  });
}

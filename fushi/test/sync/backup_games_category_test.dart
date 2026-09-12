import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// `BackupCategory.games`：游戏库（galgames + galgame_sources + 封面文件）成为
/// 可选导出 / 导入类别。此前游戏行永远随整库 DB 走（导出不可剔、导入不可跳），
/// 封面反而从不打包。顺带钉死两条一并修的旧承诺：`study_segments` 归统计类别，
/// 导入摘要的 present 集合补上 progress / statistics / games。
void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_games_src_');
    dst = await Directory.systemTemp.createTemp('bk_games_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<int> countRows(
    FushiDatabase db,
    String table, [
    String where = '',
  ]) async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS c FROM $table $where')
        .getSingle();
    return row.data['c'] as int;
  }

  Future<Archive> readZip(String zipPath) async {
    final InputFileStream input = InputFileStream(zipPath);
    try {
      return ZipDecoder().decodeBuffer(input);
    } finally {
      await input.close();
    }
  }

  Future<FushiDatabase> openBackupDb(String zipPath, Directory into) async {
    final Archive archive = await readZip(zipPath);
    final ArchiveFile dbFile = archive.findFile('fushi.db')!;
    final Directory dir = Directory(p.join(into.path, 'exdb'))
      ..createSync(recursive: true);
    File(
      p.join(dir.path, 'fushi.db'),
    ).writeAsBytesSync(dbFile.content as List<int>);
    return FushiDatabase(dir.path);
  }

  /// Seeds one game (`G1`, scrape identity bgm:100, cover on disk) with a
  /// play session, a chars-only study segment, a tag and a legacy activity row,
  /// plus one book with progress so the other categories have content too.
  Future<({FushiDatabase db, String dbDir, String coversRoot})> seedSource(
    Directory root, {
    String gameId = 'G1',
    String exePath = r'D:\games\g1\g1.exe',
  }) async {
    final String dbDir = p.join(root.path, 'support');
    final String covers = p.join(root.path, 'documents', 'game_covers');
    Directory(dbDir).createSync(recursive: true);
    File(p.join(covers, '$gameId.png'))
      ..createSync(recursive: true)
      ..writeAsStringSync('PNG');
    final FushiDatabase db = FushiDatabase(dbDir);
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: gameId,
        name: 'Game One',
        exePath: exePath,
        workdir: p.dirname(exePath),
        addedAt: 1,
        coverPath: Value<String?>(p.join(covers, '$gameId.png')),
      ),
    );
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: gameId,
        source: 'bgm',
        externalId: const Value<String?>('100'),
        dataJson: '{}',
        fetchedAt: 1,
      ),
    );
    await db.insertGalgameSession(
      GalgameSessionsCompanion.insert(
        gameId: gameId,
        startMs: 1000,
        endMs: 61000,
        durationSeconds: 60,
        dateKey: '2026-01-01',
      ),
    );
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: 'seg-$gameId',
        deviceId: 'dev-src',
        mediaKind: kActivityMediaGame,
        mediaKey: gameId,
        title: 'Game One',
        startAt: 2000,
        endAt: 2000,
        dateKey: '2026-01-01',
        hour: 0,
        chars: const Value<int>(42),
        updatedAt: 2000,
      ),
    );
    await db.upsertStudySegmentTombstone(
      mediaKind: kActivityMediaGame,
      mediaKey: gameId,
      deletedAt: 500,
    );
    final int tagId = await db.createTag('fav', 0xff0000);
    await db.addTagToGame(gameId, tagId);
    final int collectionId = await db.createMediaCollection('gal-col');
    await db.addToCollection(collectionId, MediaKind.game, gameId);
    await db.addActivityEvent(
      eventType: kActivityGame,
      mediaType: kActivityMediaGame,
      title: 'Game One',
      mediaKey: gameId,
      dateKey: '2026-01-01',
      timestampMs: 3000,
      charsDelta: 5,
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: 'x',
        extractDir: 'y',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ),
    );
    final String bkUid = (await db.resolveEpubBookUid('Bk'))!;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: bkUid,
        sectionIndex: 0,
        normCharOffset: 100,
        updatedAt: 1,
      ),
    );
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: 'seg-book',
        deviceId: 'dev-src',
        mediaKind: 'read',
        mediaKey: bkUid,
        title: 'Bk',
        startAt: 4000,
        endAt: 5000,
        dateKey: '2026-01-01',
        hour: 0,
        durationMs: const Value<int>(1000),
        updatedAt: 5000,
      ),
    );
    return (db: db, dbDir: dbDir, coversRoot: covers);
  }

  BackupService serviceFor(
    ({FushiDatabase db, String dbDir, String coversRoot}) s,
  ) =>
      BackupService(
        db: s.db,
        dbDirectory: s.dbDir,
        appVersion: '1.0.0',
        gameCoversRootDirectory: s.coversRoot,
      );

  Set<BackupCategory> allExcept(BackupCategory c) =>
      BackupCategory.values.toSet()..remove(c);

  test('games 未勾：导出 DB 无任何游戏行、zip 无 game_covers、meta 记 0', () async {
    final s = await seedSource(src);
    final String zip = p.join(src.path, 'no_games.zip');
    final BackupMeta meta = await serviceFor(
      s,
    ).createBackup(zip, categories: allExcept(BackupCategory.games));
    await s.db.close();

    expect(meta.gameCount, 0);
    expect(meta.gameCoversRoot, isNull);
    expect(meta.excludedCategories, contains('games'));
    final Archive archive = await readZip(zip);
    expect(
      archive.files.any((ArchiveFile f) => f.name.startsWith('game_covers/')),
      isFalse,
      reason: '未勾 games 不得打包封面',
    );
    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'galgames'), 0);
      expect(await countRows(db, 'galgame_sources'), 0);
      expect(await countRows(db, 'galgame_sessions'), 0);
      expect(
        await countRows(db, 'tag_assignments', "WHERE media_kind = 'game'"),
        0,
      );
      expect(
        await countRows(
          db,
          'media_collection_items',
          "WHERE media_type = 'game'",
        ),
        0,
        reason: '合集里的游戏成员随宿主一起裁掉，不留孤儿成员',
      );
      expect(
        await countRows(db, 'study_segments', "WHERE media_kind = 'game'"),
        0,
      );
      expect(
        await countRows(
          db,
          'study_segment_tombstones',
          "WHERE media_kind = 'game'",
        ),
        0,
      );
      expect(
        await countRows(db, 'activity_events', "WHERE media_type = 'game'"),
        0,
      );
      // 其它类别不受牵连。
      expect(await countRows(db, 'epub_books'), 1);
      expect(
        await countRows(db, 'study_segments', "WHERE media_kind = 'read'"),
        1,
      );
      expect(await countRows(db, 'book_tags'), 0, reason: '只剩游戏引用的标签随宿主一起排干');
    } finally {
      await db.close();
    }
  });

  test('games 勾选：导出 DB 有游戏行、zip 打包封面、meta 记根与计数', () async {
    final s = await seedSource(src);
    final String zip = p.join(src.path, 'games.zip');
    final BackupMeta meta = await serviceFor(s).createBackup(zip);
    await s.db.close();

    expect(meta.gameCount, 1);
    expect(meta.gameCoversRoot, s.coversRoot);
    expect(meta.progressCount, 1);
    expect(meta.statsCount, 2, reason: 'study_segments 计入统计记录数');
    final Archive archive = await readZip(zip);
    expect(archive.findFile('game_covers/G1.png'), isNotNull);
    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'galgames'), 1);
      expect(await countRows(db, 'galgame_sources'), 1);
      expect(await countRows(db, 'galgame_sessions'), 1);
    } finally {
      await db.close();
    }
    // 往返：meta JSON 带新字段。
    final BackupMeta round = BackupMeta.fromJson(meta.toJson());
    expect(round.gameCount, 1);
    expect(round.progressCount, 1);
    expect(round.gameCoversRoot, s.coversRoot);
  });

  test('statistics 未勾：study_segments 与其墓碑真的被裁掉', () async {
    final s = await seedSource(src);
    final String zip = p.join(src.path, 'no_stats.zip');
    await serviceFor(
      s,
    ).createBackup(zip, categories: allExcept(BackupCategory.statistics));
    await s.db.close();
    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'study_segments'), 0);
      expect(await countRows(db, 'study_segment_tombstones'), 0);
      expect(await countRows(db, 'galgame_sessions'), 0);
      expect(await countRows(db, 'galgames'), 1, reason: '游戏行是内容');
    } finally {
      await db.close();
    }
  });

  test('导出侧 summarizeLiveContent 报 games / progress / statistics 计数', () async {
    final s = await seedSource(src);
    final BackupContentSummary summary = await serviceFor(
      s,
    ).summarizeLiveContent();
    await s.db.close();
    expect(summary.countFor(BackupCategory.games), 1);
    expect(summary.countFor(BackupCategory.progress), 1);
    expect(summary.countFor(BackupCategory.statistics), 2);
    expect(
      summary.present,
      containsAll(<BackupCategory>[
        BackupCategory.games,
        BackupCategory.progress,
        BackupCategory.statistics,
      ]),
    );
  });

  test(
    '导入摘要：新包经 meta、旧包经 DB 窥探，present 都含 games/progress/statistics',
    () async {
      final s = await seedSource(src);
      final String zip = p.join(src.path, 'full.zip');
      await serviceFor(s).createBackup(zip);
      await s.db.close();

      final BackupContentSummary viaMeta =
          await BackupRestoreService.summarizeBackupFile(zip);
      expect(viaMeta.countFor(BackupCategory.games), 1);
      expect(viaMeta.countFor(BackupCategory.progress), 1);
      expect(viaMeta.countFor(BackupCategory.statistics), 2);

      // 旧包：meta 没有 gameCount / progressCount / gameCoversRoot（且
      // excludedCategories 里没有 games）——重打一个只改 meta 的 zip。
      final String legacyZip = await _rewriteMetaWithout(
        zip,
        dst,
        const <String>[
          'gameCount',
          'progressCount',
          'gameCoversRoot',
          'statsCount',
        ],
      );
      final BackupContentSummary viaPeek =
          await BackupRestoreService.summarizeBackupFile(legacyZip);
      expect(
        viaPeek.countFor(BackupCategory.games),
        1,
        reason: '旧 meta 无计数 → 窥探 DB 行数',
      );
      expect(viaPeek.countFor(BackupCategory.progress), 1);
      expect(viaPeek.countFor(BackupCategory.statistics), 2);
      expect(viaPeek.has(BackupCategory.games), isTrue);

      // 纯函数面：legacy meta + 窥探值 → present。
      final BackupContentSummary pure =
          BackupRestoreService.summarizeBackupEntries(
        const <String>['fushi.db'],
        BackupMeta(
          appVersion: '1',
          schemaVersion: 1,
          createdAt: DateTime(2026),
          bookCount: 0,
          statsCount: 0,
        ),
        dbGameCount: 3,
        dbProgressCount: 2,
        dbStatisticsCount: 5,
      );
      expect(pure.countFor(BackupCategory.games), 3);
      expect(pure.countFor(BackupCategory.progress), 2);
      expect(
        pure.countFor(BackupCategory.statistics),
        5,
        reason: '窥探值优先于旧 meta 只数 legacy 表的 statsCount',
      );
    },
  );

  test('旧包窥探失败：未知按「存在」处理，games/progress/statistics 仍在 present', () async {
    // 纯函数面：peekFailed 且 meta 缺计数 → present 含全部 DB-blob 类别（无计数）。
    final BackupContentSummary pure =
        BackupRestoreService.summarizeBackupEntries(
      const <String>['fushi.db'],
      BackupMeta(
        appVersion: '1',
        schemaVersion: 1,
        createdAt: DateTime(2026),
        bookCount: 0,
        statsCount: 0,
      ),
      peekFailed: true,
    );
    expect(
      pure.present,
      containsAll(<BackupCategory>[
        BackupCategory.games,
        BackupCategory.progress,
        BackupCategory.statistics,
        BackupCategory.videos,
        BackupCategory.audiobooks,
      ]),
      reason: '窥探失败若按 0 处理，开关不出现 → 类别集不含 games → 覆盖导入会把'
          '本机游戏库删光；未知必须按存在处理',
    );
    expect(pure.countFor(BackupCategory.games), 0, reason: '无计数，只标存在');
    // 新格式 meta（有计数）不受 peekFailed 影响：计数是权威。
    final BackupContentSummary known =
        BackupRestoreService.summarizeBackupEntries(
      const <String>['fushi.db'],
      BackupMeta(
        appVersion: '1',
        schemaVersion: 1,
        createdAt: DateTime(2026),
        bookCount: 0,
        statsCount: 0,
        videoBookCount: 0,
        audiobookCount: 0,
        gameCount: 0,
        progressCount: 0,
      ),
      peekFailed: true,
    );
    expect(known.present, isEmpty);

    // 真实文件面：旧 meta + 损坏的 fushi.db 条目 → _peekContentRowCounts 返回
    // null → summarizeBackupFile 必须把 games 标成存在。
    final String zip = p.join(dst.path, 'legacy_bad_db.zip');
    final Archive out = Archive();
    final List<int> metaBytes = utf8.encode(jsonEncode(<String, Object?>{
      'appVersion': '1.0.0',
      'schemaVersion': 1,
      'createdAt': DateTime(2026).toIso8601String(),
      'bookCount': 0,
      'statsCount': 0,
    }));
    out.addFile(ArchiveFile('backup_meta.json', metaBytes.length, metaBytes));
    final List<int> junk = utf8.encode('this is not a sqlite database at all');
    out.addFile(ArchiveFile('fushi.db', junk.length, junk));
    File(zip).writeAsBytesSync(ZipEncoder().encode(out)!);
    final BackupContentSummary viaFile =
        await BackupRestoreService.summarizeBackupFile(zip);
    expect(viaFile.has(BackupCategory.games), isTrue);
    expect(viaFile.has(BackupCategory.progress), isTrue);
    expect(viaFile.has(BackupCategory.statistics), isTrue);
  });

  test('覆盖导入 games 勾选：游戏行落地、封面树恢复、cover_path 重定位到本机', () async {
    final s = await seedSource(src);
    final String zip = p.join(src.path, 'full.zip');
    await serviceFor(s).createBackup(zip);
    await s.db.close();

    final String curDbDir = p.join(dst.path, 'support');
    final String curCovers = p.join(dst.path, 'documents', 'game_covers');
    Directory(curDbDir).createSync(recursive: true);
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      gameCoversRootDirectory: curCovers,
    );
    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      final List<GalgameRow> games = await cur.getAllGalgames();
      expect(games, hasLength(1));
      expect(games.single.coverPath, p.join(curCovers, 'G1.png'));
      expect(File(p.join(curCovers, 'G1.png')).existsSync(), isTrue);
      expect(await countRows(cur, 'galgame_sessions'), 1);
    } finally {
      await cur.close();
    }
  });

  test('覆盖导入 games 未勾：备份里的游戏不落地（行与封面都不来）', () async {
    final s = await seedSource(src);
    final String zip = p.join(src.path, 'full.zip');
    await serviceFor(s).createBackup(zip);
    await s.db.close();

    final String curDbDir = p.join(dst.path, 'support');
    final String curCovers = p.join(dst.path, 'documents', 'game_covers');
    Directory(curDbDir).createSync(recursive: true);
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      categories: allExcept(BackupCategory.games),
      gameCoversRootDirectory: curCovers,
    );
    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      expect(await countRows(cur, 'galgames'), 0);
      expect(await countRows(cur, 'galgame_sessions'), 0);
      expect(
        await countRows(cur, 'study_segments', "WHERE media_kind = 'game'"),
        0,
      );
      expect(await countRows(cur, 'epub_books'), 1, reason: '书照常恢复');
      expect(File(p.join(curCovers, 'G1.png')).existsSync(), isFalse);
    } finally {
      await cur.close();
    }
  });

  test(
    '旧包（excludedCategories 无 games、meta 无 gameCount）导入等价于 games 已勾选',
    () async {
      final s = await seedSource(src);
      final String zip = p.join(src.path, 'full.zip');
      await serviceFor(s).createBackup(zip);
      await s.db.close();
      final String legacyZip = await _rewriteMetaWithout(
        zip,
        dst,
        const <String>['gameCount', 'progressCount', 'gameCoversRoot'],
      );
      final BackupMeta legacyMeta = (await BackupRestoreService.validateBackup(
        legacyZip,
      ))!;
      expect(legacyMeta.gameCount, isNull);
      expect(legacyMeta.excludedCategories, isNot(contains('games')));

      final String curDbDir = p.join(dst.path, 'support');
      Directory(curDbDir).createSync(recursive: true);
      await BackupRestoreService.restoreBackup(
        dbDirectory: curDbDir,
        zipPath: legacyZip,
        gameCoversRootDirectory: p.join(dst.path, 'documents', 'game_covers'),
      );
      final FushiDatabase cur = FushiDatabase(curDbDir);
      try {
        expect(
          await countRows(cur, 'galgames'),
          1,
          reason: '旧包的游戏行照旧随整库恢复（Never break userspace）',
        );
        expect(await countRows(cur, 'galgame_sessions'), 1);
      } finally {
        await cur.close();
      }
    },
  );

  test('合并导入：按刮削身份去重 + 子行重映射；新游戏插入并重定位封面', () async {
    // src：G1（bgm:100，本机路径 D:\games\g1）+ G2（无刮削身份、独有）。
    final s = await seedSource(src);
    File(p.join(s.coversRoot, 'G2.png')).writeAsStringSync('PNG2');
    await s.db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'G2',
        name: 'Game Two',
        exePath: r'D:\games\g2\g2.exe',
        workdir: r'D:\games\g2',
        addedAt: 2,
        coverPath: Value<String?>(p.join(s.coversRoot, 'G2.png')),
      ),
    );
    final String zip = p.join(src.path, 'merge.zip');
    await serviceFor(s).createBackup(zip);
    await s.db.close();

    // target：同一部游戏 T1（bgm:100）装在别的路径、自己的封面 + 自己的会话。
    final String curDbDir = p.join(dst.path, 'support');
    final String curCovers = p.join(dst.path, 'documents', 'game_covers');
    Directory(curDbDir).createSync(recursive: true);
    File(p.join(curCovers, 'T1.jpg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('JPG');
    final FushiDatabase seed = FushiDatabase(curDbDir);
    await seed.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'T1',
        name: 'Game One (local)',
        exePath: r'E:\gal\one\one.exe',
        workdir: r'E:\gal\one',
        addedAt: 9,
        coverPath: Value<String?>(p.join(curCovers, 'T1.jpg')),
      ),
    );
    await seed.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'T1',
        source: 'bgm',
        externalId: const Value<String?>('100'),
        dataJson: '{"local":true}',
        fetchedAt: 9,
      ),
    );
    await seed.insertGalgameSession(
      GalgameSessionsCompanion.insert(
        gameId: 'T1',
        startMs: 9000,
        endMs: 9900,
        durationSeconds: 1,
        dateKey: '2026-01-02',
      ),
    );
    await seed.close();

    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      gameCoversRootDirectory: curCovers,
    );

    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      final List<GalgameRow> games = await cur.getAllGalgames();
      expect(
        games.map((GalgameRow g) => g.id).toSet(),
        <String>{'T1', 'G2'},
        reason: 'G1 与 T1 同刮削身份 → 去重不插；G2 独有 → 插入',
      );
      final GalgameRow t1 = games.singleWhere((GalgameRow g) => g.id == 'T1');
      expect(t1.coverPath, p.join(curCovers, 'T1.jpg'), reason: '目标自己的行原样保留');
      expect(t1.exePath, r'E:\gal\one\one.exe');
      final GalgameRow g2 = games.singleWhere((GalgameRow g) => g.id == 'G2');
      expect(
        g2.coverPath,
        p.join(curCovers, 'G2.png'),
        reason: '新插入行的 cover_path 重定位到本机 game_covers',
      );
      expect(
        File(p.join(curCovers, 'G2.png')).existsSync(),
        isTrue,
        reason: '封面 copy-if-absent 落地',
      );
      // galgame_sources：T1 保留自己的 bgm 快照。
      final List<GalgameSourceRow> t1Sources = await cur.getGalgameSources(
        'T1',
      );
      expect(t1Sources.single.dataJson, '{"local":true}');
      // 会话：src G1 的会话重映射到 T1；目标原有会话保留。
      expect(
        await countRows(cur, 'galgame_sessions', "WHERE game_id = 'T1'"),
        2,
      );
      expect(
        await countRows(cur, 'galgame_sessions', "WHERE game_id = 'G1'"),
        0,
        reason: '不得留下指向不存在宿主的会话',
      );
      // 学习段 / 墓碑 / 活动行 / 标签：media_key 全部落到 T1。
      expect(
        await countRows(
          cur,
          'study_segments',
          "WHERE media_kind = 'game' AND media_key = 'T1'",
        ),
        1,
      );
      expect(
        await countRows(
          cur,
          'study_segment_tombstones',
          "WHERE media_kind = 'game' AND media_key = 'T1'",
        ),
        1,
      );
      expect(
        await countRows(
          cur,
          'activity_events',
          "WHERE media_type = 'game' AND media_key = 'T1'",
        ),
        1,
      );
      expect(
        await countRows(
          cur,
          'tag_assignments',
          "WHERE media_kind = 'game' AND entry_key = 'T1'",
        ),
        1,
      );
      expect(
        await countRows(
          cur,
          'tag_assignments',
          "WHERE media_kind = 'game' AND entry_key = 'G1'",
        ),
        0,
      );
      expect(
        await countRows(
          cur,
          'media_collection_items',
          "WHERE media_type = 'game' AND entry_key = 'T1'",
        ),
        1,
        reason: '合集成员与标签/会话同律：经身份映射落到 T1',
      );
      expect(
        await countRows(
          cur,
          'media_collection_items',
          "WHERE media_type = 'game' AND entry_key = 'G1'",
        ),
        0,
        reason: '不得留下指向不存在游戏的孤儿成员',
      );
      // 全库不存在指向 G1 的任何引用。
      expect(
        await countRows(cur, 'study_segments', "WHERE media_key = 'G1'"),
        0,
      );
    } finally {
      await cur.close();
    }

    // 幂等：再合并一次，行数不变。
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      gameCoversRootDirectory: curCovers,
    );
    final FushiDatabase again = FushiDatabase(curDbDir);
    try {
      expect(await countRows(again, 'galgames'), 2);
      expect(await countRows(again, 'galgame_sessions'), 2);
      expect(
        await countRows(again, 'study_segments', "WHERE media_kind = 'game'"),
        1,
      );
      expect(
        await countRows(again, 'tag_assignments', "WHERE media_kind = 'game'"),
        1,
      );
    } finally {
      await again.close();
    }
  });

  test('合并导入 games 未勾：不插游戏；无宿主的游戏事实行跳过而非悬空', () async {
    final s = await seedSource(src);
    final String zip = p.join(src.path, 'merge.zip');
    await serviceFor(s).createBackup(zip);
    await s.db.close();

    final String curDbDir = p.join(dst.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      categories: allExcept(BackupCategory.games),
      gameCoversRootDirectory: p.join(dst.path, 'documents', 'game_covers'),
    );
    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      expect(await countRows(cur, 'galgames'), 0);
      expect(await countRows(cur, 'galgame_sessions'), 0);
      expect(
        await countRows(cur, 'study_segments', "WHERE media_kind = 'game'"),
        0,
      );
      expect(
        await countRows(cur, 'tag_assignments', "WHERE media_kind = 'game'"),
        0,
      );
      expect(
        await countRows(cur, 'study_segments', "WHERE media_kind = 'read'"),
        1,
        reason: '非游戏统计照常合并',
      );
      expect(await countRows(cur, 'epub_books'), 1);
    } finally {
      await cur.close();
    }
  });
}

/// Repacks [zipPath] into [into] with the listed [keys] deleted from
/// `backup_meta.json`, simulating a backup written before those fields existed.
Future<String> _rewriteMetaWithout(
  String zipPath,
  Directory into,
  List<String> keys,
) async {
  final InputFileStream input = InputFileStream(zipPath);
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBuffer(input);
  } finally {
    await input.close();
  }
  final Archive out = Archive();
  for (final ArchiveFile f in archive.files) {
    if (!f.isFile) continue;
    if (f.name == 'backup_meta.json') {
      final Map<String, dynamic> meta =
          jsonDecode(utf8.decode(f.content as List<int>))
              as Map<String, dynamic>;
      for (final String k in keys) {
        meta.remove(k);
      }
      final List<int> bytes = utf8.encode(jsonEncode(meta));
      out.addFile(ArchiveFile(f.name, bytes.length, bytes));
    } else {
      final List<int> bytes = f.content as List<int>;
      out.addFile(ArchiveFile(f.name, bytes.length, bytes));
    }
  }
  final String outPath = p.join(into.path, 'legacy_${p.basename(zipPath)}');
  File(outPath).writeAsBytesSync(ZipEncoder().encode(out)!);
  return outPath;
}

// v147 删掉了游戏台词表 galgame_text_lines（「我库里的例句」下架后无读写者）。
// 旧备份（v134–v146 导出）的主库里还带着这张表和存量台词：覆盖恢复与合并导入都必须
// 照常完成、不报错，恢复后的库里没有这张表，游戏本身与其它数据照常落地。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'temp_dir_cleanup.dart';

void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_legacy_gtl_src_');
    dst = await Directory.systemTemp.createTemp('bk_legacy_gtl_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<void> addGame(
    FushiDatabase db,
    String id, {
    required String exePath,
  }) async {
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: id,
        name: 'Game $id',
        exePath: exePath,
        workdir: p.dirname(exePath),
        addedAt: 1,
      ),
    );
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: id,
        source: 'bgm',
        externalId: const Value<String?>('100'),
        dataJson: '{}',
        fetchedAt: 1,
      ),
    );
  }

  bool hasTable(String dbPath) {
    final sqlite.Database raw = sqlite.sqlite3.open(
      dbPath,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      return raw
          .select(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' "
            "AND name = 'galgame_text_lines'",
          )
          .isNotEmpty;
    } finally {
      raw.close();
    }
  }

  /// 用当前代码导出一份备份，再把包里的主库改回 v146 的样子：补上 v134 的
  /// galgame_text_lines 表与两句存量台词、user_version 退回 146——即旧版导出的备份。
  Future<String> legacyBackupZip() async {
    final String dbDir = p.join(src.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    await addGame(db, 'G1', exePath: r'D:\games\g1\g1.exe');
    final String fresh = p.join(src.path, 'fresh.zip');
    await BackupService(
      db: db,
      dbDirectory: dbDir,
      appVersion: '1.0.0',
    ).createBackup(fresh);
    await db.close();

    final Archive archive = ZipDecoder().decodeBytes(
      await File(fresh).readAsBytes(),
    );
    final ArchiveFile dbEntry = archive.findFile(fushiDatabaseFileName)!;
    final String work = p.join(src.path, 'legacy.db');
    File(work).writeAsBytesSync(dbEntry.content as List<int>);
    final sqlite.Database raw = sqlite.sqlite3.open(work);
    try {
      raw.execute('PRAGMA journal_mode = DELETE');
      raw.execute(
        'CREATE TABLE "galgame_text_lines" ('
        '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
        '"game_id" TEXT NOT NULL REFERENCES galgames (id) ON DELETE CASCADE, '
        '"text" TEXT NOT NULL, '
        '"received_at" INTEGER NOT NULL, '
        'UNIQUE ("game_id", "text"))',
      );
      raw.execute(
        'INSERT INTO galgame_text_lines (game_id, text, received_at) VALUES '
        "('G1', 'The night is long', 10), ('G1', 'Run to the sea', 20)",
      );
      raw.execute('PRAGMA user_version = 146');
    } finally {
      raw.close();
    }
    final Uint8List legacyBytes = File(work).readAsBytesSync();
    expect(hasTable(work), isTrue, reason: '夹具：旧备份的主库带着这张表');

    final Archive legacy = Archive();
    for (final ArchiveFile f in archive.files) {
      if (!f.isFile) continue;
      if (f.name == fushiDatabaseFileName) {
        legacy.addFile(
          ArchiveFile(f.name, legacyBytes.length, legacyBytes)
            ..compress = false,
        );
      } else {
        final List<int> bytes = f.content as List<int>;
        legacy.addFile(ArchiveFile(f.name, bytes.length, bytes));
      }
    }
    final String zip = p.join(src.path, 'legacy.zip');
    File(zip).writeAsBytesSync(ZipEncoder().encode(legacy)!);
    return zip;
  }

  test('覆盖恢复：旧备份带 galgame_text_lines 照常恢复，表被删、游戏照常落地', () async {
    final String zip = await legacyBackupZip();
    final String curDbDir = p.join(dst.path, 'support');
    Directory(curDbDir).createSync(recursive: true);

    await BackupRestoreService.restoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );

    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      expect(await cur.getGalgame('G1'), isNotNull);
      final int version =
          (await cur.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          );
      expect(version, cur.schemaVersion);
    } finally {
      await cur.close();
    }
    expect(hasTable(p.join(curDbDir, fushiDatabaseFileName)), isFalse);
  });

  test('合并导入两次：旧备份带 galgame_text_lines 不报错，本机库不长出这张表', () async {
    final String zip = await legacyBackupZip();
    // 目标设备：同一部游戏（bgm:100）装在别处。
    final String curDbDir = p.join(dst.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    final FushiDatabase seedDb = FushiDatabase(curDbDir);
    await addGame(seedDb, 'T1', exePath: r'E:\gal\one.exe');
    await seedDb.close();

    for (int round = 0; round < 2; round++) {
      await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDbDir,
        zipPath: zip,
      );
    }

    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      expect(await cur.getGalgame('T1'), isNotNull);
      expect(
        await cur.getGalgame('G1'),
        isNull,
        reason: '同刮削 id 的 G1 并入本机 T1，照旧按游戏身份重映射',
      );
    } finally {
      await cur.close();
    }
    expect(hasTable(p.join(curDbDir, fushiDatabaseFileName)), isFalse);
  });
}

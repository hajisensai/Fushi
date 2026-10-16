import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'temp_dir_cleanup.dart';

/// 最低 schema 门槛在备份恢复侧的守卫：备份里的库低于
/// [kMinSupportedSchemaVersion] 时，覆盖恢复与合并导入都必须在**任何**破坏性动作
/// （快照、删 -wal/-shm、覆盖主库、建 merge-src、合并）之前抛
/// [UnsupportedLegacySchemaException]，当前库逐字节不变、不留任何恢复中间文件。
///
/// 只靠开库时的 onUpgrade 拒绝不够：覆盖恢复是先把老库写到活库路径上再开库的，
/// 那时活库已经被顶掉了。所以这里断言的是「活库字节不变」，而不只是「抛了异常」。
void main() {
  late Directory tmp;
  late String dbDirectory;
  late String livePath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_restore_legacy_');
    dbDirectory = p.join(tmp.path, 'support');
    Directory(dbDirectory).createSync();
    livePath = p.join(dbDirectory, fushiDatabaseFileName);
    // 当前设备的活库：真实的当前 schema 库 + 一行可辨认的数据。
    final FushiDatabase live = FushiDatabase(dbDirectory);
    await live.setPref('live_sentinel', 'untouched');
    await live.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await live.close();
  });

  tearDown(() => cleanupTempDir(tmp));

  /// 一个 user_version 低于门槛的真实 SQLite 老库。
  Uint8List legacyDbBytes(int userVersion) {
    final String path = p.join(tmp.path, 'legacy_src.db');
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    try {
      raw.execute(
        'CREATE TABLE preferences (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
      );
      raw.execute(
        "INSERT INTO preferences (key, value) VALUES ('backup_sentinel', 'old')",
      );
      raw.execute('PRAGMA user_version = $userVersion');
    } finally {
      raw.close();
    }
    final Uint8List bytes = File(path).readAsBytesSync();
    File(path).deleteSync();
    return bytes;
  }

  /// 打包成备份 zip。[stored]=true 时主库条目不压缩（生产备份的形态，走只读
  /// 文件头的快路径）；false 时 DEFLATE（走解到探针文件再读头的路径）。
  /// 清单故意写成**当前** schema：清单可能与包里的库不一致，服务层必须按库文件
  /// 本身判定，而不是信清单。
  String writeBackupZip(Uint8List dbBytes, {required bool stored}) {
    final List<int> meta = utf8.encode(
      jsonEncode(
        BackupMeta(
          appVersion: '2.0.0',
          schemaVersion: 116,
          createdAt: DateTime(2026, 1, 1),
          bookCount: 0,
          statsCount: 0,
        ).toJson(),
      ),
    );
    final ArchiveFile dbEntry = ArchiveFile(
      fushiDatabaseFileName,
      dbBytes.length,
      dbBytes,
    )..compress = !stored;
    final Archive archive = Archive()
      ..addFile(dbEntry)
      ..addFile(ArchiveFile('backup_meta.json', meta.length, meta));
    final String zipPath = p.join(
      tmp.path,
      stored ? 'legacy_stored.zip' : 'legacy_deflate.zip',
    );
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);
    return zipPath;
  }

  void expectLiveUntouched(Uint8List liveBefore) {
    expect(
      File(livePath).readAsBytesSync(),
      liveBefore,
      reason: '活库必须逐字节不变：门槛判定要先于任何破坏性动作',
    );
    final sqlite.Database raw = sqlite.sqlite3.open(
      livePath,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(
        raw
            .select("SELECT value FROM preferences WHERE key = 'live_sentinel'")
            .first['value'],
        'untouched',
      );
    } finally {
      raw.close();
    }
    final List<String> leftovers = Directory(dbDirectory)
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .where(
          (String n) =>
              n.contains('pre-restore') ||
              n.contains('pre-merge') ||
              n.contains('preserve') ||
              n.contains('merge-src') ||
              n.contains('probe'),
        )
        .toList();
    expect(leftovers, isEmpty, reason: '被拒绝的恢复不得留下快照 / 标记 / 探针文件');
  }

  for (final bool stored in <bool>[true, false]) {
    final String shape = stored ? 'STORE' : 'DEFLATE';

    test('覆盖恢复：老库备份（$shape）被拒绝，活库原样', () async {
      final String zipPath = writeBackupZip(
        legacyDbBytes(kMinSupportedSchemaVersion - 5),
        stored: stored,
      );
      final Uint8List liveBefore = File(livePath).readAsBytesSync();

      await expectLater(
        BackupRestoreService.restoreBackup(
          dbDirectory: dbDirectory,
          zipPath: zipPath,
        ),
        throwsA(
          isA<UnsupportedLegacySchemaException>().having(
            (UnsupportedLegacySchemaException e) => e.dbVersion,
            'dbVersion',
            kMinSupportedSchemaVersion - 5,
          ),
        ),
      );
      expectLiveUntouched(liveBefore);
    });

    test('合并导入：老库备份（$shape）被拒绝，活库原样', () async {
      final String zipPath = writeBackupZip(
        legacyDbBytes(kMinSupportedSchemaVersion - 5),
        stored: stored,
      );
      final Uint8List liveBefore = File(livePath).readAsBytesSync();

      await expectLater(
        BackupRestoreService.mergeRestoreBackup(
          dbDirectory: dbDirectory,
          zipPath: zipPath,
        ),
        throwsA(isA<UnsupportedLegacySchemaException>()),
      );
      expectLiveUntouched(liveBefore);
    });
  }

  test('失败提示是可执行的本地化文案（先装桥接版本），不是原始异常串', () {
    final String message = friendlySyncErrorDetail(
      const UnsupportedLegacySchemaException(dbVersion: 70),
    );
    expect(
      message,
      t.backup_legacy_schema(
        version: kLegacySchemaBridgeAppVersion,
        url: kLegacySchemaBridgeReleaseUrl,
      ),
    );
    expect(message, contains(kLegacySchemaBridgeAppVersion));
    // 迁移指引必须带桥接版本的真实下载地址，并点名旧 Hibiki 数据。
    expect(message, contains(kLegacySchemaBridgeReleaseUrl));
    expect(message, contains('Hibiki'));
  });
}

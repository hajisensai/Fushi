import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// BUG-4509：主库 `fushi.db` 文件头完好、页内容损坏时，开库的
/// `PRAGMA journal_mode=WAL` 报 `SqliteException(11)`「database disk image is
/// malformed」。此前 `_isSidecarOpenError` 不认 `SQLITE_CORRUPT`，`_openWithRecovery`
/// 把裸 [sqlite3.SqliteException] 原样 rethrow，app 层落进通用错误屏，「重试」对着同一个
/// 坏文件无限循环（用户日志：19 次 sandboxRelocation/initialise + 11 次 retryInitialise）。
///
/// 守两件事：
/// 1. 抛的是终态 [FushiDatabaseUnrecoverableException]（kind=corrupt），cause 是那条
///    code 11 的 SqliteException——app 层据此出「恢复备份 / 清空数据」专屏、停掉重试；
/// 2. 不进恢复阶梯：主库字节原样、不生成 `.corrupt-bak` 快照（checkpoint
///    会把坏帧折进主库，删侧车会丢掉手工恢复要用的最后写入）。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_db_corrupt_main_');
    dbPath = p.join(tempDir.path, fushiDatabaseFileName);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上连接可能还短暂持有文件句柄；忽略。
      }
    }
  });

  /// 用真实开库路径建一个健康库（跑完迁移、落一行用户数据），关库让 WAL 检查点回主库。
  Future<void> seedHealthyDb() async {
    final FushiDatabase db = FushiDatabase(tempDir.path);
    await db.setPref('bug4509_marker', 'kept');
    await db.close();
  }

  /// 保留 16 字节 SQLite magic 与 100 字节库头，只把第 1 页 b-tree 页头（偏移 100 起）
  /// 写成垃圾：文件头校验照样通过，SQLite 读第 1 页时报 SQLITE_CORRUPT。
  void corruptPageOneBody() {
    final RandomAccessFile raf = File(dbPath).openSync(mode: FileMode.append);
    try {
      raf.setPositionSync(100);
      raf.writeFromSync(List<int>.filled(200, 0xFF));
    } finally {
      raf.closeSync();
    }
  }

  test('前提：这种损坏在裸开库上确实报 SQLITE_CORRUPT(11)，且文件头仍是合法 SQLite', () async {
    await seedHealthyDb();
    corruptPageOneBody();

    final List<int> head = File(dbPath).openSync().readSync(16);
    expect(String.fromCharCodes(head), 'SQLite format 3\u0000');

    Object? raw;
    final sqlite3.Database db = sqlite3.sqlite3.open(dbPath);
    try {
      db.execute('PRAGMA journal_mode=WAL');
    } catch (e) {
      raw = e;
    } finally {
      db.close();
    }
    expect(raw, isA<sqlite3.SqliteException>());
    expect((raw! as sqlite3.SqliteException).extendedResultCode & 0xFF, 11);
  });

  test('主库页损坏 → FushiDatabaseUnrecoverableException(kind=corrupt)，不是裸 '
      'SqliteException', () async {
    await seedHealthyDb();
    corruptPageOneBody();

    final FushiDatabase db = FushiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    Object? caught;
    try {
      await db.getPref('bug4509_marker');
    } catch (e) {
      caught = e;
    }
    expect(
      caught,
      isA<FushiDatabaseUnrecoverableException>(),
      reason: '主库损坏必须是 app 认得的终态类型，否则通用错误屏的重试会无限循环',
    );
    final FushiDatabaseUnrecoverableException e =
        caught! as FushiDatabaseUnrecoverableException;
    expect(e.kind, FushiDatabaseFailureKind.corrupt);
    expect(e.dbPath, dbPath);
    expect(e.cause, isA<sqlite3.SqliteException>());
    expect((e.cause as sqlite3.SqliteException).extendedResultCode & 0xFF, 11);
  });

  test('主库页损坏时不跑恢复阶梯：主库字节不变、不写 .corrupt-bak', () async {
    await seedHealthyDb();
    corruptPageOneBody();
    final Uint8List before = File(dbPath).readAsBytesSync();

    final FushiDatabase db = FushiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });
    await expectLater(
      db.getPref('bug4509_marker'),
      throwsA(isA<FushiDatabaseUnrecoverableException>()),
    );

    expect(File(dbPath).readAsBytesSync(), before, reason: '主库一个字节都不能动');
    expect(
      tempDir.listSync().whereType<File>().where(
        (File f) => f.path.contains('.corrupt-bak-'),
      ),
      isEmpty,
      reason: '没进侧车重建（Layer 2）就不该有快照',
    );
  });
}

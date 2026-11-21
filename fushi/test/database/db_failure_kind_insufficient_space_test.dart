import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// BUG-5076：磁盘写满时开库报 `SqliteException(11)`「database disk image is
/// malformed」（反馈 AwX7bUtymI：iPad 存储写满、满屏 errno 28，`PRAGMA
/// journal_mode=WAL` 报 code 11），此前直接判成 kind=corrupt，专屏引导用户「恢复备份 /
/// 清空数据」——在数据可能完好的情况下诱导删数据。
///
/// 守的判据（唯一真相源 `classifyFushiDatabaseOpenFailure`）：
/// 1. 卷写满时，不论 sqlite 报的是 CORRUPT 还是侧车类 IOERR / CANTOPEN，都判
///    `insufficientSpace`；
/// 2. 卷写满时不跑恢复阶梯：主库字节不变、`-wal` 不删、不写 `.corrupt-bak` 快照；
/// 3. `SQLITE_FULL`(13) 与带 ENOSPC 的文件系统异常本身就判 `insufficientSpace`；
/// 4. 卷有空间时真损坏仍是 `corrupt`（不把所有失败都推给空间）。
///
/// 测试里无法真把磁盘写满，用 `debugDbVolumeOutOfSpaceForTesting` 模拟卷探测结果；
/// 真实探测在有空间的临时目录上必须返回「没满」（不误报）。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_db_enospc_');
    dbPath = p.join(tempDir.path, fushiDatabaseFileName);
  });

  tearDown(() {
    debugDbVolumeOutOfSpaceForTesting = null;
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上连接可能还短暂持有文件句柄；忽略。
      }
    }
  });

  Future<void> seedHealthyDb() async {
    final FushiDatabase db = FushiDatabase(tempDir.path);
    await db.setPref('bug5076_marker', 'kept');
    await db.close();
  }

  /// 与 BUG-4509 测试同法：保留库头，只把第 1 页 b-tree 页头写坏 → 开库报 CORRUPT(11)。
  void corruptPageOneBody() {
    final RandomAccessFile raf = File(dbPath).openSync(mode: FileMode.append);
    try {
      raf.setPositionSync(100);
      raf.writeFromSync(List<int>.filled(200, 0xFF));
    } finally {
      raf.closeSync();
    }
  }

  void simulateVolumeFull() {
    debugDbVolumeOutOfSpaceForTesting = (String dir) =>
        p.equals(dir, tempDir.path);
  }

  Future<Object?> openAndCapture() async {
    final FushiDatabase db = FushiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });
    try {
      await db.getPref('bug5076_marker');
    } catch (e) {
      return e;
    }
    return null;
  }

  Iterable<File> snapshots() => tempDir.listSync().whereType<File>().where(
    (File f) => f.path.contains('.corrupt-bak-'),
  );

  test('卷写满 + 开库报 malformed(11) → kind=insufficientSpace，主库一个字节不动', () async {
    await seedHealthyDb();
    corruptPageOneBody();
    final Uint8List before = File(dbPath).readAsBytesSync();
    simulateVolumeFull();

    final Object? caught = await openAndCapture();
    expect(caught, isA<FushiDatabaseUnrecoverableException>());
    final FushiDatabaseUnrecoverableException e =
        caught! as FushiDatabaseUnrecoverableException;
    expect(
      e.kind,
      FushiDatabaseFailureKind.insufficientSpace,
      reason: '卷写满时 malformed 不可信，不能判「损坏」把用户引去清数据',
    );
    expect((e.cause as sqlite3.SqliteException).extendedResultCode & 0xFF, 11);
    expect('$e', isNot(contains('corrupt')));
    expect('$e', contains('free up space'));
    expect(File(dbPath).readAsBytesSync(), before);
    expect(snapshots(), isEmpty);
  });

  test('卷有空间时同样的 malformed 仍判 corrupt（不把所有失败推给空间）', () async {
    await seedHealthyDb();
    corruptPageOneBody();
    debugDbVolumeOutOfSpaceForTesting = (String _) => false;

    final Object? caught = await openAndCapture();
    expect(
      caught,
      isA<FushiDatabaseUnrecoverableException>().having(
        (FushiDatabaseUnrecoverableException e) => e.kind,
        'kind',
        FushiDatabaseFailureKind.corrupt,
      ),
    );
  });

  test('卷写满 + 侧车类开库错误 → 终态 insufficientSpace，不进恢复阶梯、不删 -wal', () async {
    await seedHealthyDb();
    // 侧车类错误：`-wal` 路径被目录占住（与 wal_recovery_test 同法），卷有空间时
    // 恢复阶梯会删掉它；卷写满时一样东西都不能删。
    Directory('$dbPath-wal').createSync();
    final Uint8List before = File(dbPath).readAsBytesSync();
    simulateVolumeFull();

    final Object? caught = await openAndCapture();
    expect(
      caught,
      isA<FushiDatabaseUnrecoverableException>().having(
        (FushiDatabaseUnrecoverableException e) => e.kind,
        'kind',
        FushiDatabaseFailureKind.insufficientSpace,
      ),
    );
    expect(
      Directory('$dbPath-wal').existsSync(),
      isTrue,
      reason: '卷写满时删侧车 = 无备份删掉已提交事务的唯一副本',
    );
    expect(File(dbPath).readAsBytesSync(), before);
    expect(snapshots(), isEmpty);
  });

  test('SQLITE_FULL(13) 与 ENOSPC 文件系统异常本身判 insufficientSpace', () async {
    await seedHealthyDb();
    debugDbVolumeOutOfSpaceForTesting = (String _) => false;

    expect(
      classifyFushiDatabaseOpenFailure(
        sqlite3.SqliteException(
          extendedResultCode: 13,
          message: 'database or disk is full',
        ),
        dbPath: dbPath,
      ),
      FushiDatabaseFailureKind.insufficientSpace,
    );
    final int enospc = Platform.isWindows ? 112 : 28;
    expect(
      classifyFushiDatabaseOpenFailure(
        FileSystemException(
          'Cannot copy file',
          dbPath,
          OSError('No space left on device', enospc),
        ),
        dbPath: dbPath,
      ),
      FushiDatabaseFailureKind.insufficientSpace,
    );
    // 非空间类 OS 错误（权限）不归空间。
    expect(
      classifyFushiDatabaseOpenFailure(
        FileSystemException(
          'Cannot copy file',
          dbPath,
          OSError('Permission denied', Platform.isWindows ? 5 : 13),
        ),
        dbPath: dbPath,
      ),
      FushiDatabaseFailureKind.corrupt,
    );
  });

  test('真实卷探测：有空间的目录不误报，探测文件用完即删', () {
    expect(dbVolumeIsOutOfSpace(tempDir.path), isFalse);
    expect(tempDir.listSync(), isEmpty, reason: '探测文件不能残留');
    // 目录不存在不是空间问题（交给 cannotOpen 分类）。
    expect(dbVolumeIsOutOfSpace(p.join(tempDir.path, 'missing')), isFalse);
  });
}

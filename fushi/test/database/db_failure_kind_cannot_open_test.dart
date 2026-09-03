import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1899：「打不开」被说成了「数据库损坏」。
///
/// 用户把数据安装位置选到非默认路径后，启动即弹「Database damaged … It is likely
/// corrupt and must be restored from a backup or cleared」，而磁盘上一个字节都没坏——
/// 只是 `<dataRoot>/support` 这个空目录没被创建，sqlite 报了 SQLITE_CANTOPEN(14)。
/// 该码命中 `_isSidecarOpenError`，随后 `_mainDbHeaderIsValid` 对「文件不存在」和
/// 「文件头不是 SQLite magic」返回**同一个 false**，于是两种成因塌成了一句话，
/// 还把用户往「清空数据」上引。
///
/// 这里守两侧判据：目录压根不存在 → `cannotOpen`；文件在但内容是垃圾 → `corrupt`。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hibiki_db_failure_kind_');
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

  test('父目录不存在 → kind=cannotOpen，且文案不得声称损坏（BUG-1899）', () async {
    // 复刻用户现场：dataRoot 在，但派生的 support 子目录从没被创建过。
    final String missingDir = p.join(tempDir.path, 'support');
    expect(Directory(missingDir).existsSync(), isFalse);

    final FushiDatabase db = FushiDatabase(missingDir);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    await expectLater(
      db.getPref('anything'),
      throwsA(
        isA<FushiDatabaseUnrecoverableException>().having(
          (FushiDatabaseUnrecoverableException e) => e.kind,
          'kind',
          FushiDatabaseFailureKind.cannotOpen,
        ),
      ),
      reason: 'SQLITE_CANTOPEN(14) + 文件不存在 = 路径问题，不是损坏',
    );

    // 文案本身也要说真话：诊断串会原样显示在错误屏上（main.dart 的 SelectableText）。
    Object? captured;
    try {
      await db.getPref('anything');
    } catch (e) {
      captured = e;
    }
    final String text = captured.toString();
    expect(text, contains('does not exist on disk'));
    expect(text, isNot(contains('likely corrupt')),
        reason: '把「目录没建」说成「likely corrupt」会把用户引去清空数据');
  });

  test('文件存在但不是合法 SQLite → kind=corrupt（既有行为不回归）', () async {
    File(p.join(tempDir.path, 'fushi.db')).writeAsBytesSync(
        List<int>.generate(4096, (int i) => (i * 31 + 7) & 0xFF));

    final FushiDatabase db = FushiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    await expectLater(
      db.getPref('anything'),
      throwsA(
        isA<FushiDatabaseUnrecoverableException>().having(
          (FushiDatabaseUnrecoverableException e) => e.kind,
          'kind',
          FushiDatabaseFailureKind.corrupt,
        ),
      ),
      reason: '真损坏仍必须判 corrupt —— 那条路径的「恢复备份/清空」引导是对的',
    );
  });
}

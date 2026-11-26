// 写备份前的空间检查（自动备份第五期）：同卷合计、不知道就放行、探针出错当不知道、余量；还原点存储的
// 操作前 / 更新前还原点在空间不够时不写。可用空间一律注入，不真把盘写满。
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

void main() {
  group('ensureFreeSpace', () {
    test('同一个卷（读数相同）的目标加在一起算，外加余量', () {
      int? probe(String _) => kBackupSpaceMarginBytes + 100;
      ensureFreeSpace(const <SpaceNeed>[
        SpaceNeed('a', 60),
        SpaceNeed('b', 40),
      ], probe: probe);
      expect(
        () => ensureFreeSpace(const <SpaceNeed>[
          SpaceNeed('a', 60),
          SpaceNeed('b', 41),
        ], probe: probe),
        throwsA(
          isA<NotEnoughSpaceException>()
              .having(
                (NotEnoughSpaceException e) => e.code,
                'code',
                kNotEnoughSpaceError,
              )
              .having(
                (NotEnoughSpaceException e) => '$e',
                'toString',
                kNotEnoughSpaceError,
              )
              .having(
                (NotEnoughSpaceException e) => e.neededBytes,
                'needed',
                kBackupSpaceMarginBytes + 101,
              )
              .having((NotEnoughSpaceException e) => e.directory, 'dir', 'a'),
        ),
      );
    });

    test('不同的卷各算各的；不够的那个卷点名', () {
      int? probe(String path) => path == 'big' ? 1 << 40 : 1000;
      ensureFreeSpace(
        const <SpaceNeed>[SpaceNeed('big', 1 << 30), SpaceNeed('small', 500)],
        probe: probe,
        marginBytes: 0,
      );
      expect(
        () => ensureFreeSpace(
          const <SpaceNeed>[
            SpaceNeed('big', 1 << 30),
            SpaceNeed('small', 1001),
          ],
          probe: probe,
          marginBytes: 0,
        ),
        throwsA(
          isA<NotEnoughSpaceException>().having(
            (NotEnoughSpaceException e) => e.directory,
            'dir',
            'small',
          ),
        ),
      );
    });

    test('不知道（null / 负数 / 探针抛错 / 没登记）→ 放行', () {
      const List<SpaceNeed> huge = <SpaceNeed>[SpaceNeed('x', 1 << 50)];
      ensureFreeSpace(huge, probe: (String _) => null);
      ensureFreeSpace(huge, probe: (String _) => -1);
      ensureFreeSpace(huge, probe: (String _) => throw StateError('boom'));
      registerVolumeFreeBytes(null);
      ensureFreeSpace(huge);
    });

    test('登记的探针在没给 probe 时生效', () {
      registerVolumeFreeBytes((String _) => 1);
      addTearDown(() => registerVolumeFreeBytes(null));
      expect(volumeFreeBytes('x'), 1);
      expect(
        () => ensureFreeSpace(const <SpaceNeed>[SpaceNeed('x', 1)]),
        throwsA(isA<NotEnoughSpaceException>()),
      );
    });

    test('treeBytes / fileBytesOrZero：不存在为 0，递归数普通文件', () {
      final Directory tmp = Directory.systemTemp.createTempSync('fushi_space_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'a', 'b.bin'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(300, 1));
      File(p.join(tmp.path, 'c.bin')).writeAsBytesSync(List<int>.filled(7, 1));
      expect(treeBytes(tmp.path), 307);
      expect(treeBytes(p.join(tmp.path, 'missing')), 0);
      expect(fileBytesOrZero(p.join(tmp.path, 'c.bin')), 7);
      expect(fileBytesOrZero(p.join(tmp.path, 'missing')), 0);
    });
  });

  group('还原点存储：空间不够不写', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_space_points_');
      dbPath = p.join(tmp.path, 'fushi.db');
      final sqlite3.Database db = sqlite3.sqlite3.open(dbPath);
      db.execute('CREATE TABLE t (x); INSERT INTO t VALUES (1);');
      db.execute('PRAGMA user_version = 100');
      db.close();
    });

    tearDown(() {
      registerVolumeFreeBytes(null);
      tmp.deleteSync(recursive: true);
    });

    test('操作前还原点：抛 NotEnoughSpaceException，什么都没写；够了照常', () async {
      final RestorePointStore store = RestorePointStore(tmp.path);
      await expectLater(
        store.createPreOperationPoint(
          reason: 'replace',
          fushiDbPath: dbPath,
          freeBytes: (String _) => 1,
        ),
        throwsA(isA<NotEnoughSpaceException>()),
      );
      expect(store.list(), isEmpty);
      final RestorePoint point = await store.createPreOperationPoint(
        reason: 'replace',
        fushiDbPath: dbPath,
        freeBytes: (String _) => 1 << 50,
      );
      expect(point.reason, 'replace');
    });

    test('更新前还原点：不拍，状态记 not_enough_space（迁移照常，不抛）', () async {
      registerVolumeFreeBytes((String _) => 1);
      final RestorePointStore store = RestorePointStore(tmp.path);
      final RestorePoint? point = await store.createPreUpdatePoint(
        dbFilePath: dbPath,
        database: RestorePointDatabase.fushi,
        fromSchema: 100,
        toSchema: 101,
      );
      expect(point, isNull);
      expect(store.list(), isEmpty);
      final RestorePointSnapshotStatus? status = store.readLastStatus(
        RestorePointDatabase.fushi,
      );
      expect(status?.ok, isFalse);
      expect(status?.error, kNotEnoughSpaceError);
      expect(status?.needsNotice, isTrue);
    });
  });
}

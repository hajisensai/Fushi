import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1870：主库快照残留的识别口径 + 删除原语。
///
/// 口径只有一条：文件名以主库名（`fushi.db` / 旧名 `hibiki.db`）开头，但不是主库本体
/// 及其 `-wal` / `-shm` / `-journal` 侧车。活库结构上永远不在集合里——这是删除原语
/// 能安全暴露给存储页的前提。
void main() {
  group('isDatabaseSnapshotFileName', () {
    test('活库本体与侧车（新旧两个名字）都不是快照', () {
      for (final String db in <String>['fushi.db', 'hibiki.db']) {
        expect(isDatabaseSnapshotFileName(db), isFalse, reason: db);
        for (final String sidecar in <String>['-wal', '-shm', '-journal']) {
          expect(
            isDatabaseSnapshotFileName('$db$sidecar'),
            isFalse,
            reason: '$db$sidecar',
          );
        }
      }
    });

    test('现行与历史各种快照/备份命名都命中', () {
      const List<String> snapshots = <String>[
        // _rebuildSidecar 现行产物（主文件 + 两个侧车副本）。
        'fushi.db.corrupt-bak-1780735422',
        'fushi.db.corrupt-bak-1780735422-wal',
        'fushi.db.corrupt-bak-1780735422-shm',
        // backup_service 的覆盖导入前快照。
        'fushi.db.pre-restore.bak',
        // 历史迁移残留（用户机器实测）。
        'hibiki.db.bak.v16.1780592923530',
        'hibiki.db-wal.bak.v20.1780723449590',
        'hibiki.db-shm.bak.v23.1780839460016',
        'hibiki.db.WIPED-before-restore',
        'hibiki.db.before-v20-realtest-wal',
        'hibiki.db.v19-discarded-keep',
      ];
      for (final String name in snapshots) {
        expect(isDatabaseSnapshotFileName(name), isTrue, reason: name);
      }
    });

    test('与主库无关的文件不是快照', () {
      for (final String name in <String>[
        'local_audio_1782831652275.db',
        'youtube_stream_cache.json',
        'shared_preferences.json',
        'window_icon_default.png',
      ]) {
        expect(isDatabaseSnapshotFileName(name), isFalse, reason: name);
      }
    });
  });

  group('listDatabaseSnapshotFiles / deleteDatabaseSnapshotFiles', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_db_snapshots_');
    });
    tearDown(() async {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        /* Windows 句柄延迟释放 */
      }
    });

    File put(String name, [String content = 'x']) =>
        File(p.join(tmp.path, name))..writeAsStringSync(content);

    test('只列直接子层的快照文件：活库/侧车/无关文件/子目录/子目录里的同名都不进', () {
      final File live = put('fushi.db');
      final File wal = put('fushi.db-wal');
      final File shm = put('fushi.db-shm');
      final File other = put('local_audio_1.db');
      final File snap1 = put('fushi.db.corrupt-bak-1');
      final File snap2 = put('hibiki.db.bak.v16.2');
      Directory(p.join(tmp.path, 'fushi.db.corrupt-bak-dir')).createSync();
      Directory(p.join(tmp.path, 'backups')).createSync();
      put(p.join('backups', 'fushi.db.corrupt-bak-nested'));

      final Set<String> listed = listDatabaseSnapshotFiles(
        tmp,
      ).map((File f) => p.basename(f.path)).toSet();
      expect(listed, <String>{p.basename(snap1.path), p.basename(snap2.path)});
      for (final File keep in <File>[live, wal, shm, other]) {
        expect(listed, isNot(contains(p.basename(keep.path))));
      }
    });

    test('删除只动快照，活库与侧车逐字节不变，返回已删路径', () async {
      final File live = put('fushi.db', 'LIVE');
      final File wal = put('fushi.db-wal', 'WAL');
      final File snap1 = put('fushi.db.corrupt-bak-1');
      final File snap2 = put('hibiki.db-wal.bak.v20.3');

      final List<String> deleted = await deleteDatabaseSnapshotFiles(tmp);
      expect(deleted.toSet(), <String>{snap1.path, snap2.path});
      expect(snap1.existsSync(), isFalse);
      expect(snap2.existsSync(), isFalse);
      expect(live.readAsStringSync(), 'LIVE');
      expect(wal.readAsStringSync(), 'WAL');
      // 幂等：再删一次无事发生。
      expect(await deleteDatabaseSnapshotFiles(tmp), isEmpty);
    });

    test('support 根不存在 → 空集，不抛', () async {
      final Directory missing = Directory(p.join(tmp.path, 'nope'));
      expect(listDatabaseSnapshotFiles(missing), isEmpty);
      expect(await deleteDatabaseSnapshotFiles(missing), isEmpty);
    });
  });
}

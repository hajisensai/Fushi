import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1870：主库快照残留的识别口径 + 删除原语。
///
/// 口径是两层，两层都必须有真负例：
/// - 层 (a) 形态白名单：只认代码真产过的整文件副本命名（`corrupt-bak-<stamp>.db*`、
///   旧降级 `bak.v<N>.<stamp>`、`pre-restore.bak` / `pre-merge.bak`）。
///   `backup_service` 放在同一个 support 根、同样以主库名开头的**活控制文件**
///   （`sync-preserve.json` / `merge-preserve.json` / `merge-src*` /
///   `merge-preview-src`）永远不能命中——删掉它们会让 `recoverPendingRestore`
///   静默 return，用户的 LAN 配对/同步基线/settings 层永久丢失。
/// - 层 (b) 所有权门控：sidecar 还在 ⇒ 它拥有的 `pre-*.bak` 是活的恢复输入，
///   不可列出/不可删；sidecar 不在 ⇒ 才是孤儿。
void main() {
  group('isDatabaseSnapshotFileName（层 a 形态白名单）', () {
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
        // _rebuildSidecar 现行产物：`.corrupt-bak-<stamp>` 之后再接**被复制文件
        // 自己的扩展名**（`.db` / `.db-wal` / `.db-shm`），不是裸 `-wal`/`-shm`。
        'fushi.db.corrupt-bak-1780735422.db',
        'fushi.db.corrupt-bak-1780735422.db-wal',
        'fushi.db.corrupt-bak-1780735422.db-shm',
        'hibiki.db.corrupt-bak-1780735422.db',
        // backup_service 的导入前快照（sidecar 不在时是孤儿，见层 b）。
        'fushi.db.pre-restore.bak',
        'fushi.db.pre-merge.bak',
        // 已删除的降级救援分支留下的副本（活库 + 两个侧车各一份）。
        'hibiki.db.bak.v16.1780592923530',
        'hibiki.db-wal.bak.v20.1780723449590',
        'hibiki.db-shm.bak.v23.1780839460016',
        'fushi.db.bak.v82.1780839460016',
      ];
      for (final String name in snapshots) {
        expect(isDatabaseSnapshotFileName(name), isTrue, reason: name);
      }
    });

    test('backup_service 的活控制文件永远不是快照（误删=永久丢数据）', () {
      // 全部以主库名开头，旧黑名单口径（「开头是主库名且不是三种侧车」）会把
      // 它们统统判成可删——这就是 BUG-1870 修复引入的数据丢失面。
      for (final String name in <String>[
        'fushi.db.sync-preserve.json',
        'fushi.db.merge-preserve.json',
        'fushi.db.merge-src',
        'fushi.db.merge-src-wal',
        'fushi.db.merge-src-shm',
        'fushi.db.merge-preview-src',
        'fushi.db.merge-preview-src-wal',
        'hibiki.db.sync-preserve.json',
        'hibiki.db.merge-preserve.json',
        'hibiki.db.merge-src',
      ]) {
        expect(isDatabaseSnapshotFileName(name), isFalse, reason: name);
      }
    });

    test('形似但不在白名单里的名字一律不认（保守：宁可留着也不误删）', () {
      for (final String name in <String>[
        // 戳不是数字 / 缺被复制文件的扩展名 / 侧车后缀写在戳后面。
        'fushi.db.corrupt-bak-abc.db',
        'fushi.db.corrupt-bak-1780735422',
        'fushi.db.corrupt-bak-1780735422-wal',
        // 降级副本的版本号或时间戳不是纯数字。
        'hibiki.db.bak.vX.1',
        'hibiki.db.bak.v16',
        'hibiki.db.bak.v16.abc',
        // 导入前快照只挂主库名，不挂侧车名。
        'fushi.db-wal.pre-restore.bak',
        // 手工/临时改名，没有任何代码产过。
        'hibiki.db.WIPED-before-restore',
        'fushi.db.tmp',
        'fushi.db.bak',
      ]) {
        expect(isDatabaseSnapshotFileName(name), isFalse, reason: name);
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

    test('databaseSnapshotMainFileName 返回实际命中的库名（存储页标题用它）', () {
      expect(databaseSnapshotMainFileName('fushi.db.corrupt-bak-1.db'),
          'fushi.db');
      expect(
          databaseSnapshotMainFileName('hibiki.db-wal.bak.v20.1'), 'hibiki.db');
      expect(databaseSnapshotMainFileName('fushi.db'), isNull);
      expect(
          databaseSnapshotMainFileName('fushi.db.sync-preserve.json'), isNull);
    });
  });

  group('isDeletableDatabaseSnapshot（层 b 所有权门控）', () {
    test('sidecar 在 ⇒ 被它拥有的 pre-*.bak 不可删；sidecar 不在 ⇒ 才可删', () {
      const String preRestore = 'fushi.db.pre-restore.bak';
      const String preMerge = 'fushi.db.pre-merge.bak';
      expect(databaseSnapshotOwnerFileName(preRestore),
          'fushi.db.sync-preserve.json');
      expect(databaseSnapshotOwnerFileName(preMerge),
          'fushi.db.merge-preserve.json');

      expect(
        isDeletableDatabaseSnapshot(preRestore, <String>{
          'fushi.db',
          preRestore,
          'fushi.db.sync-preserve.json',
        }),
        isFalse,
      );
      expect(
        isDeletableDatabaseSnapshot(
            preRestore, <String>{'fushi.db', preRestore}),
        isTrue,
      );
      // merge 侧同理，且两条流程互不干扰（merge sidecar 不管 pre-restore.bak）。
      expect(
        isDeletableDatabaseSnapshot(preMerge, <String>{
          preMerge,
          'fushi.db.merge-preserve.json',
        }),
        isFalse,
      );
      expect(
        isDeletableDatabaseSnapshot(preRestore, <String>{
          preRestore,
          'fushi.db.merge-preserve.json',
        }),
        isTrue,
      );
    });

    test('没有 owner 的快照不受门控影响', () {
      expect(
        isDeletableDatabaseSnapshot('fushi.db.corrupt-bak-1.db', <String>{
          'fushi.db',
          'fushi.db.sync-preserve.json',
          'fushi.db.merge-preserve.json',
        }),
        isTrue,
      );
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

    test('只列直接子层的快照文件：活库/侧车/活控制文件/无关文件/子目录都不进', () {
      final File live = put('fushi.db');
      final File wal = put('fushi.db-wal');
      final File shm = put('fushi.db-shm');
      final File other = put('local_audio_1.db');
      final File mergeSrc = put('fushi.db.merge-src');
      final File mergeSrcWal = put('fushi.db.merge-src-wal');
      final File previewSrc = put('fushi.db.merge-preview-src');
      final File snap1 = put('fushi.db.corrupt-bak-1.db');
      final File snap2 = put('hibiki.db.bak.v16.2');
      Directory(p.join(tmp.path, 'fushi.db.corrupt-bak-3.db')).createSync();
      Directory(p.join(tmp.path, 'backups')).createSync();
      put(p.join('backups', 'fushi.db.corrupt-bak-4.db'));

      final Set<String> listed = listDatabaseSnapshotFiles(
        tmp,
      ).map((File f) => p.basename(f.path)).toSet();
      expect(listed, <String>{p.basename(snap1.path), p.basename(snap2.path)});
      for (final File keep in <File>[
        live,
        wal,
        shm,
        other,
        mergeSrc,
        mergeSrcWal,
        previewSrc,
      ]) {
        expect(listed, isNot(contains(p.basename(keep.path))));
      }
    });

    test('待恢复的 pre-restore.bak：sidecar 在时不列不删，sidecar 走后才清掉', () async {
      final File live = put('fushi.db', 'LIVE');
      final File sidecar =
          put('fushi.db.sync-preserve.json', '{"mode":"prefs"}');
      final File bak = put('fushi.db.pre-restore.bak', 'BAK');

      // sidecar 还在 = 下次启动要靠这两个文件补完 device-local 表 replay。
      expect(listDatabaseSnapshotFiles(tmp), isEmpty);
      final DatabaseSnapshotDeletionResult guarded =
          await deleteDatabaseSnapshotFiles(tmp);
      expect(guarded.deleted, isEmpty);
      expect(guarded.hasFailures, isFalse);
      expect(bak.readAsStringSync(), 'BAK');
      expect(sidecar.existsSync(), isTrue);

      // 恢复完成（sidecar 被 recoverPendingRestore 删掉）后它才是孤儿。
      sidecar.deleteSync();
      final DatabaseSnapshotDeletionResult swept =
          await deleteDatabaseSnapshotFiles(tmp);
      expect(swept.deleted, <String>[bak.path]);
      expect(bak.existsSync(), isFalse);
      expect(live.readAsStringSync(), 'LIVE');
    });

    test('删除只动快照，活库与侧车逐字节不变，返回已删路径', () async {
      final File live = put('fushi.db', 'LIVE');
      final File wal = put('fushi.db-wal', 'WAL');
      final File snap1 = put('fushi.db.corrupt-bak-1.db');
      final File snap2 = put('hibiki.db-wal.bak.v20.3');

      final DatabaseSnapshotDeletionResult result =
          await deleteDatabaseSnapshotFiles(tmp);
      expect(result.deleted.toSet(), <String>{snap1.path, snap2.path});
      expect(result.hasFailures, isFalse);
      expect(snap1.existsSync(), isFalse);
      expect(snap2.existsSync(), isFalse);
      expect(live.readAsStringSync(), 'LIVE');
      expect(wal.readAsStringSync(), 'WAL');
      // 幂等：再删一次无事发生。
      expect((await deleteDatabaseSnapshotFiles(tmp)).deleted, isEmpty);
    });

    test(
      '单个文件被占用不中止整批：其余照删，失败原样回报',
      () async {
        final File snap1 = put('fushi.db.corrupt-bak-1.db');
        final File locked = put('fushi.db.corrupt-bak-2.db');
        final File snap3 = put('fushi.db.corrupt-bak-3.db');
        // Windows 上 Defender / 索引器占住某个副本是常态：持一个写句柄就能
        // 复现「这一个删不掉」。POSIX 允许 unlink 已打开的文件，制造不出同样
        // 的失败，故只在 Windows 上跑（真实故障面也只在 Windows）。
        final RandomAccessFile handle = locked.openSync(mode: FileMode.append);
        final DatabaseSnapshotDeletionResult result;
        try {
          result = await deleteDatabaseSnapshotFiles(tmp);
        } finally {
          handle.closeSync();
        }

        // 关键不变式：一个失败没有把后面的文件也拖下水。
        expect(result.deleted.toSet(), <String>{snap1.path, snap3.path});
        expect(snap1.existsSync(), isFalse);
        expect(snap3.existsSync(), isFalse);
        expect(result.hasFailures, isTrue);
        expect(result.failures.keys, <String>[locked.path]);
        expect(result.failures[locked.path], isNotEmpty);
        expect(locked.existsSync(), isTrue);
      },
      skip: Platform.isWindows ? false : '只有 Windows 能用文件锁复现「删不掉」',
    );

    test('support 根不存在 → 空集，不抛', () async {
      final Directory missing = Directory(p.join(tmp.path, 'nope'));
      expect(listDatabaseSnapshotFiles(missing), isEmpty);
      final DatabaseSnapshotDeletionResult result =
          await deleteDatabaseSnapshotFiles(missing);
      expect(result.deleted, isEmpty);
      expect(result.hasFailures, isFalse);
    });
  });
}

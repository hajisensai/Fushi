import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 第三期审查：定时还原点按写入设备修剪（共用文件夹 / 取回本机的副本不被本机的保留规则删），
/// 外来 id 的校验。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_restore_points_dev_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  RestorePoint scheduledAt(
    RestorePointStore store,
    DateTime at, {
    String? deviceId,
    int bytes = 1,
  }) {
    final RestorePointDraft draft = store.begin(
      kind: RestorePointKind.scheduled,
      nowMs: at.millisecondsSinceEpoch,
      ownerDeviceId: deviceId,
    );
    File(
      p.join(draft.directory, kRestorePointArchiveFileName),
    ).writeAsBytesSync(List<int>.filled(bytes, 1));
    return store.commit(
      draft,
      fromSchema: kFushiDbSchemaVersion,
      toSchema: kFushiDbSchemaVersion,
      deviceId: deviceId,
      deviceName: deviceId == null ? null : 'Device $deviceId',
    );
  }

  /// 把 [point] 的元数据改成取回本机的样子（带 copiedBackAtMs）。
  void markCopiedBack(RestorePoint point) {
    final File meta = File(p.join(point.directory, kRestorePointMetaFileName));
    final Map<String, Object?> json =
        jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
    json['copiedBackAtMs'] = 1;
    meta.writeAsStringSync(jsonEncode(json));
  }

  test('设备标记与「谁在写」标记：写进元数据，标记文件不算还原点文件', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePoint point = scheduledAt(
      store,
      DateTime.utc(2026),
      deviceId: 'me',
    );
    expect(point.deviceId, 'me');
    expect(point.deviceName, 'Device me');
    expect(point.files.map((RestorePointFile f) => f.name), <String>[
      kRestorePointArchiveFileName,
    ]);
    final RestorePoint read = store.list().single;
    expect(read.deviceId, 'me');
    expect(read.copiedBackAtMs, isNull);
  });

  test('共用存储：别的设备的点不占桶、不被删；取回的点从不自动删', () {
    final RestorePointStore store = RestorePointStore(
      tmp.path,
      rootDirectory: p.join(tmp.path, 'shared'),
    );
    final DateTime now = DateTime.utc(2026, 6, 10, 12);
    // 同一天（10 天前）：本机一份、别的设备一份（更新）。别人的那份若占了这一天的桶，本机的会被删。
    final RestorePoint mine = scheduledAt(
      store,
      now.subtract(const Duration(days: 10, hours: 2)),
      deviceId: 'me',
    );
    final RestorePoint theirs = scheduledAt(
      store,
      now.subtract(const Duration(days: 10, hours: 1)),
      deviceId: 'other',
    );
    // 一份很旧的本机点，取回过（不自动删），一份很旧的本机点（该删）。
    final RestorePoint copiedBack = scheduledAt(
      store,
      now.subtract(const Duration(days: 300)),
      deviceId: 'me',
    );
    markCopiedBack(copiedBack);
    final RestorePoint oldMine = scheduledAt(
      store,
      now.subtract(const Duration(days: 301)),
      deviceId: 'me',
    );
    final RestorePoint newest = scheduledAt(store, now, deviceId: 'me');
    final List<String> gone = store
        .pruneScheduled(
          deviceId: 'me',
          sharedRoot: true,
          now: now,
          protectId: newest.id,
        )
        .map((RestorePoint e) => e.id)
        .toList();
    expect(gone, <String>[oldMine.id]);
    final Set<String> left = store.list().map((RestorePoint e) => e.id).toSet();
    expect(left, containsAll(<String>[mine.id, theirs.id, copiedBack.id]));
  });

  test('共用存储：大小上限只算本机的点，别人的大点不把本机的挤掉', () {
    final RestorePointStore store = RestorePointStore(
      tmp.path,
      rootDirectory: p.join(tmp.path, 'shared'),
    );
    final DateTime now = DateTime.utc(2026, 6, 10, 12);
    final RestorePoint mineOld = scheduledAt(
      store,
      now.subtract(const Duration(hours: 5)),
      deviceId: 'me',
      bytes: 40,
    );
    scheduledAt(
      store,
      now.subtract(const Duration(hours: 4)),
      deviceId: 'other',
      bytes: 100,
    );
    final RestorePoint mineNew = scheduledAt(
      store,
      now,
      deviceId: 'me',
      bytes: 40,
    );
    const BackupRetentionPolicy capped = BackupRetentionPolicy(
      keepMinimum: 1,
      keepAllWithin: Duration(hours: 48),
      dailyDays: 7,
      weeklyWeeks: 4,
      monthlyMonths: 3,
      maxTotalBytes: 100,
    );
    expect(
      store.pruneScheduled(
        deviceId: 'me',
        sharedRoot: true,
        now: now,
        protectId: mineNew.id,
        policy: capped,
      ),
      isEmpty,
    );
    expect(store.list().map((RestorePoint e) => e.id), contains(mineOld.id));
  });

  test('私有存储：没有设备标记的老点算本机的；共用存储：算别人的', () {
    final DateTime now = DateTime.utc(2026, 6, 10, 12);
    for (final bool shared in <bool>[false, true]) {
      final String root = p.join(tmp.path, shared ? 'shared' : 'private');
      final RestorePointStore store = RestorePointStore(
        tmp.path,
        rootDirectory: root,
      );
      final RestorePoint legacy = scheduledAt(
        store,
        now.subtract(const Duration(days: 300)),
      );
      final RestorePoint newest = scheduledAt(store, now, deviceId: 'me');
      final List<String> gone = store
          .pruneScheduled(
            deviceId: 'me',
            sharedRoot: shared,
            now: now,
            protectId: newest.id,
          )
          .map((RestorePoint e) => e.id)
          .toList();
      expect(gone, shared ? isEmpty : <String>[legacy.id], reason: '$shared');
    }
  });

  test('私有存储不看设备标记：同步设备 id 换过，旧 id 写的点照样修剪；取回的点不删', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    final DateTime now = DateTime.utc(2026, 6, 10, 12);
    final RestorePoint oldId = scheduledAt(
      store,
      now.subtract(const Duration(days: 300)),
      deviceId: 'before-reinstall',
    );
    final RestorePoint copiedBack = scheduledAt(
      store,
      now.subtract(const Duration(days: 301)),
      deviceId: 'other',
    );
    markCopiedBack(copiedBack);
    final RestorePoint newest = scheduledAt(store, now, deviceId: 'me');
    final List<String> gone = store
        .pruneScheduled(deviceId: 'me', now: now, protectId: newest.id)
        .map((RestorePoint e) => e.id)
        .toList();
    expect(gone, <String>[oldId.id]);
    expect(
      store.list().map((RestorePoint e) => e.id),
      containsAll(<String>[copiedBack.id, newest.id]),
    );
    // 查不出本机 id 也照样修剪私有存储。
    final RestorePoint ancient = scheduledAt(
      store,
      now.subtract(const Duration(days: 400)),
      deviceId: 'me',
    );
    expect(
      store
          .pruneScheduled(deviceId: null, now: now, protectId: newest.id)
          .map((RestorePoint e) => e.id),
      <String>[ancient.id],
    );
  });

  test('共用存储、查不出本机 id：一个点、一个半截目录都不删', () {
    final String root = p.join(tmp.path, 'shared');
    final RestorePointStore store = RestorePointStore(
      tmp.path,
      rootDirectory: root,
    );
    final DateTime now = DateTime.utc(2026, 6, 10, 12);
    final RestorePoint unmarkedOld = scheduledAt(
      store,
      now.subtract(const Duration(days: 300)),
    );
    final Directory unmarkedHalf = Directory(
      p.join(root, '20260101-000000-000-fushi-scheduled'),
    )..createSync(recursive: true);
    File(
      p.join(unmarkedHalf.path, kRestorePointArchiveFileName),
    ).writeAsStringSync('x');
    expect(store.cleanIncompleteScheduled(sharedRoot: true), 0);
    expect(
      store.pruneScheduled(deviceId: null, sharedRoot: true, now: now),
      isEmpty,
    );
    expect(unmarkedHalf.existsSync(), isTrue);
    expect(
      store.list().map((RestorePoint e) => e.id),
      contains(unmarkedOld.id),
    );
  });

  test('共用存储：只清本机标记的半截目录，别人的 / 没标记的不碰', () {
    final String root = p.join(tmp.path, 'shared');
    final RestorePointStore store = RestorePointStore(
      tmp.path,
      rootDirectory: root,
    );
    Directory half(String id, String? owner) {
      final Directory d = Directory(p.join(root, id))
        ..createSync(recursive: true);
      File(p.join(d.path, kRestorePointArchiveFileName)).writeAsStringSync('x');
      if (owner != null) {
        File(
          p.join(d.path, kRestorePointOwnerFileName),
        ).writeAsStringSync(owner);
      }
      return d;
    }

    final Directory mine = half('20260101-000000-000-fushi-scheduled', 'me');
    final Directory theirs = half('20260102-000000-000-fushi-scheduled', 'x');
    final Directory unmarked = half(
      '20260103-000000-000-fushi-scheduled',
      null,
    );
    expect(store.cleanIncompleteScheduled(deviceId: 'me', sharedRoot: true), 1);
    expect(mine.existsSync(), isFalse);
    expect(theirs.existsSync(), isTrue);
    expect(unmarked.existsSync(), isTrue);
    // 私有存储照旧全清。
    expect(store.cleanIncompleteScheduled(deviceId: 'me'), 2);
  });

  test('外来 id 校验：只认定时还原点的形状', () {
    expect(
      isScheduledRestorePointId('20261125-142530-123-fushi-scheduled'),
      isTrue,
    );
    expect(
      isScheduledRestorePointId('20261125-142530-123-fushi-scheduled-2'),
      isTrue,
    );
    for (final String bad in <String>[
      '',
      '.',
      '..',
      '../x',
      '/abs',
      r'C:\x',
      '20261125-142530-123-fushi-pre_update',
      '20261125-142530-123-fushi-scheduled/..',
      'x20261125-142530-123-fushi-scheduled',
      '20261125-142530-123-fushi-scheduled\x00',
    ]) {
      expect(isScheduledRestorePointId(bad), isFalse, reason: bad);
    }
    // NTFS 备用数据流（`名字:流`）。
    for (final String bad in <String>[
      '20261125-142530-123-fushi-scheduled:ads',
      'backup.zip:stream',
    ]) {
      expect(isPlainRestorePointFileName(bad), isFalse, reason: bad);
      expect(isScheduledRestorePointId(bad), isFalse, reason: bad);
    }
  });
}

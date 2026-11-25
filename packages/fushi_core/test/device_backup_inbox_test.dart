import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 第四期 A：互联 host 收到的设备备份（`fushi-data/__backups__/<设备键>/<id>/`）的列表、取包与删除，
/// 以及来自网络的名字在动盘之前的校验。
void main() {
  late Directory tmp;
  late String syncRoot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_device_inbox_');
    syncRoot = p.join(tmp.path, 'fushi-data');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 照设备上传的样子写一份副本：先 zip，后元数据（[meta] 为 false = 半截）。
  Directory putCopy(
    String device,
    String id, {
    required int createdAtMs,
    String? name,
    bool meta = true,
    int bytes = 10,
  }) {
    final Directory dir = Directory(
      p.join(syncRoot, kDeviceBackupsNamespace, device, id),
    )..createSync(recursive: true);
    File(
      p.join(dir.path, kRestorePointArchiveFileName),
    ).writeAsBytesSync(List<int>.filled(bytes, 7));
    if (meta) {
      final RestorePoint point = RestorePoint(
        id: id,
        directory: dir.path,
        kind: RestorePointKind.scheduled,
        database: RestorePointDatabase.fushi,
        createdAtMs: createdAtMs,
        fromSchema: 180,
        toSchema: 180,
        files: <RestorePointFile>[
          RestorePointFile(name: kRestorePointArchiveFileName, size: bytes),
        ],
        fullDatabase: true,
        deviceId: device,
        deviceName: name,
      );
      File(
        p.join(dir.path, kRestorePointMetaFileName),
      ).writeAsStringSync(jsonEncode(point.toJson()));
    }
    return dir;
  }

  const String phone = '0123456789abcdef';
  const String tablet = 'fedcba9876543210';
  const String id1 = '20261120-030000-000-fushi-scheduled';
  const String id2 = '20261124-030000-000-fushi-scheduled';
  const String id3 = '20261123-030000-000-fushi-scheduled';

  test('lists copies grouped by device, newest device first', () {
    putCopy(phone, id1, createdAtMs: 1000, name: 'Pixel', bytes: 5);
    putCopy(phone, id2, createdAtMs: 3000, name: 'Pixel 9', bytes: 7);
    putCopy(tablet, id3, createdAtMs: 2000, name: 'iPad');
    // 半截副本（没有元数据）：不列，但记数、算进占用。
    putCopy(
      tablet,
      '20261125-030000-000-fushi-scheduled',
      createdAtMs: 4000,
      meta: false,
      bytes: 3,
    );
    // 名字不合格的目录 / 文件：不列。
    Directory(
      p.join(syncRoot, kDeviceBackupsNamespace, 'NotHex', id1),
    ).createSync(recursive: true);
    Directory(
      p.join(syncRoot, kDeviceBackupsNamespace, phone, 'junk'),
    ).createSync(recursive: true);
    File(
      p.join(syncRoot, kDeviceBackupsNamespace, 'readme.txt'),
    ).writeAsStringSync('x');

    final List<ReceivedDeviceBackupGroup> groups = DeviceBackupInbox(
      syncRoot,
    ).list();
    expect(groups.map((ReceivedDeviceBackupGroup g) => g.deviceKey), <String>[
      phone,
      tablet,
    ]);
    final ReceivedDeviceBackupGroup a = groups.first;
    expect(a.deviceName, 'Pixel 9', reason: 'name from the newest copy');
    expect(a.copies.map((ReceivedDeviceBackup c) => c.id), <String>[id2, id1]);
    expect(a.newestAtMs, 3000);
    expect(a.incomplete, 0);
    final ReceivedDeviceBackupGroup b = groups.last;
    expect(b.copies.single.id, id3);
    expect(b.incomplete, 1);
    expect(b.totalBytes, greaterThan(b.copies.single.bytes));
    final Map<String, Object?> json = a.toJson();
    expect(json['count'], 2);
    expect(json['name'], 'Pixel 9');
    expect((json['copies']! as List<Object?>).length, 2);
  });

  test('missing inbox lists nothing', () {
    expect(DeviceBackupInbox(syncRoot).list(), isEmpty);
  });

  test('a copy whose meta names a missing file is not complete', () {
    final Directory dir = putCopy(phone, id1, createdAtMs: 1000);
    File(p.join(dir.path, kRestorePointArchiveFileName)).deleteSync();
    final DeviceBackupInbox inbox = DeviceBackupInbox(syncRoot);
    expect(inbox.find(phone, id1), isNull);
    expect(inbox.archiveOf(phone, id1), isNull);
    expect(inbox.list().single.incomplete, 1);
  });

  test('archiveOf returns the zip of a complete copy', () {
    putCopy(phone, id1, createdAtMs: 1000, bytes: 12);
    final File? zip = DeviceBackupInbox(syncRoot).archiveOf(phone, id1);
    expect(zip, isNotNull);
    expect(zip!.lengthSync(), 12);
    expect(DeviceBackupInbox(syncRoot).archiveOf(phone, id2), isNull);
  });

  test('deletes one copy, then a whole device', () async {
    putCopy(phone, id1, createdAtMs: 1000);
    putCopy(phone, id2, createdAtMs: 2000);
    putCopy(tablet, id3, createdAtMs: 3000);
    final DeviceBackupInbox inbox = DeviceBackupInbox(syncRoot);
    expect(await inbox.deleteCopy(phone, id1), isTrue);
    expect(await inbox.deleteCopy(phone, id1), isFalse);
    expect(
      inbox
          .list()
          .firstWhere((ReceivedDeviceBackupGroup g) => g.deviceKey == phone)
          .copies
          .single
          .id,
      id2,
    );
    expect(await inbox.deleteDevice(phone), isTrue);
    expect(await inbox.deleteDevice(phone), isFalse);
    expect(inbox.list().single.deviceKey, tablet);
  });

  test('rejects names that are not a device key / restore point id', () async {
    final DeviceBackupInbox inbox = DeviceBackupInbox(syncRoot);
    // 根外放一个会被误删的目录。
    final Directory victim = Directory(p.join(tmp.path, 'victim'))
      ..createSync();
    for (final String bad in <String>[
      '..',
      '../victim',
      'ABCDEF',
      '',
      'a/b',
      r'a\b',
      '0123:x',
    ]) {
      expect(() => inbox.deleteDevice(bad), throwsArgumentError, reason: bad);
      expect(() => inbox.find(bad, id1), throwsArgumentError, reason: bad);
    }
    for (final String bad in <String>[
      '..',
      '../../victim',
      'backup.zip',
      '20261120-030000-000-fushi-scheduled/..',
      '20261120-030000-000-pre_update',
    ]) {
      expect(
        () => inbox.deleteCopy(phone, bad),
        throwsArgumentError,
        reason: bad,
      );
      expect(
        () => inbox.archiveOf(phone, bad),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(victim.existsSync(), isTrue);
    expect(isDeviceBackupKey(phone), isTrue);
    expect(isDeviceBackupKey('0' * 65), isFalse);
  });

  test('does not follow a link planted in the inbox', () async {
    final Directory outside = Directory(p.join(tmp.path, 'outside', id1))
      ..createSync(recursive: true);
    File(p.join(outside.path, 'keep.txt')).writeAsStringSync('keep');
    final Directory device = Directory(
      p.join(syncRoot, kDeviceBackupsNamespace, phone),
    )..createSync(recursive: true);
    try {
      Link(p.join(device.path, id1)).createSync(outside.path);
    } on FileSystemException {
      markTestSkipped('cannot create links here');
      return;
    }
    final DeviceBackupInbox inbox = DeviceBackupInbox(syncRoot);
    expect(inbox.list(), isEmpty);
    expect(await inbox.deleteCopy(phone, id1), isFalse);
    expect(File(p.join(outside.path, 'keep.txt')).existsSync(), isTrue);
  });
}

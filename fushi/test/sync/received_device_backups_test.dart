import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/sync/auto_backup/received_device_backups.dart';

/// 第五期：app 当互联 host 时收到的别的设备的备份——收件箱位置、排除本机设备键、取 zip、删一份 /
/// 删整台设备。
void main() {
  late Directory tmp;
  late String dbDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_received_backups_');
    dbDir = tmp.path;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const String own = '00000000000000aa';
  const String phone = '0123456789abcdef';
  const String tablet = 'fedcba9876543210';
  const String id1 = '20261120-030000-000-fushi-scheduled';
  const String id2 = '20261124-030000-000-fushi-scheduled';

  /// 照设备经 WebDAV 上传的样子在 app 的同步根下写一份副本。
  Directory putCopy(
    String device,
    String id, {
    required int createdAtMs,
    String? name,
    String body = 'zip-bytes',
  }) {
    final Directory dir = Directory(
      p.join(
        dbDir,
        'sync-data',
        'fushi-data',
        kDeviceBackupsNamespace,
        device,
        id,
      ),
    )..createSync(recursive: true);
    File(
      p.join(dir.path, kRestorePointArchiveFileName),
    ).writeAsStringSync(body);
    final RestorePoint point = RestorePoint(
      id: id,
      directory: dir.path,
      kind: RestorePointKind.scheduled,
      database: RestorePointDatabase.fushi,
      createdAtMs: createdAtMs,
      fromSchema: 180,
      toSchema: 180,
      files: <RestorePointFile>[
        RestorePointFile(
          name: kRestorePointArchiveFileName,
          size: utf8.encode(body).length,
        ),
      ],
      fullDatabase: true,
      deviceId: device,
      deviceName: name,
    );
    File(
      p.join(dir.path, kRestorePointMetaFileName),
    ).writeAsStringSync(jsonEncode(point.toJson()));
    return dir;
  }

  ReceivedDeviceBackups service() =>
      ReceivedDeviceBackups.forApp(databaseDirectory: dbDir, ownDeviceKey: own);

  test('收件箱在 <数据根>/sync-data/fushi-data/__backups__（与 host 开没开无关）', () {
    expect(
      appInterconnectSyncRoot(dbDir),
      p.join(dbDir, 'sync-data', 'fushi-data'),
    );
    expect(
      service().inbox.root,
      p.normalize(
        p.absolute(
          p.join(dbDir, 'sync-data', 'fushi-data', kDeviceBackupsNamespace),
        ),
      ),
    );
  });

  test('按设备分组列出，本机自己的设备键不列', () async {
    putCopy(phone, id1, createdAtMs: 1000, name: 'Pixel');
    putCopy(phone, id2, createdAtMs: 3000, name: 'Pixel');
    putCopy(tablet, id1, createdAtMs: 2000);
    putCopy(own, id2, createdAtMs: 9000, name: 'This PC');

    final List<ReceivedDeviceBackupGroup> groups = await service().list();
    expect(groups.map((ReceivedDeviceBackupGroup g) => g.deviceKey), <String>[
      phone,
      tablet,
    ]);
    expect(groups.first.deviceName, 'Pixel');
    expect(groups.first.copies.map((ReceivedDeviceBackup c) => c.id), <String>[
      id2,
      id1,
    ]);
    expect(groups.last.deviceName, isNull);
  });

  test('没有收件箱：空列表', () async {
    expect(await service().list(), isEmpty);
  });

  test('取 zip：就是设备上传的那个备份包；本机的键不给', () {
    putCopy(phone, id1, createdAtMs: 1000, body: 'phone-backup');
    putCopy(own, id1, createdAtMs: 1000);
    final ReceivedDeviceBackups s = service();
    final File? zip = s.archiveOf(phone, id1);
    expect(zip, isNotNull);
    expect(zip!.readAsStringSync(), 'phone-backup');
    expect(s.archiveOf(phone, id2), isNull);
    expect(() => s.archiveOf(own, id1), throwsArgumentError);
    final ReceivedDeviceBackup copy = s.inbox.find(phone, id1)!;
    expect(
      receivedDeviceBackupExportFileName(copy),
      'fushi-backup-$phone-$id1.zip',
    );
  });

  test('删一份只动那一份；删设备删那台的全部；本机的键拒绝', () async {
    putCopy(phone, id1, createdAtMs: 1000);
    putCopy(phone, id2, createdAtMs: 3000);
    putCopy(tablet, id1, createdAtMs: 2000);
    putCopy(own, id1, createdAtMs: 2000);
    final ReceivedDeviceBackups s = service();

    expect(await s.deleteCopy(phone, id1), isTrue);
    expect(await s.deleteCopy(phone, id1), isFalse);
    List<ReceivedDeviceBackupGroup> groups = await s.list();
    expect(
      groups
          .firstWhere((ReceivedDeviceBackupGroup g) => g.deviceKey == phone)
          .copies
          .single
          .id,
      id2,
    );

    expect(await s.deleteDevice(tablet), isTrue);
    expect(await s.deleteDevice(tablet), isFalse);
    groups = await s.list();
    expect(groups.map((ReceivedDeviceBackupGroup g) => g.deviceKey), <String>[
      phone,
    ]);

    expect(() => s.deleteDevice(own), throwsArgumentError);
    expect(() => s.deleteCopy(own, id1), throwsArgumentError);
    await expectLater(s.deleteDevice('../x'), throwsArgumentError);
    expect(s.inbox.find(own, id1), isNotNull);
  });
}

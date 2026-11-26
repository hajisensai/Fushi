/// app 当互联 host 时收到的别的设备的备份（自动备份第五期，docs/specs/2026-11-25-auto-backup-restore-points.md）。
///
/// 手机开着「复制到服务器」时，经通用 WebDAV 把定时还原点写进 host 的同步根
/// `fushi-data/__backups__/<设备键>/<id>/`。app 当 host 时 WebDAV 根是 `<数据根>/sync-data`
/// （`FushiSyncServer.syncDataDir`），所以收件箱的位置是确定的，与 host 此刻开没开无关：关了 host
/// 留下的副本照样能列出、导出、清理。
///
/// 读盘 / 删盘与校验全在 fushi_core 的 [DeviceBackupInbox]（与无头服务端共用），这里只补 app 侧的两件
/// 事：排除本机自己的设备键，以及把目录遍历挪到后台 isolate。不 import AppModel（import 大环守卫），
/// 本机设备键由调用方给。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart'
    show DeviceBackupInbox, ReceivedDeviceBackup, ReceivedDeviceBackupGroup;
import 'package:fushi_engine/sync/sync_root_folder.dart'
    show kSyncRootFolderName;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/storage_usage_service.dart'
    show kInterconnectSyncDataSupportChild;

/// app 当 host 时客户端同步根（`<数据根>/sync-data/fushi-data`）的位置；[databaseDirectory] 是
/// `AppModel.databaseDirectory`。
String appInterconnectSyncRoot(String databaseDirectory) => p.join(
  databaseDirectory,
  kInterconnectSyncDataSupportChild,
  kSyncRootFolderName,
);

/// 导出收到的一份备份时的文件名：`fushi-backup-<设备键>-<id>.zip`（带设备键，免得几台设备同一时刻的
/// 备份撞名）。
String receivedDeviceBackupExportFileName(ReceivedDeviceBackup copy) =>
    'fushi-backup-${copy.deviceKey}-${copy.id}.zip';

/// [syncRootDirectory] 下收件箱里除 [ownDeviceKey] 以外的设备分组（同步，给后台 isolate 跑）。
List<ReceivedDeviceBackupGroup> listReceivedDeviceBackupsSync(
  String syncRootDirectory,
  String ownDeviceKey,
) => <ReceivedDeviceBackupGroup>[
  for (final ReceivedDeviceBackupGroup g in DeviceBackupInbox(
    syncRootDirectory,
  ).list())
    if (g.deviceKey != ownDeviceKey) g,
];

/// 收到的别的设备的备份：列出（排除本机）、取 zip、导出、删一份 / 删一台设备。
class ReceivedDeviceBackups {
  ReceivedDeviceBackups({
    required this.syncRootDirectory,
    required this.ownDeviceKey,
  }) : inbox = DeviceBackupInbox(syncRootDirectory);

  /// app 的收件箱：`<databaseDirectory>/sync-data/fushi-data/__backups__`。
  factory ReceivedDeviceBackups.forApp({
    required String databaseDirectory,
    required String ownDeviceKey,
  }) => ReceivedDeviceBackups(
    syncRootDirectory: appInterconnectSyncRoot(databaseDirectory),
    ownDeviceKey: ownDeviceKey,
  );

  /// WebDAV 根下的 `fushi-data/`。
  final String syncRootDirectory;

  /// 本机自己的设备键（`backupDeviceKey`）：不列、不删。
  final String ownDeviceKey;

  final DeviceBackupInbox inbox;

  /// 按设备分组（最新副本新的设备在前），本机自己的键不在里面。目录遍历在后台 isolate 里跑。
  Future<List<ReceivedDeviceBackupGroup>> list() {
    final String root = syncRootDirectory;
    final String own = ownDeviceKey;
    return Isolate.run(() => listReceivedDeviceBackupsSync(root, own));
  }

  void _checkNotOwn(String deviceKey) {
    if (deviceKey == ownDeviceKey) {
      throw ArgumentError.value(deviceKey, 'device', 'this device');
    }
  }

  /// 那一份的 zip（导出就是把它交给另存为 / 分享面板）；本机的键 / 不合格的键或 id 抛
  /// [ArgumentError]，不存在或不完整返回 null。
  File? archiveOf(String deviceKey, String id) {
    _checkNotOwn(deviceKey);
    return inbox.archiveOf(deviceKey, id);
  }

  /// 删一份（含没写完的）；不存在返回 false。
  Future<bool> deleteCopy(String deviceKey, String id) {
    _checkNotOwn(deviceKey);
    return inbox.deleteCopy(deviceKey, id);
  }

  /// 删一台设备的全部；不存在返回 false。
  Future<bool> deleteDevice(String deviceKey) {
    _checkNotOwn(deviceKey);
    return inbox.deleteDevice(deviceKey);
  }
}

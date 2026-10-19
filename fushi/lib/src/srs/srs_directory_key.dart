/// 复习（SRS）同步目录的稳定身份（`SrsSyncEngine.directoryKey`）。
///
/// 一台设备可以同时用几个同步目录（云盘、所连的互联 host、本机作为 host 时自己的目录），
/// SRS 按目录记「传到了哪、起步过没有、里面有哪些写入者」。身份要满足：同一个物理目录每次给
/// 同一个值（否则每次都当新目录加入、重传）；不同物理目录给不同值（否则会把一个目录的进度
/// 套到另一个上，误判「本写入者被清理了」而换化身）。
///
/// - 互联：所连 host 的 hostId（同一台 host 的局域网 / 公网 / P2P 地址共用）；本机 host 自己的
///   目录用本机设备 id——与连进来的客户端看到的 hostId 是同一个值、同一块目录。
/// - 云盘：后端类型 + 账户 / 服务器。开了「防扫盘混淆」时目录里的名字不同，单独算一个目录。
/// - 认不出的后端（测试替身等）退到运行时类型名。
library;

import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';
import 'package:fushi/src/sync/google_drive_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';

/// 互联目录的身份（客户端连 host、host 读自己的目录，同一块目录给同一个值）。
String srsInterconnectDirectoryKey(String hostId) => 'interconnect:$hostId';

/// [store] 所指同步目录的身份。
Future<String> srsDirectoryKeyOf(
  SyncAssetStore store,
  SyncRepository repo,
) async {
  SyncAssetStore inner = store;
  bool obfuscated = false;
  while (inner is ObfuscatingSyncBackend) {
    obfuscated = true;
    inner = inner.inner;
  }
  final String base = switch (inner) {
    InterconnectSyncBackend() => srsInterconnectDirectoryKey(
      await inner.connectedHostIdentity(),
    ),
    GoogleDriveSyncBackend() => 'googleDrive:${await inner.currentEmail ?? ''}',
    OneDriveSyncBackend() => 'oneDrive:${await inner.currentEmail ?? ''}',
    DropboxSyncBackend() => 'dropbox:${await inner.currentEmail ?? ''}',
    WebDavSyncBackend() =>
      'webDav:${await repo.getWebDavUrl() ?? ''}'
          '|${await repo.getWebDavUsername() ?? ''}',
    FtpSyncBackend() =>
      'ftp:${await repo.getFtpHost() ?? ''}:${await repo.getFtpPort()}'
          '|${await repo.getFtpUsername() ?? ''}',
    SftpSyncBackend() =>
      'sftp:${await repo.getSftpHost() ?? ''}:${await repo.getSftpPort()}'
          '|${await repo.getSftpUsername() ?? ''}',
    _ => 'store:${inner.runtimeType}',
  };
  return obfuscated ? 'obfuscated:$base' : base;
}

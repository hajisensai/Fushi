/// 复习（SRS）同步目录的稳定身份（同步 v2 按它记每个位置传到了哪：`sync2_locations`）。
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
///
/// 拿不到稳定身份（OAuth 后端的账户还没认出来 = `currentEmail` 为空、WebDAV / FTP / SFTP 的
/// 地址没配）时返回 null，调用方这一轮不同步该后端：身份从「空」变成「某账户」若被当成两个目录，
/// 同一个物理目录会重新起步、可能整库重发；两个不同账户都落成「空」更会互相套用进度、误判换化身。
library;

import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';
import 'package:fushi/src/sync/google_drive_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart' show kSyncRootFolderName;
import 'package:fushi/src/sync/webdav_sync_backend.dart';

/// host 的同步数据根（`<sync-data>`）下、复习同步命名空间里的路径：
/// `fushi-data/fushi-srs/...`（[FushiSyncServerController.clientSyncWrites] 给的相对路径）。
bool srsIsHostSrsPath(String relativePath) =>
    relativePath.startsWith('$kSyncRootFolderName/$kSrsSync2Namespace/');

/// 互联目录的身份（客户端连 host、host 读自己的目录，同一块目录给同一个值）。
String srsInterconnectDirectoryKey(String hostId) => 'interconnect:$hostId';

/// 账户型目录的身份：`<种类>:<账户>`；账户为空时 null（身份还不可用）。
String? srsAccountDirectoryKey(String kind, String? account) {
  final String? a = account?.trim();
  if (a == null || a.isEmpty) return null;
  return '$kind:$a';
}

/// 服务器型目录的身份：`<种类>:<地址>|<用户>`；地址为空时 null（身份还不可用）。
String? srsServerDirectoryKey(String kind, String? server, String? user) {
  final String? s = server?.trim();
  if (s == null || s.isEmpty) return null;
  return '$kind:$s|${user ?? ''}';
}

/// [store] 所指同步目录的身份；拿不到稳定身份时 null（见库注释）。
Future<String?> srsDirectoryKeyOf(
  SyncAssetStore store,
  SyncRepository repo,
) async {
  SyncAssetStore inner = store;
  bool obfuscated = false;
  while (inner is ObfuscatingSyncBackend) {
    obfuscated = true;
    inner = inner.inner;
  }
  final String? base = switch (inner) {
    InterconnectSyncBackend() => srsInterconnectDirectoryKey(
      await inner.connectedHostIdentity(),
    ),
    GoogleDriveSyncBackend() => srsAccountDirectoryKey(
      'googleDrive',
      await inner.currentEmail,
    ),
    OneDriveSyncBackend() => srsAccountDirectoryKey(
      'oneDrive',
      await inner.currentEmail,
    ),
    DropboxSyncBackend() => srsAccountDirectoryKey(
      'dropbox',
      await inner.currentEmail,
    ),
    WebDavSyncBackend() => srsServerDirectoryKey(
      'webDav',
      await repo.getWebDavUrl(),
      await repo.getWebDavUsername(),
    ),
    FtpSyncBackend() => srsServerDirectoryKey(
      'ftp',
      await _hostPort(repo.getFtpHost(), repo.getFtpPort()),
      await repo.getFtpUsername(),
    ),
    SftpSyncBackend() => srsServerDirectoryKey(
      'sftp',
      await _hostPort(repo.getSftpHost(), repo.getSftpPort()),
      await repo.getSftpUsername(),
    ),
    _ => 'store:${inner.runtimeType}',
  };
  if (base == null) return null;
  return obfuscated ? 'obfuscated:$base' : base;
}

/// `host:port`；host 为空时 null。
Future<String?> _hostPort(Future<String?> host, Future<int> port) async {
  final String? h = (await host)?.trim();
  final int pt = await port;
  if (h == null || h.isEmpty) return null;
  return '$h:$pt';
}

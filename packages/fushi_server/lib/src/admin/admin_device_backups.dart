/// admin API 的设备备份端点（`/api/admin/device-backups`，自动备份第四期 A，
/// docs/specs/2026-11-25-auto-backup-restore-points.md「Phase 4A」）：已配对设备经互联 WebDAV 复制过来的
/// 定时还原点，落在同步根 `fushi-data/__backups__/<设备键>/<还原点 id>/`（盘上读写见 fushi_core 的
/// [DeviceBackupInbox]）。
///
/// - `GET    /api/admin/device-backups`               按设备分组列出；
/// - `GET    /api/admin/device-backups/<设备>/<id>`   下载那份的 zip（普通的 Fushi 备份包：互联不混淆内容，
///                                                     app 里「导入备份」就能用）；
/// - `DELETE /api/admin/device-backups/<设备>/<id>`   删一份；
/// - `DELETE /api/admin/device-backups/<设备>`        删这台设备的全部。
///
/// 设备键 / id 不合格回 400（不回显值），不存在 / 不完整回 404；多出来的路径段不是这组路由。服务端自己从不
/// 删这些副本（D13）：设备按自己的保留规则修剪它写的那些，别的只有管理员在这里删。
///
/// 副本里是设备的整份数据库，所以这组端点只在 admin 面上，不进远端 AI 助手的操作目录（见 admin_ops.dart
/// 「不描述」）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String kAdminDeviceBackupsPath = '/api/admin/device-backups';

/// 无头服务端互联 WebDAV 根下的同步根（`fushi-data/`）。互联服务在跑时用它实际的
/// [FushiSyncServer.syncDataDir]；没在跑（关着 / 测试）就按同样的规则算：`HeadlessHost` 把
/// [ServerPaths.syncData] 交给 `FushiSyncServer`，后者的构造函数再拼一层 `sync-data`
/// （packages/fushi_engine/lib/sync/fushi_sync_server.dart，`syncDataDir = p.join(syncDataDir, 'sync-data')`；
/// 引擎没有导出这个名字，server_srs.dart / anki_landing.dart 同样照抄）。
String serverInterconnectSyncRoot(
  ServerPaths paths, {
  String? runningSyncDataDir,
}) => p.join(
  runningSyncDataDir ?? p.join(paths.syncData.path, 'sync-data'),
  kSyncRootFolderName,
);

/// 下载文件名里只留 `[A-Za-z0-9._-]`：其余字符换成 `-`，连着的并成一个，首尾的 `-` / `.` 去掉。
String deviceBackupFileNamePart(String raw) {
  final String s = raw
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  return s.length > 48 ? s.substring(0, 48) : s;
}

class AdminDeviceBackups {
  AdminDeviceBackups(this.ctx);

  final AdminContext ctx;

  DeviceBackupInbox get _inbox => DeviceBackupInbox(
    serverInterconnectSyncRoot(
      ctx.paths,
      runningSyncDataDir: ctx.host.syncServer?.syncDataDir,
    ),
  );

  /// 不是这组路由（或方法不对）返回 null，交给 admin API 的兜底 404。
  Future<shelf.Response?> route(String method, String path) async {
    if (path == kAdminDeviceBackupsPath) {
      return method == 'GET' ? _list() : null;
    }
    if (!path.startsWith('$kAdminDeviceBackupsPath/')) return null;
    final List<String> raw = path
        .substring(kAdminDeviceBackupsPath.length + 1)
        .split('/');
    if (raw.length > 2 || raw.any((String s) => s.isEmpty)) {
      return _json(<String, Object?>{'error': 'not found'}, 404);
    }
    final List<String> segs = <String>[];
    for (final String s in raw) {
      try {
        segs.add(Uri.decodeComponent(s));
      } on ArgumentError {
        return _invalid();
      } on FormatException {
        return _invalid();
      }
    }
    final String device = segs.first;
    final String? id = segs.length > 1 ? segs[1] : null;
    if (method == 'GET' && id == null) return null;
    if (method != 'GET' && method != 'DELETE') return null;
    // 先按形状拒：解码后带 `/`、`..`、大写之类的一律不进 inbox（它也会再校验一遍）。
    if (!isDeviceBackupKey(device) ||
        (id != null && !isScheduledRestorePointId(id))) {
      return _invalid();
    }
    final DeviceBackupInbox inbox = _inbox;
    if (method == 'DELETE') {
      final bool removed = id == null
          ? await inbox.deleteDevice(device)
          : await inbox.deleteCopy(device, id);
      if (!removed) return _notFound();
      return _json(const <String, Object?>{'ok': true});
    }
    return _download(inbox, device, id!);
  }

  shelf.Response _list() {
    final DeviceBackupInbox inbox = _inbox;
    final String dataDir = p.normalize(p.absolute(ctx.config.dataDir));
    return _json(<String, Object?>{
      // 相对数据目录（不回绝对路径）；不在数据目录下就不给。
      if (p.isWithin(dataDir, inbox.root))
        'root': p.split(p.relative(inbox.root, from: dataDir)).join('/'),
      'devices': <Map<String, Object?>>[
        for (final ReceivedDeviceBackupGroup g in inbox.list()) g.toJson(),
      ],
    });
  }

  shelf.Response _download(DeviceBackupInbox inbox, String device, String id) {
    final ReceivedDeviceBackup? copy = inbox.find(device, id);
    final String? archive = copy?.point.archivePath;
    if (copy == null || archive == null) return _notFound();
    final File file = File(archive);
    final int length;
    try {
      length = file.lengthSync();
    } on FileSystemException {
      return _notFound();
    }
    final String name = deviceBackupFileNamePart(copy.point.deviceName ?? '');
    final String fileName = 'fushi-${name.isEmpty ? device : name}-$id.zip';
    return shelf.Response.ok(
      file.openRead(),
      headers: <String, String>{
        'Content-Type': 'application/zip',
        'Content-Length': '$length',
        'Content-Disposition': 'attachment; filename="$fileName"',
        'Cache-Control': 'no-store',
      },
    );
  }
}

shelf.Response _invalid() =>
    _json(<String, Object?>{'error': 'invalid device backup name'}, 400);

shelf.Response _notFound() =>
    _json(<String, Object?>{'error': 'device backup not found'}, 404);

shelf.Response _json(Map<String, Object?> body, [int status = 200]) =>
    shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );

/// 本机作为互联 host 时，复习同步目录怎么认（app 与无头服务端共用）。
///
/// host 的同步数据根（`<sync-data>`）下，别的设备经互联写进来的复习数据就在 `fushi-data/fushi-srs/...`；host
/// 自己也在这块目录上同步，身份与连进来的客户端看到的一样（[srsInterconnectDirectoryKey]）。
library;

import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_root_folder.dart';

/// host 的同步数据根（`<sync-data>`）下、复习同步命名空间里的路径：
/// `fushi-data/fushi-srs/...`（`FushiSyncServer.onClientWrite` 给的相对路径）。
bool srsIsHostSrsPath(String relativePath) =>
    relativePath.startsWith('$kSyncRootFolderName/$kSrsSync2Namespace/');

/// host 收到的一次复习同步写入是不是某台设备**自己的**段（`.../devices/<设备>/seg-….bin`），是就返回设备 ID。
/// 转发件（`rly-…`）是别的设备代传的、head 谁都可能原样转写，都不算：只有作者自己写段，写段的已配对对端就是
/// 这台设备（native/fushi_fsrs/src/store/sync2/devices.rs 的补充名）。
String? srsHostUploadedSegmentDevice(String relativePath) {
  if (!srsIsHostSrsPath(relativePath)) return null;
  final RegExpMatch? m = _kOwnSegmentPath.firstMatch(relativePath);
  return m?.group(1);
}

final RegExp _kOwnSegmentPath = RegExp(
  r'/devices/([0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12})/seg-[^/]+$',
);

/// host 收到的复习同步写入属于哪个 profile（`fushi-data/fushi-srs/<profileUid>/...`）；不是复习路径时 null。
String? srsHostPathProfile(String relativePath) {
  if (!srsIsHostSrsPath(relativePath)) return null;
  final String rest = relativePath.substring(
    '$kSyncRootFolderName/$kSrsSync2Namespace/'.length,
  );
  final int slash = rest.indexOf('/');
  final String uid = slash < 0 ? rest : rest.substring(0, slash);
  return uid.isEmpty ? null : uid;
}

/// 互联目录的身份（客户端连 host、host 读自己的目录，同一块目录给同一个值）。
String srsInterconnectDirectoryKey(String hostId) => 'interconnect:$hostId';

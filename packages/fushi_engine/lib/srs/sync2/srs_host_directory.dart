/// 本机作为互联 host 时，复习同步目录怎么认（app 与无头服务端共用）。
///
/// host 的同步数据根（`<sync-data>`）下，别的设备经互联写进来的复习数据就在 `fushi-data/fushi-srs/<dir>/...`；host
/// 自己也在这块目录上同步，身份与连进来的客户端看到的一样（[srsInterconnectDirectoryKey]）。
///
/// `<dir>` 是**位置目录名**，不是 profile uid：全新集合的目录名等于建它的那个 uid，但并入 / 认领之后本机 profile
/// 绑到别的目录（设计 §5.1 2026-11-17 修订、规划 §6「生产代码里没有把目录名当 uid 的读法」）。写入属于哪份 profile
/// 一律经内核按绑定反查（[srsHostProfilesOfDir]，命令 `profile_of_dir`，G10-4）。
library;

import 'dart:isolate';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;

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

/// host 收到的复习同步写入落在哪个位置目录（`fushi-data/fushi-srs/<dir>/...`）；不是复习路径、或目录段是空 /
/// `.` / `..` 时 null。**目录名不是 profile uid**：属于哪份 profile 用 [srsHostProfilesOfDir] 问内核。
String? srsHostPathDir(String relativePath) {
  if (!srsIsHostSrsPath(relativePath)) return null;
  final String rest = relativePath.substring(
    '$kSyncRootFolderName/$kSrsSync2Namespace/'.length,
  );
  final int slash = rest.indexOf('/');
  final String dir = slash < 0 ? rest : rest.substring(0, slash);
  return dir.isEmpty || dir == '.' || dir == '..' ? null : dir;
}

/// 当前绑定在位置目录 [dir] 上的本机 profile（内核 `profile_of_dir`，按 uid 排；没人绑 = 空表）。[dir] 来自对端
/// 写入的路径、不可信：内核拒绝坏目录名时抛 `SrsCoreException`（`profile_of_dir: bad dir`），调用方当作「不是哪份
/// profile 的」处理。读命令，在后台 isolate 跑（[core] 那份连接上可能有长写入在排队）。
Future<List<String>> srsHostProfilesOfDir(SrsCore core, String dir) {
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  return Isolate.run<List<String>>(() {
    final Map<String, Object?> m = SrsCore.fromAddress(
      address,
      libraryPath: libraryPath,
    ).sync2(<String, Object?>{'op': 'profile_of_dir', 'dir': dir}).map;
    final Object? profiles = m['profiles'];
    if (profiles is! List<Object?> ||
        profiles.any((Object? u) => u is! String)) {
      throw FormatException('profile_of_dir: bad reply $m');
    }
    return profiles.cast<String>();
  });
}

/// 互联目录的身份（客户端连 host、host 读自己的目录，同一块目录给同一个值）。
String srsInterconnectDirectoryKey(String hostId) => 'interconnect:$hostId';

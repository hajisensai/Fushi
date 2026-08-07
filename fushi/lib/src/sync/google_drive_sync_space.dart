import 'package:meta/meta.dart';

import 'package:fushi/src/sync/sync_utils.dart' show kSyncRootFolderName;

/// ttu/Hoshi 共享同步的可见 Drive 根目录名。
///
/// 与 ッツ ebook-reader / Hoshi-Reader-Android 的 `ttu-reader-data` 逐字节一致：
/// 两个 app 因此在用户可见的 My Drive 下落进**同一个**根文件夹，进度文件（都是
/// `progress_1_6_*` 明文 JSON）得以互相读写。改这个字面量会立刻破坏与 Hoshi/ッツ
/// 的互通，勿动。

/// Google Drive 同步的「存储空间 + OAuth scope」配置。
///
/// Hibiki 的 Drive 同步有两种物理落点，本类把两者收敛成一个不可变值对象，让
/// [GoogleDriveAuth]（决定 scope）与 [GoogleDriveHandler]（决定 spaces / 根文件夹）
/// 直接读字段，而不是在每个 `files.list` 调用点散落 `if (hoshiCompat)` 分支——
/// 消除特例，两条路径共用同一套代码。
///
/// - [appData]：隐藏的、按 app 隔离的 App Data 空间（`drive.appdata` scope）。历史
///   默认（TODO-836），别的 app 物理上看不到，老用户云端数据即落于此。
/// - [ttuShared]：可见 My Drive（完整 `drive` scope）。与 Hoshi/ッツ 共享 `ttu-
///   reader-data`。需要完整 scope 才能读到 **Hoshi 创建** 的文件——`drive.file`
///   只能访问本 app 自己建的文件，看不到别的 OAuth client 建的。
@immutable
class GoogleDriveSyncSpace {
  const GoogleDriveSyncSpace({
    required this.id,
    required this.scope,
    required this.spaces,
    required this.rootParent,
    required this.rootFolderName,
  });

  /// 稳定标识（持久化 / 比较用）。
  final String id;

  /// OAuth scope。隐藏空间用 `drive.appdata`；可见共享用完整 `drive`。
  final String scope;

  /// `files.list` 的 `spaces` 参数（`appDataFolder` 或 `drive`）。子查询里
  /// `'<id>' in parents` 在 App Data 空间必须显式带 `spaces`，否则默认落到可见
  /// Drive 空间并返回空（TODO-836）。
  final String spaces;

  /// 根文件夹的 parent 别名：`appDataFolder`（隐藏空间根）或 `root`（My Drive 根）。
  final String rootParent;

  /// 同步根文件夹名。
  final String rootFolderName;

  /// 默认：隐藏 appDataFolder / `hibiki-data`。老用户云端数据原地不动。
  static const GoogleDriveSyncSpace appData = GoogleDriveSyncSpace(
    id: 'appdata',
    scope: 'https://www.googleapis.com/auth/drive.appdata',
    spaces: 'appDataFolder',
    rootParent: 'appDataFolder',
    rootFolderName: kSyncRootFolderName,
  );
}

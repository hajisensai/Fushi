import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/google_drive_sync_space.dart';
import 'package:fushi/src/sync/sync_utils.dart' show kSyncRootFolderName;

/// 守卫 Google Drive 两种存储空间的关键契约。
///
/// Hoshi 兼容互通的成立完全依赖 [GoogleDriveSyncSpace.ttuShared] 这几个字段精确：
/// 完整 `drive` scope（才能读 Hoshi 建的文件）、可见 `drive` 空间、`root` parent、
/// 根目录名 `ttu-reader-data`（与 Hoshi/ッツ 逐字节一致）。默认 [appData] 必须仍是
/// 隐藏 appDataFolder / `hibiki-data`，否则老用户云端数据被悄悄换了物理落点。
void main() {
  group('GoogleDriveSyncSpace.appData (默认，隐藏空间)', () {
    const space = GoogleDriveSyncSpace.appData;

    test('用 drive.appdata scope（app 私有隐藏空间）', () {
      expect(space.scope, 'https://www.googleapis.com/auth/drive.appdata');
    });

    test('spaces / rootParent 都是 appDataFolder', () {
      expect(space.spaces, 'appDataFolder');
      expect(space.rootParent, 'appDataFolder');
    });

    test('根目录名沿用 hibiki-data（老用户云端数据原地不动）', () {
      expect(space.rootFolderName, 'hibiki-data');
      expect(space.rootFolderName, kSyncRootFolderName);
    });
  });

  group('GoogleDriveSyncSpace.ttuShared (Hoshi/ッツ 共享)', () {
    const space = GoogleDriveSyncSpace.ttuShared;

    test('用完整 drive scope（才能读 Hoshi 建的文件，drive.file 不够）', () {
      expect(space.scope, 'https://www.googleapis.com/auth/drive');
      // 绝不能退回只读或 drive.file——那样看不到 Hoshi 创建的进度文件。
      expect(space.scope, isNot(contains('drive.file')));
      expect(space.scope, isNot(contains('readonly')));
      expect(space.scope, isNot(contains('appdata')));
    });

    test('落可见 My Drive：spaces=drive, parent=root', () {
      expect(space.spaces, 'drive');
      expect(space.rootParent, 'root');
    });

    test('根目录名 = ttu-reader-data（与 Hoshi/ッツ 同文件夹）', () {
      expect(space.rootFolderName, 'ttu-reader-data');
      expect(space.rootFolderName, kTtuSharedRootFolderName);
    });
  });

  group('fromHoshiCompat 开关映射', () {
    test('关 → appData（隐藏空间）', () {
      expect(GoogleDriveSyncSpace.fromHoshiCompat(false).id,
          GoogleDriveSyncSpace.appData.id);
    });

    test('开 → ttuShared（共享可见 Drive）', () {
      expect(GoogleDriveSyncSpace.fromHoshiCompat(true).id,
          GoogleDriveSyncSpace.ttuShared.id);
    });

    test('两种空间的 id 稳定且互异（持久化/比较用）', () {
      expect(GoogleDriveSyncSpace.appData.id, 'appdata');
      expect(GoogleDriveSyncSpace.ttuShared.id, 'ttu-shared');
    });
  });
}

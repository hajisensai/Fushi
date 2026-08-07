import 'dart:io';

import 'package:hibiki/src/sync/sync_utils.dart';

/// Fushi 改名迁移（`hibiki-data` → `fushi-data`）的共享三段骨架，五个远端
/// backend（Dropbox / OneDrive / WebDAV / FTP / SFTP）共用；Google Drive 侧的
/// 同形实现在 `GoogleDriveHandler.findOrCreateRootFolder`（先落地，保持原样）。
///
/// 语义（与 Drive 侧逐条对齐）：
/// 1. 新根已存在 → 直接返回它（幂等：迁移后/新用户路径零额外开销，旧根探测
///    根本不发生）。
/// 2. 新根不存在而旧根存在 → [renameLegacy] **远端改名**（数据原地不动），返回
///    改名后的定位符。
/// 3. 都不存在 → 返回 null，调用方照旧新建新根。
/// 4. 改名失败 → 经 [onRenameError] 留痕（ErrorLogService），按无旧根降级返回
///    null（本轮新建新根、下次同步重试改名）；**绝不吞异常、绝不挡同步**。
///
/// [find] 的异常（网络/鉴权）原样上抛——那是同步本身失败，不属于迁移降级范围。
/// 结果记忆化由调用方的 `rootFolderIdCache` 承担（findOrCreateRootFolder 每会话
/// 只真正执行一次），本函数保持纯粹可注入、可单测。
Future<T?> migrateLegacySyncRoot<T>({
  required Future<T?> Function(String name) find,
  required Future<T> Function(T legacy) renameLegacy,
  required void Function(Object error, StackTrace stack) onRenameError,
}) async {
  final T? existing = await find(kSyncRootFolderName);
  if (existing != null) return existing;

  final T? legacy = await find(kLegacySyncRootFolderName);
  if (legacy == null) return null;

  try {
    return await renameLegacy(legacy);
  } catch (e, st) {
    // 改名失败（权限/瞬时错误）按无旧根处理：本轮新建新根、下次同步重试改名。
    // 必须留痕，不吞异常。
    onRenameError(e, st);
    return null;
  }
}

/// 互联 host 侧的本地磁盘迁移：`<syncDataDir>/hibiki-data` →
/// `<syncDataDir>/fushi-data`（host 的 WebDAV 根映射到 [syncDataDir]，client 的
/// 同步根是其下以 [kSyncRootFolderName] 命名的子目录）。
///
/// 幂等：新目录已存在或旧目录不存在都直接返回。失败（权限/占用）经 [onError]
/// 留痕后返回——不挡 server 启动，client 会新建空的新根，下次 host 启动重试。
Future<void> migrateLegacySyncRootDirectory({
  required String syncDataDir,
  required void Function(Object error, StackTrace stack) onError,
}) async {
  final String sep = Platform.pathSeparator;
  final Directory newDir = Directory('$syncDataDir$sep$kSyncRootFolderName');
  final Directory legacyDir =
      Directory('$syncDataDir$sep$kLegacySyncRootFolderName');
  try {
    if (await newDir.exists()) return;
    if (!await legacyDir.exists()) return;
    await legacyDir.rename(newDir.path);
  } catch (e, st) {
    // 同盘 rename 原子且不搬数据；失败（权限/文件被占用）留痕降级，下次重试。
    onError(e, st);
  }
}

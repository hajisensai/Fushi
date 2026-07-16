import 'package:hibiki/src/sync/ttu_models.dart';

/// 6 个非 Google-Drive 后端（ftp/sftp/webdav/dropbox/onedrive/hibiki_client）共享的
/// 「书名 → folderId」内存缓存块：两个字段 + clearCache / restoreCache /
/// cachedRootFolderId / cachedFolderIds / cacheBookFolderIds / evictFolderId。
/// 原本 6 份逐字重复（含 BUG-202 evictFolderId 注释）。
///
/// 唯一真实分歧：路径式后端（WebDAV / Hibiki interconnect）的 folderId 是当作路径
/// **前缀** 用的，必须以 `/` 结尾，否则 `folderId + fileName` 会把文件写到书文件夹外
/// （BUG-845）；普通 ID 式后端（FTP/SFTP/Dropbox/OneDrive）的 folderId 是不透明
/// 定位符，不需要归一。用可覆写钩子 [normalizeCachedFolderId] 参数化：默认恒等，
/// webdav/hibiki_client 覆写成 `ensureFolderIdTrailingSlash`。这样一份缓存块对所有
/// 后端行为逐字等价。
///
/// hibiki_client 另需在 clearCache 里重置 `_sessionResolved`（HBK-AUDIT-157），
/// 通过 override clearCache + `super.clearCache()` 叠加，不动本 mixin。
mixin BookFolderCacheMixin {
  String? rootFolderIdCache;
  final Map<String, String> titleToFolderIdCache = {};

  /// 写入/逐出缓存前对 folderId 归一。默认恒等（ID 式后端）；路径式后端覆写为补尾
  /// 斜杠，保证「缓存里的 folderId 一律以 `/` 结尾」不变量按构造成立（BUG-845）。
  String normalizeCachedFolderId(String id) => id;

  void clearCache() {
    rootFolderIdCache = null;
    titleToFolderIdCache.clear();
  }

  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    // 持久化里的 id 可能是从 server href 存的、缺尾斜杠（BUG-845）；加载时经
    // [normalizeCachedFolderId] 自愈（ID 式后端为恒等，行为不变）。
    rootFolderIdCache =
        rootFolderId == null ? null : normalizeCachedFolderId(rootFolderId);
    if (titleToFolderId != null) {
      titleToFolderId.forEach((title, id) {
        titleToFolderIdCache[title] = normalizeCachedFolderId(id);
      });
    }
  }

  String? get cachedRootFolderId => rootFolderIdCache;

  Map<String, String> get cachedFolderIds =>
      Map.unmodifiable(titleToFolderIdCache);

  void cacheBookFolderIds(List<DriveFile> folders) {
    for (final f in folders) {
      // listBooks 把 DriveFile.id 设成 server 的 collection href / 后端定位符；经
      // [normalizeCachedFolderId] 归一后再缓存，路径式后端由此永不写出书文件夹外
      // （BUG-845），ID 式后端为恒等。
      titleToFolderIdCache[f.name] = normalizeCachedFolderId(f.id);
    }
  }

  void evictFolderId(String folderId) {
    // 按值反查逐出书名→folderId 缓存里指向 [folderId] 的条目，消除删书后陈旧态
    // （BUG-202）。路径式后端的 folderId 是按名派生的路径，逐出仍是廉价正确性。
    // 缓存值已统一经 [normalizeCachedFolderId] 归一，入参也归一后再比，避免尾斜杠
    // 差异漏逐出（BUG-845）。
    final normalized = normalizeCachedFolderId(folderId);
    titleToFolderIdCache.removeWhere((_, id) => id == normalized);
  }
}

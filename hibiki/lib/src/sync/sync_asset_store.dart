import 'dart:io';

/// 后端命名空间下的一个条目（资产文件或子命名空间）。
class AssetEntry {
  const AssetEntry({
    required this.id,
    required this.name,
    this.isFolder = false,
    this.sizeBytes,
  });

  /// 后端原生定位符：Drive/OneDrive 的不透明 id、WebDAV 的绝对 href、
  /// Dropbox/FTP/SFTP 的路径字符串。对调用方不透明。
  final String id;

  /// 业务可见名（如 `content.epub` / `<bookKey>` / `<name>.hibikidict`）。
  final String name;

  /// 该条目是子命名空间（文件夹）而非资产文件。
  final bool isFolder;

  /// 字节数；后端不提供时为 null（如 WebDAV PROPFIND 不返回大小）。
  final int? sizeBytes;
}

/// 与业务无关的资产存取层：在“命名空间”（文件夹/前缀）下存/取/列二进制资产，
/// 外加通用 JSON 读写。每个 `SyncBackend` 都实现它，供同步编排器统一调用。
abstract class SyncAssetStore {
  /// 确保根下存在名为 [name] 的顶层命名空间，返回其原生定位符。
  Future<String> ensureNamespace(String name);

  /// 在 [parentId] 命名空间下确保存在子命名空间 [name]，返回其原生定位符。
  Future<String> ensureFolder(String parentId, String name);

  /// 列出 [namespaceId] 下的直接子项（资产文件 + 子命名空间），不递归。
  Future<List<AssetEntry>> listChildren(String namespaceId);

  /// 在 [namespaceId] 下按名查找资产，未找到返回 null。
  Future<AssetEntry?> findAsset(String namespaceId, String name);

  /// 上传本地 [file] 为 [namespaceId] 下名为 [name] 的资产。
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  });

  /// 下载 [assetId] 指向的资产到 [destination]。
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  });

  /// 读取 [assetId] 指向的 JSON 资产；不存在或非 JSON 返回 null。
  Future<Object?> getJsonAsset(String assetId);

  /// 在 [namespaceId] 下写入名为 [name] 的 JSON 资产（覆盖）。
  Future<void> putJsonAsset(String namespaceId, String name, Object? json);
}

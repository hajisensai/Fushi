import 'dart:io';

/// 后端命名空间下的一个条目（资产文件或子命名空间）。
class AssetEntry {
  const AssetEntry({
    required this.id,
    required this.name,
    this.isFolder = false,
    this.sizeBytes,
    this.revision,
    this.modifiedAt,
  });

  /// 后端原生定位符：Drive/OneDrive 的不透明 id、WebDAV 的绝对 href、
  /// Dropbox/FTP/SFTP 的路径字符串。对调用方不透明。
  final String id;

  /// 业务可见名（如 `content.epub` / `<bookKey>` / `<name>.fushidict`）。
  final String name;

  /// 该条目是子命名空间（文件夹）而非资产文件。
  final bool isFolder;

  /// 字节数；后端不提供时为 null（如 WebDAV PROPFIND 不返回大小）。
  final int? sizeBytes;

  /// 后端**自己声明**的内容版本标记：内容哈希（Drive `md5Checksum`、Dropbox
  /// `content_hash`、OneDrive `quickXorHash`/`sha1Hash`）或服务端变更令牌
  /// （OneDrive `cTag`、WebDAV `getetag`）。契约：内容一变它必须变；对调用方不透明，
  /// 只能拿来比较相等。
  ///
  /// null = 后端给不出这样的保证，调用方必须当作「可能变了」。FTP / SFTP 只有秒级
  /// （FTP 的 LIST 甚至是分钟级）修改时间 + 大小，同一秒内写入等长新内容会撞成同一
  /// 个值，所以那两个后端不拿它们拼标记，一律给 null。
  final String? revision;

  /// 服务端修改时间（毫秒，UTC），由各后端从列目录元数据映射；拿不到为 null。
  /// SRS 同步用它做服务器时间 S（写探针文件再读回），见 docs/specs/2026-10-14-fushi-srs-design.md 铁律 F。
  /// 注意：Nextcloud 等 WebDAV 允许客户端经 X-OC-MTime 自报修改时间，本仓写入不带这个头，所以仍是服务器时间。
  final int? modifiedAt;
}

/// 单个文件传输的进度回调。
///
/// [fraction] 是 0..1 的完成比例；[bytesDone] 是本文件已传输的字节数——传输层
/// 数得出就带上（同步进度据此算速率），数不出（一次性写入等）就省略。
///
/// 第二个参数是**可选位置参数**：实现方覆盖时仍可把参数声明成
/// `void Function(double)?`（函数参数逆变，合法覆盖），只报比例的后端与测试替身
/// 不必改；调用方传入的闭包则须接受两个参数。
typedef SyncTransferProgress = void Function(double fraction, [int? bytesDone]);

/// 把只关心比例的回调接到 [SyncTransferProgress] 参数上（丢弃字节数）。
SyncTransferProgress? syncTransferFractionOnly(
  void Function(double fraction)? onProgress,
) => onProgress == null ? null : (double f, [int? _]) => onProgress(f);

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
    SyncTransferProgress? onProgress,
  });

  /// 下载 [assetId] 指向的资产到 [destination]。
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  });

  /// 读取 [assetId] 指向的 JSON 资产；不存在或非 JSON 返回 null。
  Future<Object?> getJsonAsset(String assetId);

  /// 在 [namespaceId] 下写入名为 [name] 的 JSON 资产（覆盖）。
  Future<void> putJsonAsset(String namespaceId, String name, Object? json);

  /// 删除 [id] 指向的资产或命名空间。[isFolder] 为 true 时按“文件夹”语义递归删除
  /// 其下全部内容。幂等：目标不存在视为成功（不抛）；其它错误（网络/权限/协议）
  /// 必须向上抛出，供调用方（UI）如实提示失败。
  ///
  /// 例外：FTP 后端因 ftpconnect 只回 bool、无法区分“不存在”与“真失败”，删除不
  /// 存在的目标会报错而非静默成功——即 FTP 不保证幂等（宁可暴露真错也不假装成功）。
  ///
  /// 删除是不可逆的远端副作用，调用方必须已向用户确认。
  Future<void> deleteAsset(String id, {bool isFolder = false});
}

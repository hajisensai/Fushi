import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

/// 远端书来源类型：决定书架「远端书」分区的标题/副标题文案（BUG-699 / TODO-1384）。
///
/// * [interconnect]：Hibiki 互联——局域网对端设备（`HibikiClientSyncBackend`），有
///   live 库/进度/删除/有声书 API，文案用「互联 / 对端设备」。
/// * [cloud]：云盘备份后端（WebDAV / Google Drive 等，经 `CloudRemoteBookClient`
///   适配），只是把云端书文件夹当可下载条目，没有「对端设备」语义，文案用通用
///   「云端书」。WebDAV-only 用户从没配过互联，绝不能给他们看「互联/对端设备」。
enum RemoteBookSourceKind { interconnect, cloud }

abstract class RemoteBookClient {
  /// 本客户端代表的远端书来源类型（驱动书架分区的标题/副标题文案；这是「展示」
  /// 归类，不是能力门控——删除/有声书等能力仍按具体后端类型判断）。
  RemoteBookSourceKind get remoteSourceKind;

  Future<List<RemoteBookInfo>> listRemoteBooks();

  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  });

  /// 读 host 端记录的书 [bookKey] 阅读进度（TODO-767 跨设备同步）。
  /// 无记录或不支持时返回 [RemoteBookProgress.empty]。
  Future<RemoteBookProgress> remoteBookProgress(String bookKey);

  /// 向 host 上报书 [bookKey] 的本端阅读进度（TODO-767）。host 端「取较新时间戳」
  /// 决定是否覆盖（落 host 自己的 reader_positions）。
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  );
}

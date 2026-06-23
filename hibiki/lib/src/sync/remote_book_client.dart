import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

abstract class RemoteBookClient {
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

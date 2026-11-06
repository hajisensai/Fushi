import 'dart:io';

import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';

/// 远端书来源类型：决定书架「远端书」分区的标题/副标题文案（BUG-699 / TODO-1384）。
///
/// * [interconnect]：Fushi 互联——局域网对端设备（`InterconnectSyncBackend`），有
///   live 库/进度/删除/有声书 API，文案用「互联 / 对端设备」。
/// * [cloud]：云盘备份后端（WebDAV / Google Drive 等，经 `CloudRemoteBookClient`
///   适配），只是把云端书文件夹当可下载条目，没有「对端设备」语义，文案用通用
///   「云端书」。WebDAV-only 用户从没配过互联，绝不能给他们看「互联/对端设备」。
enum RemoteBookSourceKind { interconnect, cloud }

/// 远端书来源**此刻**能不能连上（[RemoteBookSourceKind] 两类都用）：远端删除只在来源
/// 在线、可达时提供（反馈 R8duEiqRuy，所有者 2026-10-31 拍板）。
enum RemoteSourceReachability {
  /// 连得上，且接受本机凭据。
  reachable,

  /// 连不上（互联 host 没运行 Fushi / 睡眠 / 不在同一网络；云盘网络不通或服务出错）。
  unreachable,

  /// 连得上但拒绝了本机凭据：互联是配对被移除 / token 被吊销，云盘是登录失效。
  credentialRejected,
}

abstract class RemoteBookClient implements RemoteLibrarySource {
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

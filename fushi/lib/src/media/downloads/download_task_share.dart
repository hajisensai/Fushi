import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi/src/media/downloads/download_task_entry.dart';

/// 只由下载页去取的任务来源：要打网络（互联 host 的代下载任务）或扫盘（下载根里
/// 可重新入库的漫画）才拿得到，侧栏下载速览悬停时不重做这些事。
enum DownloadTaskSharedPart { remoteHosts, mangaRecoverable }

/// 下载页上这些来源最近一次算出的条目，供页外（侧栏下载速览）复用。
///
/// 同 `VideoContinueShare` 的做法：写入发生在来源段的 build 里，字段是普通可变
/// 状态、不发通知，读方只在速览加载时读一次；来源段 dispose 时只清自己写的那份
/// （它的轮询 / 监听随之停了，留着就是过期数据）。下载页这一进程里还没打开过时
/// 这两部分为空——速览里就看不到远端 / 可重新入库的条目，打开过一次后与页面一致。
class DownloadTaskShare {
  DownloadTaskShare._();

  static final DownloadTaskShare instance = DownloadTaskShare._();

  final Map<DownloadTaskSharedPart, _Published> _parts =
      <DownloadTaskSharedPart, _Published>{};

  void publish(
    DownloadTaskSharedPart part,
    Object owner,
    List<DownloadTaskEntry> entries,
  ) {
    _parts[part] = _Published(owner, List<DownloadTaskEntry>.of(entries));
  }

  void clearOwner(DownloadTaskSharedPart part, Object owner) {
    if (identical(_parts[part]?.owner, owner)) _parts.remove(part);
  }

  /// [part] 最近一次发布的条目；没发布过 / 已清掉时为空。
  List<DownloadTaskEntry> entriesOf(DownloadTaskSharedPart part) =>
      _parts[part]?.entries ?? const <DownloadTaskEntry>[];

  @visibleForTesting
  void reset() => _parts.clear();
}

class _Published {
  const _Published(this.owner, this.entries);

  final Object owner;
  final List<DownloadTaskEntry> entries;
}

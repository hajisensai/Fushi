/// 自动同步 sweep 补拉有声书接进 app 级下载任务表的端口（B5trcDxSnf）。
///
/// sweep（[SyncOrchestrator] 的「同步有声书文件」）此前自己闷头拉包：书架上看不到
/// 进度，也不和书架上手动发起的「从对端下载有声书」/「重新下载有声书」互斥，同一个
/// 有声书包可能被拉两次、并发解包写同一本书。下载任务表（`InterconnectDownloadManager`）
/// 是手动任务的唯一真相源，sweep 经这个端口：
/// - 拉之前问一声这本书有没有在跑的任务（[isBookDownloadRunning]），有就这轮跳过；
/// - 自己也登记成一条任务（[runAudiobookPull]，落地书键 = 这本书），书架本地卡的
///   任务遮罩与首页后台任务环照常显示进度，手动入口也据此不再并跑。
///
/// 编排器不认 Riverpod：app 起来时由下载任务表把自己注册到 [syncAudiobookPullTasks]，
/// 同步入口取它传给编排器。没注册（测试 / 无界面宿主）时 sweep 退回不登记的旧行为。
library;

import 'dart:io';

/// sweep 补拉一本有声书的本体：下载 + 解包落盘。[onProgress] 报 0..1，[onBytes]
/// 报已收 / 总字节（总量未知为 null）。抛错即这一本失败。
typedef SyncAudiobookPullBody =
    Future<void> Function({
      required void Function(double fraction) onProgress,
      required void Function(int received, int? total) onBytes,
    });

/// 见库注释。
abstract interface class SyncAudiobookPullTasks {
  /// 本地书 [bookKey] 此刻有没有在跑的下载任务（手动补拉 / 重拉有声书、整书下载
  /// 已落地正在拉有声书、或另一轮 sweep 的补拉）。
  bool isBookDownloadRunning(String bookKey);

  /// 把一次 sweep 补拉登记成任务跑完：任务从起跑到结束都挂在 [bookKey] 这本书上，
  /// [dest] 是这次的临时包路径（只作登记）。[body] 抛的错原样上抛。这本书此刻已有
  /// 在跑的任务时不跑 [body]、返回 false；跑完返回 true。
  Future<bool> runAudiobookPull({
    required String bookKey,
    required String title,
    required File dest,
    required SyncAudiobookPullBody body,
  });
}

/// app 级注册点（下载任务表创建时注册、销毁时注销）。
SyncAudiobookPullTasks? syncAudiobookPullTasks;

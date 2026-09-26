/// 引擎侧下载来源 → 下载保活租约的 app 侧观察者（BUG-2714）。
///
/// [DiscoveryDownloadQueue] 与视频下载管线都在 `fushi_engine`（纯 Dart，禁 import
/// Flutter / app 代码），不能直接持有 [DownloadKeepAlive]。这里从 app 侧观察它们
/// 的公开状态：有活要在本进程里干就经 [downloadKeepAliveHub] 挂保活，活干完就撤。
///
/// 纪律同 [DownloadKeepAlive]：第一次 update 必须发生在前台——两个来源的第一条
/// 活都是用户在前台点出来的（或 app 启动时恢复的持久任务），满足这一点。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';

/// 保活通知正文：已知百分比时带上。
String _downloadingText(int? percent) => percent == null
    ? t.download_task_status_downloading
    : '${t.download_task_status_downloading} · $percent%';

/// 发现页直链下载队列的保活观察者。
///
/// 队列里只要有未结束的任务（排队 / 执行中 / 退避等重试——重试定时器也在本
/// 进程里）就保活；全部结束（完成 / 失败 / 取消 / 被移除）即撤。
class DiscoveryDownloadKeepAliveBinding {
  DiscoveryDownloadKeepAliveBinding(
    this._queue, {
    DownloadKeepAlive? keepAlive,
  }) : _keepAlive = keepAlive ?? downloadKeepAliveHub.lease('discovery') {
    _queue.addListener(_sync);
    _sync();
  }

  final DiscoveryDownloadQueue _queue;
  final DownloadKeepAlive _keepAlive;
  bool _active = false;
  bool _disposed = false;

  void _sync() {
    if (_disposed) return;
    final List<DiscoveryDownloadTask> pending = <DiscoveryDownloadTask>[
      for (final DiscoveryDownloadTask task in _queue.tasks)
        if (!task.isFinished) task,
    ];
    if (pending.isEmpty) {
      _stop();
      return;
    }
    final DiscoveryDownloadTask? running = _queue.runningTask;
    final int? total = running?.totalBytes;
    final int? percent = running != null && total != null && total > 0
        ? (running.receivedBytes.clamp(0, total) * 100 ~/ total)
        : null;
    _active = true;
    unawaited(_keepAlive.update(
      title: pending.length == 1
          ? pending.single.item.title
          : t.download_keep_alive_multiple_title(count: pending.length),
      text: running == null
          ? t.download_task_status_queued
          : _downloadingText(percent),
      percent: pending.length == 1 ? percent : null,
    ));
  }

  void _stop() {
    if (!_active) return;
    _active = false;
    unawaited(_keepAlive.stop());
  }

  /// 队列销毁前调用：摘监听并撤保活。
  void dispose() {
    if (_disposed) return;
    _queue.removeListener(_sync);
    _stop();
    _disposed = true;
  }
}

/// 这条持久视频下载任务此刻是否要靠**本进程**活着才能推进。
///
/// 只认 `active` 生命周期（`cancelled` 即用户暂停，不算）。内置引擎
/// （`packages/fushi_torrent`，libtorrent 经 FFI 加载进 app 进程）的任务整条都
/// 跑在本进程里，进程被杀下载就停；外接 qBittorrent 的字节在 qB 进程里下，
/// 本进程死了不影响，不为它挂前台服务。
bool videoDownloadJobNeedsKeepAlive(VideoDownloadJobRow job) =>
    job.lifecycle == VideoDownloadJobLifecycle.active &&
    job.backendKind == QbConnectionConfig.backendEmbedded;

/// 视频下载管线（torrent）的保活观察者：订阅任务表，按
/// [videoDownloadJobNeedsKeepAlive] 汇总。
class VideoDownloadJobsKeepAliveBinding {
  VideoDownloadJobsKeepAliveBinding(
    Stream<List<VideoDownloadJobRow>> jobs, {
    DownloadKeepAlive? keepAlive,
  }) : _keepAlive = keepAlive ?? downloadKeepAliveHub.lease('video') {
    _subscription = jobs.listen(
      _sync,
      onError: (Object error, StackTrace stack) {
        // 任务表订阅断了（通常是关库）：保活宁可撤掉也不能悬空。
        debugPrint('[DownloadKeepAlive] video jobs stream failed: $error');
        _stop();
      },
    );
  }

  final DownloadKeepAlive _keepAlive;
  late final StreamSubscription<List<VideoDownloadJobRow>> _subscription;
  bool _active = false;
  bool _disposed = false;

  void _sync(List<VideoDownloadJobRow> rows) {
    if (_disposed) return;
    final List<VideoDownloadJobRow> working = <VideoDownloadJobRow>[
      for (final VideoDownloadJobRow row in rows)
        if (videoDownloadJobNeedsKeepAlive(row)) row,
    ];
    if (working.isEmpty) {
      _stop();
      return;
    }
    int? percent;
    if (working.length == 1) {
      final VideoDownloadJobRow only = working.single;
      if (only.stage == VideoDownloadJobStage.download) {
        percent = (only.stageProgress.clamp(0.0, 1.0) * 100).floor();
      }
    }
    _active = true;
    unawaited(_keepAlive.update(
      title: working.length == 1
          ? working.single.title
          : t.download_keep_alive_multiple_title(count: working.length),
      text: _downloadingText(percent),
      percent: percent,
    ));
  }

  void _stop() {
    if (!_active) return;
    _active = false;
    unawaited(_keepAlive.stop());
  }

  /// 管线 runtime 销毁时调用：退订任务表并撤保活。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    if (_active) {
      _active = false;
      await _keepAlive.stop();
    }
  }
}

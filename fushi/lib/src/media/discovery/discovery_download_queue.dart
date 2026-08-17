/// 发现页 HTTP 直链下载队列：app 生命周期常驻（组装点懒建），发现页负责
/// enqueue，关闭页面**不**中断下载（统一下载中心语义，与 torrent 任务同级）。
///
/// 执行模型与重试语义照搬 `MokuroMoeDownloadQueue`（顺序一次一个任务；单任务
/// 失败/取消只标记该任务、继续下一个；自动重试**就地复活**同一任务对象、退避
/// 期间不占执行位；手动重试清零自动重试预算）。字节层复用 `ResumableDownloader`
/// （`.part` 续传 + Range + 原子 promote），失败/取消保留 `.part`，重试即续传。
///
/// torrent payload **不进本队列**：UI 拿到 `DiscoveryPayloadKind.torrent` 的条目
/// 直接分流给 torrent 后端（`pushGenericMagnet` 链路）。这里若 resolve 出
/// torrent（源实现 bug）按不可重试失败处理。
///
/// 下载完成后经注入的 [DiscoveryDownloadImporter] 自动入库；导入失败不自动
/// 重试（同一份坏数据重跑不会变好），落 failed 等用户手动重试（重试会因目标
/// 文件已存在而跳过下载、直接重导）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/utils/misc/resumable_downloader.dart';
import 'package:fushi/src/utils/net/app_http.dart';

/// 自动重试退避梯度；长度即最大自动重试次数（语义同 `kMokuroMoeRetryBackoff`）。
const List<Duration> kDiscoveryDownloadRetryBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

/// 把条目物化成可执行 payload（生产接 `MediaDiscoverySource.resolvePayload`；
/// 注入函数而非源对象，队列不依赖源注册表）。
typedef DiscoveryPayloadResolver = Future<DiscoveryPayload> Function(
  DiscoveryResourceItem item,
);

/// 下载完成后的自动入库回调（按 [DiscoveryResourceItem.kind] 分派到各域导入器；
/// 生产分派表在组装点注入，本队列不 import 任何域代码）。
typedef DiscoveryDownloadImporter = Future<DiscoveryImportOutcome> Function(
  DiscoveryDownloadTask task,
  File file,
);

/// 测试注入口：替换真实网络（绕 HttpClient）。
typedef DiscoveryDownloadOpen = Future<ResumableDownloadResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

/// 一次自动入库的结果。
class DiscoveryImportOutcome {
  const DiscoveryImportOutcome({this.importedCount = 0, this.summary});

  /// 实际新建的库条目数（0 = 已在库被跳过等）。
  final int importedCount;

  /// 给任务行展示的一句话结果（入库标题等）。
  final String? summary;
}

/// 任务生命周期状态。[waitingRetry] 不是终态也不占执行位（语义同 mokuro 队列）。
enum DiscoveryDownloadStatus {
  queued,
  running,
  waitingRetry,
  done,
  failed,
  cancelled,
}

/// 队列中的一个下载任务（可变快照；变更经队列 notifyListeners 广播）。
class DiscoveryDownloadTask {
  DiscoveryDownloadTask._({required this.item, required this.destinationDir});

  final DiscoveryResourceItem item;

  /// 落盘目录（按媒体域由组装点决定）。
  final String destinationDir;

  DiscoveryDownloadStatus status = DiscoveryDownloadStatus.queued;

  int receivedBytes = 0;
  int? totalBytes;

  /// 失败原因（status == failed / waitingRetry 时非空）。
  String? error;

  /// 已消耗的自动重试次数；手动 retry 归零。
  int autoRetries = 0;

  /// 下载完成后的落盘路径（done 时非空）。
  String? filePath;

  /// 自动入库结果（done 且导入过时非空）。
  DiscoveryImportOutcome? importOutcome;

  /// 目标文件已存在、跳过了下载（重试重导场景仍会走导入）。
  bool skippedDownload = false;

  /// 取消请求标记：running 中被 cancel 时置位，收尾按 cancelled 归类。
  bool _cancelRequested = false;

  /// 当前任务持有的网络连接（cancel 时强关以掐断响应流）。
  HttpClient? _client;

  bool get isFinished =>
      status == DiscoveryDownloadStatus.done ||
      status == DiscoveryDownloadStatus.failed ||
      status == DiscoveryDownloadStatus.cancelled;
}

/// 内部哨兵：把「用户取消」与真实错误在收尾处分开。
class _DiscoveryDownloadCancelled implements Exception {
  const _DiscoveryDownloadCancelled();
}

/// 顺序执行的发现页直链下载队列。
class DiscoveryDownloadQueue extends ChangeNotifier {
  DiscoveryDownloadQueue({
    required DiscoveryPayloadResolver resolvePayload,
    required DiscoveryDownloadImporter importer,
    @visibleForTesting DiscoveryDownloadOpen? openOverride,
    @visibleForTesting List<Duration>? retryBackoffOverride,
  })  : _resolvePayload = resolvePayload,
        _importer = importer,
        _openOverride = openOverride,
        _retryBackoff = retryBackoffOverride ?? kDiscoveryDownloadRetryBackoff;

  final DiscoveryPayloadResolver _resolvePayload;
  final DiscoveryDownloadImporter _importer;
  final DiscoveryDownloadOpen? _openOverride;
  final List<Duration> _retryBackoff;

  final List<DiscoveryDownloadTask> _tasks = <DiscoveryDownloadTask>[];

  /// 退避中的重试定时器（可并存多个：A 退避时队列继续跑 B）。
  final Map<DiscoveryDownloadTask, Timer> _retryTimers =
      <DiscoveryDownloadTask, Timer>{};

  DiscoveryDownloadTask? _running;
  bool _disposed = false;

  /// UI 进度节流：字节回调每 chunk 触发，逐次 notify 会刷爆监听方。
  static const Duration _progressNotifyInterval = Duration(milliseconds: 250);
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  int get maxAutoRetries => _retryBackoff.length;

  /// 累计成功新建库条目数（库页刷新信号：监听方比对增量后失效对应 provider）。
  int _importedCount = 0;
  int get importedCount => _importedCount;

  List<DiscoveryDownloadTask> get tasks =>
      List<DiscoveryDownloadTask>.unmodifiable(_tasks);

  DiscoveryDownloadTask? get runningTask => _running;

  bool get hasUnfinished =>
      _tasks.any((DiscoveryDownloadTask t) => !t.isFinished);

  int get finishedCount =>
      _tasks.where((DiscoveryDownloadTask t) => t.isFinished).length;

  int get totalCount => _tasks.length;

  /// 该条目是否已排队/执行中（发现页据此禁用下载按钮，防重复入队）。
  bool isPending(DiscoveryResourceItem item) => pendingTask(item) != null;

  DiscoveryDownloadTask? pendingTask(DiscoveryResourceItem item) {
    for (final DiscoveryDownloadTask t in _tasks) {
      if (!t.isFinished &&
          t.item.sourceId == item.sourceId &&
          t.item.id == item.id) {
        return t;
      }
    }
    return null;
  }

  /// 入队一个条目；同源同 id 的未完成任务去重。返回是否真的新增。
  bool enqueue(DiscoveryResourceItem item, {required String destinationDir}) {
    assert(
      item.payloadKind == DiscoveryPayloadKind.httpFile,
      'torrent 条目走 torrent 后端，不进 HTTP 队列',
    );
    if (isPending(item)) return false;
    _tasks.add(
      DiscoveryDownloadTask._(item: item, destinationDir: destinationDir),
    );
    notifyListeners();
    _pump();
    return true;
  }

  /// 取消任务：排队/退避中→直接移除；执行中→强关连接中止（`.part` 保留，
  /// 下次同条目续传）。已结束 no-op。
  void cancel(DiscoveryDownloadTask task) {
    if (task.isFinished) return;
    _retryTimers.remove(task)?.cancel();
    if (identical(task, _running)) {
      task._cancelRequested = true;
      // 强关底层连接让响应流立刻报错；没有活动连接（还在 resolve 阶段）时
      // 由 _run 收尾处的 _cancelRequested 检查兜住。
      task._client?.close(force: true);
      return;
    }
    _tasks.remove(task);
    notifyListeners();
  }

  /// 手动重试失败/已取消任务：**就地**复活（不新建行），自动重试预算清零。
  void retry(DiscoveryDownloadTask task) {
    if (task.status != DiscoveryDownloadStatus.failed &&
        task.status != DiscoveryDownloadStatus.cancelled) {
      return;
    }
    _resetForRetry(task);
    notifyListeners();
    _pump();
  }

  /// 批量复活一切失败/取消任务。返回真正复活的任务数。
  int retryAllFailed() {
    int revived = 0;
    for (final DiscoveryDownloadTask task in _tasks) {
      if (task.status != DiscoveryDownloadStatus.failed &&
          task.status != DiscoveryDownloadStatus.cancelled) {
        continue;
      }
      _resetForRetry(task);
      revived++;
    }
    if (revived > 0) {
      notifyListeners();
      _pump();
    }
    return revived;
  }

  void _resetForRetry(DiscoveryDownloadTask task) {
    task.status = DiscoveryDownloadStatus.queued;
    task.autoRetries = 0;
    task.error = null;
    task.receivedBytes = 0;
    task.totalBytes = null;
    task.importOutcome = null;
    task.skippedDownload = false;
    task._cancelRequested = false;
  }

  /// 清掉所有已结束任务（下载页「清除已完成」）。
  void clearFinished() {
    final int before = _tasks.length;
    _tasks.removeWhere((DiscoveryDownloadTask t) => t.isFinished);
    if (_tasks.length != before) notifyListeners();
  }

  void _pump() {
    if (_disposed || _running != null) return;
    DiscoveryDownloadTask? next;
    for (final DiscoveryDownloadTask t in _tasks) {
      if (t.status == DiscoveryDownloadStatus.queued) {
        next = t;
        break;
      }
    }
    if (next == null) return;
    final DiscoveryDownloadTask task = next;
    task.status = DiscoveryDownloadStatus.running;
    _running = task;
    notifyListeners();
    unawaited(_run(task));
  }

  Future<void> _run(DiscoveryDownloadTask task) async {
    Object? failure;
    bool failureRetryable = true;
    try {
      final DiscoveryPayload payload = await _resolvePayload(task.item);
      final DiscoveryHttpPayload http = switch (payload) {
        DiscoveryHttpPayload() => payload,
        DiscoveryTorrentPayload() => throw StateError(
            'source resolved a torrent payload for an httpFile item',
          ),
      };
      if (task._cancelRequested) throw const _DiscoveryDownloadCancelled();

      final File destination = File(
        '${task.destinationDir}${Platform.pathSeparator}'
        '${_resolveFileName(task.item, http)}',
      );
      File file;
      if (await destination.exists()) {
        // 上一轮已下完但导入失败的重试路径：不重下，直接重导。
        task.skippedDownload = true;
        task.receivedBytes = await destination.length();
        task.totalBytes = task.receivedBytes;
        file = destination;
      } else {
        await Directory(task.destinationDir).create(recursive: true);
        file = await _download(task, http, destination);
      }
      task.filePath = file.path;
      if (task._cancelRequested) throw const _DiscoveryDownloadCancelled();

      try {
        final DiscoveryImportOutcome outcome = await _importer(task, file);
        task.importOutcome = outcome;
        _importedCount += outcome.importedCount;
      } catch (e) {
        // 导入失败不自动重试：同一份坏数据重跑不会变好。
        failureRetryable = false;
        rethrow;
      }
    } catch (e) {
      failure = e;
    }
    _finish(task, error: failure, retryable: failureRetryable);
  }

  Future<File> _download(
    DiscoveryDownloadTask task,
    DiscoveryHttpPayload payload,
    File destination,
  ) async {
    final DiscoveryDownloadOpen open;
    HttpClient? client;
    if (_openOverride != null) {
      open = _openOverride;
    } else {
      client = createAppHttpClient();
      task._client = client;
      open = (Uri uri, Map<String, String> headers) =>
          _openViaHttpClient(client!, payload.headers, uri, headers);
    }
    try {
      final ResumableDownloader downloader = ResumableDownloader(
        url: payload.url,
        destination: destination,
        partFile: File('${destination.path}.part'),
        open: open,
        expectedSize: payload.sizeBytes,
        onProgress: (int received, int? total) {
          task.receivedBytes = received;
          task.totalBytes = total;
          _notifyProgress();
        },
      );
      return await downloader.download();
    } finally {
      task._client = null;
      client?.close(force: true);
    }
  }

  static Future<ResumableDownloadResponse> _openViaHttpClient(
    HttpClient client,
    Map<String, String> payloadHeaders,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest request = await client.getUrl(uri);
    request.followRedirects = true;
    request.maxRedirects = 8;
    payloadHeaders.forEach(request.headers.set);
    headers.forEach(request.headers.set);
    final HttpClientResponse response = await request.close();
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach(
      (String name, List<String> values) =>
          responseHeaders[name] = values.join(', '),
    );
    return ResumableDownloadResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      stream: response,
    );
  }

  /// 从 payload / URL / 条目标题推导落盘文件名（按此优先级取第一个可用者）。
  static String _resolveFileName(
    DiscoveryResourceItem item,
    DiscoveryHttpPayload payload,
  ) {
    String? candidate = payload.fileName;
    if (candidate == null || candidate.trim().isEmpty) {
      final Uri? uri = Uri.tryParse(payload.url);
      if (uri != null) {
        for (final String segment in uri.pathSegments.reversed) {
          if (segment.trim().isNotEmpty) {
            candidate = Uri.decodeComponent(segment);
            break;
          }
        }
      }
    }
    if (candidate == null || candidate.trim().isEmpty) candidate = item.title;
    return sanitizeDiscoveryFileName(candidate);
  }

  void _notifyProgress() {
    if (_disposed) return;
    final DateTime now = DateTime.now();
    if (now.difference(_lastProgressNotify) < _progressNotifyInterval) return;
    _lastProgressNotify = now;
    notifyListeners();
  }

  /// 任务收尾（以 `_running` 身份判重，只收一次）。
  void _finish(
    DiscoveryDownloadTask task, {
    Object? error,
    bool retryable = true,
  }) {
    if (!identical(task, _running)) return;
    _running = null;
    if (task._cancelRequested || error is _DiscoveryDownloadCancelled) {
      // 强关连接会让错误以各种网络异常形态上浮；只要用户请求过取消，一律
      // 归类为 cancelled（`.part` 已保留，重试即续传）。
      task.status = DiscoveryDownloadStatus.cancelled;
    } else if (error != null) {
      task.error = '$error';
      task.status = retryable && _scheduleAutoRetry(task, error)
          ? DiscoveryDownloadStatus.waitingRetry
          : DiscoveryDownloadStatus.failed;
    } else {
      task.status = DiscoveryDownloadStatus.done;
    }
    if (_disposed) return;
    notifyListeners();
    _pump();
  }

  /// 安排一次自动重试；false = 这个错误/这个任务不该再自动重试。
  bool _scheduleAutoRetry(DiscoveryDownloadTask task, Object error) {
    if (_disposed) return false;
    if (task.autoRetries >= _retryBackoff.length) return false;
    if (!_isTransientError(error)) return false;

    final Duration delay = _retryBackoff[task.autoRetries];
    task.autoRetries++;
    // 进度归零：重跑从 `.part` 续传点重新报字节。
    task.receivedBytes = 0;
    task.totalBytes = null;
    _retryTimers[task] = Timer(delay, () {
      _retryTimers.remove(task);
      if (_disposed || task.status != DiscoveryDownloadStatus.waitingRetry) {
        return;
      }
      task.status = DiscoveryDownloadStatus.queued;
      notifyListeners();
      _pump();
    });
    return true;
  }

  /// 值得自动重试的错误 = 瞬时网络/传输故障。HTTP 状态码只认 5xx/408/429
  /// （从 `ResumableDownloader` 的 HttpException 文案里提取）；404/403 这类
  /// 稳定结论、以及体积/哈希校验失败（数据错误）重试纯属白等。
  static bool _isTransientError(Object error) {
    if (error is ResumableDownloadIntegrityException) return false;
    if (error is HttpException) {
      final RegExpMatch? match =
          RegExp(r'download failed \((\d{3})\)').firstMatch(error.message);
      if (match != null) {
        final int code = int.parse(match.group(1)!);
        return code >= 500 || code == 408 || code == 429;
      }
      return true;
    }
    return error is SocketException ||
        error is TimeoutException ||
        error is TlsException;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final Timer timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    final DiscoveryDownloadTask? running = _running;
    if (running != null) {
      running._cancelRequested = true;
      running._client?.close(force: true);
    }
    super.dispose();
  }
}

/// 净化落盘文件名：去路径分隔与 Windows 非法字符、控制字符，压缩空白；
/// 空结果回退 'download'。顶层函数以便导入分派侧复用同一净化规则。
String sanitizeDiscoveryFileName(String name) {
  final String cleaned = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      // Windows 文件名不能以点/空格结尾；顺带把 '.'/'..' 这类纯点名归零。
      .replaceAll(RegExp(r'[. ]+$'), '');
  return cleaned.isEmpty ? 'download' : cleaned;
}

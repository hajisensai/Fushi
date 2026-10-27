/// 单章的 Kavita 进度上报：防抖 + 失败重试 + 读完标记 + 不覆盖更新的服务器进度。
///
/// 一个实例对应「正在读的一章」（漫画章或 EPUB），打开时建、关闭时先 [flush] 再
/// [dispose]。拉取侧的决策见 `kavita_progress_resolver.dart`，本类只管推。
///
/// - 翻页调 [reportPage]：同一章内只保留**最后一次**，停 [debounce] 后上报；
/// - 上报失败（离线 / 5xx）：保留待推状态，按 [retryBackoff] 递增重试，成功后复位；
/// - 与已推的页号相同则跳过（原地翻回不重复上报）；
/// - 读到最后一页：进度推成功后再 `mark-multiple-read`，读完标记失败也会重试；
/// - **不覆盖**：本实例没拉过服务器进度（[serverVerified] 为 false）时，首次推之前
///   先读一次服务器进度，若服务器自上次同步后被别处推进过且页号不同，拒绝推送并
///   通过 [onServerNewer] 交给 UI（用户裁决后调 [markServerVerified] 再推）。
library;

import 'dart:async';

import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';

class KavitaProgressTarget {
  const KavitaProgressTarget({
    required this.seriesId,
    required this.volumeId,
    required this.chapterId,
    required this.libraryId,
    required this.totalPages,
  });

  final int seriesId;
  final int volumeId;
  final int chapterId;
  final int libraryId;

  /// 本章总页数（用于判断读完）。
  final int totalPages;
}

/// 推送成功回调：页号 + 本地时刻，供调用方记进绑定 / 本地进度戳。
typedef KavitaPushedCallback =
    void Function(int page, String? bookScrollId, int pushedAtMs);

class KavitaProgressSync {
  KavitaProgressSync({
    required KavitaApi api,
    required this.target,
    this.debounce = const Duration(seconds: 10),
    this.retryBackoff = const <Duration>[
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(seconds: 120),
      Duration(seconds: 300),
    ],
    int? lastPushedPage,
    int? lastSyncAt,
    bool serverVerified = false,
    int Function()? nowMs,
    this.onPushed,
    this.onServerNewer,
  }) : _api = api,
       _lastPushedPage = lastPushedPage,
       _lastSyncAt = lastSyncAt,
       _serverVerified = serverVerified,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final KavitaApi _api;
  final KavitaProgressTarget target;
  final Duration debounce;
  final List<Duration> retryBackoff;
  final KavitaPushedCallback? onPushed;

  /// 拒绝推送时回调，参数是服务器当前进度。
  final void Function(KavitaProgress server)? onServerNewer;
  final int Function() _nowMs;

  int? _lastPushedPage;
  int? _lastSyncAt;
  bool _serverVerified;

  int? _pendingPage;
  String? _pendingScrollId;
  bool _needsMarkRead = false;
  int _failures = 0;
  Timer? _timer;
  Future<bool>? _inFlight;
  bool _disposed = false;

  bool get hasPending => _pendingPage != null || _needsMarkRead;
  int get failureCount => _failures;

  /// 用户已裁决（或已拉取并确认）：此后推送不再做「服务器更新」检查。
  void markServerVerified() => _serverVerified = true;

  /// 翻页上报（防抖）。
  void reportPage(int page, {String? bookScrollId}) {
    if (_disposed) return;
    if (page < 0) return;
    if (page == _lastPushedPage && !_needsMarkRead) {
      // 翻回已推的页：撤销可能排队的旧页。
      _pendingPage = null;
      _pendingScrollId = null;
      _timer?.cancel();
      return;
    }
    _pendingPage = page;
    _pendingScrollId = bookScrollId;
    _schedule(debounce);
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    _timer = Timer(after, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// 立即把待推进度推出去；返回是否已无待推（无事可做也算成功）。
  Future<bool> flush() {
    if (_disposed && !hasPending) return Future<bool>.value(true);
    return _inFlight ??= _flushOnce().whenComplete(() => _inFlight = null);
  }

  Future<bool> _flushOnce() async {
    _timer?.cancel();
    _timer = null;
    final int? page = _pendingPage;
    if (page == null && !_needsMarkRead) return true;
    final String? scrollId = _pendingScrollId;
    try {
      if (page != null) {
        if (!_serverVerified) {
          final KavitaProgress server = await _api.getProgress(
            target.chapterId,
          );
          if (_serverIsNewer(server, page)) {
            // 保持未校验：在用户裁决（[markServerVerified]）之前，之后每次推送都
            // 重新核对，绝不在下一次翻页时悄悄覆盖更新的服务器进度。
            _pendingPage = null;
            _pendingScrollId = null;
            onServerNewer?.call(server);
            return false;
          }
          _serverVerified = true;
        }
        await _api.saveProgress(
          KavitaProgress(
            volumeId: target.volumeId,
            chapterId: target.chapterId,
            pageNum: page,
            seriesId: target.seriesId,
            libraryId: target.libraryId,
            bookScrollId: scrollId,
          ),
        );
        _lastPushedPage = page;
        // 只清掉刚推出去的这一页；推送期间又翻页会写进 _pendingPage。
        if (_pendingPage == page) {
          _pendingPage = null;
          _pendingScrollId = null;
        }
        final int now = _nowMs();
        _lastSyncAt = now;
        if (isKavitaChapterFinished(
          page: page,
          totalPages: target.totalPages,
        )) {
          _needsMarkRead = true;
        }
        onPushed?.call(page, scrollId, now);
      }
      if (_needsMarkRead) {
        await _api.markChaptersRead(
          seriesId: target.seriesId,
          chapterIds: <int>[target.chapterId],
        );
        _needsMarkRead = false;
      }
      _failures = 0;
      // 推送期间若又有新页，继续排队。
      if (_pendingPage != null && !_disposed) _schedule(debounce);
      return !hasPending;
    } on Object {
      _failures++;
      if (!_disposed) {
        final int i = (_failures - 1).clamp(0, retryBackoff.length - 1);
        _schedule(retryBackoff[i]);
      }
      return false;
    }
  }

  bool _serverIsNewer(KavitaProgress server, int localPage) {
    if (server.pageNum == localPage) return false;
    final DateTime? modified = server.lastModifiedUtc;
    if (modified == null) return false; // 服务器没有这章记录
    final int? since = _lastSyncAt;
    if (since == null) {
      // 从没同步过：服务器有真实进度（>0 页）就不盲推，交给上层拉取流程裁决。
      return server.pageNum > 0;
    }
    return modified.millisecondsSinceEpoch >
        since + kKavitaClockSkewToleranceMs;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

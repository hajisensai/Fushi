/// 来源刮削的可观察任务状态。与 Widget 解耦，使批次在来源页/弹窗销毁后仍可继续。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';

enum VideoSourceScrapePhase {
  idle,
  planning,
  recognizing,
  fetching,
  applying,
  writingSidecars,
  completed,
  cancelled,
  interrupted,
  failed,
}

class SourceScrapeIssue {
  const SourceScrapeIssue({
    required this.workTitle,
    required this.message,
    this.path,
  });

  final String workTitle;
  final String message;
  final String? path;
}

class SourceScrapeReport {
  const SourceScrapeReport({
    required this.sourceIds,
    this.totalWorks = 0,
    this.succeededWorks = 0,
    this.failedWorks = 0,
    this.pendingConfirmations = 0,
    this.nfoWritten = 0,
    this.imagesWritten = 0,
    this.protectedArtifacts = 0,
    this.unchangedArtifacts = 0,
    this.warnings = const <SourceScrapeIssue>[],
    this.errors = const <SourceScrapeIssue>[],
    this.cancelled = false,
  });

  final List<int> sourceIds;
  final int totalWorks;
  final int succeededWorks;
  final int failedWorks;
  final int pendingConfirmations;
  final int nfoWritten;
  final int imagesWritten;
  final int protectedArtifacts;
  final int unchangedArtifacts;
  final List<SourceScrapeIssue> warnings;
  final List<SourceScrapeIssue> errors;
  final bool cancelled;

  SourceScrapeReport merge(SourceScrapeReport other) => SourceScrapeReport(
        sourceIds: <int>{...sourceIds, ...other.sourceIds}.toList()..sort(),
        totalWorks: totalWorks + other.totalWorks,
        succeededWorks: succeededWorks + other.succeededWorks,
        failedWorks: failedWorks + other.failedWorks,
        pendingConfirmations: pendingConfirmations + other.pendingConfirmations,
        nfoWritten: nfoWritten + other.nfoWritten,
        imagesWritten: imagesWritten + other.imagesWritten,
        protectedArtifacts: protectedArtifacts + other.protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts + other.unchangedArtifacts,
        warnings: <SourceScrapeIssue>[...warnings, ...other.warnings],
        errors: <SourceScrapeIssue>[...errors, ...other.errors],
        cancelled: cancelled || other.cancelled,
      );
}

class VideoSourceScrapeProgress {
  const VideoSourceScrapeProgress({
    this.phase = VideoSourceScrapePhase.idle,
    this.sourceId,
    this.sourceLabel,
    this.currentWorkTitle,
    this.current = 0,
    this.total = 0,
    this.report,
    this.message,
    this.confirmation,
  });

  final VideoSourceScrapePhase phase;
  final int? sourceId;
  final String? sourceLabel;
  final String? currentWorkTitle;
  final int current;
  final int total;
  final SourceScrapeReport? report;
  final String? message;
  final VideoSourceScrapeConfirmation? confirmation;

  bool get isRunning => switch (phase) {
        VideoSourceScrapePhase.planning ||
        VideoSourceScrapePhase.recognizing ||
        VideoSourceScrapePhase.fetching ||
        VideoSourceScrapePhase.applying ||
        VideoSourceScrapePhase.writingSidecars =>
          true,
        _ => false,
      };
}

/// 严格匹配仍有多个结果时展示给用户的候选。
class VideoSourceScrapeConfirmationCandidate {
  const VideoSourceScrapeConfirmationCandidate({
    required this.lookup,
    required this.work,
  });

  final VideoMetadataLookup lookup;
  final VideoMetadataWork work;
}

/// 一个暂停中的作品级人工确认请求。
class VideoSourceScrapeConfirmation {
  VideoSourceScrapeConfirmation({
    required this.sourceId,
    required this.sourceLabel,
    required this.localWorkTitle,
    required List<VideoSourceScrapeConfirmationCandidate> candidates,
  }) : candidates = List<VideoSourceScrapeConfirmationCandidate>.unmodifiable(
          candidates,
        );

  final int sourceId;
  final String sourceLabel;
  final String localWorkTitle;
  final List<VideoSourceScrapeConfirmationCandidate> candidates;
}

typedef VideoSourceScrapeConfirmationCallback
    = Future<VideoSourceScrapeConfirmationCandidate?> Function(
  VideoSourceScrapeConfirmation confirmation,
);

/// 一次“单来源/全部来源”用户批次内共享的作品解析结果。
///
/// 混来源合集在每个来源仍需各写自己的安全 sidecar，但在线识别和详情只做一次，
/// 后续来源复用首个确定结果，避免来源覆盖顺序改变作品资料。
class VideoSourceScrapeBatchContext {
  final Map<String, VideoMetadataWork> resolvedWorks =
      <String, VideoMetadataWork>{};

  /// 与 [resolvedWorks] 同生命周期保存季集响应是否完整。非权威响应只能补写，
  /// 不能让后续来源刮削误删前一轮已经持久化的完整季集骨架。
  final Map<String, bool> authoritativeSeasonEpisodes = <String, bool>{};
}

class VideoSourceScrapeCancellationToken {
  VideoSourceScrapeCancellationToken({
    this.allowProtectedOverwrite = false,
  });

  bool _cancelled = false;

  /// 仅由本次用户确认授予；来源设置本身不能绕过逐批危险确认。
  final bool allowProtectedOverwrite;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const VideoSourceScrapeCancelled();
  }
}

class VideoSourceScrapeCancelled implements Exception {
  const VideoSourceScrapeCancelled();
}

typedef VideoSourceScrapeProgressCallback = void Function(
  VideoSourceScrapeProgress progress,
);

abstract interface class VideoSourceScrapeRunner {
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
  });
}

abstract interface class VideoSourceScrapeInterruptible {
  Future<void> markActiveRunInterrupted();
}

/// App/HomePage 生命周期级控制器：所有入口共用一把锁，保证同一时刻只有一个联网
/// 批次。任务 Future 不属于弹窗，关闭弹窗或切换媒体库视图不会中止它。
class VideoSourceScrapeTaskController extends ChangeNotifier {
  VideoSourceScrapeTaskController(this._runner);

  final VideoSourceScrapeRunner _runner;
  VideoSourceScrapeCancellationToken? _token;
  Future<SourceScrapeReport>? _active;
  Completer<VideoSourceScrapeConfirmationCandidate?>? _confirmationCompleter;
  VideoSourceScrapeConfirmation? _pendingConfirmation;
  int? _scanningSourceId;
  bool _disposed = false;
  VideoSourceScrapeProgress _progress = const VideoSourceScrapeProgress();

  VideoSourceScrapeProgress get progress => _progress;
  bool get isRunning => _active != null;
  Future<SourceScrapeReport>? get activeTask => _active;
  VideoSourceScrapeConfirmation? get pendingConfirmation =>
      _pendingConfirmation;
  int? get scanningSourceId => _scanningSourceId;
  bool get isScanning => _scanningSourceId != null;
  bool get isBusy => isRunning || isScanning;

  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    bool interactive = false,
    bool allowProtectedOverwrite = false,
  }) =>
      _start(
        <SourceLibraryRow>[source],
        interactive: interactive,
        allowProtectedOverwrite: allowProtectedOverwrite,
      );

  Future<SourceScrapeReport> scrapeAllSources(
    Iterable<SourceLibraryRow> sources, {
    bool interactive = false,
    bool allowProtectedOverwrite = false,
  }) =>
      _start(
        sources.where((SourceLibraryRow source) =>
            source.mediaKind == 'video' && source.transport == 'local'),
        interactive: interactive,
        allowProtectedOverwrite: allowProtectedOverwrite,
      );

  /// 与联网刮削共用的应用级互斥门。扫描完成即释放，随后自动刮削可以顺序接棒。
  Future<T> runSourceScan<T>(
    int sourceId,
    Future<T> Function() operation,
  ) async {
    if (_disposed) throw StateError('视频来源任务控制器已释放');
    if (_active != null || _scanningSourceId != null) {
      throw StateError('已有视频来源扫描或刮削任务正在运行');
    }
    _scanningSourceId = sourceId;
    notifyListeners();
    try {
      return await operation();
    } finally {
      if (_scanningSourceId == sourceId) _scanningSourceId = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<SourceScrapeReport> _start(
    Iterable<SourceLibraryRow> sourceIterable, {
    required bool interactive,
    required bool allowProtectedOverwrite,
  }) {
    if (_disposed) {
      return Future<SourceScrapeReport>.error(
        StateError('视频来源任务控制器已释放'),
      );
    }
    final Future<SourceScrapeReport>? running = _active;
    if (running != null) return running;
    if (_scanningSourceId != null) {
      return Future<SourceScrapeReport>.error(
        StateError('视频来源扫描尚未完成'),
      );
    }
    final List<SourceLibraryRow> sources =
        sourceIterable.toList(growable: false);
    final VideoSourceScrapeCancellationToken token =
        VideoSourceScrapeCancellationToken(
      allowProtectedOverwrite: allowProtectedOverwrite,
    );
    _token = token;
    _progress = const VideoSourceScrapeProgress(
      phase: VideoSourceScrapePhase.planning,
    );
    final Future<SourceScrapeReport> future = _run(
      sources,
      token,
      interactive: interactive,
    );
    _active = future;
    // 后台入口依赖 listener 立即展示全局任务按钮；必须在 _active 就绪后通知，
    // 否则监听者会在 planning 阶段读到 isBusy=false，直到下一条网络进度才出现。
    notifyListeners();
    void clear() {
      if (identical(_active, future)) {
        _active = null;
        _token = null;
        _clearPendingConfirmation();
        if (!_disposed) notifyListeners();
      }
    }

    future.then<void>((_) => clear(), onError: (_, __) => clear());
    return future;
  }

  Future<SourceScrapeReport> _run(
    List<SourceLibraryRow> sources,
    VideoSourceScrapeCancellationToken token, {
    required bool interactive,
  }) async {
    SourceScrapeReport aggregate = SourceScrapeReport(
      sourceIds: <int>[
        for (final SourceLibraryRow source in sources) source.id
      ],
    );
    final VideoSourceScrapeBatchContext batchContext =
        VideoSourceScrapeBatchContext();
    try {
      for (final SourceLibraryRow source in sources) {
        token.throwIfCancelled();
        final SourceScrapeReport report = await _runner.scrapeSource(
          source,
          cancellationToken: token,
          onProgress: _publish,
          onConfirmation: interactive ? _requestConfirmation : null,
          batchContext: batchContext,
        );
        aggregate = aggregate.merge(report);
      }
      _publish(VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.completed,
        current: aggregate.totalWorks,
        total: aggregate.totalWorks,
        report: aggregate,
      ));
      return aggregate;
    } on VideoSourceScrapeCancelled {
      aggregate = SourceScrapeReport(
        sourceIds: aggregate.sourceIds,
        totalWorks: aggregate.totalWorks,
        succeededWorks: aggregate.succeededWorks,
        failedWorks: aggregate.failedWorks,
        pendingConfirmations: aggregate.pendingConfirmations,
        nfoWritten: aggregate.nfoWritten,
        imagesWritten: aggregate.imagesWritten,
        protectedArtifacts: aggregate.protectedArtifacts,
        unchangedArtifacts: aggregate.unchangedArtifacts,
        warnings: aggregate.warnings,
        errors: aggregate.errors,
        cancelled: true,
      );
      _publish(VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.cancelled,
        report: aggregate,
      ));
      return aggregate;
    } catch (error) {
      _publish(VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.failed,
        report: aggregate,
        message: error.toString(),
      ));
      rethrow;
    }
  }

  void _publish(VideoSourceScrapeProgress next) {
    if (_disposed) return;
    _progress = next;
    notifyListeners();
  }

  Future<VideoSourceScrapeConfirmationCandidate?> _requestConfirmation(
    VideoSourceScrapeConfirmation confirmation,
  ) {
    if (_disposed || _token?.isCancelled == true) {
      return Future<VideoSourceScrapeConfirmationCandidate?>.value();
    }
    final Completer<VideoSourceScrapeConfirmationCandidate?> completer =
        Completer<VideoSourceScrapeConfirmationCandidate?>();
    _confirmationCompleter = completer;
    _pendingConfirmation = confirmation;
    _progress = VideoSourceScrapeProgress(
      phase: VideoSourceScrapePhase.recognizing,
      sourceId: confirmation.sourceId,
      sourceLabel: confirmation.sourceLabel,
      currentWorkTitle: confirmation.localWorkTitle,
      current: _progress.current,
      total: _progress.total,
      confirmation: confirmation,
    );
    notifyListeners();
    return completer.future.whenComplete(_clearPendingConfirmation);
  }

  void confirmPending(
    VideoSourceScrapeConfirmationCandidate candidate,
  ) {
    final Completer<VideoSourceScrapeConfirmationCandidate?>? completer =
        _confirmationCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(candidate);
    }
  }

  void skipPendingConfirmation() {
    final Completer<VideoSourceScrapeConfirmationCandidate?>? completer =
        _confirmationCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _clearPendingConfirmation() {
    _confirmationCompleter = null;
    _pendingConfirmation = null;
    if (!_disposed) notifyListeners();
  }

  void cancel() {
    _token?.cancel();
    skipPendingConfirmation();
  }

  /// 应用退出/数据库关闭前调用。网络请求无法保证立刻被底层 socket 取消，但下一阶段
  /// 边界会停止；持久 run 由 runner 标成 interrupted。
  void markInterrupted() {
    cancel();
    if (_runner case final VideoSourceScrapeInterruptible interruptible) {
      unawaited(interruptible.markActiveRunInterrupted());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _token?.cancel();
    final Completer<VideoSourceScrapeConfirmationCandidate?>? completer =
        _confirmationCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _confirmationCompleter = null;
    _pendingConfirmation = null;
    super.dispose();
  }
}

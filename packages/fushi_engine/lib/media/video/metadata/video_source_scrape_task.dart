/// 来源刮削的可观察任务状态。与 Widget 解耦，使批次在来源页/弹窗销毁后仍可继续。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';

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

/// `video_source_scrape_runs.summaryJson` 的唯一 wire 形状。
///
/// 编解码放在一起：这份 JSON 是**跑完之后**唯一还留着的、逐条作品级事实
/// （哪个作品待确认、哪个失败、失败原因是什么）。协调器写它、历史面板读它，
/// 两侧共用同一份定义，避免字段名各写一次而悄悄漂开。
String encodeSourceScrapeReport(SourceScrapeReport report) => jsonEncode(
      <String, Object?>{
        'sourceIds': report.sourceIds,
        'totalWorks': report.totalWorks,
        'succeededWorks': report.succeededWorks,
        'failedWorks': report.failedWorks,
        'pendingConfirmations': report.pendingConfirmations,
        'nfoWritten': report.nfoWritten,
        'imagesWritten': report.imagesWritten,
        'protectedArtifacts': report.protectedArtifacts,
        'unchangedArtifacts': report.unchangedArtifacts,
        'cancelled': report.cancelled,
        'warnings': _encodeIssues(report.warnings),
        'errors': _encodeIssues(report.errors),
      },
    );

List<Map<String, Object?>> _encodeIssues(List<SourceScrapeIssue> issues) =>
    <Map<String, Object?>>[
      for (final SourceScrapeIssue issue in issues)
        <String, Object?>{
          'work': issue.workTitle,
          'message': issue.message,
          if (issue.path != null) 'path': issue.path,
        },
    ];

/// 解析历史 run 的 summaryJson。任何损坏或缺字段都退化成 null / 空列表，
/// 绝不让一条陈旧记录把历史面板整段炸掉。
SourceScrapeReport? decodeSourceScrapeReport(String? json) {
  if (json == null || json.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final Map<String, Object?> map = decoded;
  int intAt(String key) {
    final Object? value = map[key];
    return value is int ? value : 0;
  }

  return SourceScrapeReport(
    sourceIds: <int>[
      for (final Object? id
          in map['sourceIds'] as List<Object?>? ?? const <Object?>[])
        if (id is int) id,
    ],
    totalWorks: intAt('totalWorks'),
    succeededWorks: intAt('succeededWorks'),
    failedWorks: intAt('failedWorks'),
    pendingConfirmations: intAt('pendingConfirmations'),
    nfoWritten: intAt('nfoWritten'),
    imagesWritten: intAt('imagesWritten'),
    protectedArtifacts: intAt('protectedArtifacts'),
    unchangedArtifacts: intAt('unchangedArtifacts'),
    warnings: _decodeIssues(map['warnings']),
    errors: _decodeIssues(map['errors']),
    cancelled: map['cancelled'] == true,
  );
}

List<SourceScrapeIssue> _decodeIssues(Object? raw) => <SourceScrapeIssue>[
      if (raw is List<Object?>)
        for (final Object? entry in raw)
          if (entry is Map<String, Object?>)
            SourceScrapeIssue(
              workTitle: entry['work'] as String? ?? '',
              message: entry['message'] as String? ?? '',
              path: entry['path'] as String?,
            ),
    ];

/// 这次 run 是否还留着**没定下身份的作品**。
///
/// 判据只看事实，不看 run 状态：一次 `completed` 的批次照样可能留下待确认或失败
/// 的作品（自动刮削没有确认回调，歧义作品只会被计数后跳过）。历史面板早先按
/// `status ∈ {failed, interrupted, cancelled}` 给重刮入口，正好把用户唯一想处理的
/// 那种 run —— 「已完成，但待确认 2、失败 4」—— 挡在门外（BUG-1721）。
bool scrapeRunHasUnresolvedWorks(VideoSourceScrapeRunRow run) =>
    run.pendingConfirmations > 0 ||
    run.failedWorks > 0 ||
    const <String>{'failed', 'interrupted', 'cancelled'}.contains(run.status);

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
  /// [plannedWorks] 非空时只处理这个子集（库内自动补刮传「未识别作品」），
  /// 为空时由 runner 自己按来源计划全量展开；[runScope] 落进 run 审计行。
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  });
}

abstract interface class VideoSourceScrapeInterruptible {
  Future<void> markActiveRunInterrupted();
}

/// 计划里已经没有这个作品了（文件被删、重命名或从来源移出）。
class VideoSourceScrapeWorkNotFound implements Exception {
  const VideoSourceScrapeWorkNotFound(this.workTitle);

  final String workTitle;

  @override
  String toString() => 'VideoSourceScrapeWorkNotFound($workTitle)';
}

/// 旧历史没有稳定键，同名记录不足以决定要修改哪一个真实条目。
class VideoSourceScrapeWorkAmbiguous extends VideoSourceScrapeWorkNotFound {
  const VideoSourceScrapeWorkAmbiguous(super.workTitle);
}

/// 为「跑完之后身份仍未定」的单个作品手动指定资料源作品。
///
/// 批次内确认（[VideoSourceScrapeConfirmationCallback]）只在交互式 run 期间存在，
/// run 一结束候选就没了；而自动刮削根本没有确认回调，歧义作品只留下一个计数。
/// 这个能力把「事后为某个作品选一个 lookup」补上，并且**刻意不新开落库路径**：
/// [rescrapeWorkWithLookup] 把选中的 lookup 当作已确认身份塞回来源刮削管线，
/// 与批次内确认、与下载导入后的精确刮削共用同一条 `_store.apply` 写入。
abstract interface class VideoSourceScrapeManualBinding {
  /// 按用户输入的标题在资料源里搜索候选。作品的剧集/电影形态由来源计划决定，
  /// 调用方不需要（也不应该）自己猜。
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  });

  /// 拉取 [lookup] 指向作品的完整资料（候选搜索结果只是摘要）。provider 不可用
  /// 返回 null。互联 7b「客户端代 host 刮削」用它拿到要回写的完整模型。
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup);

  /// 按 [lookup] 重刮 [workTitle] 这一个作品。作品不在当前来源计划里时抛
  /// [VideoSourceScrapeWorkNotFound]。
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  });
}

/// 一条排队中的「手动指定作品」请求。
///
/// 手动重刮与批次刮削共用同一把互斥门（同样联网、同样受 AniDB 限流、同样写库与
/// sidecar），所以它不能并行；但「不能并行」不等于「必须拒绝」——早先第二条请求
/// 直接抛 StateError，UI 只好把所有条目的搜索按钮一起灰掉，用户被迫盯着一条刮完
/// 才能点下一条。排队后串行执行，用户可以一口气把整屏未识别作品都指定完。
class VideoSourceScrapeManualRequest {
  VideoSourceScrapeManualRequest({
    required this.source,
    required this.workTitle,
    this.workStableKey,
    required this.lookup,
  });

  final SourceLibraryRow source;
  final String workTitle;
  final String? workStableKey;
  final VideoMetadataLookup lookup;
  final Completer<SourceScrapeReport> completer =
      Completer<SourceScrapeReport>();

  /// 当前计划按稳定键识别作品；历史记录没有键时才沿用标题。
  bool matches({
    required int sourceId,
    required String workTitle,
    String? workStableKey,
  }) =>
      source.id == sourceId &&
      (workStableKey != null
          ? this.workStableKey == workStableKey
          : this.workTitle == workTitle);
}

/// App/HomePage 生命周期级控制器：所有入口共用一把锁，保证同一时刻只有一个联网
/// 批次。任务 Future 不属于弹窗，关闭弹窗或切换媒体库视图不会中止它。
class VideoSourceScrapeTaskController extends EngineChangeNotifier {
  VideoSourceScrapeTaskController(this._runner);

  final VideoSourceScrapeRunner _runner;
  VideoSourceScrapeCancellationToken? _token;
  Future<SourceScrapeReport>? _active;
  Completer<VideoSourceScrapeConfirmationCandidate?>? _confirmationCompleter;
  VideoSourceScrapeConfirmation? _pendingConfirmation;
  int? _scanningSourceId;
  bool _disposed = false;
  VideoSourceScrapeProgress _progress = const VideoSourceScrapeProgress();

  /// 等待执行的手动重刮请求（FIFO）。批次跑着时也可以往里塞，批次结束后接棒。
  final List<VideoSourceScrapeManualRequest> _manualQueue =
      <VideoSourceScrapeManualRequest>[];

  /// 正在执行的那一条手动重刮；批次刮削期间为 null。
  VideoSourceScrapeManualRequest? _activeManualRequest;

  VideoSourceScrapeProgress get progress => _progress;
  bool get isRunning => _active != null;
  Future<SourceScrapeReport>? get activeTask => _active;
  VideoSourceScrapeConfirmation? get pendingConfirmation =>
      _pendingConfirmation;
  int? get scanningSourceId => _scanningSourceId;
  bool get isScanning => _scanningSourceId != null;
  bool get isBusy => isRunning || isScanning;

  /// 正在执行的手动重刮请求（没有则为 null）。
  VideoSourceScrapeManualRequest? get activeManualRequest =>
      _activeManualRequest;

  /// 还在排队、尚未开始的手动重刮请求数。
  int get queuedManualRequestCount => _manualQueue.length;

  /// 只读队列快照，任务面板关闭后重开仍能显示每一条待执行请求。
  List<VideoSourceScrapeManualRequest> get queuedManualRequests =>
      List<VideoSourceScrapeManualRequest>.unmodifiable(_manualQueue);

  /// 只撤回尚未执行的请求，不中断当前作品或其它排队任务。
  bool cancelQueuedManualRequest(VideoSourceScrapeManualRequest request) {
    if (_disposed || !_manualQueue.remove(request)) return false;
    request.completer.completeError(
      const VideoSourceScrapeCancelled(),
      StackTrace.current,
    );
    notifyListeners();
    return true;
  }

  /// 该作品是否已提交手动重刮（正在跑或还在队列里）。UI 据此把单条标成忙，
  /// 而不是把整屏按钮一起灰掉。
  bool isManualRequestPending({
    required int sourceId,
    required String workTitle,
    String? workStableKey,
  }) =>
      _activeManualRequest?.matches(
              sourceId: sourceId,
              workTitle: workTitle,
              workStableKey: workStableKey) ==
          true ||
      _manualQueue.any((VideoSourceScrapeManualRequest request) =>
          request.matches(
              sourceId: sourceId,
              workTitle: workTitle,
              workStableKey: workStableKey));

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

  /// 库内自动补刮批次：只刮各来源给定的「未识别作品」子集，run 记
  /// scope='sweep'。与手动批次共用同一把互斥门、同一个进度面板；已有批次在
  /// 跑时直接返回那个批次（不排队），由调用方先看 [isBusy] 决定要不要发起。
  Future<SourceScrapeReport> scrapeWorkSubsets(
    Map<SourceLibraryRow, List<VideoSourceScrapeWork>> worksBySource,
  ) =>
      _start(
        worksBySource.keys.where((SourceLibraryRow source) =>
            source.mediaKind == 'video' && source.transport == 'local'),
        interactive: false,
        allowProtectedOverwrite: false,
        plannedWorksBySource: <int, List<VideoSourceScrapeWork>>{
          for (final MapEntry<SourceLibraryRow,
              List<VideoSourceScrapeWork>> entry in worksBySource.entries)
            entry.key.id: entry.value,
        },
        runScope: 'sweep',
      );

  /// 当前 runner 是否支持事后手动指定作品。
  bool get supportsManualBinding => _runner is VideoSourceScrapeManualBinding;

  /// 只读的候选搜索：不写库、不抢刮削互斥门，用户可以在批次跑着时先查。
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) {
    if (_disposed || _runner is! VideoSourceScrapeManualBinding) {
      return Future<List<VideoSourceScrapeConfirmationCandidate>>.value(
        const <VideoSourceScrapeConfirmationCandidate>[],
      );
    }
    return (_runner as VideoSourceScrapeManualBinding).searchManualCandidates(
      source: source,
      workTitle: workTitle,
      workStableKey: workStableKey,
      query: query,
    );
  }

  /// 拉取 [lookup] 的完整作品资料（7b 回写用）；实现不支持手动绑定时返回 null。
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) {
    if (_disposed || _runner is! VideoSourceScrapeManualBinding) {
      return Future<VideoMetadataWork?>.value(null);
    }
    return (_runner as VideoSourceScrapeManualBinding)
        .fetchWorkForLookup(lookup);
  }

  /// 按用户手动选中的身份重刮单个作品。
  ///
  /// 与批次共用同一把互斥门——它同样联网、同样写库、同样写 sidecar，不能和批次
  /// 并行跑。但重复提交不再被拒绝：请求进 FIFO 队列，门一空就按提交顺序接棒，
  /// 所以用户可以连着指定多个作品而不必等前一条刮完（返回的 Future 仍然对应
  /// 调用方自己那一条的结果）。
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
  }) {
    if (_disposed) {
      return Future<SourceScrapeReport>.error(
        StateError('视频来源任务控制器已释放'),
      );
    }
    if (_runner is! VideoSourceScrapeManualBinding) {
      return Future<SourceScrapeReport>.error(
        StateError('当前刮削实现不支持手动指定作品'),
      );
    }
    final VideoSourceScrapeManualRequest request =
        VideoSourceScrapeManualRequest(
      source: source,
      workTitle: workTitle,
      workStableKey: workStableKey,
      lookup: lookup,
    );
    _manualQueue.add(request);
    if (!_disposed) notifyListeners();
    _pumpManualQueue();
    return request.completer.future;
  }

  /// 队列泵：门空了就取队首执行；门被批次或扫描占着就什么也不做——它们的收尾
  /// 会再调一次本方法接棒。
  void _pumpManualQueue() {
    if (_disposed || _manualQueue.isEmpty) return;
    if (_active != null || _scanningSourceId != null) return;
    final VideoSourceScrapeManualBinding runner =
        _runner as VideoSourceScrapeManualBinding;
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) {
      // 资料清理期间整条队列都跑不了，逐条报错比让它们无限期挂着诚实。
      _failQueuedManualRequests(StateError('视频刮削资料正在清理'));
      return;
    }
    final VideoSourceScrapeManualRequest request = _manualQueue.removeAt(0);
    final VideoSourceScrapeCancellationToken token =
        VideoSourceScrapeCancellationToken();
    _token = token;
    _activeManualRequest = request;
    _progress = VideoSourceScrapeProgress(
      phase: VideoSourceScrapePhase.planning,
      sourceId: request.source.id,
      sourceLabel: request.source.label,
      currentWorkTitle: request.workTitle,
      total: 1,
    );
    final Future<SourceScrapeReport> future = _runManualRescrape(
      runner,
      source: request.source,
      workTitle: request.workTitle,
      workStableKey: request.workStableKey,
      lookup: request.lookup,
      token: token,
    );
    _active = future;
    notifyListeners();
    void clear() {
      lease.release();
      if (identical(_active, future)) {
        _active = null;
        _token = null;
        _activeManualRequest = null;
        _clearPendingConfirmation();
        if (!_disposed) notifyListeners();
      }
      _pumpManualQueue();
    }

    future.then<void>(
      (SourceScrapeReport report) {
        if (!request.completer.isCompleted) request.completer.complete(report);
        clear();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!request.completer.isCompleted) {
          request.completer.completeError(error, stackTrace);
        }
        clear();
      },
    );
  }

  /// 清空队列并把每条请求以 [error] 结束。取消、释放和门不可用都走这里，
  /// 保证调用方的 Future 不会永远挂着。
  void _failQueuedManualRequests(Object error) {
    if (_manualQueue.isEmpty) return;
    final List<VideoSourceScrapeManualRequest> pending =
        List<VideoSourceScrapeManualRequest>.of(_manualQueue);
    _manualQueue.clear();
    for (final VideoSourceScrapeManualRequest request in pending) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, StackTrace.current);
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// 与联网刮削共用的应用级互斥门。扫描完成即释放，随后自动刮削可以顺序接棒。
  Future<T> runSourceScan<T>(
    int sourceId,
    Future<T> Function() operation,
  ) async {
    if (_disposed) throw StateError('视频来源任务控制器已释放');
    if (_active != null || _scanningSourceId != null) {
      throw StateError('已有视频来源扫描或刮削任务正在运行');
    }
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) throw StateError('视频刮削资料正在清理');
    _scanningSourceId = sourceId;
    notifyListeners();
    try {
      return await operation();
    } finally {
      if (_scanningSourceId == sourceId) _scanningSourceId = null;
      lease.release();
      if (!_disposed) notifyListeners();
      _pumpManualQueue();
    }
  }

  Future<SourceScrapeReport> _start(
    Iterable<SourceLibraryRow> sourceIterable, {
    required bool interactive,
    required bool allowProtectedOverwrite,
    Map<int, List<VideoSourceScrapeWork>>? plannedWorksBySource,
    String runScope = 'source',
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
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) {
      return Future<SourceScrapeReport>.error(
        StateError('视频刮削资料正在清理'),
      );
    }
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
      plannedWorksBySource: plannedWorksBySource,
      runScope: runScope,
    );
    _active = future;
    // 后台入口依赖 listener 立即展示全局任务按钮；必须在 _active 就绪后通知，
    // 否则监听者会在 planning 阶段读到 isBusy=false，直到下一条网络进度才出现。
    notifyListeners();
    void clear() {
      lease.release();
      if (identical(_active, future)) {
        _active = null;
        _token = null;
        _clearPendingConfirmation();
        if (!_disposed) notifyListeners();
      }
      // 批次占门期间用户可能已经手动指定了几个作品：门一空立刻接棒，
      // 不要等下一次用户交互才把队列跑起来。
      _pumpManualQueue();
    }

    future.then<void>((_) => clear(), onError: (_, __) => clear());
    return future;
  }

  Future<SourceScrapeReport> _run(
    List<SourceLibraryRow> sources,
    VideoSourceScrapeCancellationToken token, {
    required bool interactive,
    Map<int, List<VideoSourceScrapeWork>>? plannedWorksBySource,
    String runScope = 'source',
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
          plannedWorks: plannedWorksBySource?[source.id],
          runScope: runScope,
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

  /// 单作品重刮的终态发布。与批次 [_run] 的收尾保持一致：面板照样能看到
  /// 「已完成 / 失败」和这次的报告，而不是停在最后一条中间进度上。
  Future<SourceScrapeReport> _runManualRescrape(
    VideoSourceScrapeManualBinding runner, {
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken token,
  }) async {
    try {
      final SourceScrapeReport report = await runner.rescrapeWorkWithLookup(
        source: source,
        workTitle: workTitle,
        workStableKey: workStableKey,
        lookup: lookup,
        cancellationToken: token,
        onProgress: _publish,
      );
      _publish(VideoSourceScrapeProgress(
        phase: report.cancelled
            ? VideoSourceScrapePhase.cancelled
            : VideoSourceScrapePhase.completed,
        sourceId: source.id,
        sourceLabel: source.label,
        current: report.totalWorks,
        total: report.totalWorks,
        report: report,
      ));
      return report;
    } on VideoSourceScrapeCancelled {
      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        cancelled: true,
      );
      _publish(VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.cancelled,
        sourceId: source.id,
        sourceLabel: source.label,
        report: report,
      ));
      return report;
    } catch (error) {
      _publish(VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.failed,
        sourceId: source.id,
        sourceLabel: source.label,
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
    // 取消是「停下现在这批刮削」，还没轮到的手动请求一并作废，否则取消完
    // 队列会自己接着跑起来，用户看到的是「取消了个寂寞」。
    _failQueuedManualRequests(const VideoSourceScrapeCancelled());
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
    _failQueuedManualRequests(StateError('视频来源任务控制器已释放'));
    final Completer<VideoSourceScrapeConfirmationCandidate?>? completer =
        _confirmationCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _confirmationCompleter = null;
    _pendingConfirmation = null;
    super.dispose();
  }
}

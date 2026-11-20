/// 漫画演出标注的进程级后台任务（[MangaAnnotateTasks]）：单卷标注、按失败账本重试、
/// 按系列跑里的每一卷都在这里跑，按 bookKey 一卷至多一个运行中任务。
///
/// - 任务不属于任何页面：复核页只是观察者，打开时接上正在跑的任务显示进度，离开页面
///   任务照跑，只有显式 [MangaAnnotateTasks.cancel] 才停（已标的页随时落盘）。
/// - 不依赖 BuildContext：上传同意、预估确认这类交互留在发起方（复核页 / AI 操作目录
///   的确认流程），注册表只接收已确认的 [MangaAnnotateRequest]。
/// - 整卷跑完（成功 / 取消 / 中止 / 失败）经 [MangaAnnotateTasks.onSettled] 告诉用户：
///   [mangaAnnotateTasksFor] 装的是全局 toast，页面在不在都看得到；按系列跑的卷用
///   `announce: false` 起，由按系列跑自己汇总。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 一次标注要做什么（已经过同意 / 预估确认）。
class MangaAnnotateRequest {
  /// 标注：[pages] = 要标的页（null = 跑时取还没标过的页，OCR 过期则整卷）；
  /// [withRoster] = 先跑角色表（null = 本卷还没标过或已过期时才跑）。
  const MangaAnnotateRequest.annotate({
    required this.bookKey,
    required this.provider,
    this.pages,
    this.withRoster,
  }) : failure = null;

  /// 按账本重试一处失败；[provider] 换成别家即「切配置重试」。
  const MangaAnnotateRequest.retry({
    required this.bookKey,
    required this.provider,
    required MangaAnnotateFailure this.failure,
  }) : pages = null,
       withRoster = null;

  final String bookKey;
  final AiProviderConfig provider;
  final List<int>? pages;
  final bool? withRoster;

  /// 非 null = 重试这一处失败。
  final MangaAnnotateFailure? failure;

  bool get isRetry => failure != null;
}

/// 任务状态。
enum MangaAnnotateTaskStatus {
  running,

  /// 跑完（可能仍有失败页，见 [MangaAnnotateRunSummary.failedPages]）。
  completed,

  /// 用户取消（已标的页已落盘）。
  cancelled,

  /// 整次中止：鉴权失败 / 4xx 这类非临时失败（[MangaAnnotateTask.errorCode] = AI 短码）。
  aborted,

  /// 没法开始（[MangaAudioAnnotateError] 的码）或内部错误（`internal`）。
  failed;

  bool get isFinished => this != MangaAnnotateTaskStatus.running;
}

/// 同一卷已有运行中的任务（[running]）。
class MangaAnnotateBusy implements Exception {
  const MangaAnnotateBusy(this.running);
  final MangaAnnotateTask running;

  @override
  String toString() => 'MangaAnnotateBusy(${running.bookKey})';
}

/// 运行体向任务回报进度的口子（只给 [MangaAnnotateTaskRunner] 用）。
final class MangaAnnotateTaskSink {
  MangaAnnotateTaskSink._(this._task);
  final MangaAnnotateTask _task;

  void title(String title) => _task._setTitle(title);

  void progress(MangaAnnotatePhase phase, int done, int total) =>
      _task._setProgress(phase, done, total);

  void failures(List<MangaAnnotateFailure> failures) =>
      _task._setFailures(failures);
}

/// 真正跑一次标注；整次中止抛 [MangaAnnotateAbort]，开不了抛 [MangaAudioAnnotateError]。
typedef MangaAnnotateTaskRunner =
    Future<MangaAnnotateRunSummary> Function(
      MangaAnnotateRequest request,
      MangaAnnotateTaskSink sink,
      bool Function() isCancelled,
    );

/// 一卷的一次标注任务。进度 / 阶段 / 失败账本 / 结束都 [notifyListeners]。
class MangaAnnotateTask extends ChangeNotifier {
  MangaAnnotateTask._(this.request, {required this.announce})
    : startedAt = DateTime.now();

  final MangaAnnotateRequest request;

  /// 结束时是否由注册表告诉用户（按系列跑的卷为 false）。
  final bool announce;
  final DateTime startedAt;
  DateTime? finishedAt;

  String get bookKey => request.bookKey;

  /// 卷标题（会话打开后才有；之前为空）。
  String get title => _title;
  String _title = '';

  /// 当前阶段；还没开始回报时为 null。
  MangaAnnotatePhase? get phase => _phase;
  MangaAnnotatePhase? _phase;
  int get progressDone => _done;
  int _done = 0;
  int get progressTotal => _total;
  int _total = 0;

  /// 本卷失败账本（最近一次回报的快照，按阶段、页排序）。
  List<MangaAnnotateFailure> get failures => _failures;
  List<MangaAnnotateFailure> _failures = const <MangaAnnotateFailure>[];

  MangaAnnotateTaskStatus get status => _status;
  MangaAnnotateTaskStatus _status = MangaAnnotateTaskStatus.running;

  /// 跑完（[MangaAnnotateTaskStatus.completed]，取消在跑完之后才生效时也有）的摘要。
  MangaAnnotateRunSummary? get summary => _summary;
  MangaAnnotateRunSummary? _summary;

  /// [MangaAnnotateTaskStatus.aborted] / [MangaAnnotateTaskStatus.failed] 的短码。
  String? get errorCode => _errorCode;
  String? _errorCode;

  bool get cancelRequested => _cancelRequested;
  bool _cancelRequested = false;

  bool get isRunning => _status == MangaAnnotateTaskStatus.running;

  final Completer<void> _finished = Completer<void>();

  /// 任务结束（任何状态）时完成；不会以错误完成。
  Future<void> get finished => _finished.future;

  void _notify() => notifyListeners();

  void _setTitle(String title) {
    _title = title;
    _notify();
  }

  void _setProgress(MangaAnnotatePhase phase, int done, int total) {
    _phase = phase;
    _done = done;
    _total = total;
    _notify();
  }

  void _setFailures(List<MangaAnnotateFailure> failures) {
    _failures = List<MangaAnnotateFailure>.unmodifiable(failures);
    _notify();
  }

  bool _requestCancel() {
    if (!isRunning || _cancelRequested) return false;
    _cancelRequested = true;
    _notify();
    return true;
  }

  void _finish(
    MangaAnnotateTaskStatus status, {
    MangaAnnotateRunSummary? summary,
    String? errorCode,
  }) {
    _status = status;
    _summary = summary;
    _errorCode = errorCode;
    finishedAt = DateTime.now();
    _notify();
    _finished.complete();
  }
}

/// 进程级漫画标注任务表。注册表本身在任务开始 / 结束时 [notifyListeners]；单个任务的
/// 进度听 [MangaAnnotateTask]。
class MangaAnnotateTasks extends ChangeNotifier {
  MangaAnnotateTasks({required MangaAnnotateTaskRunner runner, this.onSettled})
    : _runner = runner;

  final MangaAnnotateTaskRunner _runner;

  /// 任务结束且 [MangaAnnotateTask.announce] 时调用（告诉用户结果）。
  final void Function(MangaAnnotateTask task)? onSettled;

  /// 每卷最近一次任务（运行中或已结束，留着给「查状态」）。
  final Map<String, MangaAnnotateTask> _latest = <String, MangaAnnotateTask>{};

  /// 这一卷最近一次任务（运行中或已结束）；从没跑过为 null。
  MangaAnnotateTask? taskFor(String bookKey) => _latest[bookKey];

  /// 这一卷正在跑的任务。
  MangaAnnotateTask? runningFor(String bookKey) {
    final MangaAnnotateTask? task = _latest[bookKey];
    return task != null && task.isRunning ? task : null;
  }

  bool isRunning(String bookKey) => runningFor(bookKey) != null;

  /// 所有运行中的任务。
  List<MangaAnnotateTask> get running => <MangaAnnotateTask>[
    for (final MangaAnnotateTask t in _latest.values)
      if (t.isRunning) t,
  ];

  /// 发起一次标注。同卷已有运行中的任务抛 [MangaAnnotateBusy]（不排队、不并行标同一卷）。
  /// [announce] = 结束时经 [onSettled] 告诉用户。
  MangaAnnotateTask start(
    MangaAnnotateRequest request, {
    bool announce = true,
  }) {
    final MangaAnnotateTask? busy = runningFor(request.bookKey);
    if (busy != null) throw MangaAnnotateBusy(busy);
    final MangaAnnotateTask task = MangaAnnotateTask._(
      request,
      announce: announce,
    );
    _latest[request.bookKey] = task;
    notifyListeners();
    unawaited(_drive(task));
    return task;
  }

  /// 取消这一卷正在跑的任务；没有在跑（或已在取消）返回 false。
  bool cancel(String bookKey) => runningFor(bookKey)?._requestCancel() ?? false;

  Future<void> _drive(MangaAnnotateTask task) async {
    try {
      final MangaAnnotateRunSummary summary = await _runner(
        task.request,
        MangaAnnotateTaskSink._(task),
        () => task._cancelRequested,
      );
      task._finish(
        task._cancelRequested
            ? MangaAnnotateTaskStatus.cancelled
            : MangaAnnotateTaskStatus.completed,
        summary: summary,
      );
    } on MangaAnnotateAbort catch (e) {
      task._finish(
        e.code == 'cancelled'
            ? MangaAnnotateTaskStatus.cancelled
            : MangaAnnotateTaskStatus.aborted,
        errorCode: e.code == 'cancelled' ? null : e.code,
      );
    } on MangaAudioAnnotateError catch (e) {
      task._finish(MangaAnnotateTaskStatus.failed, errorCode: e.code);
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'MangaAnnotateTasks(${task.bookKey})',
        e,
        stack,
      );
      task._finish(MangaAnnotateTaskStatus.failed, errorCode: 'internal');
    }
    notifyListeners();
    if (task.announce) onSettled?.call(task);
  }
}

/// 应用里的真实运行体：每次开一份新会话（读盘上最新的演出稿与账本），跑完随会话落盘。
Future<MangaAnnotateRunSummary> runMangaAnnotateRequest(
  AudioProductionHost appModel,
  MangaAnnotateRequest request,
  MangaAnnotateTaskSink sink,
  bool Function() isCancelled,
) async {
  final MangaAudioAnnotateSession session =
      await MangaAudioAnnotateSession.open(appModel, request.bookKey);
  final String title = session.volume.row.title;
  sink.title(title.isEmpty ? request.bookKey : title);
  sink.failures(session.ledger.sortedFailures);
  void onProgress(MangaAnnotatePhase phase, int done, int total) {
    sink.progress(phase, done, total);
    sink.failures(session.ledger.sortedFailures);
  }

  try {
    final MangaAnnotateFailure? failure = request.failure;
    if (failure != null) {
      return await session.retry(
        failure,
        provider: request.provider,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    }
    return await session.annotate(
      provider: request.provider,
      pages: request.pages ?? session.pagesToAnnotate(),
      withRoster:
          request.withRoster ??
          (session.script.annotatedPages.isEmpty || session.isStale),
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
  } finally {
    sink.failures(session.ledger.sortedFailures);
  }
}

/// 一次任务结束时给用户看的一句话。
String mangaAnnotateTaskResultText(MangaAnnotateTask task) {
  final String text = switch (task.status) {
    MangaAnnotateTaskStatus.running => '',
    MangaAnnotateTaskStatus.completed => t.manga_audio_done(
      pages: task.summary?.annotatedPages.length ?? 0,
      failed: task.summary?.failedPages.length ?? 0,
    ),
    MangaAnnotateTaskStatus.cancelled => t.manga_audio_cancelled,
    MangaAnnotateTaskStatus.aborted => t.manga_audio_aborted(
      reason: aiFailureText(task.errorCode ?? 'internal'),
    ),
    MangaAnnotateTaskStatus.failed => mangaAudioErrorText(
      task.errorCode ?? 'internal',
    ),
  };
  return task.title.isEmpty ? text : '${task.title} · $text';
}

void _toastSettled(MangaAnnotateTask task) => FushiToast.show(
  msg: mangaAnnotateTaskResultText(task),
  severity: switch (task.status) {
    MangaAnnotateTaskStatus.completed =>
      (task.summary?.failedPages.isEmpty ?? true)
          ? ToastSeverity.success
          : ToastSeverity.warning,
    MangaAnnotateTaskStatus.aborted ||
    MangaAnnotateTaskStatus.failed => ToastSeverity.error,
    _ => ToastSeverity.neutral,
  },
);

final Expando<MangaAnnotateTasks> _registries = Expando<MangaAnnotateTasks>(
  'MangaAnnotateTasks',
);

/// 这个应用（[appModel]）的漫画标注任务表；结束时弹全局 toast。
MangaAnnotateTasks mangaAnnotateTasksFor(AudioProductionHost appModel) =>
    _registries[appModel] ??= MangaAnnotateTasks(
      runner:
          (
            MangaAnnotateRequest request,
            MangaAnnotateTaskSink sink,
            bool Function() isCancelled,
          ) => runMangaAnnotateRequest(appModel, request, sink, isCancelled),
      onSettled: _toastSettled,
    );

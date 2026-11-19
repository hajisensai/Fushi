/// 漫画「广播剧 / 动画音轨」匹配的进程级任务表：一卷至多一个运行中任务，任务不属于
/// 任何页面。
///
/// - 制作页（`manga_drama_track_page.dart`）只是观察者：打开时挂上本卷正在跑或最近一次
///   的任务，离开页面只摘监听，任务照跑；只有显式 [MangaDramaTrackTasks.cancel] 才停。
/// - 整卷结束（完成 / 取消 / 失败）经 [MangaDramaTrackTasks.onSettled] 告诉用户：
///   [mangaDramaTrackTasksFor] 装的是全局 toast，页面在不在都看得到。
/// - 与单卷标注的 `manga_audio_annotate_tasks.dart` 同一形状。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:fushi_engine/tts/manga_audio/manga_drama_track.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart'
    show TtsRenderCancelToken, TtsRenderCancelled;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_drama_track_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 实际跑流水线的函数（生产 = `MangaDramaTrackService.run`；测试注入假实现）。
typedef MangaDramaTaskRunner =
    Future<MangaDramaOutcome> Function({
      required MangaDramaVolume volume,
      required List<String> audioPaths,
      required TtsRenderCancelToken cancel,
      MangaDramaProgress? onProgress,
    });

enum MangaDramaTaskStatus {
  running,
  completed,
  cancelled,
  failed;

  bool get isFinished => this != MangaDramaTaskStatus.running;
}

/// 同一卷已有任务在跑。
class MangaDramaTaskBusy implements Exception {
  const MangaDramaTaskBusy(this.running);

  final MangaDramaTask running;

  @override
  String toString() => 'MangaDramaTaskBusy(${running.bookKey})';
}

/// 一卷的一次匹配任务。进度、结束都会通知。
class MangaDramaTask extends ChangeNotifier {
  MangaDramaTask._({required this.bookKey, required List<String> audioPaths})
    : audioPaths = List<String>.unmodifiable(audioPaths);

  final String bookKey;

  /// 发起时的文件（按顺序）；跑的过程中页面显示这份，不让改。
  final List<String> audioPaths;

  final TtsRenderCancelToken _cancel = TtsRenderCancelToken();
  final Completer<void> _finished = Completer<void>();

  MangaDramaPhase phase = MangaDramaPhase.transcribing;
  int progressDone = 0;
  int progressTotal = 0;
  MangaDramaTaskStatus status = MangaDramaTaskStatus.running;

  /// 完成时的匹配统计。
  MangaDramaStats? stats;

  /// 失败原因（取消不算失败）。
  Object? error;

  bool get isRunning => status == MangaDramaTaskStatus.running;
  bool get cancelRequested => _cancel.isCancelled;

  /// 任务结束（任何结局）时完成，不会以错误完成。
  Future<void> get finished => _finished.future;

  void _progress(MangaDramaPhase p, int done, int total) {
    if (!isRunning) return;
    phase = p;
    progressDone = done;
    progressTotal = total;
    notifyListeners();
  }

  void _settle(MangaDramaTaskStatus next, {MangaDramaStats? s, Object? e}) {
    status = next;
    stats = s;
    error = e;
    notifyListeners();
    if (!_finished.isCompleted) _finished.complete();
  }
}

class MangaDramaTrackTasks extends ChangeNotifier {
  MangaDramaTrackTasks({this.onSettled});

  /// 任务结束时调用（生产 = 全局 toast）。
  final void Function(MangaDramaTask task)? onSettled;

  /// 每卷最近一次任务（运行中或已结束，页面重新打开时显示上次结果）。
  final Map<String, MangaDramaTask> _latest = <String, MangaDramaTask>{};

  MangaDramaTask? taskFor(String bookKey) => _latest[bookKey];

  MangaDramaTask? runningFor(String bookKey) {
    final MangaDramaTask? task = _latest[bookKey];
    return task != null && task.isRunning ? task : null;
  }

  bool isRunning(String bookKey) => runningFor(bookKey) != null;

  /// 发起本卷的匹配。同一卷已有任务在跑时抛 [MangaDramaTaskBusy]。
  MangaDramaTask start({
    required MangaDramaVolume volume,
    required List<String> audioPaths,
    required MangaDramaTaskRunner run,
  }) {
    final MangaDramaTask? running = runningFor(volume.bookKey);
    if (running != null) throw MangaDramaTaskBusy(running);
    final MangaDramaTask task = MangaDramaTask._(
      bookKey: volume.bookKey,
      audioPaths: audioPaths,
    );
    task.progressTotal = audioPaths.length;
    _latest[volume.bookKey] = task;
    notifyListeners();
    unawaited(_drive(task, volume, run));
    return task;
  }

  /// 显式取消。没有在跑或已在取消时返回 false。
  bool cancel(String bookKey) {
    final MangaDramaTask? task = runningFor(bookKey);
    if (task == null || task.cancelRequested) return false;
    task._cancel.cancel();
    task.notifyListeners();
    return true;
  }

  Future<void> _drive(
    MangaDramaTask task,
    MangaDramaVolume volume,
    MangaDramaTaskRunner run,
  ) async {
    try {
      final MangaDramaOutcome outcome = await run(
        volume: volume,
        audioPaths: task.audioPaths,
        cancel: task._cancel,
        onProgress: task._progress,
      );
      task._settle(MangaDramaTaskStatus.completed, s: outcome.track.stats);
    } on TtsRenderCancelled {
      task._settle(MangaDramaTaskStatus.cancelled);
    } on Object catch (e) {
      task._settle(
        task.cancelRequested
            ? MangaDramaTaskStatus.cancelled
            : MangaDramaTaskStatus.failed,
        e: task.cancelRequested ? null : e,
      );
    }
    notifyListeners();
    onSettled?.call(task);
  }
}

/// 失败 → 给用户看的一句话（纯函数）。取消不算失败，返回 null。
String? mangaDramaErrorMessage(Object error) => switch (error) {
  TtsRenderCancelled() => null,
  MangaDramaAsrUnavailable() => t.manga_audio_drama_error_asr,
  MangaDramaFfmpegMissing() => t.manga_audio_drama_error_ffmpeg,
  MangaDramaEmptyTranscript() => t.manga_audio_drama_error_empty,
  _ => t.manga_audio_drama_error_failed(error: '$error'),
};

void _toastSettled(MangaDramaTask task) {
  switch (task.status) {
    case MangaDramaTaskStatus.completed:
      FushiToast.show(
        msg: t.manga_audio_drama_done,
        severity: ToastSeverity.success,
      );
    case MangaDramaTaskStatus.cancelled:
      FushiToast.show(msg: t.manga_audio_drama_cancelled);
    case MangaDramaTaskStatus.failed:
      final Object? error = task.error;
      FushiToast.show(
        msg: error == null
            ? t.manga_audio_drama_cancelled
            : (mangaDramaErrorMessage(error) ?? t.manga_audio_drama_cancelled),
        severity: ToastSeverity.warning,
      );
    case MangaDramaTaskStatus.running:
      break;
  }
}

final Expando<MangaDramaTrackTasks> _registries = Expando<MangaDramaTrackTasks>(
  'MangaDramaTrackTasks',
);

/// 每个 `AppModel` 一张表，结束时弹全局 toast。
MangaDramaTrackTasks mangaDramaTrackTasksFor(AudioProductionHost appModel) =>
    _registries[appModel] ??= MangaDramaTrackTasks(onSettled: _toastSettled);

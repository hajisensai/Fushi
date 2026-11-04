import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/platform/home_widgets/home_widget_channel.dart';

/// 一次播放活动的内容（与 Swift `FushiPlaybackAttributes.ContentState` 逐字段对应）。
@immutable
class PlaybackActivityState {
  const PlaybackActivityState({
    required this.title,
    required this.subtitle,
    required this.line,
    required this.isPlaying,
    required this.progress,
    required this.elapsedLabel,
    required this.remainingLabel,
    this.nextLine,
    this.startedAt,
    this.endsAt,
    this.detail,
    this.canFavorite = false,
    this.favorited = false,
    this.realtimeLabels = false,
  });

  final String title;
  final String subtitle;
  final String line;
  final String? nextLine;
  final bool isPlaying;
  final double? startedAt;
  final double? endsAt;
  final double progress;
  final String elapsedLabel;
  final String remainingLabel;
  final String? detail;
  final bool canFavorite;
  final bool favorited;

  /// true：时间文字可以由系统按 [startedAt]…[endsAt] 自走（音乐：1 倍速、整首）。
  /// false：自走的只有进度条，文字用 [elapsedLabel] / [remainingLabel]——有声书的
  /// 进度条走本章、文字是整本，且倍速下墙钟与音频时间对不上。
  final bool realtimeLabels;

  /// 不含随时间自走的量（进度 / 时间标签 / 起止时刻）：只有它变了才值得推一次更新。
  String get significantKey =>
      '$title|$subtitle|$line|$nextLine|$isPlaying|$detail|$canFavorite|'
      '$favorited';

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'subtitle': subtitle,
    'line': line,
    'nextLine': nextLine,
    'isPlaying': isPlaying,
    'startedAt': startedAt,
    'endsAt': endsAt,
    'progress': progress,
    'elapsedLabel': elapsedLabel,
    'remainingLabel': remainingLabel,
    'detail': detail,
    'canFavorite': canFavorite,
    'favorited': favorited,
    'realtimeLabels': realtimeLabels,
  };
}

/// 此刻「谁在出声」：种类（`audiobook` / `music`）+ 起活动用的属性 + 内容。
@immutable
class PlaybackActivitySample {
  const PlaybackActivitySample({
    required this.kind,
    required this.attributes,
    required this.state,
  });

  final String kind;

  /// Swift `FushiPlaybackInfo`（`kind` / `cover` / 无障碍文案）；只在起活动时发一次。
  final Map<String, Object?> attributes;
  final PlaybackActivityState state;
}

/// 一次转录任务活动的内容（与 Swift `FushiTaskContent` 逐字段对应）。
@immutable
class TaskActivityState {
  const TaskActivityState({
    required this.title,
    required this.detail,
    required this.progress,
    required this.percentLabel,
    required this.finished,
    this.pausedNote,
  });

  final String title;
  final String detail;
  final double progress;
  final String percentLabel;
  final String? pausedNote;
  final bool finished;

  String get key =>
      '$title|$detail|${(progress * 100).floor()}|$percentLabel|$pausedNote|'
      '$finished';

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'detail': detail,
    'progress': progress,
    'percentLabel': percentLabel,
    'pausedNote': pausedNote,
    'finished': finished,
  };
}

/// 正在跑的那个转录任务。
@immutable
class TaskActivitySample {
  const TaskActivitySample({
    required this.jobId,
    required this.attributes,
    required this.state,
  });

  final String jobId;

  /// Swift `FushiTaskInfo`（`kind` / `url`）。
  final Map<String, Object?> attributes;
  final TaskActivityState state;
}

/// Live Activity（iOS）/ 菜单栏播放条（macOS）的状态机：把「此刻该显示什么」收敛到原生侧。
///
/// 播放与转录各有一条**串行**同步：同一时刻只跑一轮，跑的过程中（例如还在等
/// `startPlayback` 返回）又来了变化只记「脏」，这一轮结束后立刻用**最新**样本再跑一轮。
/// 所以不会并发起出两个活动，start 期间的暂停 / 换句 / 会话结束也不会丢，最终总能收敛到
/// 最新状态（包括会话已经没了 → 把刚起好的活动收掉）。
///
/// 数据只从 [readPlayback] / [readRunningTask] / [readFinishedTask] 读，调用方（
/// `HomeWidgetLiveActivities`）在自己的监听里调 [syncPlayback] / [syncTask]。
class LiveActivityController {
  LiveActivityController({
    required this.channel,
    required this.readPlayback,
    required this.readRunningTask,
    required this.readFinishedTask,
    this.pauseTimeout = const Duration(minutes: 10),
    this.resyncInterval = const Duration(seconds: 30),
    this.finishedLinger = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final HomeWidgetChannel channel;

  /// 此刻的播放样本；null = 没有在播（也没有暂停着的会话）。
  final PlaybackActivitySample? Function() readPlayback;

  /// 此刻正在跑的转录任务；null = 没有。
  final TaskActivitySample? Function() readRunningTask;

  /// [jobId] 已经跑完时的最终样本（成功）；失败 / 被移除为 null。
  final TaskActivitySample? Function(String jobId) readFinishedTask;

  /// 暂停超过这么久就收掉播放活动；重新播放时再起一个。
  final Duration pauseTimeout;

  /// 内容不变但正在播放时，隔这么久校一次进度（拖动 / 卡顿后的偏差）。
  final Duration resyncInterval;

  /// 转录完成后活动在锁屏上留多久。
  final Duration finishedLinger;

  final DateTime Function() _now;

  String? _playbackId;
  String? _playbackKind;
  String? _playbackKey;
  DateTime? _lastFullPushAt;
  Timer? _pauseTimer;
  bool _pauseExpired = false;
  bool _playbackSyncing = false;
  bool _playbackDirty = false;
  bool _forceNext = false;

  String? _taskId;
  String? _taskJobId;
  String? _taskKey;
  bool _taskSyncing = false;
  bool _taskDirty = false;

  bool _disposed = false;

  /// 当前播放活动的种类（`audiobook` / `music`）；没有活动为 null。
  String? get playbackKind => _playbackKind;

  @visibleForTesting
  String? get playbackId => _playbackId;

  @visibleForTesting
  String? get taskId => _taskId;

  /// 把播放活动收敛到 [readPlayback] 的最新样本。[force] = 内容没变也推一次（例如收藏
  /// 状态刚查回来）。正在同步时只记脏，返回的 Future 立即完成。
  Future<void> syncPlayback({bool force = false}) async {
    _forceNext |= force;
    if (_disposed) return;
    if (_playbackSyncing) {
      _playbackDirty = true;
      return;
    }
    _playbackSyncing = true;
    try {
      do {
        _playbackDirty = false;
        final bool f = _forceNext;
        _forceNext = false;
        await _syncPlaybackOnce(force: f);
      } while (_playbackDirty && !_disposed);
    } finally {
      _playbackSyncing = false;
    }
  }

  /// 把转录活动收敛到 [readRunningTask] 的最新样本；串行规则同 [syncPlayback]。
  Future<void> syncTask() async {
    if (_disposed) return;
    if (_taskSyncing) {
      _taskDirty = true;
      return;
    }
    _taskSyncing = true;
    try {
      do {
        _taskDirty = false;
        await _syncTaskOnce();
      } while (_taskDirty && !_disposed);
    } finally {
      _taskSyncing = false;
    }
  }

  /// 收掉本控制器起的活动并停止工作（app 根卸载）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final String? playback = _playbackId;
    final String? task = _taskId;
    _playbackId = null;
    _taskId = null;
    if (playback != null) unawaited(channel.endActivity(playback));
    if (task != null) unawaited(channel.endActivity(task));
  }

  Future<void> _syncPlaybackOnce({required bool force}) async {
    final PlaybackActivitySample? sample = readPlayback();
    if (sample == null) {
      await _endPlayback();
      return;
    }
    if (sample.state.isPlaying) {
      _pauseTimer?.cancel();
      _pauseTimer = null;
      _pauseExpired = false;
    } else if (_pauseExpired) {
      // 暂停太久：收掉，重新播放时再起一个。
      await _endPlayback();
      return;
    } else {
      _pauseTimer ??= Timer(pauseTimeout, () {
        _pauseTimer = null;
        _pauseExpired = true;
        unawaited(syncPlayback());
      });
    }
    if (_playbackId != null && _playbackKind != sample.kind) {
      await _endPlayback();
    }
    final String? id = _playbackId;
    if (id == null) {
      // 只在真正开始播放时起活动。
      if (!sample.state.isPlaying) return;
      if (!await channel.activitiesEnabled()) return;
      final String? newId = await channel.startPlayback(
        attributes: sample.attributes,
        state: sample.state.toJson(),
      );
      if (newId == null) return;
      _playbackId = newId;
      _playbackKind = sample.kind;
      _playbackKey = sample.state.significantKey;
      _lastFullPushAt = _now();
      if (_disposed) await _endPlayback();
      return;
    }
    final DateTime now = _now();
    final DateTime? last = _lastFullPushAt;
    final bool changed = sample.state.significantKey != _playbackKey;
    final bool due =
        sample.state.isPlaying &&
        (last == null || now.difference(last) >= resyncInterval);
    if (!force && !changed && !due) return;
    _playbackKey = sample.state.significantKey;
    _lastFullPushAt = now;
    await channel.updatePlayback(id, sample.state.toJson());
  }

  Future<void> _endPlayback() async {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final String? id = _playbackId;
    _playbackId = null;
    _playbackKind = null;
    _playbackKey = null;
    if (id != null) await channel.endActivity(id);
  }

  Future<void> _syncTaskOnce() async {
    final TaskActivitySample? running = readRunningTask();
    final String? id = _taskId;
    if (running == null) {
      if (id == null) return;
      final String? jobId = _taskJobId;
      _taskId = null;
      _taskJobId = null;
      _taskKey = null;
      final TaskActivitySample? finished = jobId == null
          ? null
          : readFinishedTask(jobId);
      if (finished != null) {
        // 一步结束并带上最终内容：原生侧不会出现「先结束、后更新」的乱序。
        await channel.endActivity(
          id,
          dismissAfter: finishedLinger.inSeconds.toDouble(),
          finalState: finished.state.toJson(),
        );
      } else {
        await channel.endActivity(id);
      }
      return;
    }
    if (id != null && _taskJobId != running.jobId) {
      _taskId = null;
      _taskJobId = null;
      _taskKey = null;
      await channel.endActivity(id);
    }
    final String? current = _taskId;
    if (current == null) {
      if (!await channel.activitiesEnabled()) return;
      final String? newId = await channel.startTask(
        attributes: running.attributes,
        state: running.state.toJson(),
      );
      if (newId == null) return;
      _taskId = newId;
      _taskJobId = running.jobId;
      _taskKey = running.state.key;
      if (_disposed) {
        _taskId = null;
        await channel.endActivity(newId);
      }
      return;
    }
    if (running.state.key == _taskKey) return;
    _taskKey = running.state.key;
    await channel.updateTask(current, running.state.toJson());
  }
}

/// 播放中让系统自走进度条的起止墙钟时刻（秒）。倍速 [speed] 下按墙钟换算：
/// 整段媒体时长 [duration] 在墙钟上占 duration / speed。
({double startedAt, double endsAt})? playbackWallClock({
  required Duration position,
  required Duration duration,
  required double speed,
  required DateTime now,
}) {
  if (duration <= Duration.zero || speed <= 0) return null;
  final double nowSec = now.millisecondsSinceEpoch / 1000;
  final double start = nowSec - position.inMilliseconds / 1000 / speed;
  return (
    startedAt: start,
    endsAt: start + duration.inMilliseconds / 1000 / speed,
  );
}

/// `1:02:03` / `4:05`。
String formatPlaybackClock(Duration d) {
  final Duration v = d.isNegative ? Duration.zero : d;
  final int h = v.inHours;
  final String m = (v.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final String s = (v.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

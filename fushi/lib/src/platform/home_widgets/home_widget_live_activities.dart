import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show FavoriteSentence, FavoriteSentenceRepository, SentenceSourceKind;
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/audiobook/asr_pipeline_progress.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_transcribe_tasks_section.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart'
    show statTodayKey;
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

/// 有声书 / 音乐 / 设备端转录 → Live Activity（iOS 灵动岛 + 锁屏）或 macOS 菜单栏播放条。
///
/// 只订阅现成的 ChangeNotifier（会话、控制器、歌词、转录队列），在「当前句 / 歌词行 /
/// 播放状态 / 收藏状态」变化时推一次；进度条由系统按起止时刻自己走，不按秒推。
/// 播放暂停超过 [pauseTimeout] 或会话结束就收掉活动。
class HomeWidgetLiveActivities {
  HomeWidgetLiveActivities({
    required this.appModel,
    required this.channel,
    this.pauseTimeout = const Duration(minutes: 10),
  });

  final AppModel appModel;
  final HomeWidgetChannel channel;
  final Duration pauseTimeout;

  AudiobookSession? _session;
  AudiobookPlayerController? _controller;
  MusicPlayerEngine? _music;
  MusicLyricsLive? _lyrics;
  AudiobookTranscribeImportQueue? _queue;

  String? _playbackId;
  String? _playbackKind;
  String? _playbackKey;
  int _lastFullPushMs = 0;
  Timer? _pauseTimer;
  bool _starting = false;

  String? _taskId;
  String? _taskJobId;
  String? _taskKey;
  bool _backgrounded = false;

  String? _favoriteCheckedFor;
  bool _currentFavorited = false;

  bool _disposed = false;

  void start() {
    unawaited(channel.endAllActivities());
    _session = appModel.audiobookSession..addListener(_onAudiobookSession);
    _music = appModel.musicSession.engine..addListener(_schedulePlayback);
    _lyrics = appModel.musicLyricsLive
      ..addListener(_schedulePlayback)
      ..setLiveActivityWanted(true);
    if (appModel.isDatabaseReady && isAsrSupported) {
      _queue = appModel.audiobookTranscribeImportQueue
        ..addListener(_scheduleTask);
    }
    _onAudiobookSession();
    _scheduleTask();
  }

  void dispose() {
    _disposed = true;
    _pauseTimer?.cancel();
    _session?.removeListener(_onAudiobookSession);
    _controller?.removeListener(_schedulePlayback);
    _music?.removeListener(_schedulePlayback);
    _lyrics
      ?..removeListener(_schedulePlayback)
      ..setLiveActivityWanted(false);
    _queue?.removeListener(_scheduleTask);
  }

  /// app 进后台 / 回前台：转录在后台可能被系统挂起，如实标出来。
  void setBackgrounded(bool value) {
    if (_backgrounded == value) return;
    _backgrounded = value;
    _scheduleTask();
  }

  // ── 按钮回调 ──────────────────────────────────────────────────────

  /// Live Activity / 菜单栏上的 上一句 / 播放暂停 / 下一句 / 收藏这句。
  Future<bool> handlePlaybackAction(String? action) async {
    if (_playbackKind == 'music') {
      final MusicPlayerEngine? music = _music;
      if (music == null) return false;
      switch (action) {
        case 'toggle':
          await music.togglePlayPause();
        case 'previous':
          await music.skipPrevious();
        case 'next':
          await music.skipNext();
        default:
          return false;
      }
      return true;
    }
    final AudiobookPlayerController? c = _controller;
    if (c == null) return false;
    switch (action) {
      case 'toggle':
        await c.togglePlayPause();
      case 'previous':
        await c.skipToPrevCue();
      case 'next':
        await c.skipToNextCue();
      case 'favorite':
        await _toggleFavorite();
      default:
        return false;
    }
    return true;
  }

  /// 主屏「接着听」：会话还在就后台续播。没有会话返回 false（调用方改走前台打开）。
  Future<bool> resumeAudiobook() async {
    final AudiobookPlayerController? c = _session?.controller;
    if (c == null) return false;
    await c.play();
    return true;
  }

  Future<void> _toggleFavorite() async {
    final SessionBookInfo? book = _session?.book;
    final String text =
        _controller?.displayCueForFloatingLyric?.text.trim() ?? '';
    if (book == null || text.isEmpty) return;
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    final String? existing = await repo.matchedFavoriteId(
      text: text,
      bookKey: book.bookKey,
      sectionIndex: null,
      normCharOffset: null,
    );
    if (existing != null) {
      await repo.removeById(existing);
      _currentFavorited = false;
    } else {
      // 来源记成「有声书」：收藏夹里点它回到这本书（与书内收藏同一个 bookKey 身份）。
      await repo.add(
        FavoriteSentence(
          text: text,
          bookTitle: book.title,
          createdAt: DateTime.now(),
          bookKey: book.bookKey,
          source: SentenceSourceKind.audiobook.dbValue,
          dateKey: statTodayKey(),
        ),
      );
      _currentFavorited = true;
    }
    _favoriteCheckedFor = text;
    _schedulePlayback(force: true);
  }

  // ── 播放 ──────────────────────────────────────────────────────────

  void _onAudiobookSession() {
    final AudiobookPlayerController? next = _session?.controller;
    if (!identical(next, _controller)) {
      _controller?.removeListener(_schedulePlayback);
      _controller = next?..addListener(_schedulePlayback);
    }
    _schedulePlayback();
  }

  bool _pushScheduled = false;
  bool _forceNext = false;

  void _schedulePlayback({bool force = false}) {
    _forceNext |= force;
    if (_pushScheduled || _disposed) return;
    _pushScheduled = true;
    scheduleMicrotask(() {
      _pushScheduled = false;
      final bool f = _forceNext;
      _forceNext = false;
      unawaited(_syncPlayback(force: f));
    });
  }

  ({String kind, PlaybackActivityState state, String? cover})?
  _currentPlayback() {
    final MusicPlayerEngine? music = _music;
    final AudiobookPlayerController? c = _controller;
    final SessionBookInfo? book = _session?.book;
    final bool musicActive =
        music != null && music.current != null && music.isPlaying;
    if (musicActive || (c == null && music?.current != null)) {
      final MusicPlayItem item = music!.current!;
      final Duration duration = Duration(milliseconds: item.durationMs ?? 0);
      final Duration position = music.position;
      final ({double startedAt, double endsAt})? clock = music.isPlaying
          ? playbackWallClock(
              position: position,
              duration: duration,
              speed: 1,
              now: DateTime.now(),
            )
          : null;
      final String line = _lyrics?.currentLineText ?? '';
      return (
        kind: 'music',
        cover: item.coverPath,
        state: PlaybackActivityState(
          title: item.title,
          subtitle: item.artist ?? '',
          line: line,
          nextLine: _lyrics?.nextLineText,
          isPlaying: music.isPlaying,
          startedAt: clock?.startedAt,
          endsAt: clock?.endsAt,
          progress: duration.inMilliseconds <= 0
              ? 0
              : position.inMilliseconds / duration.inMilliseconds,
          elapsedLabel: formatPlaybackClock(position),
          remainingLabel: '-${formatPlaybackClock(duration - position)}',
          realtimeLabels: true,
        ),
      );
    }
    if (c == null || book == null) return null;
    final String line = c.displayCueForFloatingLyric?.text.trim() ?? '';
    if (line != _favoriteCheckedFor) {
      _favoriteCheckedFor = line;
      _currentFavorited = false;
      if (line.isNotEmpty) unawaited(_refreshFavorited(book, line));
    }
    final Duration total = c.totalDuration;
    final Duration global = c.globalPosition;
    final ({double startedAt, double endsAt})? clock = c.isPlaying
        ? playbackWallClock(
            position: c.position,
            duration: c.duration,
            speed: c.speed,
            now: DateTime.now(),
          )
        : null;
    final int count = c.chapterCueCount;
    final int index = c.currentCueIdx;
    final Duration remaining = total > global ? total - global : Duration.zero;
    return (
      kind: 'audiobook',
      cover: book.coverPath,
      state: PlaybackActivityState(
        title: book.title,
        subtitle: book.author ?? '',
        line: line,
        isPlaying: c.isPlaying,
        startedAt: clock?.startedAt,
        endsAt: clock?.endsAt,
        progress: c.duration.inMilliseconds <= 0
            ? 0
            : c.position.inMilliseconds / c.duration.inMilliseconds,
        elapsedLabel: formatPlaybackClock(c.position),
        remainingLabel: '-${formatPlaybackClock(remaining)}',
        detail: count > 0 && index >= 0
            ? t.home_widget_activity_sentence_of(index: index + 1, total: count)
            : null,
        canFavorite: line.isNotEmpty,
        favorited: _currentFavorited,
      ),
    );
  }

  Future<void> _refreshFavorited(SessionBookInfo book, String line) async {
    final bool favorited = await FavoriteSentenceRepository(appModel.database)
        .isFavorited(
          text: line,
          bookKey: book.bookKey,
          sectionIndex: null,
          normCharOffset: null,
        );
    if (_favoriteCheckedFor != line || favorited == _currentFavorited) return;
    _currentFavorited = favorited;
    _schedulePlayback(force: true);
  }

  Future<void> _syncPlayback({bool force = false}) async {
    if (_disposed || _starting) return;
    final ({String kind, PlaybackActivityState state, String? cover})? now =
        _currentPlayback();
    if (now == null) {
      await _endPlayback();
      return;
    }
    // 暂停太久就收掉；重新播放时再起一个。
    if (now.state.isPlaying) {
      _pauseTimer?.cancel();
      _pauseTimer = null;
    } else {
      _pauseTimer ??= Timer(pauseTimeout, () => unawaited(_endPlayback()));
    }
    final String? id = _playbackId;
    if (id != null && _playbackKind != now.kind) {
      await _endPlayback();
    }
    if (_playbackId == null) {
      if (!now.state.isPlaying) return; // 只在真正开始播放时起活动。
      _starting = true;
      try {
        if (!await channel.activitiesEnabled()) return;
        final String? newId = await channel.startPlayback(
          attributes: <String, Object?>{
            'kind': now.kind,
            'cover': await _activityCover(now.cover),
            'accessibilityPlay': t.home_widget_activity_play,
            'accessibilityPause': t.home_widget_activity_pause,
            'accessibilityPrevious': t.home_widget_activity_previous,
            'accessibilityNext': t.home_widget_activity_next,
            'accessibilityFavorite': t.home_widget_activity_favorite,
          },
          state: now.state.toJson(),
        );
        _playbackId = newId;
        _playbackKind = newId == null ? null : now.kind;
        _playbackKey = now.state.significantKey;
        _lastFullPushMs = DateTime.now().millisecondsSinceEpoch;
      } finally {
        _starting = false;
      }
      return;
    }
    // 只在内容变化时推；内容不变但播放中，每 30 秒校一次进度（拖动 / 卡顿后的偏差）。
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final bool changed = now.state.significantKey != _playbackKey;
    if (!force && !changed && nowMs - _lastFullPushMs < 30000) return;
    _playbackKey = now.state.significantKey;
    _lastFullPushMs = nowMs;
    await channel.updatePlayback(_playbackId!, now.state.toJson());
  }

  /// 活动的封面要放进 App Group（扩展进程读不到 app 沙盒）；iOS 封面路径本就在 app
  /// 沙盒里，所以交给快照写入器同一个目录。没有 App Group 时为 null（显示图标）。
  Future<String?> Function(String? path) activityCoverResolver =
      (String? _) async => null;

  Future<String?> _activityCover(String? path) => activityCoverResolver(path);

  Future<void> _endPlayback() async {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final String? id = _playbackId;
    _playbackId = null;
    _playbackKind = null;
    _playbackKey = null;
    if (id != null) await channel.endActivity(id);
  }

  // ── 转录 ──────────────────────────────────────────────────────────

  bool _taskScheduled = false;

  void _scheduleTask() {
    if (_taskScheduled || _disposed) return;
    _taskScheduled = true;
    scheduleMicrotask(() {
      _taskScheduled = false;
      unawaited(_syncTask());
    });
  }

  Future<void> _syncTask() async {
    final AudiobookTranscribeImportQueue? queue = _queue;
    if (queue == null || _disposed) return;
    AudiobookTranscribeJob? running;
    for (final AudiobookTranscribeJob job in queue.jobs) {
      if (job.status == AudiobookTranscribeJobStatus.running) {
        running = job;
        break;
      }
    }
    final String? id = _taskId;
    if (running == null) {
      if (id == null) return;
      final AudiobookTranscribeJob? finished = _jobById(queue, _taskJobId);
      _taskId = null;
      _taskJobId = null;
      _taskKey = null;
      if (finished?.status == AudiobookTranscribeJobStatus.done) {
        await channel.updateTask(
          id,
          _taskState(finished!, finished: true).toJson(),
        );
        await channel.endActivity(id, dismissAfter: 30 * 60);
      } else {
        await channel.endActivity(id);
      }
      return;
    }
    // 后台没在放音频时，系统随时可能挂起转录：如实标「已暂停」，回前台自动清掉。
    final bool paused = _backgrounded && !_anyAudioPlaying;
    final _TaskState state = _taskState(running, paused: paused);
    if (id != null && _taskJobId != running.id) {
      await channel.endActivity(id);
      _taskId = null;
    }
    if (_taskId == null) {
      if (!await channel.activitiesEnabled()) return;
      _taskId = await channel.startTask(
        attributes: <String, Object?>{
          'kind': 'transcribe',
          'url': 'fushi://shortcut/books',
        },
        state: state.toJson(),
      );
      _taskJobId = running.id;
      _taskKey = state.key;
      return;
    }
    if (state.key == _taskKey) return;
    _taskKey = state.key;
    await channel.updateTask(_taskId!, state.toJson());
  }

  bool get _anyAudioPlaying =>
      (_controller?.isPlaying ?? false) || (_music?.isPlaying ?? false);

  AudiobookTranscribeJob? _jobById(
    AudiobookTranscribeImportQueue queue,
    String? id,
  ) {
    for (final AudiobookTranscribeJob job in queue.jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  _TaskState _taskState(
    AudiobookTranscribeJob job, {
    bool paused = false,
    bool finished = false,
  }) {
    final double progress = finished ? 1 : (job.progress ?? 0);
    return _TaskState(
      title: finished
          ? t.home_widget_task_transcribe_done
          : t.home_widget_task_transcribe_title,
      detail: finished
          ? job.title
          : '${job.title} · ${audiobookTranscribeJobStatusLabel(job, compact: true)}',
      progress: progress,
      // 匹配正文 / 入库没有数值进度：不编百分比，只显示步骤名。
      percentLabel: finished || job.progress != null
          ? formatAsrPercent(progress)
          : '…',
      pausedNote: paused ? t.home_widget_task_paused : null,
      finished: finished,
    );
  }
}

class _TaskState {
  const _TaskState({
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

/// `1:02:03` / `4:05`。
String formatPlaybackClock(Duration d) {
  final Duration v = d.isNegative ? Duration.zero : d;
  final int h = v.inHours;
  final String m = (v.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final String s = (v.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

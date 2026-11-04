import 'dart:async';
import 'dart:io';

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
import 'package:fushi/src/platform/home_widgets/live_activity_controller.dart';

export 'package:fushi/src/platform/home_widgets/live_activity_controller.dart'
    show formatPlaybackClock, playbackWallClock;

/// 有声书 / 音乐 / 设备端转录 → Live Activity（iOS 灵动岛 + 锁屏）或 macOS 菜单栏播放条。
///
/// 只订阅现成的 ChangeNotifier（会话、控制器、歌词、转录队列），把它们读成样本交给
/// [LiveActivityController]（串行收敛、暂停超时、换种类）。进度条由系统按起止时刻自己走，
/// 不按秒推。
class HomeWidgetLiveActivities {
  HomeWidgetLiveActivities({required this.appModel, required this.channel});

  final AppModel appModel;
  final HomeWidgetChannel channel;

  late final LiveActivityController _activities = LiveActivityController(
    channel: channel,
    readPlayback: _currentPlayback,
    readRunningTask: _runningTask,
    readFinishedTask: _finishedTask,
  );

  AudiobookSession? _session;
  AudiobookPlayerController? _controller;
  MusicPlayerEngine? _music;
  MusicLyricsLive? _lyrics;
  AudiobookTranscribeImportQueue? _queue;
  bool _backgrounded = false;

  String? _favoriteCheckedFor;
  bool _currentFavorited = false;

  bool _disposed = false;
  bool _pushScheduled = false;
  bool _forceNext = false;
  bool _taskScheduled = false;

  /// 先**等**原生把上次进程留下的活动全部收掉，再开始订阅：否则冷启动时会话恢复起的新活动
  /// 可能被迟到的「全部结束」一起收掉。
  Future<void> start() async {
    await channel.endAllActivities();
    if (_disposed) return;
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
    _session?.removeListener(_onAudiobookSession);
    _controller?.removeListener(_schedulePlayback);
    _music?.removeListener(_schedulePlayback);
    _lyrics
      ?..removeListener(_schedulePlayback)
      ..setLiveActivityWanted(false);
    _queue?.removeListener(_scheduleTask);
    _activities.dispose();
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
    if (_activities.playbackKind == 'music') {
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

  /// 主屏「接着听」/ 控制中心「接着听」：会话还在就后台续播。[kind] 是小组件快照里
  /// `nowPlaying.kind`（`music` / `audiobook`）；null = 控制中心（不知道是哪个，按快照同一
  /// 优先级：音乐 → 有声书）。没有可续的会话返回 false（原生侧改走前台打开链接）。
  Future<bool> resumePlayback(String? kind) async {
    final MusicPlayerEngine? music = _music;
    if (kind != 'audiobook' && music != null && music.current != null) {
      await music.play();
      return true;
    }
    final AudiobookPlayerController? c = _session?.controller;
    if (kind != 'music' && c != null) {
      await c.play();
      return true;
    }
    return false;
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

  /// 同一帧里多个监听器连着通知（控制器 + 歌词）合成一次同步。
  void _schedulePlayback({bool force = false}) {
    _forceNext |= force;
    if (_pushScheduled || _disposed) return;
    _pushScheduled = true;
    scheduleMicrotask(() {
      _pushScheduled = false;
      final bool f = _forceNext;
      _forceNext = false;
      unawaited(_activities.syncPlayback(force: f));
    });
  }

  /// 本机封面文件的绝对路径（原生侧缩略后拷进 App Group，扩展进程读不到 app 沙盒）；
  /// 远程封面 / 文件不在时为 null，活动上显示类型图标。
  static String? _localCover(String? path) {
    if (path == null || path.isEmpty) return null;
    final String local = path.startsWith('file://')
        ? Uri.parse(path).toFilePath()
        : path;
    if (local.startsWith('http://') || local.startsWith('https://')) {
      return null;
    }
    return File(local).existsSync() ? local : null;
  }

  Map<String, Object?> _attributes(String kind, String? cover) {
    final bool music = kind == 'music';
    return <String, Object?>{
      'kind': kind,
      'cover': _localCover(cover),
      'accessibilityPlay': t.widget_label_play,
      'accessibilityPause': t.widget_label_pause,
      'accessibilityPrevious': music
          ? t.widget_label_previous
          : t.widget_activity_previous_sentence,
      'accessibilityNext': music
          ? t.widget_label_next
          : t.widget_activity_next_sentence,
      'accessibilityFavorite': t.widget_activity_favorite_sentence,
    };
  }

  PlaybackActivitySample? _currentPlayback() {
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
      return PlaybackActivitySample(
        kind: 'music',
        attributes: _attributes('music', item.coverPath),
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
    return PlaybackActivitySample(
      kind: 'audiobook',
      attributes: _attributes('audiobook', book.coverPath),
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
            ? t.widget_activity_sentence_of(index: index + 1, total: count)
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

  // ── 转录 ──────────────────────────────────────────────────────────

  void _scheduleTask() {
    if (_taskScheduled || _disposed) return;
    _taskScheduled = true;
    scheduleMicrotask(() {
      _taskScheduled = false;
      unawaited(_activities.syncTask());
    });
  }

  static const Map<String, Object?> _taskAttributes = <String, Object?>{
    'kind': 'transcribe',
    'url': 'fushi://widget/tab/books',
  };

  TaskActivitySample? _runningTask() {
    final AudiobookTranscribeImportQueue? queue = _queue;
    if (queue == null) return null;
    for (final AudiobookTranscribeJob job in queue.jobs) {
      if (job.status == AudiobookTranscribeJobStatus.running) {
        // 后台没在放音频时，系统随时可能挂起转录：如实标「已暂停」，回前台自动清掉。
        final bool paused = _backgrounded && !_anyAudioPlaying;
        return TaskActivitySample(
          jobId: job.id,
          attributes: _taskAttributes,
          state: _taskState(job, paused: paused),
        );
      }
    }
    return null;
  }

  TaskActivitySample? _finishedTask(String jobId) {
    final AudiobookTranscribeImportQueue? queue = _queue;
    if (queue == null) return null;
    for (final AudiobookTranscribeJob job in queue.jobs) {
      if (job.id != jobId) continue;
      if (job.status != AudiobookTranscribeJobStatus.done) return null;
      return TaskActivitySample(
        jobId: job.id,
        attributes: _taskAttributes,
        state: _taskState(job, finished: true),
      );
    }
    return null;
  }

  bool get _anyAudioPlaying =>
      (_controller?.isPlaying ?? false) || (_music?.isPlaying ?? false);

  TaskActivityState _taskState(
    AudiobookTranscribeJob job, {
    bool paused = false,
    bool finished = false,
  }) {
    final double progress = finished ? 1 : (job.progress ?? 0);
    return TaskActivityState(
      title: finished
          ? t.widget_activity_transcribe_done
          : t.widget_activity_transcribe_title,
      detail: finished
          ? job.title
          : '${job.title} · ${audiobookTranscribeJobStatusLabel(job, compact: true)}',
      progress: progress,
      // 匹配正文 / 入库没有数值进度：不编百分比，只显示步骤名。
      percentLabel: finished || job.progress != null
          ? formatAsrPercent(progress)
          : '…',
      pausedNote: paused ? t.widget_activity_task_paused : null,
      finished: finished,
    );
  }
}

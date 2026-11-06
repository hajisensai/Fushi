/// 进程级音乐会话（设计 §7.5）：持有 [MusicPlayerEngine]，接系统媒体会话（锁屏 /
/// 通知 / 耳机键），与有声书互斥——同一时刻只有一方持有媒体会话，另一方暂停。
/// 播放流（最近播放）与逐曲断点（`music_resume.dart`）也在这里落库。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/music/music_history.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_queue_feed.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_favorites.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/i18n/strings.g.dart';

/// 一首播完算「听完」的容差。
const Duration kMusicCompletionSlack = Duration(seconds: 2);

/// 断点写入节流：在播时位置每变这么多才写一次（进程被杀最多丢这么多）。
const Duration kMusicResumeWriteStep = Duration(seconds: 5);

/// 断点写入节流：没在播（暂停 / 播完 / 暂停时拖动）时，位置变了这么多就写。
const Duration kMusicResumeIdleWriteStep = Duration(seconds: 1);

/// 播放失败的提示文字。
String musicPlaybackFailureText(MusicBackendFailed failure) =>
    switch (failure.reason) {
      MusicPlaybackFailure.cdNoDisc => t.music_cd_play_no_disc(
        device: failure.device ?? '',
      ),
      MusicPlaybackFailure.cdOtherDisc => t.music_cd_play_other_disc(
        device: failure.device ?? '',
      ),
      MusicPlaybackFailure.appleMusicSessionLost =>
        t.music_apple_music_session_lost,
      MusicPlaybackFailure.appleMusicSignedOut =>
        t.music_apple_music_signed_out,
      MusicPlaybackFailure.trackUnavailable ||
      null => t.music_play_failed(error: failure.message),
    };

class MusicSession extends ChangeNotifier {
  MusicSession({
    required this.engine,
    required AudioController audio,
    required AudiobookSession audiobook,
    required FushiDatabase? Function() database,
    required bool Function() showMediaNotification,
    this.favorites,
    this.appleMusicFavorites,
    MusicResumeMode Function()? resumeMode,
  }) : _audio = audio,
       _audiobook = audiobook,
       _database = database,
       _showMediaNotification = showMediaNotification,
       _resumeMode = resumeMode ?? (() => MusicResumeMode.longTracks) {
    engine
      // 独占 / 指定设备打不开、已自动退回：明确提示，不静默（设计 §14）。
      ..onOutputFallback = (MusicBackendOutputFallback f) {
        FushiToast.show(
          msg: switch (f.reason) {
            MusicOutputFallbackReason.exclusiveUnavailable =>
              t.music_output_fallback_exclusive,
            MusicOutputFallbackReason.deviceUnavailable =>
              t.music_output_fallback_device,
          },
        );
      }
      // 播放失败：音频 CD 没盘 / 换了盘说清楚是哪台光驱，其余带上 mpv 的原文。
      ..onPlaybackFailed = (MusicBackendFailed f) {
        FushiToast.show(msg: musicPlaybackFailureText(f));
      }
      ..onWillPlay = _onWillPlay
      ..onTrackStarted = _onTrackStarted
      ..onTrackLeft = _onTrackLeft
      ..resolveStartPosition = _resolveStartPosition
      ..addListener(_onEngineChanged);
    _audiobook.addListener(_onAudiobookChanged);
    favorites?.addListener(notifyListeners);
    appleMusicFavorites?.addListener(notifyListeners);
    _subs.addAll(<StreamSubscription<Object?>>[
      _audio
          .streamFor(_audio.playIntentStream, MediaSessionOwner.music)
          .listen(_onPlayIntent),
      _audio
          .streamFor(_audio.seekStream, MediaSessionOwner.music)
          .listen((Duration p) => unawaited(engine.seek(p))),
      _audio
          .streamFor(_audio.skipNextStream, MediaSessionOwner.music)
          .listen((_) => unawaited(engine.skipNext())),
      _audio
          .streamFor(_audio.skipPreviousStream, MediaSessionOwner.music)
          .listen((_) => unawaited(engine.skipPrevious())),
      _audio
          .streamFor(_audio.rewindStream, MediaSessionOwner.music)
          .listen(
            (_) => unawaited(engine.seekRelative(const Duration(seconds: -5))),
          ),
      _audio
          .streamFor(_audio.fastForwardStream, MediaSessionOwner.music)
          .listen(
            (_) => unawaited(engine.seekRelative(const Duration(seconds: 5))),
          ),
    ]);
  }

  final MusicPlayerEngine engine;
  final AudioController _audio;

  /// 电台式续播（在线插件的个人电台 / 以某首起电台）：快放完时再取一批拼到队尾。
  late final MusicQueueFeedRunner queueFeeds = MusicQueueFeedRunner(engine);

  /// audio_service 只在 Android / iOS / macOS 有平台实现（系统媒体会话 + 通知 / 锁屏
  /// 控制）；其余平台不为音乐单独起它。测试可覆盖。
  @visibleForTesting
  static bool hasSystemMediaSession =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  final AudiobookSession _audiobook;
  final FushiDatabase? Function() _database;
  final bool Function() _showMediaNotification;

  /// 断点续播模式（设置 `music_resume_mode`）。
  final MusicResumeMode Function() _resumeMode;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  /// 歌曲收藏 = 在线平台账号的「喜欢」（插件 `like` 能力）；没有插件音源的平台为 null。
  /// 收藏状态变化时本会话也 [notifyListeners]；只关心收藏的界面可以直接听它。
  final MusicPluginFavorites? favorites;

  /// Apple Music 整曲的「喜欢」（Apple Music 评分）；本平台不能整曲播放时也在，只是
  /// [AppleMusicFavorites.canFavorite] 为 false。变化时本会话也 [notifyListeners]。
  final AppleMusicFavorites? appleMusicFavorites;

  /// 这一首能不能收藏：声明了 `like` 的插件曲目，或已连接账号时的 Apple Music 整曲；
  /// 本地 / 其它服务器曲目为 false。
  bool canFavorite(MusicPlayItem item) =>
      (favorites?.canFavorite(item) ?? false) ||
      (appleMusicFavorites?.canFavorite(item) ?? false);

  /// 这一首是否已在平台上喜欢（同步读内存缓存，首次读时后台拉取）。
  bool isFavorite(MusicPlayItem item) {
    final AppleMusicFavorites? am = appleMusicFavorites;
    if (am != null && am.canFavorite(item)) return am.isFavorite(item);
    return favorites?.isFavorite(item) ?? false;
  }

  /// 喜欢 ↔ 取消喜欢（调插件；成功后更新缓存并通知）。失败抛出让 UI 提示：
  /// [MusicFavoriteUnsupported]（不能收藏）、[MusicFavoriteLoginRequired]（引导登录）、
  /// `MusicPluginException`（插件 / 平台报错）。
  Future<void> toggleFavorite(MusicPlayItem item) {
    final AppleMusicFavorites? am = appleMusicFavorites;
    if (am != null && am.canFavorite(item)) return am.toggle(item);
    final MusicPluginFavorites? f = favorites;
    if (f == null) {
      return Future<void>.error(const MusicFavoriteUnsupported());
    }
    return f.toggle(item);
  }

  bool _audioSessionSubscribed = false;
  bool _resumeAfterInterruption = false;

  int? _playEventId;
  MusicPlayItem? _playEventItem;

  bool get isActive => engine.isActive;

  /// 锁屏 / 媒体通知副标题要显示的当前歌词行（设计 §6.2；null = 显示艺人）。由 AppModel
  /// 接到 `MusicLyricsLive.mediaSessionLine`，行变化时调 [refreshMediaSession]。
  String? Function()? mediaSessionLyricLine;

  /// 当前行变了：重发媒体会话元数据。
  void refreshMediaSession() => _publishMediaSession();

  void _onPlayIntent(MediaPlayIntent intent) {
    switch (intent) {
      case MediaPlayIntent.play:
        unawaited(engine.play());
      case MediaPlayIntent.pause:
        unawaited(engine.pause());
      case MediaPlayIntent.toggle:
        unawaited(engine.togglePlayPause());
    }
  }

  /// 系统音频会话（设计 §7.5）：mpv 不管 Android 音频焦点 / iOS AVAudioSession，
  /// 由 audio_session 接——耳机拔出暂停、来电等打断暂停并在系统允许时恢复。
  /// 蓝牙 / 线控按键走 audio_service 的媒体按键（[AudioController] 的意图流）。
  ///
  /// 每次开播都重新 configure：有声书用的是 spokenAudio 模式，两边共用同一个系统会话。
  Future<void> _ensureAudioSession() async {
    final AudioSession session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.longFormAudio,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        // 被短暂压低（导航播报等）时系统自己降音量，不暂停。
        androidWillPauseWhenDucked: false,
      ),
    );
    if (_audioSessionSubscribed) return;
    _audioSessionSubscribed = true;
    _subs.add(
      session.becomingNoisyEventStream.listen((_) {
        // 耳机拔出 / 蓝牙断开：立即暂停，不外放。
        if (engine.isPlaying) unawaited(engine.pause());
      }),
    );
    _subs.add(session.interruptionEventStream.listen(_onInterruption));
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (engine.isPlaying) {
            _resumeAfterInterruption =
                event.type == AudioInterruptionType.pause;
            unawaited(engine.pause());
          }
      }
      return;
    }
    // 打断结束：只有系统表示可以恢复（暂时性打断，如来电挂断）才自动续播。
    if (event.type == AudioInterruptionType.pause && _resumeAfterInterruption) {
      unawaited(engine.play());
    }
    _resumeAfterInterruption = false;
  }

  /// 音乐要开始出声：认领媒体会话，正在放的有声书暂停（不停会话，回去还能接着听）。
  void _onWillPlay() {
    unawaited(
      _ensureAudioSession().then(
        (_) async => (await AudioSession.instance).setActive(true),
      ),
    );
    _audio.claimSession(MediaSessionOwner.music);
    // audio_service 之前只在开书 / 有声书时才起（openMedia）：先放音乐的话 handler 还是
    // null，_publishMediaSession 直接返回——没有锁屏 / 通知控制，桌面小组件的原生按钮也
    // 连不上会话。这里起跑同一份记忆化初始化，就绪后补发一次当前状态。只在 audio_service
    // 有平台实现（系统媒体会话）的平台上起。
    if (hasSystemMediaSession) {
      unawaited(_audio.initialiseHandler().then((_) => _publishMediaSession()));
    }
    final controller = _audiobook.controller;
    if (controller != null && controller.isPlaying) {
      unawaited(controller.pause());
    }
  }

  /// 有声书开始出声：把会话让回去，音乐暂停。
  void _onAudiobookChanged() {
    final controller = _audiobook.controller;
    if (controller == null || !controller.isPlaying) return;
    if (_audio.sessionOwner.value != MediaSessionOwner.audiobook) {
      _audio.claimSession(MediaSessionOwner.audiobook);
    }
    if (engine.isPlaying) unawaited(engine.pause());
  }

  void _onTrackStarted(MusicPlayItem item) {
    // 引擎此时已把位置清零给新曲：上一首播到哪要读它清零前存下的值（同步读，免得被后续
    // 位置推送覆盖）。
    unawaited(_rotatePlayEvent(item, listened: engine.listenedBeforeStart));
  }

  Future<void> _rotatePlayEvent(
    MusicPlayItem? next, {
    Duration? listened,
  }) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    await _finishPlayEvent(db, listened: listened);
    if (next == null) return;
    _playEventItem = next;
    _playEventId = await db.startMusicPlayEvent(
      trackUid: next.trackUid,
      startedAt: DateTime.now().millisecondsSinceEpoch,
      snapshot: musicPlayEventSnapshotOf(next, source: engine.source),
    );
  }

  /// 最近播放的曲目（按曲目去重，新的在前；含在线插件 / 服务器曲目）。没有数据库时为空。
  Future<List<MusicRecentTrack>> recentTracks({int limit = 20}) async {
    final FushiDatabase? db = _database();
    if (db == null) return const <MusicRecentTrack>[];
    return loadRecentMusicTracks(db, limit: limit);
  }

  /// 最近播放的来源（专辑 / 歌单 …，按来源去重，新的在前）。没有数据库时为空。
  Future<List<MusicRecentPlaySource>> recentSources({
    int limit = 20,
    Set<MusicPlaySourceKind>? kinds,
  }) async {
    final FushiDatabase? db = _database();
    if (db == null) return const <MusicRecentPlaySource>[];
    return loadRecentMusicSources(db, limit: limit, kinds: kinds);
  }

  /// 结算当前播放事件。[listened] 缺省取引擎当前位置（停止 / 释放时还没清零）。
  Future<void> _finishPlayEvent(FushiDatabase db, {Duration? listened}) async {
    final int? id = _playEventId;
    final MusicPlayItem? item = _playEventItem;
    _playEventId = null;
    _playEventItem = null;
    if (id == null || item == null) return;
    final Duration played = listened ?? engine.position;
    final int? durationMs = item.durationMs;
    await db.finishMusicPlayEvent(
      id,
      listenedMs: played.inMilliseconds,
      completed:
          durationMs != null &&
          played + kMusicCompletionSlack >= Duration(milliseconds: durationMs),
    );
  }

  void _onEngineChanged() {
    _publishMediaSession();
    _maybeWriteResumePoint();
    notifyListeners();
  }

  // ── 逐曲断点续播（music_resume.dart）──

  /// 断点写入串行队列：同一首的写与随后的读（再打开时）按提交顺序落库。
  Future<void> _resumeWrites = Future<void>.value();

  /// 测试用：等已提交的断点写全部落库。
  @visibleForTesting
  Future<void> get resumeWritesIdle => _resumeWrites;

  /// 最近一次提交写入的（trackUid, 位置毫秒），节流用。
  ({String uid, int ms})? _resumeWritten;

  /// [item] 的断点记不记：后端能从曲内起播（Apple Music 不能）、不是自管队列（电台）、
  /// 续播模式对这首曲长开着。
  bool _resumeTracked(MusicPlayItem item, int? durationMs) {
    final MusicBackendCapabilities caps = engine.capabilitiesFor(item);
    if (!caps.startAt || caps.externalQueue) return false;
    return musicResumeApplies(mode: _resumeMode(), durationMs: durationMs);
  }

  static int? _durationMsOf(MusicPlayItem item, Duration? reported) =>
      reported != null && reported > Duration.zero
      ? reported.inMilliseconds
      : item.durationMs;

  /// 引擎状态变了：当前曲的位置按节流写盘。在播时每 [kMusicResumeWriteStep]、没在播时
  /// （暂停 / 播完 / 暂停时拖动——系统媒体控件、耳机、进度条都可能）每
  /// [kMusicResumeIdleWriteStep]。打开中 / 断点恢复还没落地时不写（位置是过渡值）。
  void _maybeWriteResumePoint() {
    final MusicPlayItem? item = engine.startedItem;
    if (item == null || engine.resolving || engine.restoringResume) return;
    final int? durationMs = _durationMsOf(item, engine.duration);
    if (!_resumeTracked(item, durationMs)) return;
    final int ms = engine.position.inMilliseconds;
    final ({String uid, int ms})? last = _resumeWritten;
    // 刚打开、还一点没放（从头放的打开，如「从头播放」/「上一首」）：不急着删旧断点，
    // 真放起来后被新位置覆盖；换下 / 退出时的结算照常按位置写。
    if (ms == 0 && last?.uid != item.trackUid) return;
    final Duration step = engine.isPlaying
        ? kMusicResumeWriteStep
        : kMusicResumeIdleWriteStep;
    if (last != null &&
        last.uid == item.trackUid &&
        (ms - last.ms).abs() < step.inMilliseconds) {
      return;
    }
    _queueResumeWrite(item.trackUid, ms, durationMs);
  }

  /// 一首被换下：按它换下前的位置结算（不节流）。恢复没落地时不写（库里还是原断点）。
  void _onTrackLeft(MusicTrackLeave leave) {
    if (leave.restoring) return;
    final int? durationMs = _durationMsOf(leave.item, leave.duration);
    if (!_resumeTracked(leave.item, durationMs)) return;
    _queueResumeWrite(
      leave.item.trackUid,
      leave.position.inMilliseconds,
      durationMs,
    );
  }

  void _queueResumeWrite(String uid, int positionMs, int? durationMs) {
    _resumeWritten = (uid: uid, ms: positionMs);
    final int now = DateTime.now().millisecondsSinceEpoch;
    _resumeWrites = _resumeWrites.then((_) async {
      final FushiDatabase? db = _database();
      if (db == null) return;
      try {
        if (musicResumePointIsFinished(
          positionMs: positionMs,
          durationMs: durationMs,
        )) {
          await db.deleteMusicResumePoint(uid);
        } else {
          await db.upsertMusicResumePoint(
            uid,
            positionMs: positionMs,
            durationMs: durationMs,
            updatedAt: now,
          );
        }
      } on Object catch (e, st) {
        // 一笔写失败（库正在关）不能断掉后面的写：记日志，队列继续。
        ErrorLogService.instance.log('MusicSession.resumePoint', e, st);
      }
    });
  }

  /// 把当前曲此刻的位置写穿并等所有断点写落库：进后台（Android 后台播放可能被杀）与
  /// 退出（`ExitFlushRegistry`）时调。
  Future<void> flushResumePoint() async {
    final MusicPlayItem? item = engine.startedItem;
    if (item != null && !engine.resolving && !engine.restoringResume) {
      final int? durationMs = _durationMsOf(item, engine.duration);
      if (_resumeTracked(item, durationMs)) {
        _queueResumeWrite(
          item.trackUid,
          engine.position.inMilliseconds,
          durationMs,
        );
      }
    }
    await _resumeWrites;
  }

  /// 打开 [item] 时从哪开始放（引擎的 [MusicPlayerEngine.resolveStartPosition]）。先等
  /// 在途的断点写落库：刚换下的同一首（切走又切回）要读到它刚写的位置。
  Future<Duration> _resolveStartPosition(
    MusicPlayItem item,
    EpisodeStartIntent intent,
  ) async {
    final MusicResumeMode mode = _resumeMode();
    if (!musicResumeApplies(mode: mode, durationMs: item.durationMs)) {
      return Duration.zero;
    }
    await _resumeWrites;
    final FushiDatabase? db = _database();
    if (db == null) return Duration.zero;
    final MusicResumePointRow? row;
    try {
      row = await db.getMusicResumePoint(item.trackUid);
    } on Object catch (e, st) {
      // 读不到断点不能挡住播放：从头放，记日志。
      ErrorLogService.instance.log('MusicSession.resumePoint', e, st);
      return Duration.zero;
    }
    return resolveMusicResumeStart(
      mode: mode,
      intent: intent,
      savedPositionMs: row?.positionMs,
      durationMs: item.durationMs ?? row?.durationMs,
    );
  }

  /// 清掉 [trackUid] 的断点（曲目详情「清除播放位置」）。正在放的就是它时，从此刻起重新记。
  Future<void> clearResumePoint(String trackUid) async {
    if (_resumeWritten?.uid == trackUid) _resumeWritten = null;
    await _resumeWrites;
    await _database()?.deleteMusicResumePoint(trackUid);
    notifyListeners();
  }

  void _publishMediaSession() {
    if (_audio.sessionOwner.value != MediaSessionOwner.music) return;
    if (!_showMediaNotification()) return;
    final FushiAudioHandler? handler = _audio.audioHandler;
    final MusicPlayItem? item = engine.current;
    if (handler == null) return;
    if (item == null) {
      handler.clearNotification();
      return;
    }
    final String? cover = item.coverPath;
    handler.setMediaItemInfo(
      title: item.title,
      artist: item.artist,
      duration: item.durationMs == null
          ? null
          : Duration(milliseconds: item.durationMs!),
      // 服务器曲库的封面是 http(s) 地址（audio_service 自己下载），本地封面是文件。
      artUri: cover == null
          ? null
          : (cover.startsWith('http://') || cover.startsWith('https://'))
          ? Uri.parse(cover)
          : (File(cover).existsSync() ? Uri.file(cover) : null),
    );
    final String? line = mediaSessionLyricLine?.call();
    if (line != null) {
      handler.updateNotificationSubtitle(
        title: item.title,
        subtitle: line,
        fallbackArtist: item.artist,
      );
    }
    handler.updatePlaybackState(
      playing: engine.isPlaying,
      position: engine.position,
      speed: engine.currentSettings.speed,
      duration: engine.duration ?? Duration.zero,
    );
  }

  /// 停止音乐并释放媒体会话。停止时的位置经 [MusicPlayerEngine.onTrackLeft] 结算断点，
  /// 这里等它落库。
  Future<void> stop() async {
    final FushiDatabase? db = _database();
    if (db != null) await _finishPlayEvent(db);
    await engine.stop();
    await _resumeWrites;
    if (_audio.sessionOwner.value == MediaSessionOwner.music) {
      _audio.audioHandler?.clearNotification();
      _audio.claimSession(MediaSessionOwner.none);
    }
  }

  @override
  void dispose() {
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _audiobook.removeListener(_onAudiobookChanged);
    favorites?.removeListener(notifyListeners);
    favorites?.dispose();
    appleMusicFavorites?.removeListener(notifyListeners);
    appleMusicFavorites?.dispose();
    engine.removeListener(_onEngineChanged);
    queueFeeds.dispose();
    engine.dispose();
    super.dispose();
  }
}

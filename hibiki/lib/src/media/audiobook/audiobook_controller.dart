import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';

/// 有声书播放控制器。
///
/// 职责：
/// - 持有 [AudioPlayer]，管理单文件或多文件播放（[ConcatenatingAudioSource]）；
/// - 每 200 ms 轮询 positionStream，在当前章节 cue 列表中二分定位当前句；
/// - 暴露 [currentCue]、[isPlaying]、[position] 供 UI 订阅；
/// - 提供 play/pause/seek/skipToCue/setSpeed API。
class AudiobookPlayerController extends ChangeNotifier {
  AudiobookPlayerController();

  // ── 内部状态 ──────────────────────────────────────────────────────────────

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;

  /// 当前书的元数据（null = 未加载）。PR4 中用于更新锁屏媒体卡片。
  Audiobook? _audiobook;

  /// 当前书的元数据（PR4 集成时供外部读取）。
  Audiobook? get audiobook => _audiobook;

  /// 当前章节所有 cue（已按 startMs 排序）。
  List<AudioCue> _chapterCues = [];

  /// 多文件时每个文件的全局起始毫秒偏移量（index → offsetMs）。
  List<int> _fileOffsets = [];

  // ── 对外暴露的状态 ─────────────────────────────────────────────────────────

  /// 当前正在朗读的 cue，null = 未定位到句子。
  AudioCue? get currentCue => _currentCue;
  AudioCue? _currentCue;

  /// 是否正在播放。
  bool get isPlaying => _player.playing;

  /// 当前全局播放位置。
  Duration get position => _player.position;

  /// 总时长（多文件为所有文件之和）。
  Duration get duration => _player.duration ?? Duration.zero;

  /// 当前速度。
  double get speed => _player.speed;

  // ── 初始化 ─────────────────────────────────────────────────────────────────

  /// 加载有声书并配置音频会话。
  ///
  /// [audiobook]  有声书元数据（已存入 Isar）。
  /// [audioFiles] 按顺序排列的音频文件列表（与 AudioCue.audioFileIndex 对应）。
  ///
  /// 加载完成后会从 Hive (`appModel` box) 读取上次保存的播放位置并
  /// `seek` 过去，避免页面重建（背景回前台 / 路由重建）时音频从头开始。
  Future<void> load({
    required Audiobook audiobook,
    required List<File> audioFiles,
  }) async {
    _audiobook = audiobook;

    await _player.stop();
    _positionSub?.cancel();
    _playingSub?.cancel();

    await _configureAudioSession();

    if (audioFiles.length == 1) {
      await _player.setAudioSource(
        AudioSource.file(audioFiles.first.path),
      );
      _fileOffsets = [0];
    } else {
      // 多文件：先逐个设置以获取时长，计算累计偏移
      _fileOffsets = [];
      int cumulative = 0;
      final List<AudioSource> sources = [];
      for (final File f in audioFiles) {
        _fileOffsets.add(cumulative);
        final Duration? dur = await _durationOf(f);
        cumulative += dur?.inMilliseconds ?? 0;
        sources.add(AudioSource.file(f.path));
      }
      await _player.setAudioSource(ConcatenatingAudioSource(children: sources));
    }

    // 恢复上次播放位置（页面重建场景下避免音频回到 0）。
    final int savedMs = _readSavedPositionMs(audiobook.bookUid);
    if (savedMs > 0) {
      try {
        await _player.seek(Duration(milliseconds: savedMs));
      } catch (e) {
        debugPrint('[hibiki-audiobook] seek to saved $savedMs ms failed: $e');
      }
    }

    _startPositionTracking();
    notifyListeners();
  }

  // ── 进度持久化 ─────────────────────────────────────────────────────────────

  /// Hive 里保存上次播放位置的 key 前缀（值为全局毫秒 int）。
  static const String _kPositionKeyPrefix = 'audiobook_pos_';

  /// 上次写入的位置（毫秒），用于节流。
  int _lastSavedPosMs = -1;

  /// 写入节流阈值：position 与上次保存差值小于该值时跳过。
  static const int _kPositionSaveThresholdMs = 3000;

  Box? _prefsBox() {
    if (!Hive.isBoxOpen('appModel')) return null;
    return Hive.box('appModel');
  }

  int _readSavedPositionMs(String bookUid) {
    final Box? box = _prefsBox();
    if (box == null) return 0;
    final Object? raw = box.get('$_kPositionKeyPrefix$bookUid');
    if (raw is int) return raw;
    return 0;
  }

  /// 把当前播放位置写入 Hive。被节流：3 秒内的连续调用只生效一次。
  ///
  /// 调用时机：cue 变化（_updateCurrentCue）、暂停、dispose。
  void _maybeSavePosition({bool force = false}) {
    final String? uid = _audiobook?.bookUid;
    if (uid == null) return;
    final Box? box = _prefsBox();
    if (box == null) return;
    final int posMs = _player.position.inMilliseconds;
    if (!force && (posMs - _lastSavedPosMs).abs() < _kPositionSaveThresholdMs) {
      return;
    }
    _lastSavedPosMs = posMs;
    box.put('$_kPositionKeyPrefix$uid', posMs);
  }

  /// 切换章节后更新当前章节的 cue 列表。
  ///
  /// 调用后控制器会继续播放（若已在播放），高亮随之跳转到新章节的 cue。
  /// 立即基于当前播放位置解析 currentCue，避免播放栏/高亮在 positionStream
  /// 下一次 tick 之前出现空白（尤其是暂停状态下 positionStream 不发事件）。
  void setChapterCues(List<AudioCue> cues) {
    _chapterCues = List<AudioCue>.from(cues)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    _currentCue = null;
    _updateCurrentCue(_player.position.inMilliseconds);
    notifyListeners();
  }

  // ── 播放控制 API ───────────────────────────────────────────────────────────

  /// 开始播放。
  ///
  /// 不 await `_player.play()`：just_audio 的 `play()` 返回的 Future 在播放
  /// **结束或暂停**时才完成，await 会让调用方误以为播放迟迟没启动。真正的
  /// 播放状态翻转通过 [_playingSub] 订阅 `playingStream` 拿到，立刻触发
  /// `notifyListeners()`，按钮图标不需要等网络/缓冲。
  Future<void> play() async {
    unawaited(_player.play());
  }

  Future<void> pause() async {
    await _player.pause();
    _maybeSavePosition(force: true);
  }

  Future<void> togglePlayPause() async {
    if (_player.playing) {
      await pause();
    } else {
      await play();
    }
  }

  /// 跳转到全局毫秒位置。
  Future<void> seekMs(int positionMs) async {
    await _player.seek(Duration(milliseconds: positionMs));
    notifyListeners();
  }

  /// 快进 / 快退（秒）。
  Future<void> seekRelative(int deltaSeconds) async {
    final int newMs =
        (position.inMilliseconds + deltaSeconds * 1000).clamp(0, duration.inMilliseconds);
    await seekMs(newMs);
  }

  /// 跳转到指定 cue 的起始位置。
  Future<void> skipToCue(AudioCue cue) async {
    final int globalMs = _toGlobalMs(cue);
    await seekMs(globalMs);
  }

  /// 跳到上一句（当前章节 cue 列表内）。
  ///
  /// 若距离当前 cue 起始已超过 1.5s，则回到当前 cue 起始（等效 restart）；
  /// 否则跳到前一个 cue。没有定位到 cue 时跳到第一句。
  Future<void> skipToPrevCue() async {
    if (_chapterCues.isEmpty) return;
    final int posMs = position.inMilliseconds;
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: _chapterCues,
      positionMs: posMs,
    );
    if (idx < 0) {
      await skipToCue(_chapterCues.first);
      return;
    }
    final int cueGlobalMs = _toGlobalMs(_chapterCues[idx]);
    if (posMs - cueGlobalMs > 1500 || idx == 0) {
      await skipToCue(_chapterCues[idx]);
      return;
    }
    await skipToCue(_chapterCues[idx - 1]);
  }

  /// 跳到下一句（当前章节 cue 列表内）。
  ///
  /// 已在最后一句则不动作。未定位到 cue 时跳到第一句。
  Future<void> skipToNextCue() async {
    if (_chapterCues.isEmpty) return;
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: _chapterCues,
      positionMs: position.inMilliseconds,
    );
    if (idx < 0) {
      await skipToCue(_chapterCues.first);
      return;
    }
    if (idx + 1 >= _chapterCues.length) return;
    await skipToCue(_chapterCues[idx + 1]);
  }

  /// 设置播放速度（例如 0.75 / 1.0 / 1.25 / 1.5）。
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    notifyListeners();
  }

  // ── 内部实现 ───────────────────────────────────────────────────────────────

  Future<void> _configureAudioSession() async {
    final AudioSession session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidWillPauseWhenDucked: false,
      ),
    );
    session.becomingNoisyEventStream.listen((_) {
      _player.pause();
    });
  }

  void _startPositionTracking() {
    _positionSub = _player.positionStream.listen((pos) {
      _updateCurrentCue(pos.inMilliseconds);
    });
    // 订阅播放状态流：just_audio 内部状态翻转（包括焦点丢失、播完自动暂停）
    // 都会在这里得到通知，UI 即时刷新播放/暂停图标。
    _playingSub = _player.playingStream.listen((_) {
      notifyListeners();
    });
  }

  void _updateCurrentCue(int posMs) {
    if (_chapterCues.isEmpty) {
      return;
    }
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: _chapterCues,
      positionMs: posMs,
    );
    final AudioCue? newCue = idx >= 0 ? _chapterCues[idx] : null;
    if (newCue?.textFragmentId != _currentCue?.textFragmentId) {
      _currentCue = newCue;
      _maybeSavePosition();
      notifyListeners();
    }
  }

  /// 将 cue 的 per-file 毫秒转换为全局毫秒（多文件场景）。
  int _toGlobalMs(AudioCue cue) {
    final int offset = cue.audioFileIndex < _fileOffsets.length
        ? _fileOffsets[cue.audioFileIndex]
        : 0;
    return offset + cue.startMs;
  }

  /// 读取音频文件时长（用于多文件累计偏移计算）。
  static Future<Duration?> _durationOf(File file) async {
    final AudioPlayer probe = AudioPlayer();
    try {
      final Duration? d = await probe.setFilePath(file.path);
      return d;
    } catch (_) {
      return null;
    } finally {
      await probe.dispose();
    }
  }

  // ── 生命周期 ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _maybeSavePosition(force: true);
    _positionSub?.cancel();
    _playingSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

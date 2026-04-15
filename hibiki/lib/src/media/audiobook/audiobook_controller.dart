import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
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
  Future<void> load({
    required Audiobook audiobook,
    required List<File> audioFiles,
  }) async {
    _audiobook = audiobook;

    await _player.stop();
    _positionSub?.cancel();

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

    _startPositionTracking();
    notifyListeners();
  }

  /// 切换章节后更新当前章节的 cue 列表。
  ///
  /// 调用后控制器会继续播放（若已在播放），高亮随之跳转到新章节的 cue。
  void setChapterCues(List<AudioCue> cues) {
    _chapterCues = List<AudioCue>.from(cues)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    _currentCue = null;
    notifyListeners();
  }

  // ── 播放控制 API ───────────────────────────────────────────────────────────

  Future<void> play() async {
    await _player.play();
    notifyListeners();
  }

  Future<void> pause() async {
    await _player.pause();
    notifyListeners();
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
      _player.pause().then((_) => notifyListeners());
    });
  }

  void _startPositionTracking() {
    _positionSub = _player.positionStream.listen((pos) {
      _updateCurrentCue(pos.inMilliseconds);
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
    _positionSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

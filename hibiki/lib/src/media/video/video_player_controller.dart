import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频播放控制器：用 media_kit 播放视频，并按字幕 cue 做 125ms 同步高亮。
///
/// cue 选择语义照搬有声书 [AudiobookPlayerController] 的 `_updateCurrentCue`：
/// endMs 闭区间、gap（[JsonAlignmentParser.findCueIndex] 返回 -1）保留上一句
/// 高亮、同句不重复 [notifyListeners]、delayMs 扣减位置。
///
/// 与有声书的关键差异：位置来源不是 just_audio 的 positionStream，而是
/// [Timer.periodic]（125ms）读 `player.state.position`；播放后端是 media_kit
/// [Player]。
///
/// 设计约束（务必遵守）：
/// - [Player] / [VideoController] **延迟构造**：构造函数只初始化纯 cue 状态，
///   不 `new Player()`，因为测试宿主无 libmpv，构造即抛。真正实例化放在 [load]。
/// - cue 选择逻辑抽成可测的 [updateCueForPosition]，并经 [debugUpdateCueForPosition]
///   暴露给单测——单测只调 [setCues] + [debugUpdateCueForPosition]，不触发 Player。
class VideoPlayerController extends ChangeNotifier {
  Player? _player;
  VideoController? _videoController;

  List<AudioCue> _cues = <AudioCue>[];
  AudioCue? _currentCue;
  int _currentCueIndex = -1;

  /// 音画延迟（毫秒）：正值表示"视频比文字先播"，查 cue 时把位置往回拨。
  int _delayMs = 0;

  Timer? _tick;
  StreamSubscription<bool>? _playingSub;

  String? _bookUid;

  /// 上次持久化时的整秒位置；用于 [_maybeSavePosition] 节流到每秒至多一次。
  int _lastSavedSec = -1;

  /// 位置持久化回调：整秒变化时调用，由上层（repository）落库。
  Future<void> Function(String bookUid, int positionMs)? onPositionWrite;

  AudioCue? get currentCue => _currentCue;

  int get currentCueIndex => _currentCueIndex;

  List<AudioCue> get cues => _cues;

  VideoController? get videoController => _videoController;

  bool get isPlaying => _player?.state.playing ?? false;

  /// 设置 cue 列表：拷贝并按 startMs 升序排序（[JsonAlignmentParser.findCueIndex]
  /// 要求升序），重置当前 cue 状态。
  void setCues(List<AudioCue> cues) {
    _cues = List<AudioCue>.of(cues)
      ..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
    _currentCue = null;
    _currentCueIndex = -1;
    notifyListeners();
  }

  /// 设置音画延迟（毫秒），clamp 到 ±600000（±10 分钟）。
  void setDelayMs(int delayMs) {
    _delayMs = delayMs.clamp(-600000, 600000);
  }

  /// 加载视频并开始播放准备：实例化 [Player] / [VideoController]、打开视频、
  /// 可选挂载外挂字幕、设置初速、seek 到初始位置、订阅播放态、启动 125ms tick。
  ///
  /// 测试宿主无 libmpv，**不要在单测里调用**（会因 `new Player()` 抛）。
  Future<void> load({
    required String bookUid,
    required File videoFile,
    required List<AudioCue> cues,
    int initialPositionMs = 0,
    double initialSpeed = 1.0,
    String? externalSubtitlePath,
  }) async {
    _bookUid = bookUid;
    setCues(cues);

    // 重复 load：先释放上一次的 tick / 订阅 / player，避免泄漏。
    _tick?.cancel();
    _tick = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _player?.dispose();

    final Player player = Player();
    _player = player;
    _videoController = VideoController(player);

    await player.open(
      Media(videoFile.uri.toString()),
      play: false,
    );

    if (externalSubtitlePath != null && externalSubtitlePath.isNotEmpty) {
      await player.setSubtitleTrack(
        SubtitleTrack.uri(File(externalSubtitlePath).uri.toString()),
      );
    }

    await player.setRate(initialSpeed);
    if (initialPositionMs > 0) {
      await player.seek(Duration(milliseconds: initialPositionMs));
    }

    // 订阅播放态翻转（包括播完自动暂停、焦点丢失），即时刷新 UI 图标。
    _playingSub = player.stream.playing.listen((_) {
      notifyListeners();
    });

    // 125ms 周期读位置，驱动 cue 同步（对齐有声书 createPositionStream 的节奏）。
    _tick = Timer.periodic(const Duration(milliseconds: 125), (_) {
      final Player? p = _player;
      if (p == null) return;
      updateCueForPosition(p.state.position.inMilliseconds);
    });
  }

  /// cue 同步核心：照搬有声书 `_updateCurrentCue` 语义。
  ///
  /// 1. 先 [_maybeSavePosition]（位置持久化不受 cue gap guard 影响）。
  /// 2. 空 cues 直接返回。
  /// 3. `effectiveMs = posMs - delayMs`，下界 clamp 到 0。
  /// 4. [JsonAlignmentParser.findCueIndex] 二分定位；返回 -1（gap / 早于首句）
  ///    时**保留**上一句高亮，直接返回。
  /// 5. 命中下标与 [_currentCueIndex] 相同时不重复 [notifyListeners]。
  /// 6. 否则更新当前 cue 并通知。
  void updateCueForPosition(int posMs) {
    _maybeSavePosition(posMs);
    if (_cues.isEmpty) return;
    final int effectiveMs = (posMs - _delayMs).clamp(0, 1 << 30);
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: _cues,
      positionMs: effectiveMs,
    );
    // Gap：保持上一条 cue 不清高亮，避免闪烁。
    if (idx < 0) return;
    if (idx == _currentCueIndex) return;
    _currentCueIndex = idx;
    _currentCue = _cues[idx];
    notifyListeners();
  }

  @visibleForTesting
  void debugUpdateCueForPosition(int posMs) => updateCueForPosition(posMs);

  /// 整秒变化且 [_bookUid] 非空时，异步触发位置持久化（每秒至多一次）。
  void _maybeSavePosition(int posMs) {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    final int sec = posMs ~/ 1000;
    if (sec == _lastSavedSec) return;
    _lastSavedSec = sec;
    unawaited(onPositionWrite?.call(bookUid, posMs));
  }

  /// 开始播放（未 load 时 no-op 安全）。
  Future<void> play() async {
    await _player?.play();
  }

  /// 暂停（未 load 时 no-op 安全）。
  Future<void> pause() async {
    await _player?.pause();
  }

  /// 切换播放/暂停（未 load 时 no-op 安全）。
  Future<void> togglePlayPause() async {
    await _player?.playOrPause();
  }

  /// seek 到指定毫秒位置（未 load 时 no-op 安全）。
  Future<void> seekMs(int positionMs) async {
    await _player?.seek(Duration(milliseconds: positionMs.clamp(0, 1 << 30)));
  }

  /// 设置播放倍速（未 load 时 no-op 安全）。
  Future<void> setSpeed(double rate) async {
    await _player?.setRate(rate);
  }

  /// 跳到指定 cue 的起始位置。
  Future<void> skipToCue(AudioCue cue) async {
    await seekMs(cue.startMs);
  }

  /// 跳到下一句 cue（已是最后一句时 no-op）。
  Future<void> skipToNextCue() async {
    if (_cues.isEmpty) return;
    final int next = _currentCueIndex + 1;
    if (next < 0 || next >= _cues.length) return;
    await skipToCue(_cues[next]);
  }

  /// 跳到上一句 cue（已是第一句或未定位时 no-op）。
  Future<void> skipToPrevCue() async {
    if (_cues.isEmpty) return;
    final int prev = _currentCueIndex - 1;
    if (prev < 0 || prev >= _cues.length) return;
    await skipToCue(_cues[prev]);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    unawaited(_playingSub?.cancel());
    _playingSub = null;
    unawaited(_player?.dispose());
    _player = null;
    _videoController = null;
    super.dispose();
  }
}

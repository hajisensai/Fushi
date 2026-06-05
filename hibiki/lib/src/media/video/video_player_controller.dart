import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
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

  /// 最近一次 [setSpeed] / [load] 之倍速；player 未实例化时供 [speed] getter 回退。
  double _lastSpeed = 1.0;

  Timer? _tick;
  StreamSubscription<bool>? _playingSub;

  String? _bookUid;

  /// 视频文件绝对路径；制卡时按 cue 时间裁字幕音频片段用。
  String? _videoPath;

  /// 上次持久化时的整秒位置；用于 [_maybeSavePosition] 节流到每秒至多一次。
  int _lastSavedSec = -1;

  /// 位置持久化回调：整秒变化时调用，由上层（repository）落库。
  Future<void> Function(String bookUid, int positionMs)? onPositionWrite;

  AudioCue? get currentCue => _currentCue;

  int get currentCueIndex => _currentCueIndex;

  List<AudioCue> get cues => _cues;

  VideoController? get videoController => _videoController;

  /// 视频文件绝对路径（制卡裁字幕音频用）；未 [load] 时为空。
  String? get videoPath => _videoPath;

  bool get isPlaying => _player?.state.playing ?? false;

  /// 当前播放位置（毫秒）；未 [load] 时为 null。换集前用它补记当前集精确进度
  /// （tick 整秒节流外的尾差）。
  int? get positionMs => _player?.state.position.inMilliseconds;

  /// 当前音画延迟（毫秒）；设置面板显示用。
  int get delayMs => _delayMs;

  /// 当前播放倍速；未 [load] 时回退最近一次 [setSpeed] 之值（构造默认 1.0）。
  double get speed => _player?.state.rate ?? _lastSpeed;

  /// 截取当前解码帧为 JPEG 字节（制卡截图用）。未 [load] 返回 null。
  Future<Uint8List?> screenshot() async {
    return _player?.screenshot(format: 'image/jpeg');
  }

  /// 当前视频可用的字幕轨（含内嵌轨）；未 [load] 时为空。
  ///
  /// 为运行时切换 + Phase 1 内嵌字幕功能预留；无法纯单测（需真实 libmpv
  /// player），靠 analyze 验证编译。
  List<SubtitleTrack> get subtitleTracks =>
      _player?.state.tracks.subtitle ?? const <SubtitleTrack>[];

  /// 切换字幕轨（运行时 / Phase 1 预留）。未 [load] 时 no-op 安全。
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    await _player?.setSubtitleTrack(track);
  }

  /// 当前视频可用的音轨；未 [load] 时为空。
  List<AudioTrack> get audioTracks =>
      _player?.state.tracks.audio ?? const <AudioTrack>[];

  /// 切换音轨。未 [load] 时 no-op 安全。
  Future<void> selectAudioTrack(AudioTrack track) async {
    await _player?.setAudioTrack(track);
  }

  /// 当前选中音轨在「真实音轨列表」中的 0-based 序号（ffmpeg `-map 0:a:<idx>`
  /// 的 ordinal），用于制卡时把字幕音频片段裁到用户正在听的那条轨。
  ///
  /// libmpv 的 `tracks.audio` 是 `[auto, no, real0, real1…]`（demux 顺序），与
  /// ffmpeg `0:a:N` 的音频流顺序一致；当前选中轨取 `state.track.audio`。返回值是
  /// 选中轨在「去掉 auto/no 后的真实轨」里的下标。
  ///
  /// 返回 null 表示「跟随默认」（未选过具体轨，selected 为 auto/no，或单音轨视频）
  /// ——此时 ffmpeg 不加 `-map`，用其默认音频选择，与既有行为一致。
  int? get currentAudioStreamIndex {
    final Player? player = _player;
    if (player == null) return null;
    final AudioTrack selected = player.state.track.audio;
    if (selected.id == 'auto' || selected.id == 'no') return null;
    final List<AudioTrack> real = player.state.tracks.audio
        .where((AudioTrack t) => t.id != 'auto' && t.id != 'no')
        .toList(growable: false);
    // 单条真实轨时无需显式映射（ffmpeg 默认就选它），返回 null 保持简单。
    if (real.length <= 1) return null;
    final int idx = real.indexWhere((AudioTrack t) => t.id == selected.id);
    return idx < 0 ? null : idx;
  }

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
    _videoPath = videoFile.path;
    debugPrint('[video-load] cues=${cues.length} path=${videoFile.path}');
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

    // 关闭 libmpv 画面字幕渲染——字幕统一走可点击 overlay（cue 同步 + 逐字查词）。
    // mkv 内嵌字幕会被 libmpv 默认渲染成画面像素（不可点）；用户点它会穿透到视频层
    // 触发暂停而非查词。故一律关 libmpv 字幕，由 overlay 承载所有字幕（外挂 sidecar
    // 与内嵌抽取的 cue 都走 overlay）。externalSubtitlePath 已在上层解析成 cues 传入。
    await player.setSubtitleTrack(SubtitleTrack.no());

    _lastSpeed = initialSpeed;
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

    // 无外挂字幕且无 cue 时，桌面端后台抽内嵌字幕轨成可点击 cue（不阻塞首帧）。
    if ((externalSubtitlePath == null || externalSubtitlePath.isEmpty) &&
        cues.isEmpty) {
      unawaited(_loadEmbeddedSubtitleIfNeeded(bookUid: bookUid));
    }
  }

  /// 桌面端后台抽第一条内嵌字幕轨 → 解析成 cue → [setCues]，触发可点击 overlay。
  ///
  /// 仅当无外挂字幕且当前无 cue 时由 [load] 末尾触发（调用方已门控）。移动端跳过
  /// （ffmpeg 不可用），失败 / 无字幕轨静默返回，保留 libmpv 画面渲染兜底。
  ///
  /// 抽字幕较慢（ffmpeg 跑几秒），故 [load] 用 `unawaited` 后台触发不阻塞播放；
  /// 抽完才 [setCues]，overlay 此时才出现。期间若发生重新 [load]（[_videoPath]
  /// 变化）则丢弃旧结果，避免把上一段视频的字幕错挂到新视频。
  Future<void> _loadEmbeddedSubtitleIfNeeded({required String bookUid}) async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    final String? videoPath = _videoPath;
    if (videoPath == null) return;

    final Directory dir =
        Directory.systemTemp.createTempSync('hibiki_video_sub');
    final String outputPath = '${dir.path}/video_embedded_sub.ass';
    try {
      final String? extracted = await extractEmbeddedSubtitleViaFfmpeg(
        inputPath: videoPath,
        streamIndex: 0,
        outputPath: outputPath,
      );
      if (extracted == null) {
        debugPrint('[video-embedded-sub] no embedded subtitle track extracted');
        return;
      }
      // 抽字幕期间发生了重新 load（换片）：丢弃过期结果。
      if (_videoPath != videoPath) {
        debugPrint(
            '[video-embedded-sub] discarded stale result (video changed)');
        return;
      }
      final String text = await readTextWithEncoding(File(extracted));
      final List<AudioCue> cues =
          AssParser.parseString(content: text, bookUid: bookUid);
      if (cues.isEmpty) {
        debugPrint('[video-embedded-sub] parsed 0 cues from embedded track');
        return;
      }
      // 再次校验未换片，再写穿 cue。
      if (_videoPath != videoPath) {
        debugPrint('[video-embedded-sub] discarded stale cues (video changed)');
        return;
      }
      debugPrint('[video-embedded-sub] extracted ${cues.length} cues');
      setCues(cues);
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
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
    debugPrint('[video-cue] idx=$idx pos=${posMs}ms text="${_cues[idx].text}"');
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

  /// 设置播放倍速（未 load 时也记下 [_lastSpeed]，下次 load 不丢）。
  Future<void> setSpeed(double rate) async {
    _lastSpeed = rate;
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

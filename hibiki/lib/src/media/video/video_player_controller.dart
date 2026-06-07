import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_playback_source.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频播放控制器：用 media_kit 播放视频，并按字幕 cue 做 125ms 同步高亮。
///
/// cue 选择语义大体照搬有声书 [AudiobookPlayerController] 的 `_updateCurrentCue`：
/// endMs 闭区间、同句不重复 [notifyListeners]、delayMs 扣减位置。**关键差异**：
/// gap（[JsonAlignmentParser.findCueIndex] 返回 -1）时有声书保留上一句正文高亮，
/// 而视频底部字幕 overlay 必须清空——真实字幕在时间窗结束后就该消失（BUG-074）。
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
class VideoPlayerController extends ChangeNotifier
    implements VideoPlaybackSource {
  Player? _player;
  VideoController? _videoController;

  List<AudioCue> _cues = <AudioCue>[];
  AudioCue? _currentCue;
  int _currentCueIndex = -1;

  /// 音画延迟（毫秒）：正值表示"视频比文字先播"，查 cue 时把位置往回拨。
  int _delayMs = 0;

  /// 最近一次 [setSpeed] / [load] 之倍速；player 未实例化时供 [speed] getter 回退。
  double _lastSpeed = 1.0;

  /// 当前启用的 mpv 着色器绝对路径（[load] 复用 / [applyShaders] 实时切换）。
  List<String> _shaderPaths = <String>[];

  /// 当前 mpv 配置（[load] 复用 / [applyMpvConfig] 实时切换）。
  VideoMpvConfig _mpvConfig = VideoMpvConfig.defaults;

  Timer? _tick;
  StreamSubscription<bool>? _playingSub;

  /// 视频原始分辨率变化订阅（用于字幕 \pos letterbox 映射在分辨率到位后重定位）。
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;

  String? _bookUid;

  /// 视频文件绝对路径；制卡时按 cue 时间裁字幕音频片段用。
  String? _videoPath;

  /// 上次持久化时的整秒位置；用于 [_maybeSavePosition] 节流到每秒至多一次。
  int _lastSavedSec = -1;

  /// 恢复 seek 的目标位置（毫秒）；非 null 表示「正在恢复上次进度，seek 尚未落地」。
  ///
  /// media_kit 在 `open(play:false)` 刚返回时 player 常未就绪（position/duration 仍
  /// 为 0），此刻 [load] 发出的 seek 会被丢弃；随后 125ms tick 读到 0 会经
  /// [_maybeSavePosition] 把 **0 持久化、覆盖掉真实进度**，导致「每次进去都回到 0」。
  /// 设此守护后，三个写入点（tick / [flushPosition] / [_forceSavePositionSync]）在
  /// position 追上目标（容差 1.5s）之前一律不写，position 追上后由 [_isRestoringPast]
  /// 清除守护、恢复正常持久化。
  int? _restoreTargetMs;

  /// 位置持久化回调：整秒变化时调用，由上层（repository）落库。
  Future<void> Function(String bookUid, int positionMs)? onPositionWrite;

  @override
  AudioCue? get currentCue => _currentCue;

  @override
  int get currentCueIndex => _currentCueIndex;

  List<AudioCue> get cues => _cues;

  VideoController? get videoController => _videoController;

  /// 视频文件绝对路径（制卡裁字幕音频用）；未 [load] 时为空。
  String? get videoPath => _videoPath;

  @override
  bool get isPlaying => _player?.state.playing ?? false;

  /// 当前播放位置（毫秒）；未 [load] 时为 null。换集前用它补记当前集精确进度
  /// （tick 整秒节流外的尾差）。
  @override
  int? get positionMs => _player?.state.position.inMilliseconds;

  /// 媒体总时长（毫秒）；未 [load] / 未解析媒体头时为 null。
  @override
  int? get durationMs => _player?.state.duration.inMilliseconds;

  /// 视频原始分辨率（字幕 `\pos` letterbox 映射用）；未解码时为 null。
  int? get videoWidth => _player?.state.width;
  int? get videoHeight => _player?.state.height;

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

  /// 当前启用的着色器绝对路径（设置界面回显用）。
  List<String> get shaderPaths => List<String>.unmodifiable(_shaderPaths);

  /// 运行时切换 mpv 着色器（设置面板 toggle 即时生效）。未 [load]（无 player）时只记下，
  /// 下次 [load] 应用。仅桌面 libmpv 真正生效；移动端静默 no-op。
  Future<void> applyShaders(List<String> absolutePaths) async {
    _shaderPaths = List<String>.of(absolutePaths);
    final Player? player = _player;
    if (player == null) return;
    await applyShadersToPlayer(player, _shaderPaths);
  }

  /// 运行时应用 mpv 配置（设置面板改动即时生效）。未 [load] 时只记下，下次 [load]
  /// 应用。仅桌面 libmpv 真正生效；移动端/不支持的属性静默 no-op。
  Future<void> applyMpvConfig(VideoMpvConfig config) async {
    _mpvConfig = config;
    final Player? player = _player;
    if (player == null) return;
    await applyMpvConfigToPlayer(player, config);
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
    List<String> shaderPaths = const <String>[],
    VideoMpvConfig mpvConfig = VideoMpvConfig.defaults,
    bool autoPlay = false,
  }) async {
    _bookUid = bookUid;
    _videoPath = videoFile.path;
    debugPrint('[video-load] cues=${cues.length} path=${videoFile.path}');
    setCues(cues);

    // 重复 load（换集）：取消上一次的 tick / 订阅，但**复用同一 Player /
    // VideoController**，不 dispose 重建。复用是关键（BUG-120）——media_kit 全屏是推到
    // 根 navigator 的独立路由，绑定的是「进入全屏那一刻」的 VideoController 实例；若每次
    // 换集 dispose+new VideoController，全屏路由仍绑在旧（已 dispose）实例上 → 全屏换集
    // 黑屏、00:00（退全屏看窗口侧新实例才正常）。复用后只 player.open 换片，全屏路由始终
    // 绑同一实例 → 新视频正常渲染；也是 media_kit 切播放列表的正规姿势。
    _tick?.cancel();
    _tick = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _widthSub?.cancel();
    _widthSub = null;
    await _heightSub?.cancel();
    _heightSub = null;

    final Player player = _player ?? Player();
    if (_player == null) {
      _player = player;
      _videoController = VideoController(player);
    }

    await player.open(
      Media(videoFile.uri.toString()),
      play: false,
    );

    // 关闭 libmpv 画面字幕渲染——字幕统一走可点击 overlay（cue 同步 + 逐字查词）。
    // mkv 内嵌字幕会被 libmpv 默认渲染成画面像素（不可点）；用户点它会穿透到视频层
    // 触发暂停而非查词。故一律关 libmpv 字幕，由 overlay 承载所有字幕（外挂 sidecar
    // 与内嵌抽取的 cue 都走 overlay）。externalSubtitlePath 已在上层解析成 cues 传入。
    await player.setSubtitleTrack(SubtitleTrack.no());

    // 应用启用的 mpv 着色器（Anime4K 等；仅桌面 libmpv 生效，移动端静默 no-op）。
    _shaderPaths = List<String>.of(shaderPaths);
    await applyShadersToPlayer(player, _shaderPaths);

    // 应用 mpv 画质/解码配置（桌面 libmpv 生效；移动端/不支持属性静默 no-op）。
    _mpvConfig = mpvConfig;
    await applyMpvConfigToPlayer(player, _mpvConfig);

    _lastSpeed = initialSpeed;
    await player.setRate(initialSpeed);
    // 恢复上次位置。media_kit 在 open(play:false) 后 player 未必立即可 seek（内部
    // position 仍 0），此时 seek 会被丢弃，随后 tick 读到 0 会把真实进度覆盖成 0。
    // 故：① 设 _restoreTargetMs 守护，seek 落地前禁止任何写入点用过渡期小值覆盖；
    //     ② 等 player 可 seek（duration ready）再 seek，让恢复真正生效。
    if (initialPositionMs > 0) {
      _restoreTargetMs = initialPositionMs;
      await _waitUntilSeekable(player);
      if (_player != player) return; // 等待期间换片：放弃这次恢复
      await player.seek(Duration(milliseconds: initialPositionMs));
    } else {
      _restoreTargetMs = null;
    }

    // 订阅播放态翻转（包括播完自动暂停、焦点丢失），即时刷新 UI 图标。
    _playingSub = player.stream.playing.listen((_) {
      notifyListeners();
    });

    // 订阅视频原始分辨率变化：解码出分辨率后让 overlay 重新做 \pos letterbox 映射。
    _widthSub = player.stream.width.listen((_) => notifyListeners());
    _heightSub = player.stream.height.listen((_) => notifyListeners());

    // 125ms 周期读位置，驱动 cue 同步（对齐有声书 createPositionStream 的节奏）。
    _tick = Timer.periodic(const Duration(milliseconds: 125), (_) {
      final Player? p = _player;
      if (p == null) return;
      updateCueForPosition(p.state.position.inMilliseconds);
    });

    // 自动播放：进页面/换集后直接开播（用户偏好）。放在恢复 seek **之后**（否则
    // 先从 0 起播再跳到恢复位置，产生可见闪跳），且放在订阅播放态之后（让
    // stream.playing 监听捕获到起播事件、即时刷新 UI）。换片守卫同上。
    if (autoPlay && _player == player) {
      await player.play();
    }

    // 无外挂字幕且无 cue 时，桌面端后台抽内嵌字幕轨成可点击 cue（不阻塞首帧）。
    if ((externalSubtitlePath == null || externalSubtitlePath.isEmpty) &&
        cues.isEmpty) {
      unawaited(_loadEmbeddedSubtitleIfNeeded(bookUid: bookUid));
    }
  }

  /// 桌面端后台自动抽**第一条可转文本的**内嵌字幕轨 → cue → [setCues]，触发
  /// 可点击 overlay。
  ///
  /// 仅当无外挂字幕且当前无 cue 时由 [load] 末尾触发（调用方已门控）。移动端跳过
  /// （ffmpeg 不可用），无可用文本轨 / 失败静默返回，保留 libmpv 画面渲染兜底。
  ///
  /// **复用字幕菜单同一套 codec 感知逻辑**（[listAllSubtitleSources] +
  /// [loadCuesForSource]），不再硬编码 `.ass` / [AssParser] / streamIndex 0——
  /// 否则同一个 mp4（`mov_text`）菜单能出字幕、自动加载却静默失败（BUG-071 同源
  /// 不一致）。优先选能转文本 cue 的内嵌轨（跳过 pgs 等图形轨），都不行则不自动
  /// 加载。[listAllSubtitleSources] 的 langCode 只影响外挂字幕排序，这里只取内嵌
  /// 轨故传固定值。
  ///
  /// 抽字幕较慢（ffmpeg 跑几秒），故 [load] 用 `unawaited` 后台触发不阻塞播放；
  /// 抽完才 [setCues]，overlay 此时才出现。期间若发生重新 [load]（[_videoPath]
  /// 变化）则丢弃旧结果，避免把上一段视频的字幕错挂到新视频。
  Future<void> _loadEmbeddedSubtitleIfNeeded({required String bookUid}) async {
    // 桌面走系统 ffmpeg、移动端走捆绑 ffmpeg-kit（见 resolveFfmpegBackend），两端都能
    // 抽内封字幕，故不再按平台门控（早先「移动端无 ffmpeg」的限制已随捆绑解除）。
    // 真无 ffmpeg 时 listAllSubtitleSources 返回空、优雅降级，不会出错。
    final String? videoPath = _videoPath;
    if (videoPath == null) return;

    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: 'ja');
    if (_videoPath != videoPath) return; // 枚举期间换片：丢弃。

    // 第一条「能转文本 cue」的内嵌轨（codec 映射非 null）；跳过图形轨。
    SubtitleSource? chosen;
    for (final SubtitleSource s in sources) {
      if (s.isEmbedded && subtitleFormatForCodec(s.codec ?? '') != null) {
        chosen = s;
        break;
      }
    }
    if (chosen == null) {
      debugPrint('[video-embedded-sub] no text-capable embedded track');
      return;
    }

    final List<AudioCue> cues =
        await loadCuesForSource(chosen, videoPath, bookUid);
    if (_videoPath != videoPath) return; // 加载期间换片：丢弃。
    if (cues.isEmpty) {
      debugPrint('[video-embedded-sub] parsed 0 cues from embedded track');
      return;
    }
    debugPrint('[video-embedded-sub] extracted ${cues.length} cues');
    setCues(cues);
  }

  /// cue 同步核心：照搬有声书 `_updateCurrentCue` 语义。
  ///
  /// 1. 先 [_maybeSavePosition]（位置持久化不受 cue gap guard 影响）。
  /// 2. 空 cues 直接返回。
  /// 3. `effectiveMs = posMs - delayMs`，下界 clamp 到 0。
  /// 4. [JsonAlignmentParser.findCueIndex] 二分定位；返回 -1（gap / 早于首句）
  ///    时**清空**当前字幕（视频字幕在时间窗结束后应消失，BUG-074），仅在确有
  ///    字幕需清时 [notifyListeners]。
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
    // Gap（两条字幕间的静音）或早于首句：清空当前字幕。视频底部字幕 overlay 与
    // 有声书的「正文跟随高亮」语义不同——真实字幕在其时间窗 [startMs, endMs] 结束
    // 后就该消失，不能像高亮那样在 gap 里保留上一句（否则一句播完到下一句开始前
    // 字幕一直挂着，BUG-074）。findCueIndex 在 gap 返回 -1 正是「让上层清」的契约。
    // 已无字幕（_currentCueIndex == -1）时直接返回，避免无谓 notify。
    if (idx < 0) {
      if (_currentCueIndex == -1) return;
      _currentCueIndex = -1;
      _currentCue = null;
      notifyListeners();
      return;
    }
    if (idx == _currentCueIndex) return;
    _currentCueIndex = idx;
    _currentCue = _cues[idx];
    debugPrint('[video-cue] idx=$idx pos=${posMs}ms text="${_cues[idx].text}"');
    notifyListeners();
  }

  @visibleForTesting
  void debugUpdateCueForPosition(int posMs) => updateCueForPosition(posMs);

  /// 等 [player] 进入可 seek 状态（`duration > 0` 表示已解析媒体头）。
  ///
  /// media_kit 在 `open(play:false)` 刚返回时常 duration/position 仍为 0，此刻 seek
  /// 会被丢弃；等首个非零 duration 再 seek 才可靠。最多等 5 秒，超时则尽力 seek
  /// （[_restoreTargetMs] 守护兜底，不会因没落地而把真实进度覆盖成 0）。
  Future<void> _waitUntilSeekable(Player player) async {
    if (player.state.duration > Duration.zero) return;
    try {
      await player.stream.duration
          .firstWhere((Duration d) => d > Duration.zero)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // 超时/异常：尽力继续 seek。
    }
  }

  /// 恢复 seek 是否尚未落地：[_restoreTargetMs] 非 null 且当前 [posMs] 还在目标之前
  /// （过渡期小值/0）时返回 true，调用方应跳过持久化以免覆盖真实进度。position 追上
  /// 目标（容差 1.5s）后清除守护并返回 false，恢复正常持久化。
  bool _isRestoringPast(int posMs) {
    final int? target = _restoreTargetMs;
    if (target == null) return false;
    if (posMs >= target - 1500) {
      _restoreTargetMs = null;
      return false;
    }
    return true;
  }

  /// 整秒变化且 [_bookUid] 非空时，异步触发位置持久化（每秒至多一次）。
  void _maybeSavePosition(int posMs) {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    // 恢复 seek 未落地：当前 position 是过渡期小值，写它会覆盖真实进度。跳过。
    if (_isRestoringPast(posMs)) return;
    final int sec = posMs ~/ 1000;
    if (sec == _lastSavedSec) return;
    _lastSavedSec = sec;
    unawaited(onPositionWrite?.call(bookUid, posMs));
  }

  /// 强制把**当前**播放位置经 [onPositionWrite] 写一次并 **await 到落库**，
  /// 绕过 [_maybeSavePosition] 的整秒节流。
  ///
  /// 周期保存只在整秒边界写，又是 fire-and-forget；用户退出（pop/dispose）那一刻
  /// 的最后几百毫秒进度（同一整秒内）会被节流吞掉，导致「退出再进没回到上次位置」。
  /// 退出前调本方法把退出瞬间的位置可靠写穿（对齐有声书
  /// [AudiobookPlayerController.flushPosition]）。
  ///
  /// 必须在 [Player] 仍存活时调用（[positionMs] 读 `_player.state.position`）：
  /// [VideoHibikiPage.dispose] 先 `flushPosition()` 再 `dispose()`；换集前
  /// （[_switchEpisode]）也调一次记录当前集精确进度。未 [load]（无 player /
  /// 无 bookUid）时 no-op 安全。
  Future<void> flushPosition() async {
    final String? bookUid = _bookUid;
    final int? posMs = positionMs;
    if (bookUid == null || posMs == null) return;
    // 恢复 seek 未落地：退出瞬间的 position 仍是过渡期小值，写它会覆盖真实进度。跳过。
    if (_isRestoringPast(posMs)) return;
    _lastSavedSec = posMs ~/ 1000;
    await onPositionWrite?.call(bookUid, posMs);
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

  /// 相对当前位置 seek（±[deltaMs]，如 ±10 秒），clamp 到 [0, duration]。
  /// 未 load（无位置）时 no-op 安全。
  Future<void> seekRelative(int deltaMs) async {
    final int? pos = positionMs;
    if (pos == null) return;
    await seekMs(clampSeekTargetMs(pos, deltaMs, durationMs));
  }

  /// 纯函数：相对 seek 目标 clamp 到 [0, duration]（duration 未知时只保证 >=0）。
  /// 抽出便于单测（[seekRelative] 本身需真实 player 无法纯测）。
  static int clampSeekTargetMs(int posMs, int deltaMs, int? durationMs) {
    final int target = posMs + deltaMs;
    if (target < 0) return 0;
    if (durationMs != null && durationMs > 0 && target > durationMs) {
      return durationMs;
    }
    return target;
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
    // 退出前强制记录当前位置：周期保存的整秒节流会吞掉退出瞬间同一整秒内的最后
    // 几百毫秒进度。这里在 [_player] 仍存活时同步读位置并 fire-and-forget 写一次
    // （绕过节流），保证「退出再进恢复到上次位置」。可 await 的可靠落库由
    // [VideoHibikiPage.dispose] 在调用本方法前先 [flushPosition] 完成。
    _forceSavePositionSync();
    _tick?.cancel();
    _tick = null;
    unawaited(_playingSub?.cancel());
    _playingSub = null;
    unawaited(_widthSub?.cancel());
    _widthSub = null;
    unawaited(_heightSub?.cancel());
    _heightSub = null;
    unawaited(_player?.dispose());
    _player = null;
    _videoController = null;
    super.dispose();
  }

  /// 同步强制写一次当前位置（绕过整秒节流），供 [dispose] 兜底调用。
  /// [onPositionWrite] 的写库 Future 在此 fire-and-forget（dispose 不能 await）。
  void _forceSavePositionSync() {
    final String? bookUid = _bookUid;
    final int? posMs = positionMs;
    if (bookUid == null || posMs == null) return;
    // 恢复 seek 未落地：dispose 瞬间的 position 仍是过渡期小值，勿覆盖真实进度。
    if (_isRestoringPast(posMs)) return;
    _lastSavedSec = posMs ~/ 1000;
    unawaited(onPositionWrite?.call(bookUid, posMs));
  }
}

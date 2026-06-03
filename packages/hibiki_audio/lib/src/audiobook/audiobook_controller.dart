import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'audiobook_model.dart';
import '../matching/collection_audio_matcher.dart';
import '../parsers/json_alignment_parser.dart';
import '../matching/sasayaki_match_codec.dart';

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
  StreamSubscription<void>? _noisySub;

  List<File> _audioFiles = [];

  List<File> get audioFiles => _audioFiles;

  AudioPlayer? _clipPlayer;
  StreamSubscription<PlayerState>? _clipStateSub;

  /// playCueOnce 用：播放到当前音频文件内此 ms 后自动暂停；null = 不限制。
  int? _stopAtPositionMs;

  /// playCueOnce 完成后恢复到的位置；null = 不恢复。
  ({int audioFileIndex, int positionMs})? _returnToPosition;

  /// load() 完成前为未完成状态；seek 方法先 await 此 Completer 以避免
  /// 在音频源尚未就绪时 seek 导致位置归零。
  Completer<void> _loadReady = Completer<void>()..complete();

  /// 当前书的元数据（null = 未加载）。PR4 中用于更新锁屏媒体卡片。
  Audiobook? _audiobook;

  /// 当前书的元数据（PR4 集成时供外部读取）。
  Audiobook? get audiobook => _audiobook;

  /// 当前章节所有 cue（已按 startMs 排序）。
  List<AudioCue> _chapterCues = [];

  /// 外部只读快照，供按 textFragmentId 查找 cue。
  List<AudioCue> get chapterCuesSnapshot => _chapterCues;

  /// 全书 cue（供收藏句子跨章匹配），setAllBookCues 设定。
  List<AudioCue> _allBookCues = [];
  Map<int, int> _allBookCueIdToIndex = {};
  List<AudioCue> get allBookCuesSnapshot => _allBookCues;

  /// clip 播放前主播放器是否正在播放，clip 结束后恢复。
  bool _resumeMainAfterClip = false;

  // ── 对外暴露的状态 ─────────────────────────────────────────────────────────

  /// 当前正在朗读的 cue，null = 未定位到句子。
  AudioCue? get currentCue => _currentCue;
  AudioCue? _currentCue;
  int _currentCueIndex = -1;

  AudioCue? cueAtCurrentPositionInBook() {
    if (_allBookCues.isEmpty) return _currentCue;
    final int audioFileIndex = _player.currentIndex ?? 0;
    final int effectiveMs =
        (_player.position.inMilliseconds - delayMs.value).clamp(0, 1 << 30);
    AudioCue? best;
    int bestStart = -1;
    for (final AudioCue cue in _allBookCues) {
      if (cue.audioFileIndex != audioFileIndex) continue;
      final int start = cue.startMs;
      final int end = cue.endMs;
      if (start <= effectiveMs && end > effectiveMs) return cue;
      if (start <= effectiveMs && start > bestStart) {
        best = cue;
        bestStart = start;
      }
    }
    return best ?? _currentCue;
  }

  /// 当前章节 cue 列表长度（UI 用于 "第 x / n 句" 进度显示）。
  int get chapterCueCount => _chapterCues.length;

  /// 当前 cue 在章节 cue 列表中的 0-based 索引（-1 = 未定位）。
  int get currentCueIdx => _currentCueIndex;

  /// 当前 cue 在 [allBookCuesSnapshot] 中的索引（-1 = 未匹配）。
  /// 歌词模式使用此索引而非 [currentCueIdx]（后者是 chapter-relative）。
  int get allBookCueIdx {
    final AudioCue? cue = _currentCue;
    if (cue == null || _allBookCues.isEmpty) return -1;
    final int? id = cue.id;
    if (id != null) {
      return _allBookCueIdToIndex[id] ?? -1;
    }
    return _allBookCueIndex(allBookCues: _allBookCues, currentCue: cue);
  }

  // ── PR8b: Follow audio ────────────────────────────────────────────────────

  /// 持久化后的 Follow audio 开关。UI 监听这个 ValueNotifier 切换磁铁图标。
  /// 值由 [load] 的 `initialFollowAudio` 初始化（调用方从 Hive 读），写入
  /// 靠 [setFollowAudio] 经 [onFollowAudioPersist] 落 Hive。
  final ValueNotifier<bool> followAudio = ValueNotifier<bool>(true);

  /// cue 跨章回调。当 cue 的 textFragmentId 解码出的 sectionIndex 与
  /// reader 当前挂载章节（[getCurrentReaderSection]）不一致、且 [followAudio]
  /// 与 [_hasPlayedOnce] 都已就绪时触发；只报新章的 index。
  ///
  /// 对齐 Sasayaki 原版 SasayakiPlayer.updateCue 行为：cue 与当前 reader 章
  /// 不同 → loadChapter(cue.chapterIndex, 0)。reader 页面接这个回调调
  /// `AudiobookBridge.requestSectionNav`，跳完务必回调
  /// [notifySectionRestoreCompleted] 把 chapterTransition 守卫清掉。
  ///
  /// 控制器不直接调桥，避免和 WebView 耦合；reader 页面是唯一持有
  /// InAppWebViewController 的地方。
  void Function(int sectionIndex)? onCrossChapter;

  /// 由 reader 页面提供：返回当前挂载的 chapter index（开书前 -1）。
  int Function()? getCurrentReaderSection;

  /// 边界跳句回调：skipToPrevCue 到章首 / skipToNextCue 到章尾时触发。
  /// delta = -1 (上一章末尾) 或 +1 (下一章开头)。
  /// reader 负责加载目标章 cues 并 seek。
  Future<void> Function(int delta)? onBoundarySkip;

  /// 对齐 Sasayaki `hasPlayedOnce`：true 之前不允许跨章自动翻页，避免
  /// 打开书 / 恢复位置瞬间 cue 与 reader 当前章不一致就立刻跳章，
  /// 把用户当前阅读位置吃掉。在首次 [play] 调用时翻为 true，不会复位
  /// （即使中途暂停）。换书走 [load] 显式复位。
  bool _hasPlayedOnce = false;

  /// [snapReaderToAudio] 设置的一次性强制 reveal 标志。用户显式点击
  /// Follow audio ON 时，即使 [_hasPlayedOnce] 为 false 也应立刻把
  /// reader 拉到音频位置。[consumeForceReveal] 消费后自动清零。
  bool _forceNextReveal = false;

  /// 返回并清除 [_forceNextReveal]。reader 的 `_onCueChanged` 读一次
  /// 决定是否强制 reveal，之后恢复正常 [shouldRevealCurrentCue] 逻辑。
  bool consumeForceReveal() {
    if (!_forceNextReveal) return false;
    _forceNextReveal = false;
    return true;
  }

  /// 跨章 await 期间为 true，[_updateCurrentCue] 和 [setChapterCues]
  /// 直接 return，避免 cue 推进 / _currentCue 被清零。reader 完成跳章后
  /// 调 [notifySectionRestoreCompleted] 清回 false。
  bool _chapterTransition = false;

  /// Follow audio 开关变化时的持久化回调。Reader 页面 attach audiobook 时
  /// 装入这个字段（一般是 `(v) => repo.updateFollowAudio(bookUid, v)`），
  /// [setFollowAudio] 内部调用。独立于按钮 UI 让 play bar 只翻内存状态
  /// 不用知道 Hive。
  Future<void> Function(bool value)? onFollowAudioPersist;

  // ── 每本书独立的音画同步延迟 + 播放速度 ─────────────────────────────────
  // 对齐 upstream Sasayaki 的 "per-book delay and speed, both saved"。
  // 延迟为正时音频领先文字（cue 查询位置要向前扣），为负时滞后。
  // Reader 页面在 load 后经下面两个 persist 回调把新值落 Hive。

  /// 音画同步延迟（毫秒）。UI 订阅这个 ValueNotifier 展示当前偏移。
  final ValueNotifier<int> delayMs = ValueNotifier<int>(0);

  /// 延迟变化时的持久化回调。
  Future<void> Function(int ms)? onDelayPersist;

  /// 播放速度变化时的持久化回调。内部在 [setSpeed] 调用。
  Future<void> Function(double speed)? onSpeedPersist;

  // ── 音量 ─────────────────────────────────────────────────────────────────
  double get volume => _player.volume;

  Future<void> setVolume(double v) async {
    await _player.setVolume(v.clamp(0.0, 2.0));
    notifyListeners();
  }

  // ── 图片暂停 ───────────────────────────────────────────────────────────────
  // 遇到图片时自动暂停播放，停留指定秒数后恢复。0 = 不暂停。

  final ValueNotifier<int> imagePauseSec = ValueNotifier<int>(0);

  Future<void> Function(int sec)? onImagePausePersist;

  Timer? _imagePauseTimer;

  /// 当前是否处于图片暂停等待中。
  bool get isImagePaused => _imagePauseTimer?.isActive ?? false;

  void setImagePauseSec(int sec) {
    final int clamped = sec.clamp(0, 15);
    if (imagePauseSec.value == clamped) return;
    imagePauseSec.value = clamped;
    final Future<void> Function(int)? persist = onImagePausePersist;
    if (persist != null) {
      unawaited(persist(clamped));
    }
  }

  /// 由 reader 页面在检测到图片后调用。暂停播放并在 [imagePauseSec] 秒后恢复。
  void triggerImagePause() {
    final int sec = imagePauseSec.value;
    if (sec <= 0 || !_player.playing) return;
    _imagePauseTimer?.cancel();
    unawaited(_player.pause());
    _imagePauseTimer = Timer(Duration(seconds: sec), () {
      _imagePauseTimer = null;
      if (!_player.playing) {
        unawaited(_player.play());
        // 暂停时视口停在插图上；恢复后把视口拉回当前 cue（插图后那句），
        // 让 reader 的 _onCueChanged 以 forceReveal 续上 audio-follow（snapReaderToAudio
        // 内部会 notifyListeners）。
        snapReaderToAudio();
      }
    });
    notifyListeners();
  }

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
  /// [audiobook]           有声书元数据（已存入 Isar）。
  /// [audioFiles]          按顺序排列的音频文件列表（与 AudioCue.audioFileIndex 对应）。
  /// [initialFollowAudio]  Follow audio 开关初值；调用方应从
  ///                       `AudiobookRepository.readFollowAudio` 取得。
  ///
  /// 加载完成后会从 Hive (`appModel` box) 读取上次保存的播放位置并
  /// `seek` 过去，避免页面重建（背景回前台 / 路由重建）时音频从头开始。
  Future<void> load({
    required Audiobook audiobook,
    required List<File> audioFiles,
    bool initialFollowAudio = true,
    int initialDelayMs = 0,
    double initialSpeed = 1.0,
    int initialPositionMs = 0,
    int initialImagePauseSec = 0,
  }) async {
    // 新一轮加载：旧 Completer 若未完成则补完（防上次 load 异常中断），
    // 再建新的未完成 Completer 阻塞后续 seek 直到本次 load 结束。
    if (!_loadReady.isCompleted) _loadReady.complete();
    _loadReady = Completer<void>();

    _audiobook = audiobook;
    _audioFiles = audioFiles;
    // Follow audio / delay / speed 状态由调用方从持久层读出传入；不触发
    // persist 回调 —— 载入不是用户操作，又把同值写回 Hive 就是循环。
    followAudio.value = initialFollowAudio;
    delayMs.value = initialDelayMs;
    imagePauseSec.value = initialImagePauseSec;
    _imagePauseTimer?.cancel();
    _imagePauseTimer = null;
    _hasPlayedOnce = false;
    _forceNextReveal = false;
    _chapterTransition = false;

    await _player.stop();
    _positionSub?.cancel();
    _playingSub?.cancel();

    await _configureAudioSession();

    if (audioFiles.length == 1) {
      try {
        await _player
            .setAudioSource(
              AudioSource.file(audioFiles.first.path),
              preload: false,
            )
            .timeout(const Duration(seconds: 60));
      } catch (e, stack) {
        debugPrint('AudiobookController.setSource: $e\n$stack');
        debugPrint('[hibiki-audiobook] setAudioSource failed: $e');
        _loadReady.complete();
        rethrow;
      }
    } else {
      final List<AudioSource> sources = [];
      for (final File f in audioFiles) {
        sources.add(AudioSource.file(f.path));
      }
      try {
        await _player
            .setAudioSource(
              ConcatenatingAudioSource(children: sources),
              preload: false,
            )
            .timeout(const Duration(seconds: 60));
      } catch (e, stack) {
        debugPrint('AudiobookController.setSource: $e\n$stack');
        debugPrint('[hibiki-audiobook] setAudioSource (multi) failed: $e');
        _loadReady.complete();
        rethrow;
      }
    }

    // 恢复上次播放位置（页面重建场景下避免音频回到 0）。
    final int savedMs = initialPositionMs;
    if (savedMs > 0) {
      try {
        await _player.seek(Duration(milliseconds: savedMs));
      } catch (e, stack) {
        debugPrint('AudiobookController.seekSaved: $e\n$stack');
        debugPrint('[hibiki-audiobook] seek to saved $savedMs ms failed: $e');
      }
    }

    // 先应用持久化速度再启动跟踪：播放速度由 just_audio 的内部状态持有，
    // 不走 notifyListeners 也能在下次 setSpeed / UI 读 `speed` getter 时反映。
    if ((initialSpeed - 1.0).abs() > 0.001) {
      try {
        await _player.setSpeed(initialSpeed);
      } catch (e, stack) {
        debugPrint('AudiobookController.setSpeed: $e\n$stack');
        debugPrint(
            '[hibiki-audiobook] initial setSpeed $initialSpeed failed: $e');
      }
    }

    _loadReady.complete();
    _startPositionTracking();
    notifyListeners();
  }

  // ── 进度持久化 ─────────────────────────────────────────────────────────────

  /// 上次写入时位置对应的**整秒下标**（对齐上游 SasayakiPlayer.tick 的
  /// `Int(seconds.rounded(.down)) != lastUpdate` 语义：只要秒变了就存）。
  /// -1 表示从未保存过。
  int _lastSavedWholeSec = -1;

  /// 播放位置写入回调。调用方在 attach 时装入，
  /// 一般实现为写 Drift database preferences。
  void Function(String bookUid, int positionMs)? onPositionWrite;

  /// 把当前播放位置写入持久化存储。对齐上游：**每整秒变化一次**就写。
  /// 125ms tick 触发 8 次里只有 1 次真的落库，IO 成本和上游等价。
  ///
  /// 调用时机：cue 变化（_updateCurrentCue）、暂停、dispose。
  void _maybeSavePosition({bool force = false}) {
    final String? uid = _audiobook?.bookUid;
    if (uid == null) return;
    final int posMs = _player.position.inMilliseconds;
    final int wholeSec = posMs ~/ 1000;
    if (!force && wholeSec == _lastSavedWholeSec) {
      return;
    }
    _lastSavedWholeSec = wholeSec;
    onPositionWrite?.call(uid, posMs);
  }

  /// 切换章节后更新当前章节的 cue 列表。
  ///
  /// 调用后控制器会继续播放（若已在播放），高亮随之跳转到新章节的 cue。
  /// 立即基于当前播放位置解析 currentCue，避免播放栏/高亮在 positionStream
  /// 下一次 tick 之前出现空白（尤其是暂停状态下 positionStream 不发事件）。
  void setChapterCues(List<AudioCue> cues) {
    _chapterCues = List<AudioCue>.from(cues)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    // 跨章守卫期间只替换 cue 列表，不清 _currentCue 也不重算——
    // 否则 _updateCurrentCue 被 guard 挡住，_currentCue 卡 null，
    // 守卫放下后第一次 tick 会匹配到 cue[0] 导致进度清零。
    // 守卫放下后 notifySectionRestoreCompleted 会负责恢复。
    if (_chapterTransition) return;
    _currentCue = null;
    _currentCueIndex = -1;
    _updateCurrentCue(_player.position.inMilliseconds);
    notifyListeners();
  }

  void setAllBookCues(List<AudioCue> cues) {
    _allBookCues = List<AudioCue>.from(cues);
    final Map<int, int> idMap = <int, int>{};
    for (int i = 0; i < _allBookCues.length; i++) {
      final int? id = _allBookCues[i].id;
      if (id != null) idMap[id] = i;
    }
    _allBookCueIdToIndex = idMap;
  }

  // ── 播放控制 API ───────────────────────────────────────────────────────────

  /// 开始播放。
  ///
  /// 不 await `_player.play()`：just_audio 的 `play()` 返回的 Future 在播放
  /// **结束或暂停**时才完成，await 会让调用方误以为播放迟迟没启动。真正的
  /// 播放状态翻转通过 [_playingSub] 订阅 `playingStream` 拿到，立刻触发
  /// `notifyListeners()`，按钮图标不需要等网络/缓冲。
  Future<void> play() async {
    // 对齐 Sasayaki：首次 play 之后才允许跨章自动翻页。打开书 / 恢复
    // 位置阶段 cue 与 reader 当前章不一致是常态，不应在用户没按播放时
    // 就把 reader 拉到音频章。
    _hasPlayedOnce = true;
    // 用户在图片自动暂停窗口内手动播放：取消待恢复计时器并把视口从插图拉回当前
    // cue（否则计时器到点见已在播放而跳过 snap，视口卡在插图上直到下次 cue 推进）。
    if (_imagePauseTimer != null) {
      _imagePauseTimer!.cancel();
      _imagePauseTimer = null;
      snapReaderToAudio();
    }
    unawaited(_player.play());
  }

  Future<void> pause() async {
    _imagePauseTimer?.cancel();
    _imagePauseTimer = null;
    _resumeMainAfterClip = false;
    await _player.pause();
    _maybeSavePosition(force: true);
  }

  Future<void> togglePlayPause() async {
    _stopAtPositionMs = null;
    _returnToPosition = null;
    if (_player.playing) {
      await pause();
    } else {
      await play();
    }
  }

  /// 跳转到全局毫秒位置。
  ///
  /// 如果音频 duration 尚未就绪（null / 0）或目标超出范围，直接忽略，
  /// 避免 just_audio 将位置重置到 0。
  Future<void> seekMs(int positionMs) async {
    await _loadReady.future;
    final Duration? dur = _player.duration;
    if (dur == null || dur.inMilliseconds <= 0) return;
    final int clampedMs = positionMs.clamp(0, dur.inMilliseconds);
    await _player.seek(Duration(milliseconds: clampedMs));
    notifyListeners();
  }

  /// 快进 / 快退（秒）。
  Future<void> seekRelative(int deltaSeconds) async {
    final int newMs = (position.inMilliseconds + deltaSeconds * 1000)
        .clamp(0, duration.inMilliseconds);
    await seekMs(newMs);
  }

  /// 跳转到指定 cue 的起始位置。
  ///
  /// 不复用 [seekMs]：seekMs 末尾会 notify 一次 "位置变了"，但 positionStream
  /// 在 seek 完会立刻推新位置触发 [_updateCurrentCue]，cue 变化时也 notify
  /// 一次 —— 同一次跳转会 double-notify，下游 reader._onCueChanged 被重复
  /// 触发两次 forkScrollEntry / cueMap 查询。这里直接 seek 后显式调一次
  /// [_updateCurrentCue]：暂停态下 positionStream 不发事件，必须显式；
  /// 播放态下 positionStream 稍后 tick 到新位置，_updateCurrentCue 判断
  /// cue 已变化就不再 notify，天然幂等。
  Future<void> skipToCue(AudioCue cue) async {
    _stopAtPositionMs = null;
    _returnToPosition = null;
    await _loadReady.future;
    final ({int audioFileIndex, int positionMs})? mappedPosition =
        _positionForCue(cue);
    if (mappedPosition == null) {
      // Invalid alignment data should fail closed; falling back to 0 makes
      // tap-to-seek look like it jumped to the start of the audiobook.
      return;
    }
    final int positionMs = _clampToKnownDuration(mappedPosition.positionMs);
    await _player.seek(
      Duration(milliseconds: positionMs),
      index: mappedPosition.audioFileIndex,
    );
    _chapterTransition = false;
    final int idx = _chapterCues.indexOf(cue);
    if (idx >= 0) {
      _currentCueIndex = idx;
      _currentCue = cue;
      _maybeEmitCrossChapter(cue);
      notifyListeners();
    } else {
      _updateCurrentCue(_player.position.inMilliseconds);
    }
  }

  /// 播放指定 cue 单句后暂停，完成后回到之前的播放位置。
  ///
  /// 对齐 Hoshi `playCue(cue, stop: true)`：从 cue.startMs 播放到
  /// cue.endMs 自动暂停，恢复主播放器位置到调用前。
  Future<void> playCueOnce(AudioCue cue) async {
    await _loadReady.future;
    final ({int audioFileIndex, int positionMs})? startPosition =
        _positionForCue(cue);
    if (startPosition == null) return;

    _returnToPosition = (
      audioFileIndex: _player.currentIndex ?? 0,
      positionMs: _player.position.inMilliseconds,
    );
    _stopAtPositionMs = cue.endMs;

    await _player.seek(
      Duration(
        milliseconds: _clampToKnownDuration(startPosition.positionMs),
      ),
      index: startPosition.audioFileIndex,
    );
    _chapterTransition = false;
    final int idx = _chapterCues.indexOf(cue);
    if (idx >= 0) {
      _currentCueIndex = idx;
      _currentCue = cue;
      notifyListeners();
    }
    unawaited(_player.play());
  }

  /// 从指定 cue 开始连续播放（不暂停）。
  ///
  /// 对齐 Hoshi `playCue(cue, stop: false)`：seek 到 cue.startMs
  /// 然后持续播放，不设 endMs 限制。
  Future<void> playCueAndContinue(AudioCue cue) async {
    _stopAtPositionMs = null;
    _returnToPosition = null;
    await skipToCue(cue);
    if (!_player.playing) {
      _hasPlayedOnce = true;
      unawaited(_player.play());
    }
  }

  /// 跳到上一句（当前章节 cue 列表内）。
  ///
  /// 对齐上游 Sasayaki `prevCue()`：以 `currentCue?.startTime ?? currentPosition`
  /// 为参照 —— 当前 cue 存在就取它的前一条；落在 gap 里就取"最近一条起点早于
  /// 当前位置"的前一条。始终跳立即邻居，不做 "1.5s 内 restart" 的语义扩展。
  Future<void> skipToPrevCue() async {
    if (_chapterCues.isEmpty) return;
    final int? target = _prevCueIndex(
      cues: _chapterCues,
      currentCueIndex: _currentCueIndex,
      currentCue: _currentCue,
      positionMs: position.inMilliseconds,
    );
    if (target == null) {
      unawaited(onBoundarySkip?.call(-1));
      return;
    }
    await skipToCue(_chapterCues[target]);
  }

  /// 跳到下一句（当前章节 cue 列表内）。
  ///
  /// 已在最后一句则不动作。未定位到 cue 时跳到第一句。
  Future<void> skipToNextCue() async {
    if (_chapterCues.isEmpty) return;
    final int? target = _nextCueIndex(
      cues: _chapterCues,
      currentCueIndex: _currentCueIndex,
      positionMs: position.inMilliseconds,
    );
    if (target == null) {
      unawaited(onBoundarySkip?.call(1));
      return;
    }
    await skipToCue(_chapterCues[target]);
  }

  /// 前跳或后跳 [delta] 句（正数前跳，负数后跳）。
  ///
  /// 超出章节边界时 clamp 到首句 / 末句。
  Future<void> skipByCues(int delta) async {
    if (_chapterCues.isEmpty || delta == 0) return;
    int idx = _currentCueIndex;
    if (idx < 0) {
      idx = JsonAlignmentParser.findCueIndex(
        cues: _chapterCues,
        positionMs: position.inMilliseconds,
      );
      if (idx < 0) idx = 0;
    }
    final int target = (idx + delta).clamp(0, _chapterCues.length - 1);
    if (target == idx) return;
    await skipToCue(_chapterCues[target]);
  }

  /// 跳转到指定 0-based cue 索引。
  Future<void> skipToCueIndex(int index) async {
    if (_chapterCues.isEmpty) return;
    final int clamped = index.clamp(0, _chapterCues.length - 1);
    await skipToCue(_chapterCues[clamped]);
  }

  /// 设置播放速度（例如 0.75 / 1.0 / 1.25 / 1.5）。
  /// 新值落 [onSpeedPersist]；相同值（容差 0.001）跳过写库但仍 setSpeed
  /// 一次以处理 just_audio 内部偶发丢速场景。
  Future<void> setSpeed(double speed) async {
    final double prev = _player.speed;
    await _player.setSpeed(speed);
    notifyListeners();
    if ((speed - prev).abs() < 0.001) return;
    final Future<void> Function(double)? persist = onSpeedPersist;
    if (persist != null) {
      unawaited(persist(speed));
    }
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
    // HBK-AUDIT-069: load() 可被重复调用并重新进入此方法，必须先取消上一个
    // becomingNoisy 订阅，否则每次 re-load 都会泄漏一个仍会 _player.pause() 的
    // 监听器（对齐 audio_recorder_page 的 cancel-before-resubscribe 写法）。
    _noisySub?.cancel();
    _noisySub = session.becomingNoisyEventStream.listen((_) {
      _player.pause();
    });
  }

  void _startPositionTracking() {
    // 对齐 Sasayaki 的 CMTime(0.125) 周期观察者：just_audio 的 positionStream
    // 默认 200ms 间隔，改用 createPositionStream 锁到 125ms，让 cue 切换
    // 和高亮跟随更贴近 Sasayaki 的节奏。min == max 是固定周期（避免
    // 状态变化时 just_audio 自发降频到 maxPeriod）。
    _positionSub = _player
        .createPositionStream(
      minPeriod: const Duration(milliseconds: 125),
      maxPeriod: const Duration(milliseconds: 125),
    )
        .listen((pos) {
      _updateCurrentCue(pos.inMilliseconds);
    });
    // 订阅播放状态流：just_audio 内部状态翻转（包括焦点丢失、播完自动暂停）
    // 都会在这里得到通知，UI 即时刷新播放/暂停图标。
    _playingSub = _player.playingStream.listen((_) {
      notifyListeners();
    });
  }

  void _updateCurrentCue(int posMs) {
    // 位置持久化挪到 chapterTransition guard 之前，对齐 Sasayaki tick 的
    // 结构：位置保存在 tick() 主体，updateCue() 的 guard 不影响保存节奏。
    // 跨章 await 几秒内，如果 guard 把 save 一起卡住，用户此时杀进程会
    // 丢掉这几秒的进度。_maybeSavePosition 自身有 3s 阈值，不会每 tick
    // 写 Hive。
    _maybeSavePosition();
    // playCueOnce: 到达 endMs 后暂停并恢复位置。
    if (_stopAtPositionMs != null && posMs >= _stopAtPositionMs!) {
      final ({int audioFileIndex, int positionMs})? returnTo =
          _returnToPosition;
      _stopAtPositionMs = null;
      _returnToPosition = null;
      unawaited(_player.pause());
      if (returnTo != null) {
        unawaited(_player.seek(
          Duration(milliseconds: returnTo.positionMs),
          index: returnTo.audioFileIndex,
        ));
      }
      notifyListeners();
      return;
    }
    // 跨章 await 期间不推进 cue，否则 positionStream 连续触发
    // _maybeEmitCrossChapter 重复调 onCrossChapter。
    if (_chapterTransition) return;
    if (_chapterCues.isEmpty) {
      return;
    }
    // 应用用户设置的音画延迟：delayMs 正值表示"音频比文字先播"，查询
    // cue 时要把位置往回拨；负值相反。下界 clamp 到 0 避免负位置查询。
    // 上界不 clamp（_player.duration 可能暂未就绪），超出时 findCueIndex
    // 自行返回最后一个 cue 即可。
    final int audioFileIndex = _player.currentIndex ?? 0;
    final List<AudioCue> fileCues = _chapterCuesForAudioFile(audioFileIndex);
    if (fileCues.isEmpty) return;
    final int effectiveMs = (posMs - delayMs.value).clamp(0, 1 << 30);
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: fileCues,
      positionMs: effectiveMs,
    );
    // Gap（两条 cue 之间的静音）：保持上一条 cue 不清高亮，避免闪烁。
    // 用 index 而非 textFragmentId 比较，防止重复短句 id 相同时短路。
    if (idx < 0) return;
    final AudioCue cue = fileCues[idx];
    final int chapterIdx = _chapterCues.indexOf(cue);
    if (chapterIdx == _currentCueIndex) return;
    _currentCueIndex = chapterIdx;
    _currentCue = cue;
    _maybeEmitCrossChapter(_currentCue);
    notifyListeners();
  }

  /// 对齐 Sasayaki `displayCue(cue, reveal: autoScroll && hasPlayedOnce)`：
  /// 高亮时是否把 cue 滚进视口。Follow audio OFF、还没按过 play、音频
  /// 已暂停、或正在 playCueOnce 单句试听时，即使 cue 切换也**只加高亮
  /// class、不动视口**，让用户保持当前阅读位置不被音频位置覆盖。
  ///
  /// reader 的 `_onCueChanged` 在调 AudiobookBridge.highlight 时读一次
  /// 这个值传过去。
  bool get shouldRevealCurrentCue =>
      followAudio.value &&
      _hasPlayedOnce &&
      _player.playing &&
      _stopAtPositionMs == null;

  /// 诊断用：暴露 `_hasPlayedOnce` 供 reader 日志打印，不参与业务判断。
  bool get hasPlayedOnce => _hasPlayedOnce;

  /// 返回 [_chapterCues] 中解码成 Sasayaki 且 sectionIndex 匹配给定值的
  /// cue 列表。对齐 Sasayaki 原版 reader.js 的 `applySasayakiCues(cues)`：
  /// ttu 切章时，reader 调用这个把"当前挂载段"的所有 cue 一次性批量传给
  /// WebView，JS 侧提前包好 `<span>` 存进 cueId→spans Map，之后每句高亮
  /// 只要 O(1) Map 查表，不再每次 TreeWalker 扫归一化字符。
  ///
  /// Sasayaki 路径一本书只有一个音频"章"（cue 列表扁平），所以 [_chapterCues]
  /// 实际就是全书 cue。这里按 `SasayakiMatchCodec` 解码过滤出目标段，
  /// 不命中 / SMIL/JSON 路径的 cue 自然被跳过。
  List<AudioCue> sasayakiCuesForSection(int sectionIndex) {
    final List<AudioCue> out = <AudioCue>[];
    for (final AudioCue cue in _chapterCues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag == null) continue;
      if (frag.sectionIndex != sectionIndex) continue;
      out.add(cue);
    }
    return out;
  }

  /// cue 属于不同 section 时竖起守卫并通知 reader 跳章。
  ///
  /// 关键差异（修正点）：以前用 `_lastCueSectionIndex`（上一条 cue 的 sec）
  /// 判定跨章，结果用户手动翻到错误章节后 cue 持续在原章、prev == sec、
  /// 永不触发自动跳回。改为对比 [getCurrentReaderSection]——reader 实际
  /// 挂载的是哪一章，才是 Sasayaki 的判定参照系。
  ///
  /// SMIL/JSON 等非 sasayaki 路径 cue 的 textFragmentId 解码返回 null，
  /// 自然跳过这套逻辑（它们没有跨章同步概念）。
  void _maybeEmitCrossChapter(AudioCue? cue, {bool bypassPlayGuard = false}) {
    if (_chapterTransition) {
      // ignore: avoid_print
      print('[hibiki-crossChapter] blocked: _chapterTransition=true');
      return;
    }
    if (cue == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag == null) return;
    final int cueSec = frag.sectionIndex;
    final int currentSec = getCurrentReaderSection?.call() ?? -1;
    // ignore: avoid_print
    print(
        '[hibiki-crossChapter] cueSec=$cueSec currentSec=$currentSec follow=${followAudio.value} played=$_hasPlayedOnce');
    if (currentSec < 0) return;
    if (cueSec == currentSec) return;
    if (!followAudio.value) return;
    if (!bypassPlayGuard && !_hasPlayedOnce) return;
    _chapterTransition = true;
    onCrossChapter?.call(cueSec);
  }

  /// 由 reader 在章节跳转完成（或失败）后调用：清守卫，
  /// 用当前播放位置重算 cue 并立刻 notify，暂停态也能即时高亮。
  ///
  /// 无论成功失败都必须调用，否则 _chapterTransition 永远卡 true。
  void notifySectionRestoreCompleted({
    required int currentReaderSection,
    required bool success,
  }) {
    _chapterTransition = false;
    _updateCurrentCue(_player.position.inMilliseconds);
  }

  /// 用户手动翻章时清 `_chapterTransition` 守卫，防止旧跨章逻辑卡死。
  void cancelChapterTransition() {
    _chapterTransition = false;
  }

  /// 翻转 Follow audio 开关并经 [onFollowAudioPersist] 落 Hive。相同值调用
  /// 不 notify 也不写库。持久化失败不回滚内存状态——下次启动时从 Hive
  /// 读回会自动纠偏，比"静默回滚"更易排查。
  ///
  /// OFF → ON 时主动让 reader 回到当前 cue：
  /// - 跨 section：复用 [_maybeEmitCrossChapter] 请求跳章，跳完
  ///   [notifySectionRestoreCompleted] 自己会 notify。
  /// - 同 section：notifyListeners 让 `_onCueChanged` 以 `reveal=true`
  ///   重新拉回当前 cue。
  /// 否则用户手动翻页后再开 Follow 只翻图标，要等下一条 cue 才被动回跳，
  /// 体感是"跳不回去"。
  void setFollowAudio(bool value) {
    if (followAudio.value == value) return;
    followAudio.value = value;
    final Future<void> Function(bool)? persist = onFollowAudioPersist;
    if (persist != null) {
      unawaited(persist(value));
    }
    if (!value) return;
    snapReaderToAudio();
  }

  /// 把 reader 当前页强制对齐到音频所在页。用于：
  /// - OFF → ON 翻 Follow audio（[setFollowAudio]）
  /// - Follow ON 时用户手翻到别段（reader 侧 sectionChanged auto=false）
  ///
  /// 跨段走 `_maybeEmitCrossChapter` 请跳章，跳完
  /// [notifySectionRestoreCompleted] 自己会 notify；同段直接 notifyListeners
  /// 让 `_onCueChanged` 以 `reveal=true` 把 scrollTop 拉回 cue 那一页。
  /// 已在跨章 await 中幂等返回（既有 transition 会接管）。
  void snapReaderToAudio() {
    if (_chapterTransition) return;
    final AudioCue? cue = _currentCue;
    if (cue == null) return;
    _forceNextReveal = true;
    _maybeEmitCrossChapter(cue, bypassPlayGuard: true);
    if (_chapterTransition) return;
    notifyListeners();
  }

  // HBK-AUDIT-070: snapAudioToReader / getReaderViewportPos 是从未被装配的死
  // 伪功能——没有任何生产者给 getReaderViewportPos 赋值，也没有调用方调用
  // snapAudioToReader；且唯一可能的视口生产者 AudiobookBridge.getViewportNormOffset
  // 输出的是 0..10000 进度分数而非 cue 的 normChar 偏移，坐标空间不兼容。
  // 在出现真实生产者前删除该半成品，避免误导维护者。

  /// 设置音画延迟（毫秒），带边界夹取。对齐上游 Sasayaki sheet 的 ±2s
  /// slider 范围；超出这个范围几乎不可能是有意义的对齐偏移。
  /// 写库走 [onDelayPersist]。相同值跳过 notify/写库。
  void setDelayMs(int ms) {
    final int clamped = ms.clamp(-600000, 600000);
    if (delayMs.value == clamped) return;
    delayMs.value = clamped;
    // 立刻在当前位置重查 cue，让高亮即时反映新偏移，不用等
    // positionStream 下一 tick（暂停状态下完全不发）。
    _updateCurrentCue(_player.position.inMilliseconds);
    final Future<void> Function(int)? persist = onDelayPersist;
    if (persist != null) {
      unawaited(persist(clamped));
    }
  }

  /// 将 cue 映射到 just_audio playlist index + 文件内毫秒。
  ({int audioFileIndex, int positionMs})? _positionForCue(AudioCue cue) {
    if (cue.audioFileIndex < 0 || cue.audioFileIndex >= _audioFiles.length) {
      return null;
    }
    return (audioFileIndex: cue.audioFileIndex, positionMs: cue.startMs);
  }

  int _clampToKnownDuration(int positionMs) {
    final Duration? dur = _player.duration;
    if (dur == null || dur.inMilliseconds <= 0) return positionMs;
    return positionMs.clamp(0, dur.inMilliseconds);
  }

  List<AudioCue> _chapterCuesForAudioFile(int audioFileIndex) {
    return _chapterCues
        .where((AudioCue cue) => cue.audioFileIndex == audioFileIndex)
        .toList();
  }

  static int? _positionMsForCue({
    required int audioFileIndex,
    required int startMs,
    required int audioFileCount,
  }) {
    if (audioFileIndex < 0 || audioFileIndex >= audioFileCount) {
      return null;
    }
    return startMs;
  }

  static int? _nextCueIndex({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required int positionMs,
  }) {
    if (cues.isEmpty) return null;
    int idx = currentCueIndex;
    if (idx < 0 || idx >= cues.length) {
      idx = JsonAlignmentParser.findCueIndex(
        cues: cues,
        positionMs: positionMs,
      );
      if (idx < 0) return 0;
    }
    if (idx + 1 >= cues.length) return null;
    return idx + 1;
  }

  /// [skipToPrevCue] 的纯决策（与 [_nextCueIndex] 对称）。对齐上游 Sasayaki
  /// `prevCue()`：
  ///  - 已定位到当前 cue：取它的前一条；已在首句返回 null（= 触发跨章边界）。
  ///  - 未定位到 cue（gap / 开头）：按位置二分，取"最近一条起点早于当前位置"的
  ///    cue；早于全部 cue 时回到首句（索引 0）。
  ///
  /// 注意：这里的 gap 回退**刻意**不等同于 [JsonAlignmentParser.findCueIndex]
  /// ——后者在 gap 内返回 -1（无高亮），而"上一句"导航需要落到 gap 之前的那条
  /// cue，二者是不同语义，不能互相替代。
  static int? _prevCueIndex({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required AudioCue? currentCue,
    required int positionMs,
  }) {
    if (cues.isEmpty) return null;
    if (currentCue != null) {
      final int curIdx = currentCueIndex >= 0
          ? currentCueIndex
          : cues.indexWhere(
              (c) => c.textFragmentId == currentCue.textFragmentId,
            );
      if (curIdx > 0) return curIdx - 1;
      if (curIdx == 0) return null; // 已在首句 → 跨章边界
      // curIdx == -1（未按 fragmentId 命中）：落到下面按位置查找。
    }
    // 二分找第一条 startMs >= positionMs；上一条即为目标。
    int lo = 0;
    int hi = cues.length;
    while (lo < hi) {
      final int mid = (lo + hi) >>> 1;
      if (cues[mid].startMs < positionMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? 0 : lo - 1;
  }

  static int _allBookCueIndex({
    required List<AudioCue> allBookCues,
    required AudioCue currentCue,
  }) {
    for (int i = 0; i < allBookCues.length; i++) {
      if (_isSameCue(allBookCues[i], currentCue)) return i;
    }
    return -1;
  }

  static bool _isSameCue(AudioCue a, AudioCue b) {
    if (identical(a, b)) return true;
    final int? aId = a.id;
    final int? bId = b.id;
    if (aId != null && bId != null) return aId == bId;
    if (a.bookUid == b.bookUid &&
        a.chapterHref == b.chapterHref &&
        a.sentenceIndex == b.sentenceIndex &&
        a.audioFileIndex == b.audioFileIndex &&
        a.startMs == b.startMs &&
        a.endMs == b.endMs) {
      return true;
    }
    return a.textFragmentId.isNotEmpty && a.textFragmentId == b.textFragmentId;
  }

  @visibleForTesting
  static int? positionMsForCueForTesting({
    required int audioFileIndex,
    required int startMs,
    required int audioFileCount,
  }) {
    return _positionMsForCue(
      audioFileIndex: audioFileIndex,
      startMs: startMs,
      audioFileCount: audioFileCount,
    );
  }

  @visibleForTesting
  static int? nextCueIndexForTesting({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required int positionMs,
  }) {
    return _nextCueIndex(
      cues: cues,
      currentCueIndex: currentCueIndex,
      positionMs: positionMs,
    );
  }

  @visibleForTesting
  static int? prevCueIndexForTesting({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required AudioCue? currentCue,
    required int positionMs,
  }) {
    return _prevCueIndex(
      cues: cues,
      currentCueIndex: currentCueIndex,
      currentCue: currentCue,
      positionMs: positionMs,
    );
  }

  @visibleForTesting
  static int allBookCueIndexForTesting({
    required List<AudioCue> allBookCues,
    required AudioCue currentCue,
  }) {
    return _allBookCueIndex(
      allBookCues: allBookCues,
      currentCue: currentCue,
    );
  }

  // ── 生命周期 ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _maybeSavePosition(force: true);
    _imagePauseTimer?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _noisySub?.cancel();
    followAudio.dispose();
    delayMs.dispose();
    imagePauseSec.dispose();
    _clipStateSub?.cancel();
    _clipStateSub = null;
    _clipPlayer?.dispose();
    _clipPlayer = null;
    _player.dispose();
    super.dispose();
  }

  Future<void> playRange(AudioPlaybackRange range) async {
    if (range.audioFileIndex < 0 ||
        range.audioFileIndex >= _audioFiles.length) {
      return;
    }
    if (range.endMs <= range.startMs) {
      return;
    }
    final bool shouldResumeMain = _resumeMainAfterClip || _player.playing;
    await stopClip(resumeMain: false);

    _resumeMainAfterClip = shouldResumeMain;
    if (_player.playing) {
      await _player.pause();
    }

    final AudioPlayer clip = AudioPlayer();
    _clipPlayer = clip;

    await clip.setAudioSource(
      ClippingAudioSource(
        child: AudioSource.file(_audioFiles[range.audioFileIndex].path),
        start: Duration(milliseconds: range.startMs),
        end: Duration(milliseconds: range.endMs),
      ),
    );
    await clip.setSpeed(_player.speed);

    _clipStateSub?.cancel();
    _clipStateSub = clip.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        stopClip();
      }
    });

    await clip.play();
  }

  Future<void> stopClip({bool resumeMain = true}) async {
    _clipStateSub?.cancel();
    _clipStateSub = null;
    final AudioPlayer? old = _clipPlayer;
    if (old != null) {
      _clipPlayer = null;
      await old.stop();
      old.dispose();
    }
    if (resumeMain && _resumeMainAfterClip) {
      _resumeMainAfterClip = false;
      unawaited(_player.play());
    }
  }
}

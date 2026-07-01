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

  /// 每个音频文件的时长（毫秒），下标 = audioFileIndex。由对齐 cue 的
  /// per-file 最大 endMs 推算（load-free，播放前即可用），供 [totalDuration]
  /// / [globalPosition] 显示用。空 = 无对齐数据，回退到 just_audio。
  List<int> _fileDurationsMs = const <int>[];

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

  /// 供**悬浮字幕 / 媒体通知副标题 / 书架 mini bar** 这类「显示意图」表面使用的
  /// cue（TODO-1065, BUG-509）。与 [currentCue] 的关键差异：
  ///
  /// [currentCue] 是 reader 正文高亮的权威值——`_updateCurrentCue` 在 `idx<0`
  /// （音频引子期 / 句间静音 gap）时**刻意裸 return 保持上一句**，避免高亮闪烁
  /// （见 findCueIndex 闭区间契约 + BUG-074 家族）。这条 hold 契约**不改**。
  ///
  /// 但显示表面不需要「hold 上一句防闪烁」，反而希望：
  ///  - 音频开头到首句 startMs 之间就先显示**首句**（消除首句空窗）；
  ///  - 句间 gap 内提前显示**下一条即将到来**的 cue（不再等上一句播完）。
  ///
  /// 因此本 getter 独立按当前位置重算，不复用被 hold 的 `_currentCue`：
  ///  - 命中某条 cue 区间（`idx>=0`）→ 返回该 cue（= 当前句）；
  ///  - 位置早于首句 → 返回首句（index 0）；
  ///  - 落在 gap → 返回下一条 startMs 严格大于当前位置的 cue；
  ///  - 位置晚于末句（无下一条）→ 返回末句，保持显示不清空。
  ///
  /// 前瞻在 `effectiveMs = pos - delayMs` 空间计算，与用户音画同步偏移一致。
  /// 无 cue 数据时回退到 [currentCue]（可能为 null）。
  AudioCue? get displayCueForFloatingLyric {
    final int audioFileIndex = _player.currentIndex ?? 0;
    final List<AudioCue> fileCues = _chapterCuesForAudioFile(audioFileIndex);
    if (fileCues.isEmpty) return _currentCue;
    final int effectiveMs =
        (_player.position.inMilliseconds - delayMs.value).clamp(0, 1 << 30);
    return _displayCueFor(cues: fileCues, effectiveMs: effectiveMs);
  }

  /// [displayCueForFloatingLyric] 的纯决策（与 [_nextCueIndex]/[_prevCueIndex]
  /// 同构，抽成静态便于单测，不触 [_player]）。[cues] 须已按 startMs 升序、且同属
  /// 当前音频文件；[effectiveMs] 已减 delay。空列表返回 null。
  static AudioCue? _displayCueFor({
    required List<AudioCue> cues,
    required int effectiveMs,
  }) {
    if (cues.isEmpty) return null;
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: cues,
      positionMs: effectiveMs,
    );
    // 命中某条 cue 区间：当前句。
    if (idx >= 0) return cues[idx];
    // idx<0：早于首句 / 句间 gap / 晚于末句。取「下一条 startMs 严格大于当前
    // 位置」的 cue（早于首句时即首句 index 0）；无下一条（晚于末句）→ 末句。
    for (final AudioCue cue in cues) {
      if (cue.startMs > effectiveMs) return cue;
    }
    return cues.last;
  }

  /// [displayCueForFloatingLyric] 在给定 cue 列表中的 0-based 索引（-1 = 未命中）。
  /// 供悬浮字幕 N>0 上下文窗口选行用；语义与 getter 一致（首句前=首句、gap=下一句），
  /// 只是把「显示 cue」映射回调用方选定的列表（全书快照 or 章内快照）的下标。
  int displayCueIndexIn(List<AudioCue> cues) {
    final AudioCue? cue = displayCueForFloatingLyric;
    if (cue == null || cues.isEmpty) return -1;
    for (int i = 0; i < cues.length; i++) {
      if (_isSameCue(cues[i], cue)) return i;
    }
    return -1;
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

  /// User-initiated reader navigation temporarily owns the visible section.
  /// While the audio remains on the exact same cue, follow-audio must not
  /// immediately cross-chapter back and undo a TOC/link/page-turn jump.
  AudioCue? _manualReaderOverrideCue;

  /// 显式 seek（skipToCue / playCueOnce）进行中：`preload:false` 下跨文件
  /// `seek(index:)` 会触发目标文件异步加载，加载期 positionStream 先吐瞬态
  /// 位置（0 / 旧文件章首），逐 tick 触发 _maybeEmitCrossChapter / reveal，
  /// 造成「音频开头 → 章节开头 → 正确位置」三段跳（BUG-061）。
  /// 立旗后 [_updateCurrentCue] 顶部抑制瞬态 tick，直到 player 切到目标音频
  /// 文件且位置到达目标（见 [reachedExplicitSeekTargetForTesting]）才放行。
  bool _explicitSeekInFlight = false;
  int _explicitSeekTargetFileIndex = -1;
  int _explicitSeekTargetMs = 0;

  /// 落定容差（毫秒）：位置到达 `targetMs - 容差` 即视为 seek 落定，
  /// 取约两个 125ms tick 的量级，吸收 just_audio 加载完成后的首帧抖动。
  static const int _kExplicitSeekToleranceMs = 300;

  /// Follow audio 开关变化时的持久化回调。Reader 页面 attach audiobook 时
  /// 装入这个字段（一般是 `(v) => repo.updateFollowAudio(bookKey, v)`），
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

  /// 音量变化时的持久化回调。内部在 [setVolume] 调用（与 [onSpeedPersist] 同型）。
  Future<void> Function(double volume)? onVolumePersist;

  // ── 音量 ─────────────────────────────────────────────────────────────────
  double get volume => _player.volume;

  Future<void> setVolume(double v) async {
    final double clamped = v.clamp(0.0, 2.0);
    final double prev = _player.volume;
    await _player.setVolume(clamped);
    notifyListeners();
    if ((clamped - prev).abs() < 0.001) return;
    final Future<void> Function(double)? persist = onVolumePersist;
    if (persist != null) {
      unawaited(persist(clamped));
    }
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

  /// TODO-1037：跨章推进经过「独立成章的纯图片页」时的停留。
  ///
  /// 与 [triggerImagePause] 的区别：后者是 reader 在**已渲染章同一 DOM 内**两条
  /// 相邻 cue 锚点间跨过 `<img>` 时调用（`window.__hoshiImageBetween`），用一次性
  /// Timer 暂停 + 到点自恢复，调用方不等待。但纯图片章没有 cue → cue 驱动的跨章会
  /// 一步从文本章 N 跳到下一个有文本的章 N+k，中间整章是图片的章从不挂载、从不被
  /// 那条 DOM 内判定看见（两锚点在不同章 DOM，`document.contains(prev)` 直接返回
  /// null），所以图片等待对独立成章的图片页彻底失效（BUG）。
  ///
  /// 修复方向 A：reader 在跨章落定前枚举中间纯图片章，对每一章导航过去并调用本
  /// 方法停留 [imagePauseSec] 秒。本方法是 **await-based**（reader 要顺序停留多张图
  /// 再继续到目标章），复用 [triggerImagePause] 同一套「暂停播放→等 imagePauseSec
  /// 秒→恢复播放」原语，不新造定时器语义；用同一 [_imagePauseTimer] 字段记录在途
  /// 停留，让 [isImagePaused] 在跨章停留期间也为真。
  ///
  /// 坑1（[triggerImagePause] 的 `!_player.playing` 早返回）规避：跨章停留是「正
  /// 在跟随播放时跨过整章图片」，进来时 player 必为 playing（cue 推进才驱动跨章），
  /// 本方法主动 `pause()`→等待→`play()`，不照搬那条「非播放即早退」守卫（它防的是
  /// 用户已手动暂停时不该再被图片暂停二次接管，与本路径语义不同）。仍受
  /// `imagePauseSec > 0` 门控：等于 0（图片等待关）时直接返回，调用方按原跨章直跳。
  Future<void> awaitImageChapterPause() async {
    final int sec = imagePauseSec.value;
    if (sec <= 0) return;
    _imagePauseTimer?.cancel();
    if (_player.playing) {
      await _player.pause();
    }
    notifyListeners();
    final Completer<void> done = Completer<void>();
    _imagePauseTimer = Timer(Duration(seconds: sec), () {
      _imagePauseTimer = null;
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    // 停留结束恢复播放，让 cue 推进继续把文字带到下一章。reader 侧在跨章序列收尾
    // 时统一 notify / reanchor，这里只负责恢复播放时钟。
    if (!_player.playing) {
      await _player.play();
    }
    notifyListeners();
  }

  /// TODO-1037：reader 在「跨章中间存在纯图片章」的多步停留序列期间，竖起
  /// [_chapterTransition] 守卫，阻止 [_updateCurrentCue] / [_maybeEmitCrossChapter]
  /// 在序列途中（每个中间章 [notifySectionRestoreCompleted] 把守卫清回 false 后）
  /// 重入 `onCrossChapter` 造成乱跳。序列结束由 reader 调
  /// [notifySectionRestoreCompleted]（最终目标章载入完成）清回 false。
  void holdChapterTransition() {
    _chapterTransition = true;
  }

  /// TODO-1037（重入竞态根因）：[_pauseThroughImageOnlyChapters] 逐个导航中间纯
  /// 图片章时，每个中间章载入完成会**同步**触发 [notifySectionRestoreCompleted]
  /// （reader 的 `_onRestoreComplete` 在 `_restoreCompleter.complete(true)` 之后、
  /// 等待方 `_navigateToChapterAndWait` 的 await 续体作为微任务恢复**之前**就同步
  /// 跑完）。那次同步的 `notifySectionRestoreCompleted` 会先把 [_chapterTransition]
  /// 清回 false，再同步 `_updateCurrentCue`——此刻音频仍在播放（`awaitImageChapterPause`
  /// 的 `pause()` 要等本次导航 await 返回后才发起），cue 位置仍指向最终文本章 →
  /// `_maybeEmitCrossChapter` 命中 `cueSec(目标) != currentSec(图片章)` 重新发起跨章 →
  /// 剩余中间图片章被一步跳过（即 f3e4d2e52 声称修好的症状复现）。reader 端
  /// `_imageChapterPauseInFlight` 是 reader 私有标志，控制器看不到，挡不住这条同步
  /// 重入。修复：reader 在整段停留序列期间置此标志为真，[notifySectionRestoreCompleted]
  /// 见真则**保持守卫不放、不重算 cue**（中间章载入不是序列终点）；序列收尾 reader
  /// 置回 false 后，最终落到目标文本章的导航才正常清守卫并重算。
  bool _imageChapterPauseActive = false;

  void setImageChapterPauseActive(bool active) {
    _imageChapterPauseActive = active;
  }

  /// 测试用：暴露 [_chapterTransition] 守卫当前是否持住，便于断言重入竞态修复。
  @visibleForTesting
  bool get chapterTransitionHeldForTesting => _chapterTransition;

  /// 是否正在播放。
  bool get isPlaying => _player.playing;

  /// 当前全局播放位置。
  Duration get position => _player.position;

  /// 当前文件时长（per-file，供 [seekRelative] / [seekMs] 钳制用）。
  Duration get duration => _player.duration ?? Duration.zero;

  /// 全书总时长（所有音频文件时长之和）。优先用对齐 cue 推算（播放前即可用，
  /// 无需解码音频）；无 cue 数据时回退到 just_audio 当前文件时长。
  ///
  /// 与 [duration]（per-file，供 seek 钳制）不同，这是显示用的「总长度」。
  Duration get totalDuration {
    final Duration? playerDur = _player.duration;
    if (_fileDurationsMs.isNotEmpty) {
      int sum = 0;
      for (final int ms in _fileDurationsMs) {
        sum += ms;
      }
      if (sum > 0) {
        // cue 估算到「末句结束」会比真实文件短（片尾静音/音乐不在 cue 里）。
        // 单文件时 `_player.duration` 是真实整段时长，取较大者，避免播放到
        // 末句之后出现 pos>dur 的显示瑕疵；多文件时 `_player.duration` 只是
        // 当前文件，远小于全书 sum，max 自然取 sum。
        final int playerMs = playerDur?.inMilliseconds ?? 0;
        return Duration(milliseconds: sum > playerMs ? sum : playerMs);
      }
    }
    return playerDur ?? Duration.zero;
  }

  /// 全书累计播放位置 = 当前文件之前所有文件时长之和 + 当前文件内位置。
  /// 与 [totalDuration] 配对供进度条显示；无 cue 数据时退化为当前文件位置。
  ///
  /// 前序文件用 cue 估算时长累加，当前文件内用真实 `_player.position`——
  /// 二者精度不同，跨文件瞬间可能轻微抖动（真实文件长常 > 末句 endMs），
  /// 仅结尾几百毫秒的视觉抖动，不影响只读进度条的正确性。
  Duration get globalPosition {
    final int idx = _player.currentIndex ?? 0;
    int base = 0;
    for (int i = 0; i < idx && i < _fileDurationsMs.length; i++) {
      base += _fileDurationsMs[i];
    }
    return Duration(milliseconds: base + _player.position.inMilliseconds);
  }

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
    double initialVolume = 1.0,
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
    _imageChapterPauseActive = false;

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

    // 恢复持久化音量（默认 1.0 不必下发；非默认才设，避免无谓 platform 调用）。
    // 与 speed/delay 同：load 不触发 persist 回调，载入不是用户操作。
    if ((initialVolume - 1.0).abs() > 0.001) {
      try {
        await _player.setVolume(initialVolume.clamp(0.0, 2.0));
      } catch (e, stack) {
        debugPrint('AudiobookController.setVolume: $e\n$stack');
        debugPrint(
            '[hibiki-audiobook] initial setVolume $initialVolume failed: $e');
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

  /// 播放位置写入回调。调用方在 attach 时装入，一般实现为写 Drift database
  /// preferences。返回写库 Future，让 [flushPosition] 能 await 到真正落库
  /// （周期路径仍 fire-and-forget，不 await）。
  Future<void> Function(String bookKey, int positionMs)? onPositionWrite;

  /// 把当前播放位置写入持久化存储。对齐上游：**每整秒变化一次**就写。
  /// 125ms tick 触发 8 次里只有 1 次真的落库，IO 成本和上游等价。
  ///
  /// 调用时机：cue 变化（_updateCurrentCue）、暂停、dispose。
  void _maybeSavePosition({bool force = false}) {
    final String? uid = _audiobook?.bookKey;
    if (uid == null) return;
    final int posMs = _player.position.inMilliseconds;
    final int wholeSec = posMs ~/ 1000;
    if (!force && wholeSec == _lastSavedWholeSec) {
      return;
    }
    _lastSavedWholeSec = wholeSec;
    unawaited(onPositionWrite?.call(uid, posMs));
  }

  /// 强制把当前播放位置同步写入持久层并 **await 到落库**。
  ///
  /// 用于 app 退到后台（reader 页 `didChangeAppLifecycleState` 的
  /// paused/inactive）：后台之后进程随时可能被系统杀掉，而硬杀场景 [dispose]
  /// 的 `force` 保存不会执行，周期保存（[_maybeSavePosition]）又是
  /// fire-and-forget（写库 Future 没人等，可能在进程被回收前还没 commit），
  /// 加上后台 Dart timer 挂起后周期保存本身也停了。这里在仍存活的 onPause
  /// 窗口里把当前位置 await 写穿，保证退到后台那一刻的进度可靠落库。
  Future<void> flushPosition() async {
    final String? uid = _audiobook?.bookKey;
    if (uid == null) return;
    final int posMs = _player.position.inMilliseconds;
    _lastSavedWholeSec = posMs ~/ 1000;
    await onPositionWrite?.call(uid, posMs);
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
    // 换 cue 列表是上下文边界：任何挂起的显式 seek 抑制窗都失效，必须复位，
    // 否则下面的 _updateCurrentCue 重算会被旗挡住、_currentCue 卡 null（W-2）。
    _explicitSeekInFlight = false;
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
    _rebuildFileDurations();
  }

  /// 从全书 cue 推算每个文件时长 = 该文件内 cue 的最大 endMs。
  void _rebuildFileDurations() {
    int maxIdx = -1;
    for (final AudioCue cue in _allBookCues) {
      if (cue.audioFileIndex > maxIdx) maxIdx = cue.audioFileIndex;
    }
    if (maxIdx < 0) {
      _fileDurationsMs = const <int>[];
      return;
    }
    final List<int> durations = List<int>.filled(maxIdx + 1, 0);
    for (final AudioCue cue in _allBookCues) {
      final int idx = cue.audioFileIndex;
      if (idx < 0) continue;
      if (cue.endMs > durations[idx]) durations[idx] = cue.endMs;
    }
    _fileDurationsMs = durations;
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
    _manualReaderOverrideCue = null;
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
  /// 立起显式 seek 抑制窗：记录目标音频文件与位置，[_updateCurrentCue]
  /// 据此在加载期抑制瞬态 tick，直到真实位置落定（BUG-061）。
  void _beginExplicitSeek(int targetFileIndex, int targetMs) {
    _explicitSeekInFlight = true;
    _explicitSeekTargetFileIndex = targetFileIndex;
    _explicitSeekTargetMs = targetMs;
  }

  Future<void> skipToCue(AudioCue cue) async {
    _manualReaderOverrideCue = null;
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
    _beginExplicitSeek(mappedPosition.audioFileIndex, positionMs);
    await _player.seek(
      Duration(milliseconds: positionMs),
      index: mappedPosition.audioFileIndex,
    );
    _chapterTransition = false;
    final int idx = _chapterCues.indexOf(cue);
    if (idx >= 0) {
      // 权威写入目标 cue（不依赖瞬态 position）；保持 _explicitSeekInFlight=true，
      // 由 _updateCurrentCue 在位置落定后清旗，期间抑制加载期瞬态 tick。
      _currentCueIndex = idx;
      _currentCue = cue;
      _maybeEmitCrossChapter(cue);
      notifyListeners();
    } else {
      // 非 sasayaki 路径维持原有「按当前位置即时定位」语义，不抑制。
      _explicitSeekInFlight = false;
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

    final int targetMs = _clampToKnownDuration(startPosition.positionMs);
    _beginExplicitSeek(startPosition.audioFileIndex, targetMs);
    await _player.seek(
      Duration(milliseconds: targetMs),
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

  void _updateCurrentCue(int posMs, {bool forceNotify = false}) {
    // 显式 seek（skipToCue/playCueOnce）加载期：抑制瞬态 tick 驱动位置保存 /
    // cue 推进 / 跨章 / reveal，直到真实位置到达目标（BUG-061）。落定的那一
    // tick 清旗后继续往下按正常逻辑处理。
    if (_explicitSeekInFlight) {
      // 暂停态：skipToCue/playCueOnce 已把目标 cue 作为权威值写入 _currentCue，
      // 但 `seek(index:)` 仍会吐瞬态位置（旧位置 / 0 / 旧章首）。此时没有真实
      // 播放推进，而 reached 判据（posMs >= target-容差）会被两种瞬态误判为
      // 「落定」：① 前向 seek 时停在本句末尾、旧位置已落进 target-容差窗内；
      // ② 后向 seek（上一句）时旧位置本就高于 target。一旦误判清旗，就会用瞬态
      // 旧位置 findCueIndex 重解析，把权威 cue 覆盖回旧句——表现为「暂停后点
      // 下一句又跳回当前句 / 上一句乱跳」。暂停时一律抑制瞬态、保留权威 cue、
      // 不清旗；待用户按播放、首帧真实到达 target 后再走下面的正常落定逻辑。
      if (!_player.playing) return;
      if (reachedExplicitSeekTargetForTesting(
        currentFileIndex: _player.currentIndex ?? 0,
        posMs: posMs,
        targetFileIndex: _explicitSeekTargetFileIndex,
        targetMs: _explicitSeekTargetMs,
      )) {
        _explicitSeekInFlight = false;
      } else {
        return;
      }
    }
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
    if (chapterIdx == _currentCueIndex) {
      // cue 未变但 reader 章可能仍不同步（BUG-069）：skipToCue 跨章时会预置
      // _currentCueIndex 到目标 cue，但其 _maybeEmitCrossChapter 可能因
      // !_hasPlayedOnce（本会话首次「从本句播放」）/ restore-in-flight 等守卫
      // 被挡，文字停在原章；之后 cue 一直不变就走这条裸 return、永不再做跨章
      // 检查 → 要用户再点一次才跟过去。在「正在跟随播放」（playing 且非
      // playCueOnce 单句试听）时补一次安静（不打印）的跨章检查，让文字收敛到
      // 当前 cue 所属章。_maybeEmitCrossChapter 同章早退（已同步时 no-op）、
      // 跳章期间 _chapterTransition 守卫挡住后续 tick，不会 per-tick 抖动；
      // 暂停态不补检查，避免覆盖用户手动翻页。
      if (_player.playing && _stopAtPositionMs == null) {
        _maybeEmitCrossChapter(cue, quiet: true);
      }
      if (forceNotify) {
        notifyListeners();
      }
      return;
    }
    _manualReaderOverrideCue = null;
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
  void _maybeEmitCrossChapter(AudioCue? cue,
      {bool bypassPlayGuard = false, bool quiet = false}) {
    if (_chapterTransition) {
      if (!quiet) {
        // ignore: avoid_print
        print('[hibiki-crossChapter] blocked: _chapterTransition=true');
      }
      return;
    }
    if (cue == null) return;
    if (!bypassPlayGuard && _isManualReaderOverrideCue(cue)) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag == null) return;
    final int cueSec = frag.sectionIndex;
    final int currentSec = getCurrentReaderSection?.call() ?? -1;
    if (!quiet) {
      // ignore: avoid_print
      print(
          '[hibiki-crossChapter] cueSec=$cueSec currentSec=$currentSec follow=${followAudio.value} played=$_hasPlayedOnce');
    }
    if (!shouldCrossChapterForTesting(
      cueSec: cueSec,
      currentSec: currentSec,
      followAudio: followAudio.value,
      hasPlayedOnce: _hasPlayedOnce,
      bypassPlayGuard: bypassPlayGuard,
    )) {
      return;
    }
    _chapterTransition = true;
    onCrossChapter?.call(cueSec);
  }

  /// 纯决策：当前 cue 所属章 [cueSec] 与 reader 实际挂载章 [currentSec] 是否
  /// 应触发跨章跟随。`currentSec < 0`（reader 未就绪）或同章不跳；follow 关 /
  /// 还没按过 play（非 bypass）也不跳。抽出便于单测，并让「cue 未变但章不同步」
  /// 的恢复补检查（[_updateCurrentCue]）复用同一判据。`hasPlayedOnce` 守卫正是
  /// 首次「从本句播放」跨章被挡、需点两次的根因（BUG-069）。
  @visibleForTesting
  static bool shouldCrossChapterForTesting({
    required int cueSec,
    required int currentSec,
    required bool followAudio,
    required bool hasPlayedOnce,
    bool bypassPlayGuard = false,
  }) {
    if (currentSec < 0) return false;
    if (cueSec == currentSec) return false;
    if (!followAudio) return false;
    if (!bypassPlayGuard && !hasPlayedOnce) return false;
    return true;
  }

  /// 由 reader 在章节跳转完成（或失败）后调用：清守卫，
  /// 用当前播放位置重算 cue 并立刻 notify，暂停态也能即时高亮。
  ///
  /// 无论成功失败都必须调用，否则 _chapterTransition 永远卡 true。
  void notifySectionRestoreCompleted({
    required int currentReaderSection,
    required bool success,
  }) {
    // TODO-1037（重入竞态守卫）：图片章停留序列进行中，中间章载入不是序列终点。
    // 此刻清守卫 + 同步重算 cue 会在音频仍播放、cue 仍指目标文本章时重入
    // _maybeEmitCrossChapter，一步跳过剩余中间图片章。保持守卫不放、不重算，
    // 待 reader 收尾置 setImageChapterPauseActive(false) 后由落到目标章的导航正常清。
    if (_imageChapterPauseActive) return;
    _chapterTransition = false;
    // 章节恢复完成是上下文边界：复位显式 seek 抑制窗，避免旧旗挡住重算（W-2）。
    _explicitSeekInFlight = false;
    _updateCurrentCue(_player.position.inMilliseconds, forceNotify: success);
  }

  /// 用户手动翻章时清 `_chapterTransition` 守卫，防止旧跨章逻辑卡死。
  void cancelChapterTransition() {
    _chapterTransition = false;
  }

  /// Called by the reader for TOC/link/search/bookmark/page-turn jumps. It lets
  /// the manually selected reader section stay visible until the audio advances
  /// to a different cue or the user explicitly asks to follow audio again.
  void noteManualReaderNavigation() {
    _chapterTransition = false;
    _manualReaderOverrideCue = _currentCue;
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
    _manualReaderOverrideCue = null;
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

  bool _isManualReaderOverrideCue(AudioCue cue) {
    final AudioCue? overrideCue = _manualReaderOverrideCue;
    return overrideCue != null && _isSameCue(overrideCue, cue);
  }

  static bool _isSameCue(AudioCue a, AudioCue b) {
    if (identical(a, b)) return true;
    final int? aId = a.id;
    final int? bId = b.id;
    if (aId != null && bId != null) return aId == bId;
    if (a.bookKey == b.bookKey &&
        a.chapterHref == b.chapterHref &&
        a.sentenceIndex == b.sentenceIndex &&
        a.audioFileIndex == b.audioFileIndex &&
        a.startMs == b.startMs &&
        a.endMs == b.endMs) {
      return true;
    }
    return a.textFragmentId.isNotEmpty && a.textFragmentId == b.textFragmentId;
  }

  /// 显式 seek 是否「落定」：player 已切到目标音频文件、且当前位置到达
  /// `targetMs - toleranceMs`。未落定（仍在加载期 / index 未切 / 位置仍为
  /// 瞬态 0）时返回 false，调用方应抑制该 tick（BUG-061）。纯函数，可单测。
  @visibleForTesting
  static bool reachedExplicitSeekTargetForTesting({
    required int currentFileIndex,
    required int posMs,
    required int targetFileIndex,
    required int targetMs,
    int toleranceMs = _kExplicitSeekToleranceMs,
  }) {
    return currentFileIndex == targetFileIndex &&
        posMs >= targetMs - toleranceMs;
  }

  /// 测试钩子：直接以指定位置驱动一次 [_updateCurrentCue]，模拟 positionStream
  /// 的一帧 tick（含显式 seek 加载期的瞬态位置）。生产代码不调用。
  @visibleForTesting
  void debugUpdateCueForPosition(int posMs) => _updateCurrentCue(posMs);

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

  /// 测试钩子：暴露 [_displayCueFor] 纯决策（悬浮字幕/通知/mini bar 显示 cue）。
  @visibleForTesting
  static AudioCue? displayCueForTesting({
    required List<AudioCue> cues,
    required int effectiveMs,
  }) {
    return _displayCueFor(cues: cues, effectiveMs: effectiveMs);
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

  /// 真正停播（止声）：停掉主播放器与 clip 播放器并释放其 native 解码器，
  /// 再强制落库当前位置。供退出/停止会话路径在 [dispose] 之前 `await`。
  ///
  /// 根因（BUG-278 / TODO-367）：会话停止路径 [AudiobookSession.stop] 此前是
  /// `await controller.pause(); controller.dispose();`。`pause()`（just_audio
  /// 语义「保留解码器以便快速恢复」）**不释放 native 资源**，紧随的
  /// `dispose()` 在 `ChangeNotifier` 同步签名里是 fire-and-forget（无法 await
  /// 异步的平台拆除），二者竞争——Android(ExoPlayer) 上表现为退出/停止后音频仍在响。
  ///
  /// `stop()`（just_audio 语义「app 暂时不再播音频，释放解码器与 native 资源」）
  /// 才是真正「让声音停下并放掉资源」的操作，与 [load] 第一步、[stopClip] 的
  /// 「先 stop 再 dispose」一致。把它做成可 `await`：先 stop settle 完平台切换，
  /// 再让调用方 dispose，避免「stop 的异步平台切换」与「dispose 置 `_disposed`」
  /// 交错触发 just_audio 内部状态机崩溃。`_clipPlayer` 同理。
  Future<void> stopPlayback() async {
    _imagePauseTimer?.cancel();
    _imagePauseTimer = null;
    _resumeMainAfterClip = false;
    final AudioPlayer? clip = _clipPlayer;
    await Future.wait<void>(<Future<void>>[
      _player.stop(),
      if (clip != null) clip.stop(),
    ]);
    _maybeSavePosition(force: true);
  }

  /// 测试钩子：主播放器是否处于播放态（just_audio 公开状态）。
  @visibleForTesting
  bool get debugMainPlayerPlaying => _player.playing;

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
    // 同步 dispose 无法 await stop（会与 just_audio 异步平台切换竞争），止声职责
    // 交给停止路径（[AudiobookSession.stop] → [stopPlayback]）在 dispose 前完成；
    // 这里只做 just_audio 自身的资源释放。
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

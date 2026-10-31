import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/media/audiobook/audiobook_jump_threshold.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio/just_audio.dart';

/// 有声书播放控制器。
///
/// 职责：
/// - 持有 [AudioPlayer]，管理单文件或多文件播放（[ConcatenatingAudioSource]）；
/// - 每 200 ms 轮询 positionStream，在当前章节 cue 列表中二分定位当前句；
/// - 暴露 [currentCue]、[isPlaying]、[position] 供 UI 订阅；
/// - 提供 play/pause/seek/skipToCue/setSpeed API。
/// 一次 play 激活何时算「结束」：`play()` 的 Future 完成，**或**播放态翻回 false。
///
/// [AudiobookPlayerController] 的激活串行尾只该串行化**激活**，不能押在 `play()` 的
/// Future 上——那个 Future 在 just_audio 里有一条永不完成的路径：音频会话激活被拒
/// （来电 / 音频焦点被别的 App 占着）时 `play()` 只把 playing 回滚成 false，
/// `playCompleter` 从未交给平台层，`pause()` / `stop()` 都解不开它。旧写法于是把
/// 串行尾永久卡住，此后每一次播放请求（播放键 / 通知栏 / 耳机）都排在它后面永不执行
/// ——「后台挂久了音频断了，且再也点不起来」（BUG-2961）。播放态翻回 false（被拒、
/// 暂停、播完、停止）正是这次激活的真实终点；Android / Darwin 后端「play 回调挂到
/// pause 才回」的语义也由它覆盖。[playingStream] 关闭（播放器已释放）同样算结束，
/// 不向等待 `play()` 的调用方抛 `StateError`。
///
/// 调用约定：[played] 必须是**刚刚**调用 `play()` 返回的 Future——just_audio 在
/// `play()` 的第一个 await 之前就同步把 playing 置 true，[playingStream] 的当前值
/// 因此已是这次激活的 true，不会被调用前残留的 false 立即放行。
///
/// 代价：「防交错」比押 play Future 弱一档——暂停落在上一次 `play()` 的
/// `setActive` await 窗口内时，下一次 play 可能与它各发一次平台 play 请求。原生后端
/// 忽略重复 play（just_audio 自己的注释也这么约定），多出的那个 completer 由本函数的
/// 播放态分支兜住，不会再卡死串行尾。
Future<void> playActivationSettled(
  Future<void> played,
  Stream<bool> playingStream,
) {
  return Future.any<void>(<Future<void>>[
    played,
    playingStream
        .firstWhere((bool playing) => !playing, orElse: () => false)
        .then((_) {}),
  ]);
}

/// BUG-3777 D：App 生命周期下阅读器是否对用户可见（喂给
/// [AudiobookPlayerController.setReaderVisible]）。`inactive` 仍算可见：桌面失焦、
/// iOS 下拉控制中心时画面还在；`hidden` / `paused` / `detached` 才是看不见、且即将
/// 或已经被系统挂起的状态。
bool readerVisibleForLifecycleState(AppLifecycleState state) =>
    state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

class AudiobookPlayerController extends ChangeNotifier {
  /// [positionPollPeriod]：位置轮询周期，生产恒为默认 125 ms。只给测试换成远大于
  /// 用例耗时的值：真时间下这只墙钟计时器会在 seek 返回后的任意时刻插进一次
  /// 「seek 之后的真位置」，断言「尚未到位」的用例就与机器快慢赛跑。
  AudiobookPlayerController({
    @visibleForTesting
    Duration positionPollPeriod = const Duration(milliseconds: 125),
  }) : _positionPollPeriod = positionPollPeriod;

  final Duration _positionPollPeriod;

  // ── 内部状态 ──────────────────────────────────────────────────────────────

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;

  /// BUG-3777 F：只为观测播放器平台错误（解码失败 / 输出设备丢失 / 后台被系统掐断）。
  /// 只记日志，不自动重试——重试会掩盖根因。
  StreamSubscription<PlaybackEvent>? _playbackErrorSub;
  StreamSubscription<void>? _noisySub;

  /// 主播放器的 play 激活串行尾：只负责**串行化并发 `play()`**，让两次激活不交错。
  ///
  /// **停止路径绝不允许 `await` 本字段**（守卫测试
  /// `audiobook_stop_darwin_play_semantics_test.dart`）。它挂的是
  /// `AudioPlayer.play()` 返回的 Future，而该 Future 的完成时机**因后端而异**：
  ///
  /// * media_kit（Windows / Linux）：平台接受 play 请求即完成。
  /// * just_audio 原生 Darwin（macOS / iOS 的 AVQueuePlayer）与 Android
  ///   （ExoPlayer）：把 play 的平台回调**挂起到 pause / complete / stop 才触发**
  ///   （见 `just_audio/darwin/Classes/AudioPlayer.m` 的 `_playResult`：`play:`
  ///   只把 `FlutterResult` 存起来，由 `pause` / `complete` / `stop` 释放）。
  ///
  /// 于是「播放中退出」时，若 [_stopPlaybackOnce] 先 `await` 本字段，就与**唯一能
  /// 解开它的** `_player.stop()` 形成循环等待：stop 永不返回、音频一路播到整本
  /// 结束；而 `AudiobookSession._stopInternal` 早已同步清空 `_book` / `_controller`
  /// 并 notify，播放条随之消失、controller 沦为孤儿——用户除杀进程外没有任何停止
  /// 入口。[_stopPlaybackOnce] 因此改为「先止声、后落库」，让 stop 成为解锁者。
  Future<void> _playActivationTail = Future<void>.value();

  /// 位置写入串行尾。周期写、后台 flush、最终 stop flush 共用一条队列，确保旧写入
  /// 不会在最终位置之后完成并反向覆盖数据库/缓存。
  Future<void> _positionWriteTail = Future<void>.value();

  bool _stopRequested = false;
  Future<void>? _stopPlaybackFuture;
  bool _teardownDone = false;

  /// 测试注入：模拟 stop 平台层抛错，验证 disposeAndRelease 仍完成资源收束。
  @visibleForTesting
  Future<void> Function()? debugStopMainPlayerForTesting;

  List<File> _audioFiles = [];

  List<File> get audioFiles => _audioFiles;

  /// 远端（流式）音频接缝；本机书为 null。非空时 [audioFiles] 只是撑下标的占位文件，
  /// **读音频内容一律走 [trackInputFor]**，不要碰 `audioFiles[i].path`。
  AudiobookRemotePlayback? _remotePlayback;
  AudiobookRemotePlayback? get remotePlayback => _remotePlayback;
  bool get isRemoteAudio => _remotePlayback != null;

  /// 第 [fileIndex] 个音频文件交给 ffmpeg 等外部进程读取时的输入：本机书是文件路径，
  /// 远端书是地址 + 现取的鉴权头（令牌临近过期会先刷新）。
  Future<AudiobookTrackInput> trackInputFor(int fileIndex) async {
    final AudiobookRemotePlayback? remote = _remotePlayback;
    if (remote != null) return remote.trackInput(fileIndex);
    return AudiobookTrackInput(input: _audioFiles[fileIndex].path);
  }

  AudioPlayer? _clipPlayer;

  /// 与 [_clipPlayer] 同生同灭的结果句柄（[playRange] 交给调用方）：片段播完 / 被停 /
  /// 被下一段顶掉 / 播放器停止或销毁时由 [_finishClipPlayback] 完成（FDN66-xurt）。
  RangePlayback? _clipPlayback;
  StreamSubscription<PlayerState>? _clipStateSub;
  StreamSubscription<Duration>? _clipPositionSub;

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

  /// 当前章节所有 cue，按**播放顺序**（audioFileIndex，再文件内 startMs）排好，
  /// 只在 [setChapterCues] 时重建。
  ///
  /// startMs 是文件内相对值：多文件书里整表的 startMs **不单调**（每个文件一段从 0
  /// 起的块），所以凡是按位置二分的查找都只能在当前文件那一段里做
  /// （[_fileCueSpan]），不能对整表二分。
  List<AudioCue> _chapterCues = [];

  /// 与 [_chapterCues] 同序的播放顺序视图（章尾未匹配 cue 的跨章判据
  /// [unmatchedCueCrossChapterTargetForTesting] 要的是播放邻居）。
  List<AudioCue> _playbackOrderedCues = const <AudioCue>[];

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
    final ({int fileIndex, int positionMs}) at = _effectiveFilePosition;
    final int effectiveMs = (at.positionMs - delayMs.value).clamp(0, 1 << 30);
    final int idx = _allBookIndexAt(
      cues: _allBookCues,
      audioFileIndex: at.fileIndex,
      effectiveMs: effectiveMs,
    );
    return idx >= 0 ? _allBookCues[idx] : _currentCue;
  }

  /// 整书 cue 里「此刻在播」的那条的下标：命中区间的那条；落在句间静音里取最近一条
  /// 已开始的（保持上一句，不闪）；本文件里还没有任何一句开始为 -1。
  static int _allBookIndexAt({
    required List<AudioCue> cues,
    required int audioFileIndex,
    required int effectiveMs,
  }) {
    int best = -1;
    int bestStart = -1;
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      if (cue.audioFileIndex != audioFileIndex) continue;
      final int start = cue.startMs;
      if (start <= effectiveMs && cue.endMs > effectiveMs) return i;
      if (start <= effectiveMs && start > bestStart) {
        best = i;
        bestStart = start;
      }
    }
    return best;
  }

  /// BUG-3777 R1：播放器此刻所在句（整书下标），每个播放 tick 按真实位置更新，
  /// **不受**跨章守卫 [_chapterTransition] 冻结（显式 seek / 首次激活载入窗口这两类
  /// 音频瞬态照样挡在外面）。-1 = 自上次跨章开始 / 换 cue 以来还没有可信的 tick。
  ///
  /// 与 [_currentCue] 分开：后者是「正文跟随句」，跨章期间必须冻结（正文还没换到
  /// 新章，推进它会重复请求跨章）；而歌词层是整书列表，不依赖正文挂载哪一章。后台
  /// 时正文 WebView 被节流、跨章迟迟完不成，歌词若也跟着冻结，回前台就是「歌词停在
  /// 几分钟前、声音早已走远」。
  int _playbackAllBookIdx = -1;

  /// 每 tick 更新 [_playbackAllBookIdx]；返回它是否换了句。
  bool _trackPlaybackCue(int posMs) {
    if (_allBookCues.isEmpty) return false;
    final int idx = _allBookIndexAt(
      cues: _allBookCues,
      audioFileIndex: _player.currentIndex ?? 0,
      effectiveMs: (posMs - delayMs.value).clamp(0, 1 << 30),
    );
    if (idx < 0 || idx == _playbackAllBookIdx) return false;
    _playbackAllBookIdx = idx;
    return true;
  }

  /// 歌词层当前行（整书下标，-1 = 不可解析）。平时与正文跟随句同源（[allBookCueIdx]，
  /// 解析不到再按位置）；跨章过渡期间正文跟随句冻结，改用按 tick 推进的播放所在句
  /// （BUG-3777 R1）。
  int get lyricsCueAllBookIdx {
    final int playing = _playbackAllBookIdx;
    if (_chapterTransition && playing >= 0 && playing < _allBookCues.length) {
      return playing;
    }
    final int idx = allBookCueIdx;
    return idx >= 0 ? idx : allBookCueIdxAtPosition;
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
    final ({int fileIndex, int positionMs}) at = _effectiveFilePosition;
    final List<AudioCue> fileCues = _chapterCuesForAudioFile(at.fileIndex);
    if (fileCues.isEmpty) return _currentCue;
    final int effectiveMs = (at.positionMs - delayMs.value).clamp(0, 1 << 30);
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

  /// [allBookCueIdx] 的「位置驱动」变体：直接按 [_player] 当前位置实时重算的
  /// cue（[cueAtCurrentPositionInBook]）映射到 allBook 索引，**不依赖**
  /// [_currentCue]。
  ///
  /// BUG-872：重开书时 [load] 已把播放器 seek 回保存位置，但 [_currentCue] 由
  /// 125ms 播放 tick（[_updateCurrentCue]）填充，且 load 期常先吐一条 posMs≈0 的
  /// 瞬态把 [_currentCue] 定成首句（[allBookCueIdx]==0）——歌词模式入场直接用它
  /// 就高亮跳回第一句，等首个真实 tick 才跳到正确行。播放器**位置**已恢复到
  /// `savedMs`，故按位置重算才是权威（[cueAtCurrentPositionInBook] 内部在位置
  /// 无命中时仍回退 [_currentCue]）。歌词入场 / 恢复用本 getter，一次性锚定，
  /// 与悬浮字幕 [displayCueForFloatingLyric] 同源回避 tick 依赖。
  int get allBookCueIdxAtPosition {
    final AudioCue? cue = cueAtCurrentPositionInBook();
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

  /// 显式跳句回调（BUG-1080）：[skipToCue] 漏斗成功定位目标后触发，带目标 cue。
  ///
  /// [skipToCue] 是**所有**显式句子跳转的唯一漏斗（skipToPrevCue / skipToNextCue /
  /// skipByCues / skipToCueIndex / playCueAndContinue，以及底栏按钮、媒体通知、
  /// 音量键、快捷键最终都汇聚到这里）。reader 借此把阅读统计的字数水位抬到目标
  /// cue 位置——「音频跳过的段落不算已读」，否则跳句后的 WebView 跟随滚动会被
  /// 进度回调误计成本次读到的新字数（幻象字数）。
  /// 控制器只报事件不做统计判断，与 [onBoundarySkip] 同样保持与 reader 解耦。
  void Function(AudioCue cue)? onExplicitCueJump;

  /// 大跨度音频跳转回调：一次显式 seek（拖进度 / 系统媒体控件拖动 / 点句播放 /
  /// 章节定位，即 [seekGlobalMs] / [seekMs] / [skipToCue] 三个漏斗）要把全书位置
  /// 挪动至少 [audioJumpThresholdSec] 时，在物理 seek **之前**带上出发点的全书
  /// 毫秒触发。reader 借此把出发点压进「跳转回退」历史。快进快退
  /// （[seekRelative]）是步进不是跳转，不报；逐句切换跨度小于阈值，自然不报。
  void Function(int fromGlobalMs)? onBeforeAudioJump;

  /// 音频移动多远才算「跳转」（秒）：逐句、几秒的修正、没听清往回拖一小段都不进回退
  /// 历史。读的是设置「阅读 › 有声书 › 返回原位置的跳转距离」的实时值（会话注入闭包，
  /// 见 AudiobookSession），未注入时取出厂默认 2 分钟（反馈 0AwuVqrNFn：旧值写死
  /// 15 秒，往回拖一分钟也弹返回胶囊）。
  int Function() audioJumpThresholdSec = _defaultAudioJumpThresholdSec;

  static int _defaultAudioJumpThresholdSec() =>
      kAudiobookJumpThresholdSecDefault;

  /// 从全书 [fromGlobalMs] 挪到 [targetGlobalMs] 是否构成一次进回退历史的「跳转」
  /// （阈值 [thresholdSec] 先夹进合理区间）。
  static bool isAudioJump({
    required int fromGlobalMs,
    required int targetGlobalMs,
    required int thresholdSec,
  }) =>
      (targetGlobalMs - fromGlobalMs).abs() >=
      normalizeAudiobookJumpThresholdSec(thresholdSec) * 1000;

  void _reportAudioJump(int targetGlobalMs) {
    final void Function(int)? listener = onBeforeAudioJump;
    if (listener == null) return;
    final int fromMs = globalPosition.inMilliseconds;
    if (!isAudioJump(
      fromGlobalMs: fromMs,
      targetGlobalMs: targetGlobalMs,
      thresholdSec: audioJumpThresholdSec(),
    )) {
      return;
    }
    listener(fromMs);
  }

  /// 当前文件之前所有文件的累计时长：文件内偏移 → 全书毫秒。
  int _globalBaseOfFile(int fileIndex) {
    int base = 0;
    for (int i = 0; i < fileIndex && i < _fileDurationsMs.length; i++) {
      base += _fileDurationsMs[i];
    }
    return base;
  }

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

  /// 用户**显式**跳句（上一句 / 下一句按钮、快捷键、音量键句子导航、媒体通知的上下
  /// 一句、章首章尾的跨章跳句）落定的目标句，等 reader 把视口跟过去一次。
  ///
  /// 反馈 yk2XDOGh-H：暂停中逐句跳，目标句翻到了下一页，视口却不动——[shouldRevealCurrentCue]
  /// 要求正在播放（BUG-2961 / BUG-2781：暂停态被动的进度更新不拽视口，用户自己翻走的
  /// 阅读位置不被拉回）。显式跳句不是被动更新，是用户要去那一句，所以单独放行：
  /// 只放行**这一句**、只放行**一次**（[consumeExplicitNavigationReveal]），被动更新、
  /// 之后的暂停 / 播放切换照旧不动视口。
  ///
  /// 与 [_forceNextReveal] 分开：后者越过「跟随音频」开关（用户刚把开关打开）；这里
  /// 尊重开关——跟随关时显式跳句也不拽视口，歌词覆盖层「跟随关」的自由滚动也不受影响
  /// （歌词层只读 [consumeForceReveal]）。
  AudioCue? _explicitNavigationRevealCue;

  /// reader 的 `_onCueChanged` 读一次：当前句就是刚显式跳到的那句、且正文跟随开着
  /// 时返回 true（reader 据此 reveal：翻页 / 滚动 / VN 翻屏由各 view mode 的 JS 按同一个
  /// reveal 参数各自落实）。无论结果如何都清掉登记，不会在之后的某次通知里迟到生效。
  bool consumeExplicitNavigationReveal() {
    final AudioCue? target = _explicitNavigationRevealCue;
    _explicitNavigationRevealCue = null;
    if (target == null || !_effectiveFollowAudio) return false;
    final AudioCue? current = _currentCue;
    return current != null && _isSameCue(target, current);
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

  /// 显式 seek 的目标句（[skipToCue] 才有；按位置 seek 为 null）。抑制窗期间它是
  /// 「音频要去哪一句」的权威值——[notifySectionRestoreCompleted] 在平台 seek 尚未
  /// 返回时据它判跨章，而不是拿 seek 前的旧位置重算（BUG-3798）。
  AudioCue? _explicitSeekTargetCue;

  /// 当前显式 seek 的平台操作（已下发、平台尚未返回）的编号；null = 没有在途操作。
  /// 期间 `_player.position` / `currentIndex` 仍可能是 seek 前的值（just_audio 只
  /// 乐观更新位置、不更新文件下标；桌面后端连位置都可能晚到），任何「按当前位置
  /// 重算 cue」都会解析出旧句（BUG-3798）。
  ///
  /// 用编号而不是计数：窗口只属于**最新**那次显式 seek。平台的 seek 回执可能永远
  /// 不来——just_audio 0.9.42 Android 端 `AudioPlayer.java` 只在进入 STATE_READY
  /// （`completeSeek`）或下一次 seek（`abortSeek`）时回 seek 结果，`dispose()` 不回，
  /// 落到 STATE_ENDED 也不回。计数会被这样一次挂起的 seek 永久卡在 >0；编号则由
  /// 更新的意图（下一次显式 seek、手动 seek / 翻页、换 cue 列表、换书、销毁）取代。
  int? _explicitSeekPlatformOp;
  int _explicitSeekPlatformOpSeq = 0;

  bool get _explicitSeekPlatformPending => _explicitSeekPlatformOp != null;

  @visibleForTesting
  bool get explicitSeekPlatformPendingForTesting =>
      _explicitSeekPlatformPending;

  /// 调用方已宣布「音频马上由我 [skipToCue] 定位、reader 也由我跳章」（有声书面板
  /// 「章节」tab），在那次 seek 发出前不得按旧位置发自动跨章（BUG-3798）。
  bool _crossChapterHeldForCallerSeek = false;

  /// 跨章守卫持住期间发生过显式跳句（[skipToCue]）：那次跳句的跨章判定被守卫挡下，
  /// 由守卫所属导航的落地回执（[notifySectionRestoreCompleted]）补判一次。旧实现靠
  /// 跳句时无条件清守卫来「立刻判」，代价是提前放掉 reader 在飞导航的守卫（BUG-3798）。
  bool _crossChapterDeferredToReceipt = false;

  /// 落定容差（毫秒）：位置到达 `targetMs - 容差` 即视为 seek 落定，
  /// 取约两个 125ms tick 的量级，吸收 just_audio 加载完成后的首帧抖动。
  static const int _kExplicitSeekToleranceMs = 300;

  /// 首次激活平台时待落定的恢复位置（BUG-3496）。
  ///
  /// [load] 用 `preload: false` 设源，随后的「恢复上次播放位置」seek 只是记在
  /// just_audio 的空闲播放器上：平台真正载入发生在**第一次 play**，由
  /// `_setPlatformActive` 把这个位置当 `initialPosition` 交给平台。Windows / Linux
  /// 的 just_audio_media_kit 载入时先把位置清零、按已挂起的播放请求从 0 起播，等
  /// mpv 报出时长后才 seek 到 initialPosition——这段时间 positionStream 一路吐 0，
  /// 当前句解析成全书第一句（「小学館eBooks」），按过播放、跟随开着，于是请求
  /// 跨章、正文被拽到第 1 章，播放器随后落到真实位置也不再跨回（落点常是未匹配
  /// 句，邻居判定保位）。BUG-3430 的 `_loadReady` 门挡不住它：门等的那次 seek
  /// 根本没到平台。
  ///
  /// 激活前若播放器仍空闲且挂着非零位置，就记下这个落点；落定前 [_updateCurrentCue]
  /// 不推进 cue、不跨章、不落库，对外的 [position] / [globalPosition] 报落点本身。
  ///
  /// 「落定」不能只看位置：media_kit 的 `load()` 在 `open()` 返回、mpv 真正 seek
  /// **之前**就先上报一帧位置恰为 initialPosition 的事件（状态仍 loading），之后 mpv
  /// 的 time-pos 又从 0 报上来。判据（[classifyActivationTickForTesting]）因此是：
  /// 平台已离开 loading、已报出时长（media_kit 正是在时长到达时才下发 seek）、位置
  /// 不低于落点−容差（或已到更后面的文件）。满足的 tick 照常处理，但守卫不在这一刻
  /// 解除：时长到达那一帧事件里的位置可能仍是回显值，mpv 的 seek 生效前还会再报
  /// 一帧旧的 0 附近位置。所以低于落点−容差的回退一直挡到平台**从落点往后真的
  /// 播出 [_kActivationSettleProgressMs]**（或进到后面的文件）为止——这是按播放
  /// 进度判的，不是计时。显式 seek / 真正下发的拖进度是新的用户意图，取代它。
  ({int fileIndex, int positionMs})? _activationRestoreTarget;

  /// 见 [_activationRestoreTarget]：从落点往后真实播出这么多才解除回退挡板。
  static const int _kActivationSettleProgressMs = 1000;

  void _clearActivationRestore() {
    _activationRestoreTarget = null;
  }

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
  // 遇到图片时自动暂停播放，停留指定秒数后恢复。0 = 不暂停。默认值与持久层同源
  // （[AudiobookRepository.defaultImagePauseSec]，没存过值的书吃它）。

  final ValueNotifier<int> imagePauseSec = ValueNotifier<int>(
    AudiobookRepository.defaultImagePauseSec,
  );

  Future<void> Function(int sec)? onImagePausePersist;

  Timer? _imagePauseTimer;

  /// TODO-2389：[awaitImageChapterPause] 的在途 Completer。它必须是控制器字段而
  /// 不是局部变量——否则唯一能完成它的只有 [_imagePauseTimer] 回调，而该定时器在
  /// 全文 7 处被 cancel（[triggerImagePause] / [awaitImageChapterPause] 自身重入 /
  /// [load] / [play] / [pause] / [stopPlayback] / [_teardownForDispose]），每一处
  /// 都会让 `await done.future` 永久挂起 → reader 的
  /// `_pauseThroughImageOnlyChapters` 的 finally 永不执行 →
  /// `setImageChapterPauseActive(false)` 不执行 → 进程级 `_imageChapterPauseActive`
  /// 卡 true → [notifySectionRestoreCompleted] 永久早退 → cue 驱动的跨章推进直到
  /// 下次 [load] 新有声书前彻底失效。
  Completer<void>? _imageChapterPauseCompleter;

  /// TODO-2389：双 epoch。reader 级（换书/停止/销毁）与单次图片章停留级各一个。
  /// 作废一轮停留时**先递增 epoch 再 complete**，被唤醒的旧续体只能收尾返回，
  /// 不得恢复播放或改状态（否则「取消」变成「立刻恢复播放」）。
  int _readerTransitionEpoch = 0;
  int _imageChapterPauseEpoch = 0;

  /// 当前是否处于图片暂停等待中。
  ///
  /// 跨章停留（[awaitImageChapterPause]）在「已 pause、定时器尚未武装」的窗口里
  /// 没有 Timer，只有 Completer，也必须算作等待中。
  bool get isImagePaused =>
      (_imagePauseTimer?.isActive ?? false) ||
      _imageChapterPauseCompleter != null;

  bool _ownsImageChapterPause({
    required int readerTransitionEpoch,
    required int imageChapterPauseEpoch,
  }) {
    return readerTransitionEpoch == _readerTransitionEpoch &&
        imageChapterPauseEpoch == _imageChapterPauseEpoch;
  }

  /// 结束当前 await-based 图片章停留，但绝不由失效 continuation 恢复播放。
  ///
  /// Timer 与 Completer 必须成对处理：只 cancel Timer 会让
  /// [awaitImageChapterPause] 永久挂起；只 complete Completer 又会让旧 await 续体
  /// 继续跑到恢复播放。先递增 epoch，再 complete，使续体只能收尾返回。
  ///
  /// **所有** cancel [_imagePauseTimer] 的位置都必须走本方法（或
  /// [_invalidateReaderTransition]），不得再出现裸 `_imagePauseTimer?.cancel()`；
  /// 守卫见 `test/media/audiobook/image_chapter_pause_cancel_test.dart`。
  void _invalidateImageChapterPause() {
    _imageChapterPauseEpoch++;
    _imagePauseTimer?.cancel();
    _imagePauseTimer = null;
    final Completer<void>? pending = _imageChapterPauseCompleter;
    _imageChapterPauseCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  /// reader 级作废：换书 / 停止播放 / 销毁控制器。控制器是进程级会话对象，
  /// 可被相邻两个 reader State 复用，此处递增 reader epoch 让上一个 owner 的
  /// 在途停留续体彻底失效。
  void _invalidateReaderTransition() {
    _readerTransitionEpoch++;
    _invalidateImageChapterPause();
    _readerMovedDuringImagePause = false;
  }

  /// BUG-890：图片等待（自动暂停）窗口内用户是否手动翻页离开了插图那句。
  /// 图片等待到点自动恢复播放时，若为真则**不**强制把 reader 拽回音频位
  /// （否则把用户手动翻到的位置吃掉）——让跟随只在播放推进到下一句时经
  /// [_manualReaderOverrideCue] 护栏自然接管。由 [noteManualReaderNavigation]
  /// 在 [isImagePaused] 期间置真，定时器回调消费后复位，生命周期各点复位防泄漏。
  bool _readerMovedDuringImagePause = false;

  /// 纯决策：图片等待自动恢复播放时是否应把 reader 强制 snap 回音频位。
  /// 用户在暂停窗口内手动翻页离开（[readerMovedDuringPause] 为真）→ 不 snap。
  @visibleForTesting
  static bool shouldSnapAfterImagePauseResume({
    required bool readerMovedDuringPause,
  }) => !readerMovedDuringPause;

  /// 插图停留秒数上限（BUG-3887：设置项改成可自定义秒数的步进器，原先只有
  /// 0/5/10/15 四档）。
  static const int maxImagePauseSec = 60;

  void setImagePauseSec(int sec) {
    final int clamped = sec.clamp(0, maxImagePauseSec);
    if (imagePauseSec.value == clamped) return;
    imagePauseSec.value = clamped;
    final Future<void> Function(int)? persist = onImagePausePersist;
    if (persist != null) {
      unawaited(persist(clamped));
    }
  }

  /// BUG-3777 D：阅读器此刻是否对用户可见（reader 按 App 生命周期喂进来）。
  ///
  /// 图片停留的语义是「暂停几秒让用户看插图」——看不见时没有插图可看，停留只剩副
  /// 作用：iOS 后台暂停后 App 立刻被挂起，负责恢复播放的 Dart [Timer] 永不触发；
  /// Android 暂停让媒体会话离开 playing、前台服务降级，进程同样会被冻结。两平台都
  /// 表现为「后台听着听着就停了、再也不自己接上」。所以不可见时不发起停留，变不可见
  /// 那一刻在途的停留立即结束并恢复播放。
  bool _readerVisible = true;

  /// 测试 / 诊断用。
  bool get readerVisible => _readerVisible;

  void setReaderVisible(bool visible) {
    if (_readerVisible == visible) return;
    _readerVisible = visible;
    if (visible || !isImagePaused) return;
    // 在途停留（同 DOM 插图 / 整章插图两种）成对作废：整章停留的 await 续体只收尾
    // 返回（reader 的跨章序列照常走完 finally），恢复播放由这里统一发起。
    _invalidateImageChapterPause();
    _readerMovedDuringImagePause = false;
    if (!_player.playing) unawaited(_activateMainPlayer());
    notifyListeners();
  }

  /// 由 reader 页面在检测到图片后调用。暂停播放并在 [imagePauseSec] 秒后恢复。
  void triggerImagePause() {
    final int sec = imagePauseSec.value;
    if (sec <= 0 || !_player.playing) return;
    if (!_readerVisible) return;
    // TODO-2389：成对作废（cancel Timer + complete 在途 Completer）。
    _invalidateImageChapterPause();
    // BUG-890：新一轮图片等待开始，复位“窗口内是否手动翻页”标志。
    _readerMovedDuringImagePause = false;
    unawaited(_player.pause());
    _imagePauseTimer = Timer(Duration(seconds: sec), () {
      _imagePauseTimer = null;
      // BUG-890：消费并复位标志（无论下面是否恢复都清，防泄漏到下一轮）。
      final bool readerMoved = _readerMovedDuringImagePause;
      _readerMovedDuringImagePause = false;
      if (!_player.playing) {
        unawaited(_activateMainPlayer());
        // 暂停时视口停在插图上；恢复后把视口拉回当前 cue（插图后那句），
        // 让 reader 的 _onCueChanged 以 forceReveal 续上 audio-follow（snapReaderToAudio
        // 内部会 notifyListeners）。
        // BUG-890：但若用户在这几秒暂停窗口内已手动翻页离开插图那句，则不强制
        // snap——否则把用户手动翻到的位置吃掉。既有 _manualReaderOverrideCue 护栏
        // 会让恢复后“同一句”期间保位不跳，跟随只在播放推进到下一句时自然接管。
        if (shouldSnapAfterImagePauseResume(
          readerMovedDuringPause: readerMoved,
        )) {
          snapReaderToAudio();
        }
      }
    });
    notifyListeners();
  }

  /// TODO-1037：跨章推进经过「独立成章的纯图片页」时的停留。
  ///
  /// 与 [triggerImagePause] 的区别：后者是 reader 在**已渲染章同一 DOM 内**两条
  /// 相邻 cue 锚点间跨过 `<img>` 时调用（`window.__fushiImageBetween`），用一次性
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
  ///
  /// TODO-2389（挂起根因）：本方法必须在**任何**取消点都能返回，否则 reader 的
  /// `_pauseThroughImageOnlyChapters` 的 finally 永不执行，跨章推进永久失效。
  /// 在途状态记在 [_imageChapterPauseCompleter] + 双 epoch 上，取消点统一走
  /// [_invalidateImageChapterPause] / [_invalidateReaderTransition]。
  ///
  /// TODO-2369（不得阻塞到播放停止）：末尾恢复播放用 `unawaited`，见那里的注释。
  Future<void> awaitImageChapterPause() async {
    final int sec = imagePauseSec.value;
    if (sec <= 0) return;
    // BUG-3777 D：后台看不见插图，不停留（见 [setReaderVisible]）。
    if (!_readerVisible) return;
    // 自身重入：上一轮停留成对作废，本轮拿新 epoch。
    _invalidateImageChapterPause();
    final int readerTransitionEpoch = _readerTransitionEpoch;
    final int imageChapterPauseEpoch = _imageChapterPauseEpoch;
    final Completer<void> done = Completer<void>();
    _imageChapterPauseCompleter = done;

    if (_player.playing) {
      // `_player.pause()` 要等平台确认；本轮若在这段窗口里被作废（用户按暂停 /
      // 退出阅读器 / 换书），done 已被完成，这里不再干等平台。
      await Future.any<void>(<Future<void>>[_player.pause(), done.future]);
    }
    if (!_ownsImageChapterPause(
      readerTransitionEpoch: readerTransitionEpoch,
      imageChapterPauseEpoch: imageChapterPauseEpoch,
    )) {
      return;
    }
    notifyListeners();
    _imagePauseTimer = Timer(Duration(seconds: sec), () {
      if (!_ownsImageChapterPause(
        readerTransitionEpoch: readerTransitionEpoch,
        imageChapterPauseEpoch: imageChapterPauseEpoch,
      )) {
        return;
      }
      _imagePauseTimer = null;
      if (identical(_imageChapterPauseCompleter, done)) {
        _imageChapterPauseCompleter = null;
      }
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    if (!_ownsImageChapterPause(
      readerTransitionEpoch: readerTransitionEpoch,
      imageChapterPauseEpoch: imageChapterPauseEpoch,
    )) {
      return;
    }
    // 停留结束恢复播放，让 cue 推进继续把文字带到下一章。reader 侧在跨章序列收尾
    // 时统一 notify / reanchor，这里只负责恢复播放时钟。
    if (!_player.playing) {
      // TODO-2369：不能 await。本方法的契约是「这一张整章插图停留结束」，不是
      // 「播放已重新建立」；把二者绑在一起就把 reader 的跨章 finally 押在了播放
      // 激活上。just_audio 的 `play()` Future 在若干寻常路径上**永远不会完成**：
      // 音频会话激活被拒（来电/音频焦点被抢）时走 else 分支，playCompleter 从不
      // complete 而末尾仍 `await playCompleter.future`；`_sendPlayRequest` 也会在
      // `playing` 已翻回 false 时 defensive-return 丢掉 completer。一旦挂住，
      // `setImageChapterPauseActive(false)` 永不执行，跨章推进永久失效。
      // 仍然走 [_activateMainPlayer]（不得退回裸 `_player.play()`），保留
      // `_stopRequested` 门与 `_playActivationTail` 串行化（BUG-1240）。
      unawaited(_activateMainPlayer());
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
    _playbackAllBookIdx = -1;
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

  /// 当前位置：第几个音频文件、文件内毫秒（含激活落点的瞬态修正）。远端书的进度
  /// 同步用它换算全书真实秒数。
  ({int fileIndex, int positionMs}) get currentFilePosition =>
      _effectiveFilePosition;

  /// 当前全局播放位置。
  Duration get position =>
      Duration(milliseconds: _effectiveFilePosition.positionMs);

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
    final ({int fileIndex, int positionMs}) at = _effectiveFilePosition;
    int base = 0;
    for (int i = 0; i < at.fileIndex && i < _fileDurationsMs.length; i++) {
      base += _fileDurationsMs[i];
    }
    return Duration(milliseconds: base + at.positionMs);
  }

  /// 当前速度。
  double get speed => _player.speed;

  /// 各音频文件时长（毫秒，按 [audioFiles] 顺序）；未就绪时为空。只读快照。
  List<int> get fileDurationsMs => List<int>.unmodifiable(_fileDurationsMs);

  /// 某句 cue 在全书时间轴上的起点（毫秒）：其所在文件之前所有文件时长之和 +
  /// 文件内 [AudioCue.startMs]。有声书面板的章节时间戳用它，与 [globalPosition]
  /// 同一套累加口径。
  int globalMsOfCue(AudioCue cue) {
    int base = 0;
    for (
      int i = 0;
      i < cue.audioFileIndex && i < _fileDurationsMs.length;
      i++
    ) {
      base += _fileDurationsMs[i];
    }
    return base + cue.startMs;
  }

  /// 全书时间轴上的 seek：把 [globalMs] 拆成（文件下标, 文件内偏移）。同文件走
  /// [seekMs]；跨文件走与 [skipToCue] 同一条显式 seek 路径（`_player.seek(index:)`
  /// + 抑制窗，位置落定后由 `_updateCurrentCue` 清旗）。文件时长未知（单文件 /
  /// 未就绪）时退回 [seekMs]。有声书面板的整书进度条用它。
  Future<void> seekGlobalMs(int globalMs) async {
    await _loadReady.future;
    _reportAudioJump(globalMs);
    if (_fileDurationsMs.isEmpty) {
      await _seekWithinFile(globalMs);
      return;
    }
    final ({int fileIndex, int offsetMs}) target = splitGlobalMs(
      globalMs,
      _fileDurationsMs,
    );
    final int currentIndex = _player.currentIndex ?? 0;
    if (target.fileIndex == currentIndex) {
      await _seekWithinFile(target.offsetMs);
      return;
    }
    _clearExplicitSeekSuppression();
    _beginExplicitSeek(target.fileIndex, target.offsetMs);
    await _seekPlatformForExplicitSeek(target.fileIndex, target.offsetMs);
    notifyListeners();
  }

  /// 把全书毫秒拆成（文件下标, 文件内偏移）：越界夹到末文件末尾。纯函数，供
  /// [seekGlobalMs] 与测试共用。
  static ({int fileIndex, int offsetMs}) splitGlobalMs(
    int globalMs,
    List<int> fileDurationsMs,
  ) {
    int remaining = globalMs < 0 ? 0 : globalMs;
    int fileIndex = 0;
    for (; fileIndex < fileDurationsMs.length - 1; fileIndex++) {
      final int d = fileDurationsMs[fileIndex];
      if (remaining < d) break;
      remaining -= d;
    }
    final int last = fileDurationsMs.isEmpty ? 0 : fileDurationsMs[fileIndex];
    if (remaining > last) remaining = last;
    return (fileIndex: fileIndex, offsetMs: remaining);
  }

  // ── 章 → 首句 cue 缓存（面板章节时间戳 / 章节点击定位） ─────────────────
  final Map<int, AudioCue?> _sectionFirstCueCache = <int, AudioCue?>{};

  /// 某章（EPUB section 下标）在**全书** cue 里的首句；该章没有 cue → null。按章
  /// 缓存，[setAllBookCues] / [load] 时失效。与 [sentenceAudioCuesForSection]
  /// 不同——那个只看当前章 cue 列表。
  AudioCue? sectionFirstCue(int sectionIndex) {
    return _sectionFirstCueCache.putIfAbsent(sectionIndex, () {
      AudioCue? best;
      int bestMs = 0;
      for (final AudioCue cue in _allBookCues) {
        final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
          cue.textFragmentId,
        );
        if (frag == null || frag.sectionIndex != sectionIndex) continue;
        final int ms = globalMsOfCue(cue);
        if (best == null || ms < bestMs) {
          best = cue;
          bestMs = ms;
        }
      }
      return best;
    });
  }

  /// 某章内、章内偏移 ≥ [fromOffset] 的第一句（按全书时间最早）。[fromOffset] ≤ 0
  /// 即 [sectionFirstCue]。偏移默认取 cue 自身的 normCharStart；阅读器给出
  /// [offsetOf]（音频坐标 → 学习单位，与目录锚点同尺）时以它为准，映射不出的 cue
  /// 退回 normCharStart。同一 spine 内按锚点分节的目录项靠它定位（HBK040）；不缓存，
  /// 调用方自己记忆。
  AudioCue? sectionCueFrom(
    int sectionIndex,
    int fromOffset, {
    int? Function(SubtitleRematchFragment fragment)? offsetOf,
  }) {
    if (fromOffset <= 0) return sectionFirstCue(sectionIndex);
    AudioCue? best;
    int bestMs = 0;
    for (final AudioCue cue in _allBookCues) {
      final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
        cue.textFragmentId,
      );
      if (frag == null || frag.sectionIndex != sectionIndex) continue;
      final int offset = offsetOf?.call(frag) ?? frag.normCharStart;
      if (offset < fromOffset) continue;
      final int ms = globalMsOfCue(cue);
      if (best == null || ms < bestMs) {
        best = cue;
        bestMs = ms;
      }
    }
    return best;
  }

  /// 某章首句在全书时间轴上的起点（毫秒）；该章没有 cue → null。
  int? sectionStartGlobalMs(int sectionIndex) {
    final AudioCue? first = sectionFirstCue(sectionIndex);
    return first == null ? null : globalMsOfCue(first);
  }

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
  ///
  /// [audioSources] 非空时用它代替按 [audioFiles] 建的文件源（TTS 朗读：每句一个
  /// 按需合成的流式源），两者必须一一对应——[audioFiles] 仍是制卡切句子音频时读的
  /// 本地路径。
  ///
  /// [remotePlayback] 非空 = 远端（流式）书：[audioFiles] 是占位文件，[audioSources]
  /// 由它提供，句子回放与制卡取音频走它（见 [trackInputFor]）。
  Future<void> load({
    required Audiobook audiobook,
    required List<File> audioFiles,
    List<AudioSource>? audioSources,
    AudiobookRemotePlayback? remotePlayback,
    bool initialFollowAudio = true,
    int initialDelayMs = 0,
    double initialSpeed = 1.0,
    int initialPositionMs = 0,
    int initialImagePauseSec = AudiobookRepository.defaultImagePauseSec,
    double initialVolume = 1.0,
  }) async {
    // 新一轮加载：旧 Completer 若未完成则补完（防上次 load 异常中断），
    // 再建新的未完成 Completer 阻塞后续 seek 直到本次 load 结束。
    if (!_loadReady.isCompleted) _loadReady.complete();
    // 本轮载入只认自己的 Completer：并发的下一轮 load 会换掉字段，旧轮的收尾不得
    // 提前放开新一轮的门（也不能对新 Completer 二次 complete 抛 StateError）。
    final Completer<void> ready = Completer<void>();
    _loadReady = ready;
    // 门必须在 load 的每条退出路径上打开：seek 与 play（BUG-3430 起 play 也等这道门，
    // 且串在 _playActivationTail 上）都在等它。载入中途抛错（stop / 音频会话配置 /
    // setAudioSource）若漏开门，此后每一次播放都永远挂起。
    try {
      _audiobook = audiobook;
      _audioFiles = audioFiles;
      _remotePlayback = remotePlayback;
      _rebuildFileDurations();
      // Follow audio / delay / speed 状态由调用方从持久层读出传入；不触发
      // persist 回调 —— 载入不是用户操作，又把同值写回 Hive 就是循环。
      followAudio.value = initialFollowAudio;
      delayMs.value = initialDelayMs;
      imagePauseSec.value = initialImagePauseSec;
      // TODO-2389：换书是 reader 级作废——成对处理 Timer/Completer 并让上一本书的
      // 在途停留续体彻底失效（顺带复位 _readerMovedDuringImagePause）。
      _invalidateReaderTransition();
      _hasPlayedOnce = false;
      _forceNextReveal = false;
      _chapterTransition = false;
      _crossChapterHeldForCallerSeek = false;
      _crossChapterDeferredToReceipt = false;
      _explicitSeekPlatformOp = null;
      _clearActivationRestore();
      _imageChapterPauseActive = false;

      await _player.stop();
      _positionSub?.cancel();
      _playingSub?.cancel();
      _playbackErrorSub?.cancel();

      await _configureAudioSession();

      if (audioSources != null) {
        assert(audioSources.length == audioFiles.length);
        try {
          await _player
              .setAudioSource(
                ConcatenatingAudioSource(children: audioSources),
                preload: false,
              )
              .timeout(const Duration(seconds: 60));
        } catch (e, stack) {
          debugPrint('AudiobookController.setSource(stream): $e\n$stack');
          rethrow;
        }
      } else if (audioFiles.length == 1) {
        try {
          await _player
              .setAudioSource(
                AudioSource.file(audioFiles.first.path),
                preload: false,
              )
              .timeout(const Duration(seconds: 60));
        } catch (e, stack) {
          debugPrint('AudiobookController.setSource: $e\n$stack');
          debugPrint('[fushi-audiobook] setAudioSource failed: $e');
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
          debugPrint('[fushi-audiobook] setAudioSource (multi) failed: $e');
          rethrow;
        }
      }

      // 恢复上次播放位置（页面重建场景下避免音频回到 0）。
      // BUG-2330：持久化的是**全书**毫秒（[globalPosition] 口径）。多文件有声书要按
      // 各文件时长拆成（文件下标, 文件内偏移）再 seek——调用方须在 load 前
      // [setAllBookCues] 灌好 cue 才有 [_fileDurationsMs]；没有（单文件 / 无对齐）时
      // 全书毫秒 = 文件内毫秒，退化为裸 seek。旧数据里多文件书存的是「不知哪个文件
      // 的文件内毫秒」，按全书毫秒解释落点 ≤ 旧行为（旧行为恒落文件 0），不会更糟。
      final int savedMs = initialPositionMs;
      if (savedMs > 0) {
        try {
          if (_fileDurationsMs.isEmpty) {
            await _player.seek(Duration(milliseconds: savedMs));
          } else {
            final ({int fileIndex, int offsetMs}) target = splitGlobalMs(
              savedMs,
              _fileDurationsMs,
            );
            await _player.seek(
              Duration(milliseconds: target.offsetMs),
              index: target.fileIndex,
            );
          }
        } catch (e, stack) {
          debugPrint('AudiobookController.seekSaved: $e\n$stack');
          debugPrint('[fushi-audiobook] seek to saved $savedMs ms failed: $e');
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
            '[fushi-audiobook] initial setSpeed $initialSpeed failed: $e',
          );
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
            '[fushi-audiobook] initial setVolume $initialVolume failed: $e',
          );
        }
      }

      // 并发的下一轮 load 开头已替本轮补完过门，这里不能二次 complete。
      if (!ready.isCompleted) ready.complete();
      _startPositionTracking();
      notifyListeners();
    } finally {
      if (!ready.isCompleted) ready.complete();
    }
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

  Future<void> _enqueuePositionWrite(String uid, int posMs) {
    final Future<void> Function(String bookKey, int positionMs)? write =
        onPositionWrite;
    if (write == null) return _positionWriteTail;

    final Future<void> operation = _positionWriteTail.then<void>(
      (_) => write(uid, posMs),
    );
    // 尾链必须自行恢复，某一次写失败不能让所有后续 flush 永久短路；调用方仍拿到
    // 原始 operation，因此显式 flush/stop 可以观察并上抛本次错误。
    _positionWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// 把当前播放位置写入持久化存储。对齐上游：**每整秒变化一次**就写。
  /// 125ms tick 触发 8 次里只有 1 次真的落库，IO 成本和上游等价。
  ///
  /// 调用时机：cue 变化（_updateCurrentCue）、暂停、dispose。
  ///
  /// 三条落库路径（本方法 / [flushPosition] / [stopPlayback]）采的都是 [globalPosition]
  /// 全书毫秒（BUG-2330）：多文件书若存文件内毫秒而不存文件下标，重开只能落回文件 0。
  void _maybeSavePosition({bool force = false}) {
    if (_stopRequested) return;
    final String? uid = _audiobook?.bookKey;
    if (uid == null) return;
    final int posMs = globalPosition.inMilliseconds;
    final int wholeSec = posMs ~/ 1000;
    if (!force && wholeSec == _lastSavedWholeSec) {
      return;
    }
    _lastSavedWholeSec = wholeSec;
    unawaited(
      _enqueuePositionWrite(uid, posMs).catchError((
        Object error,
        StackTrace stack,
      ) {
        debugPrint(
          '[AudiobookPlayerController] periodic position write failed: '
          '$error\n$stack',
        );
      }),
    );
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
    if (uid == null) {
      await _positionWriteTail;
      return;
    }
    final int posMs = globalPosition.inMilliseconds;
    _lastSavedWholeSec = posMs ~/ 1000;
    await _enqueuePositionWrite(uid, posMs);
  }

  /// 切换章节后更新当前章节的 cue 列表。
  ///
  /// 调用后控制器会继续播放（若已在播放），高亮随之跳转到新章节的 cue。
  /// 立即基于当前播放位置解析 currentCue，避免播放栏/高亮在 positionStream
  /// 下一次 tick 之前出现空白（尤其是暂停状态下 positionStream 不发事件）。
  void setChapterCues(List<AudioCue> cues) {
    // 播放顺序 = (文件下标, 文件内起点)。只按 startMs 排会把多文件书各文件的 cue
    // 交错在一起（startMs 是文件内相对值），上一句 / 下一句就跳到别的文件；每句一个
    // 文件的 TTS 朗读里 startMs 全是 0，只按它排顺序完全随机。
    int playbackOrder(AudioCue a, AudioCue b) {
      final int byFile = a.audioFileIndex.compareTo(b.audioFileIndex);
      if (byFile != 0) return byFile;
      return a.startMs.compareTo(b.startMs);
    }

    _chapterCues = List<AudioCue>.from(cues)..sort(playbackOrder);
    _playbackOrderedCues = List<AudioCue>.from(cues)..sort(playbackOrder);
    // 跨章守卫期间只替换 cue 列表，不清 _currentCue 也不重算——
    // 否则 _updateCurrentCue 被 guard 挡住，_currentCue 卡 null，
    // 守卫放下后第一次 tick 会匹配到 cue[0] 导致进度清零。
    // 守卫放下后 notifySectionRestoreCompleted 会负责恢复。
    // 显式 seek 的平台操作在途：位置仍是 seek 前的，不得清抑制窗、不得按位置重算
    // （否则重算出 seek 前那一句并据此跨章——面板跳章时新章文档载入正是在这个窗口里
    // 重灌 cue，BUG-3798）。与守卫期间同样只换列表、保住当前句；seek 返回后由
    // [skipToCue] 写入目标句、由 seek 之后的位置落定。
    if (_chapterTransition || _explicitSeekPlatformPending) {
      // 当前句保留，但它的下标必须指向**新**列表：下标仍指旧列表时，落地回执的
      // 重算会把新列表里同下标的那句判成「cue 未变」而早退，高亮停在旧章那一句
      // （PR #2544 的「换 cue 列表后高亮冻结」场景）。
      final AudioCue? kept = _currentCue;
      _currentCueIndex = kept == null
          ? -1
          : _chapterCues.indexWhere((AudioCue c) => _isSameCue(c, kept));
      return;
    }
    // 换 cue 列表是上下文边界：任何挂起的显式 seek 抑制窗都失效，必须复位，
    // 否则下面的 _updateCurrentCue 重算会被旗挡住、_currentCue 卡 null（W-2）。
    _clearExplicitSeekSuppression();
    // BUG-2781：换 cue 列表不是音频推进。旧列表里的当前句若仍在新列表里，就保住它的
    // 身份（只换下标）；否则按位置重算出的**同一句**会被 [_updateCurrentCue] 判成
    // 「cue 变了」，走变更分支——清掉手动翻页护栏、无视暂停直接发跨章。reader 每章
    // 文档载入都会重灌一次整书 cue（`_injectAudiobookBridge`），于是有声书暂停时
    // 用户翻到别的章，新章一载入就被拽回音频所在章。旧句不在新列表（逐章 cue 列表
    // 换章）时照旧从空开始按位置解析。
    final AudioCue? previousCue = _currentCue;
    _currentCue = null;
    _currentCueIndex = -1;
    if (previousCue != null) {
      final int kept = _chapterCues.indexWhere(
        (AudioCue c) => _isSameCue(c, previousCue),
      );
      if (kept >= 0) {
        _currentCueIndex = kept;
        _currentCue = _chapterCues[kept];
      }
    }
    _updateCurrentCue(_player.position.inMilliseconds);
    notifyListeners();
  }

  void setAllBookCues(List<AudioCue> cues) {
    _sectionFirstCueCache.clear();
    _allBookCues = List<AudioCue>.from(cues);
    final Map<int, int> idMap = <int, int>{};
    for (int i = 0; i < _allBookCues.length; i++) {
      final int? id = _allBookCues[i].id;
      if (id != null) idMap[id] = i;
    }
    _allBookCueIdToIndex = idMap;
    _playbackAllBookIdx = -1;
    _rebuildFileDurations();
  }

  /// cue 的 [AudioCue.endMs] 被就地更新后（TTS 朗读：一句合成完才知道真实时长）
  /// 重算各文件时长与全书时间轴。cue 对象身份不变，阅读器 / 歌词持有的引用照常有效。
  void refreshCueTimings() {
    _rebuildFileDurations();
    notifyListeners();
  }

  /// 从全书 cue 推算每个文件时长 = 该文件内 cue 的最大 endMs。推算口径只有
  /// [audiobookFileDurationsFromCues] 一份：持久化的全书毫秒按它编码，换字幕时
  /// 仓库层按同一口径换算进度（BUG-3197），两处口径漂开就会错位。
  void _rebuildFileDurations() {
    // 流式书没有字幕时推不出文件时长：用服务器给的音轨时长，整本进度条才走得动。
    // 规则只在 [audiobookPositionDurationsMs] 写一次，仓库层换字幕时用同一条换算。
    _fileDurationsMs = _positionDurationsFor(_allBookCues);
    _sectionFirstCueCache.clear();
  }

  List<int> _positionDurationsFor(Iterable<AudioCue> cues) =>
      audiobookPositionDurationsMs(
        cues,
        remoteTrackDurationsMs:
            _remotePlayback?.trackDurationsMs ?? const <int>[],
      );

  // ── 播放控制 API ───────────────────────────────────────────────────────────

  /// 开始播放。
  ///
  /// 等待 just_audio 的平台 play 请求被接受。调用者仍可 fire-and-forget 本方法。
  ///
  /// ⚠️ **[stopPlayback] 绝不能等这个 Future settle**（BUG-1736）：just_audio 的
  /// 原生 Darwin(AVQueuePlayer) 与 Android(ExoPlayer) 后端把 play 的平台回调**挂起
  /// 到 pause / complete / stop 才触发**，于是「stop 等 play、而唯一能解开 play 的
  /// 正是 stop 自己」构成循环等待死锁，音频一路播到整本结束且无法手动关闭。
  /// 停止路径现在是同步采样位置 → stop → 落库，不再 await 任何激活 Future；
  /// BUG-1240 要求的「落库值取自 stop 归零之前」由同步采样满足。
  /// 这段文档此前写的正好相反，是当初把死锁写进来的直接来源，别再改回去。
  Future<void> play() async {
    // 对齐 Sasayaki：首次 play 之后才允许跨章自动翻页。打开书 / 恢复
    // 位置阶段 cue 与 reader 当前章不一致是常态，不应在用户没按播放时
    // 就把 reader 拉到音频章。
    _hasPlayedOnce = true;
    _manualReaderOverrideCue = null;
    // 用户在图片自动暂停窗口内手动播放：取消待恢复计时器并把视口从插图拉回当前
    // cue（否则计时器到点见已在播放而跳过 snap，视口卡在插图上直到下次 cue 推进）。
    // 手动按播放是显式“继续听书”手势，仍 snap；只复位 BUG-890 的窗口内翻页标志。
    // TODO-2389：跨章停留在「已 pause、定时器未武装」的窗口里只有 Completer 没有
    // Timer，用 isImagePaused 覆盖两种在途形态，并成对作废。
    if (isImagePaused) {
      _invalidateImageChapterPause();
      _readerMovedDuringImagePause = false;
      snapReaderToAudio();
    }
    await _activateMainPlayer();
    // BUG-3430：开书落在阅读存档，有声书位置在按播放这一刻接管（对齐 Hoshi 的
    // togglePlayback → displayCue(reveal)）。当前句往往没变（暂停在句 X、重开后按播放
    // 仍是句 X），不主动投影就要等下一句才翻过去；门控同跟读本身（跟随开、正在播）。
    resyncReaderToAudio();
  }

  Future<void> _activateMainPlayer() {
    if (_stopRequested) return Future<void>.value();
    final Future<void> operation = _playActivationTail.then<void>((_) async {
      // BUG-3430：开书慢时（Windows 尤甚）用户按播放可能早于「恢复上次播放位置」的
      // seek 落定；此刻起播，播放器先从 0 报位置，当前句跳到全书第一句再跳回。等载入
      // （含恢复 seek）完成再起播，与 [seekMs] 同一道门；从未载入时它本就已完成。
      await _loadReady.future;
      if (_stopRequested) return;
      _armActivationRestoreGuard();
      await playActivationSettled(_player.play(), _player.playingStream);
    });
    _playActivationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// 见 [_activationRestoreTarget]：只在播放器还没激活过平台（`idle`）、且挂着
  /// 非零起播位置时武装；已载入的平台上 play 不经过载入，没有清零窗口。
  void _armActivationRestoreGuard() {
    if (_player.processingState != ProcessingState.idle ||
        _player.audioSource == null) {
      return;
    }
    final int positionMs = _player.position.inMilliseconds;
    _clearActivationRestore();
    if (positionMs <= 0) return;
    _activationRestoreTarget = (
      fileIndex: _player.currentIndex ?? 0,
      positionMs: positionMs,
    );
  }

  /// 播放位置的唯一读口（文件下标 + 文件内毫秒）。首次激活的落点没落定时，播放器
  /// 报的是平台载入的瞬态（0 / 还在前一个文件），一律以落点本身代替——悬浮字幕、
  /// 歌词入场锚定、跳句起点、进度条、落库都从这里取，不各读各的。
  ({int fileIndex, int positionMs}) get _effectiveFilePosition {
    final int rawIndex = _player.currentIndex ?? 0;
    final int rawMs = _player.position.inMilliseconds;
    final ({int fileIndex, int positionMs})? target = _activationRestoreTarget;
    if (target != null &&
        (rawIndex < target.fileIndex ||
            (rawIndex == target.fileIndex &&
                rawMs < target.positionMs - _kExplicitSeekToleranceMs))) {
      return target;
    }
    return (fileIndex: rawIndex, positionMs: rawMs);
  }

  /// 测试钩子：激活落点是否仍挂起。
  @visibleForTesting
  bool get activationRestorePendingForTesting =>
      _activationRestoreTarget != null;

  Future<void> pause() async {
    // TODO-2389：用户在插图停留期按暂停——成对作废，让 awaitImageChapterPause
    // 的 await 立刻返回（且续体因 epoch 不匹配不会把播放又恢复回去）。
    _invalidateImageChapterPause();
    _readerMovedDuringImagePause = false;
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
    _reportAudioJump(_globalBaseOfFile(_player.currentIndex ?? 0) + positionMs);
    await _seekWithinFile(positionMs);
  }

  /// [seekMs] 的本体，不报 [onBeforeAudioJump]：[seekGlobalMs] 已在入口报过、
  /// [seekRelative] 是步进不是跳转。
  Future<void> _seekWithinFile(int positionMs) async {
    await _loadReady.future;
    // 手动 seek（拖进度条 / 快进快退，seekRelative 也经此）是一个全新的、取代
    // 任何 in-flight 显式 seek（skipToCue / playCueOnce）的用户意图：**无条件**先
    // 复位抑制窗——放在 duration 守卫之前，即便 duration 尚未就绪、物理 seek 因
    // 守卫早退而没下发，用户「离开旧目标」的意图也已成立。守卫只决定物理 seek
    // 能否下发，不该门控意图取消；否则暂停态下 [_updateCurrentCue] 会以旧目标
    // 持续抑制新位置的 tick，cue/高亮卡在旧句直到到达旧目标（BUG-903）。
    _clearExplicitSeekSuppression();
    // 手动改音频位置同样取代上一次显式 seek 的平台在途窗口（那次 seek 的回执可能
    // 永远不来，见 [_explicitSeekPlatformOp]）；本次 seek 不登记窗口（BUG-903 语义）。
    _explicitSeekPlatformOp = null;
    final Duration? dur = _player.duration;
    if (dur == null || dur.inMilliseconds <= 0) return;
    final int clampedMs = positionMs.clamp(0, dur.inMilliseconds);
    // BUG-3496：首次激活的落点没落定时用户拖了进度。just_audio 在 loading 期的
    // seek 直接丢弃（`AudioPlayer.seek` 的 loading 分支），平台照旧去旧落点，落点
    // 不改；平台已载入时 seek 真会下发，落点改成用户要的位置（瞬态照旧挡住）。
    if (_activationRestoreTarget != null &&
        _player.processingState != ProcessingState.loading) {
      _activationRestoreTarget = (
        fileIndex: _player.currentIndex ?? 0,
        positionMs: clampedMs,
      );
    }
    await _player.seek(Duration(milliseconds: clampedMs));
    notifyListeners();
  }

  /// Restore a source locator on the original per-file media timeline.
  /// Unlike cue navigation this never applies the subtitle delay or clamps
  /// against the currently playing file's duration. Cue-derived durations are
  /// estimates, so only the target audio source's decoded duration is trusted.
  Future<void> restoreToFileOffset({
    required int fileIndex,
    required int positionMs,
  }) async {
    await _loadReady.future;
    if (fileIndex < 0 || fileIndex >= _audioFiles.length) {
      throw RangeError.range(fileIndex, 0, _audioFiles.length - 1, 'fileIndex');
    }
    if (positionMs < 0) {
      throw RangeError.value(positionMs, 'positionMs', 'Must be non-negative');
    }
    final List<IndexedAudioSource>? sequence = _player.sequence;
    final Duration? targetDuration =
        sequence != null && fileIndex < sequence.length
        ? sequence[fileIndex].duration
        : null;
    if (targetDuration != null &&
        targetDuration.inMilliseconds > 0 &&
        positionMs > targetDuration.inMilliseconds) {
      throw RangeError.range(
        positionMs,
        0,
        targetDuration.inMilliseconds,
        'positionMs',
      );
    }
    _manualReaderOverrideCue = null;
    _stopAtPositionMs = null;
    _returnToPosition = null;
    // BUG-3798：不清跨章守卫——它属于 reader 侧在飞的导航（见 [skipToCue]）。
    _currentCue = null;
    _currentCueIndex = -1;
    _beginExplicitSeek(fileIndex, positionMs);
    try {
      await _seekPlatformForExplicitSeek(fileIndex, positionMs);
    } catch (_) {
      if (_explicitSeekTargetFileIndex == fileIndex &&
          _explicitSeekTargetMs == positionMs) {
        _clearExplicitSeekSuppression();
      }
      rethrow;
    }
    notifyListeners();
  }

  /// 换掉整列流式音频源（TTS 朗读播放中换声音）：cue / 时间轴 / 会话不变，只把
  /// 每句的音频源换成新声音的源，落到第 [fileIndex] 句句首；[play] 为真时随即续播。
  ///
  /// 必须整列重设而不是只 seek：just_audio 已经向旧源要过、预读过的音频（当前句与
  /// 下一句）留在播放器里，不换源就会先播完旧声音。数量必须与现有文件列表一致。
  Future<void> replaceStreamSources({
    required List<File> audioFiles,
    required List<AudioSource> audioSources,
    required int fileIndex,
    required bool play,
  }) async {
    await _loadReady.future;
    // 换声音途中会话被停掉（[AudiobookSession.stop] 先立 `_stopRequested` 再
    // dispose）：不再碰已停 / 将释放的播放器，也不在 dispose 之后 notifyListeners。
    if (_stopRequested) return;
    if (audioSources.length != audioFiles.length ||
        audioFiles.length != _audioFiles.length) {
      throw ArgumentError.value(
        audioSources.length,
        'audioSources',
        'Must match the loaded files',
      );
    }
    if (fileIndex < 0 || fileIndex >= audioFiles.length) {
      throw RangeError.range(fileIndex, 0, audioFiles.length - 1, 'fileIndex');
    }
    // 只停播放器、不走 [pause]：换源不是用户暂停，不落位置、不作废插图停留。
    await _player.pause();
    _audioFiles = audioFiles;
    _manualReaderOverrideCue = null;
    _stopAtPositionMs = null;
    _returnToPosition = null;
    // BUG-3798：不清跨章守卫——它属于 reader 侧在飞的导航（见 [skipToCue]）。
    _currentCue = null;
    _currentCueIndex = -1;
    _beginExplicitSeek(fileIndex, 0);
    try {
      await _awaitPlatformForExplicitSeek<Duration?>(
        () => _player
            .setAudioSource(
              ConcatenatingAudioSource(children: audioSources),
              initialIndex: fileIndex,
              initialPosition: Duration.zero,
              preload: false,
            )
            .timeout(const Duration(seconds: 60)),
      );
    } catch (_) {
      if (_explicitSeekTargetFileIndex == fileIndex &&
          _explicitSeekTargetMs == 0) {
        _clearExplicitSeekSuppression();
      }
      rethrow;
    }
    if (_stopRequested) return;
    notifyListeners();
    if (play) await this.play();
  }

  /// 快进 / 快退（秒）。
  Future<void> seekRelative(int deltaSeconds) async {
    final int newMs = (position.inMilliseconds + deltaSeconds * 1000).clamp(
      0,
      duration.inMilliseconds,
    );
    await _seekWithinFile(newMs);
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
  void _beginExplicitSeek(
    int targetFileIndex,
    int targetMs, {
    AudioCue? targetCue,
  }) {
    // 新的显式目标取代首次激活的恢复点（它自带同一判据的抑制窗）。
    _clearActivationRestore();
    _explicitSeekInFlight = true;
    _explicitSeekTargetFileIndex = targetFileIndex;
    _explicitSeekTargetMs = targetMs;
    _explicitSeekTargetCue = targetCue;
  }

  /// 下发显式 seek 并登记「平台尚未返回」窗口（见 [_explicitSeekPlatformPending]）。
  Future<void> _seekPlatformForExplicitSeek(int fileIndex, int positionMs) =>
      _awaitPlatformForExplicitSeek<void>(
        () =>
            _player.seek(Duration(milliseconds: positionMs), index: fileIndex),
      );

  /// 显式 seek 的平台操作（seek / 整列换源）一律经这里：窗口期间产生的位置都是
  /// 操作之前的，不能作为「已到位」的证据（见 [_updateCurrentCue]）。
  Future<T> _awaitPlatformForExplicitSeek<T>(Future<T> Function() op) async {
    final int id = ++_explicitSeekPlatformOpSeq;
    _explicitSeekPlatformOp = id;
    try {
      return await op();
    } finally {
      // 抛错同样关窗；已被更新的意图取代的旧操作不得关掉新操作的窗口。
      if (_explicitSeekPlatformOp == id) _explicitSeekPlatformOp = null;
    }
  }

  /// 复位显式 seek 抑制窗（[_beginExplicitSeek] 的逆操作）。上下文边界
  /// （换 cue 列表 / 章节恢复完成）或**手动改位置**（拖进度条 / 快进快退 /
  /// TOC 翻页）时调用：一个全新的用户意图取代了 in-flight 的 explicit seek，
  /// 必须连 stale 目标字段一起清掉，否则暂停态下 [_updateCurrentCue] 会继续
  /// 以过期目标判据抑制新位置的瞬态 tick，cue/高亮卡在旧句直到到达旧目标
  /// （BUG-903）。清零目标维持「flag=false ⟺ 目标为 sentinel」不变式。
  void _clearExplicitSeekSuppression() {
    _explicitSeekInFlight = false;
    _explicitSeekTargetFileIndex = -1;
    _explicitSeekTargetMs = 0;
    _explicitSeekTargetCue = null;
  }

  /// 平台已进入「不会再回这次 seek」的状态（播放终态 completed / 播放出错 / stop）：
  /// 关掉平台在途窗口与显式 seek 抑制窗，之后的位置 tick 照常驱动 cue 跟随。
  ///
  /// 窗口的关闭条件因此全部是结构性信号，不靠超时：just_audio 0.9.42 Android
  /// `AudioPlayer.java` 只在 STATE_READY（`completeSeek`）或下一次 seek
  /// （`abortSeek`）时回 seek 结果；不回的情形只有 STATE_ENDED、`onPlayerError`、
  /// stop / dispose——前两种在这里由 playbackEvent 接住，stop / 换书 / dispose 由
  /// 各自路径关窗，「更新的意图」由新的 seek / 翻页 / 换 cue 列表取代。暂停**不**关：
  /// 暂停态 ExoPlayer 仍会进 READY 并回执，此刻提前关窗会让暂停期的章节落地回执按
  /// seek 前的文件下标重算（BUG-3798）。
  void _abandonUnansweredExplicitSeek() {
    if (!_explicitSeekPlatformPending && !_explicitSeekInFlight) return;
    _explicitSeekPlatformOp = null;
    _clearExplicitSeekSuppression();
  }

  /// BUG-3798：「跳章 + 定音频」组合操作（有声书面板「章节」tab）的第一步。
  ///
  /// 调用方接着先手动跳章、再 [skipToCue]（`callerPositionsReader: true`）。跳章在飞
  /// 期间音频仍在旧章往下播：换句会解除手动导航护栏（[_manualReaderOverrideCue] 只护
  /// 跳章那一刻的那一句），新章落地的回执又按旧位置重算 cue——两条路都会对旧章发
  /// 自动跨章，把刚跳过去的 reader 拽回去。本方法让 [_maybeEmitCrossChapter] 在那次
  /// [skipToCue] 发出前一律不发；[skipToCue] 一进门就解除（无论之后是否真的 seek）。
  void holdCrossChapterUntilCallerSeek() {
    _crossChapterHeldForCallerSeek = true;
  }

  @visibleForTesting
  bool get crossChapterHeldForCallerSeekForTesting =>
      _crossChapterHeldForCallerSeek;

  /// 测试钩子：暴露显式 seek 抑制窗当前是否挂起，用于验证手动 seek 复位它。
  @visibleForTesting
  bool get explicitSeekInFlightForTesting => _explicitSeekInFlight;

  /// [callerPositionsReader]：调用方自己负责把 reader 导航到这一句所在章（有声书面板
  /// 「章节」tab：先 seek 音频、再手动跳章）。此时本次 seek 不得再替它发一次自动跨章，
  /// 目标句登记为手动导航护栏（[_manualReaderOverrideCue]），音频播到下一句才恢复跟随。
  ///
  /// [revealReader]：这是用户的**显式句子导航**（上一句 / 下一句 / 跨章跳句），暂停中
  /// 也要让 reader 视口跟到目标句（必要时翻页 / 跨章），见
  /// [_explicitNavigationRevealCue]。按位置 / 收藏 / 书签 / 跳章定位音频的调用方
  /// 不传：它们要么自己定位 reader，要么本就不该在暂停时拽视口。
  Future<void> skipToCue(
    AudioCue cue, {
    bool callerPositionsReader = false,
    bool revealReader = false,
  }) async {
    _crossChapterHeldForCallerSeek = false;
    _explicitNavigationRevealCue = null;
    _manualReaderOverrideCue = callerPositionsReader ? cue : null;
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
    _reportAudioJump(
      _globalBaseOfFile(mappedPosition.audioFileIndex) + positionMs,
    );
    // BUG-1080：目标已成功定位、跳转必然发生 → 通知 reader 抬统计字数水位到目标
    // cue（跳过的段落不算已读）。放在物理 seek 之前，保证水位在任何后续进度回调
    // （seek 落地触发的 WebView 跟随滚动 → _refreshProgress）之前就位。
    onExplicitCueJump?.call(cue);
    _beginExplicitSeek(
      mappedPosition.audioFileIndex,
      positionMs,
      targetCue: cue,
    );
    await _seekPlatformForExplicitSeek(
      mappedPosition.audioFileIndex,
      positionMs,
    );
    // BUG-3798：这里**不碰**跨章守卫。守卫属于 reader 侧仍在飞的那次导航，只能由它的
    // 落地回执 / 中止信号释放；旧实现在此无条件清掉，跨章导航还没落地就恢复了 cue
    // 推进与跨章判定。守卫持住时下面的 _maybeEmitCrossChapter 早退，落地回执
    // （notifySectionRestoreCompleted）会按本次目标句再判一次跨章。
    // 按身份而不是对象引用找目标句：seek 在途期间 reader 可能重灌了一份新对象的
    // cue 列表（新章文档载入），引用比较找不到就会退回「按当前位置重算」，而 seek
    // 刚返回时文件下标的平台事件可能还没到，重算出 seek 前那一句（BUG-3798）。
    // 反馈 yk2XDOGh-H：显式句子导航在暂停中也让视口跟过去。登记放在 seek 返回之后、
    // 当前句写成目标句的这一刻——seek 在途期间别的通知读不到它，不会对着旧句被消费掉。
    final bool navigationReveal =
        revealReader && !callerPositionsReader && _effectiveFollowAudio;
    final int idx = _chapterCues.indexWhere((AudioCue c) => _isSameCue(c, cue));
    if (idx >= 0) {
      // 权威写入目标 cue（不依赖瞬态 position）；保持 _explicitSeekInFlight=true，
      // 由 _updateCurrentCue 在位置落定后清旗，期间抑制加载期瞬态 tick。
      _currentCueIndex = idx;
      _currentCue = cue;
      if (navigationReveal) _explicitNavigationRevealCue = cue;
      if (_chapterTransition) _crossChapterDeferredToReceipt = true;
      // 显式导航跨章不看「按过播放」：暂停中跳到上一章 / 下一章的句子，正文同样跟过去
      // （与用户点「跟随音频」同一条 bypass 口径）。
      _maybeEmitCrossChapter(cue, bypassPlayGuard: navigationReveal);
      notifyListeners();
    } else {
      // 非 sasayaki 路径维持原有「按当前位置即时定位」语义，不抑制。
      _explicitSeekInFlight = false;
      if (navigationReveal) _explicitNavigationRevealCue = cue;
      _updateCurrentCue(_player.position.inMilliseconds);
      // 目标句与当前句相同时 _updateCurrentCue 不通知；补一次，让登记当场被消费，
      // 不留到之后某次无关通知里迟到地拽视口。
      if (navigationReveal) notifyListeners();
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

    final ({int fileIndex, int positionMs}) returnAt = _effectiveFilePosition;
    _returnToPosition = (
      audioFileIndex: returnAt.fileIndex,
      positionMs: returnAt.positionMs,
    );
    _stopAtPositionMs = cue.endMs;

    final int targetMs = _clampToKnownDuration(startPosition.positionMs);
    _beginExplicitSeek(startPosition.audioFileIndex, targetMs);
    await _seekPlatformForExplicitSeek(startPosition.audioFileIndex, targetMs);
    // BUG-3798：单句试听同样不得放掉 reader 在飞跨章导航的守卫（见 [skipToCue]）。
    // 按身份而不是对象引用找目标句：seek 在途期间 reader 可能重灌了一份新对象的
    // cue 列表（新章文档载入），引用比较找不到就会退回「按当前位置重算」，而 seek
    // 刚返回时文件下标的平台事件可能还没到，重算出 seek 前那一句（BUG-3798）。
    final int idx = _chapterCues.indexWhere((AudioCue c) => _isSameCue(c, cue));
    if (idx >= 0) {
      _currentCueIndex = idx;
      _currentCue = cue;
      notifyListeners();
    }
    unawaited(_activateMainPlayer());
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
      unawaited(_activateMainPlayer());
    }
  }

  /// 跳到上一句（当前章节 cue 列表内）。
  ///
  /// 对齐上游 Sasayaki `prevCue()`：以 `currentCue?.startTime ?? currentPosition`
  /// 为参照 —— 当前 cue 存在就取它的前一条；落在 gap 里就取"最近一条起点早于
  /// 当前位置"的前一条。始终跳立即邻居，不做「播进本句一段时间先回句首」的
  /// 音乐播放器语义：长句播到中后段时那样会连按都回句首、到不了上一句
  /// （BUG-3791）。重播当前句走 [replayCurrentCue]。
  Future<void> skipToPrevCue() async {
    if (_chapterCues.isEmpty) return;
    final int? target = _prevCueIndex(
      cues: _chapterCues,
      currentCueIndex: _currentCueIndex,
      currentCue: _currentCue,
      audioFileIndex: _effectiveFilePosition.fileIndex,
      positionMs: position.inMilliseconds,
    );
    if (target == null) {
      unawaited(onBoundarySkip?.call(-1));
      return;
    }
    await skipToCue(_chapterCues[target], revealReader: true);
  }

  /// 跳到下一句（当前章节 cue 列表内）。
  ///
  /// 已在最后一句则不动作。未定位到 cue 时跳到第一句。
  Future<void> skipToNextCue() async {
    if (_chapterCues.isEmpty) return;
    final int? target = _nextCueIndex(
      cues: _chapterCues,
      currentCueIndex: _currentCueIndex,
      audioFileIndex: _effectiveFilePosition.fileIndex,
      positionMs: position.inMilliseconds,
    );
    if (target == null) {
      unawaited(onBoundarySkip?.call(1));
      return;
    }
    await skipToCue(_chapterCues[target], revealReader: true);
  }

  /// 重播当前句：回到当前句起点接着播（暂停中则开始播放）。
  ///
  /// 「当前句」就是高亮的那句——句间静音里 [_updateCurrentCue] 保留上一句，所以在
  /// 两句之间按下重播的是刚听完的那句，而不是下一句。还没定位到任何句时按播放器
  /// 位置解析，与 [skipByCues] 同一起点（[_cueIndexAtFilePosition]）。
  Future<void> replayCurrentCue() async {
    final int target = _replayCueIndex(
      cues: _chapterCues,
      currentCueIndex: _currentCueIndex,
      audioFileIndex: _effectiveFilePosition.fileIndex,
      positionMs: position.inMilliseconds,
    );
    if (target < 0) return;
    await playCueAndContinue(_chapterCues[target]);
  }

  static int _replayCueIndex({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required int audioFileIndex,
    required int positionMs,
  }) {
    if (cues.isEmpty) return -1;
    if (currentCueIndex >= 0 && currentCueIndex < cues.length) {
      return currentCueIndex;
    }
    return _cueIndexAtFilePosition(
      cues: cues,
      audioFileIndex: audioFileIndex,
      positionMs: positionMs,
    );
  }

  /// 测试钩子：[replayCurrentCue] 的目标句解析。
  @visibleForTesting
  static int replayCueIndexForTesting({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required int positionMs,
    int audioFileIndex = 0,
  }) => _replayCueIndex(
    cues: cues,
    currentCueIndex: currentCueIndex,
    audioFileIndex: audioFileIndex,
    positionMs: positionMs,
  );

  /// 前跳或后跳 [delta] 句（正数前跳，负数后跳）。
  ///
  /// 超出章节边界时 clamp 到首句 / 末句。
  Future<void> skipByCues(int delta) async {
    if (_chapterCues.isEmpty || delta == 0) return;
    int idx = _currentCueIndex;
    if (idx < 0) {
      idx = _cueIndexAtFilePosition(
        cues: _chapterCues,
        audioFileIndex: _effectiveFilePosition.fileIndex,
        positionMs: position.inMilliseconds,
      );
    }
    final int target = (idx + delta).clamp(0, _chapterCues.length - 1);
    if (target == idx) return;
    await skipToCue(_chapterCues[target], revealReader: true);
  }

  /// 跳转到指定 0-based cue 索引。
  Future<void> skipToCueIndex(int index) async {
    if (_chapterCues.isEmpty) return;
    final int clamped = index.clamp(0, _chapterCues.length - 1);
    await skipToCue(_chapterCues[clamped], revealReader: true);
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
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
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
          minPeriod: _positionPollPeriod,
          maxPeriod: _positionPollPeriod,
        )
        .listen((pos) {
          _updateCurrentCue(pos.inMilliseconds);
        });
    // 订阅播放状态流：just_audio 内部状态翻转（包括焦点丢失、播完自动暂停）
    // 都会在这里得到通知，UI 即时刷新播放/暂停图标。
    _playingSub = _player.playingStream.listen((_) {
      notifyListeners();
    });
    ProcessingState lastProcessingState = _player.processingState;
    _playbackErrorSub = _player.playbackEventStream.listen(
      (PlaybackEvent event) {
        // 播放**进入**终态（整本播完）：Android 端这次 seek 的回执永远不来（见
        // [_explicitSeekPlatformOp]），而终态的位置就是平台的真实位置。只认进入
        // 那一刻：已在终态时再发 seek，just_audio 的乐观事件仍带着旧的 completed，
        // 不能拿它关掉新 seek 的窗口。
        final ProcessingState previous = lastProcessingState;
        lastProcessingState = event.processingState;
        if (event.processingState == ProcessingState.completed &&
            previous != ProcessingState.completed) {
          _abandonUnansweredExplicitSeek();
        }
      },
      onError: (Object e, StackTrace stack) {
        ErrorLogService.instance.log(
          'AudiobookController.playbackEvent',
          'playing=${_player.playing} '
              'state=${_player.processingState.name} '
              'index=${_player.currentIndex} '
              'pos=${_player.position.inMilliseconds}ms: $e',
          stack,
        );
        // 播放出错：平台不会再回这次 seek（Android `onPlayerError` 不回 seekResult，
        // 还会自行跳到下一个文件开头），目标已不可能按原样到达。
        _abandonUnansweredExplicitSeek();
      },
    );
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
      // BUG-3798：只认 seek **之后**产生的位置。平台操作返回前的 tick 报的是 seek 前
      // 的旧位置——向后 seek 时旧位置本就高于目标，「位置 ≥ 目标 − 容差」会把它误判成
      // 已到位，清旗后按旧位置重算，把权威目标句覆盖回 seek 前那一句（跨文件时连旧章
      // 一起，触发跨章回弹）。
      if (_explicitSeekPlatformPending) return;
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
    // BUG-3496：首次激活平台的载入窗口（见 [_activationRestoreTarget]）。平台还在从
    // 0 起播、没 seek 到恢复点之前，位置全是瞬态：不推进 cue、不跨章、不落库，
    // 当前句保持载入时按恢复点解析出的那一句。
    final ({int fileIndex, int positionMs})? activation =
        _activationRestoreTarget;
    if (activation != null) {
      switch (classifyActivationTickForTesting(
        platformLoading: _player.processingState == ProcessingState.loading,
        durationMs: _player.duration?.inMilliseconds,
        currentFileIndex: _player.currentIndex ?? 0,
        posMs: posMs,
        targetFileIndex: activation.fileIndex,
        targetMs: activation.positionMs,
      )) {
        case ActivationRestoreTick.transient:
          return;
        case ActivationRestoreTick.unreachable:
          _clearActivationRestore();
        case ActivationRestoreTick.landed:
          if ((_player.currentIndex ?? 0) > activation.fileIndex ||
              posMs >= activation.positionMs + _kActivationSettleProgressMs) {
            _clearActivationRestore();
          }
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
        unawaited(
          _player.seek(
            Duration(milliseconds: returnTo.positionMs),
            index: returnTo.audioFileIndex,
          ),
        );
      }
      notifyListeners();
      return;
    }
    // BUG-3777 R1：播放所在句照常按位置推进（歌词层用它），跨章期间换句也要 notify——
    // 否则后台跨章卡住时歌词层一直停在进章那一句。
    final bool playbackCueChanged = _trackPlaybackCue(posMs);
    // 跨章 await 期间不推进 cue，否则 positionStream 连续触发
    // _maybeEmitCrossChapter 重复调 onCrossChapter。
    if (_chapterTransition) {
      if (playbackCueChanged) notifyListeners();
      return;
    }
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
      // playCueOnce 单句试听）时补一次跨章检查，让文字收敛到
      // 当前 cue 所属章。_maybeEmitCrossChapter 同章早退（已同步时 no-op）、
      // 跳章期间 _chapterTransition 守卫挡住后续 tick，不会 per-tick 抖动；
      // 暂停态不补检查，避免覆盖用户手动翻页。
      if (_player.playing && _stopAtPositionMs == null) {
        _maybeEmitCrossChapter(cue);
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
  ///
  /// 这是**被动跟随**的判据（暂停态不拽视口，BUG-2961 / BUG-2781）；用户在暂停中
  /// 显式跳句的那一次 reveal 另走 [consumeExplicitNavigationReveal]，不改这里——
  /// 它还决定「当前句拥有阅读位置」，暂停中放宽会让用户手翻的位置不落库。
  bool get shouldRevealCurrentCue =>
      _effectiveFollowAudio &&
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
  List<AudioCue> sentenceAudioCuesForSection(int sectionIndex) {
    final List<AudioCue> out = <AudioCue>[];
    for (final AudioCue cue in _chapterCues) {
      final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
        cue.textFragmentId,
      );
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
      return;
    }
    if (_crossChapterHeldForCallerSeek) return;
    if (cue == null) return;
    if (!bypassPlayGuard && _isManualReaderOverrideCue(cue)) return;
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    final int currentSec = getCurrentReaderSection?.call() ?? -1;
    final int cueSec;
    if (frag != null) {
      cueSec = frag.sectionIndex;
    } else {
      // 章尾未匹配 cue：本章最后一句已播完、正在播的这条没匹配上正文（常是下一章
      // 的章名 / 无正文的过场）。旧码在此直接 return，文字要等到下一章第一条**匹配**
      // 的 cue 才跟过去——用户听着下一章的开头、屏幕还停在上一章章尾。按播放邻居
      // 判定：上一条匹配 cue 属于当前章且本章之后再无匹配 cue → 进入下一章。
      cueSec = unmatchedCueCrossChapterTargetForTesting(
        playbackOrderedCues: _playbackOrderedCues,
        cue: cue,
        currentSec: currentSec,
      );
      if (cueSec < 0) return;
    }
    if (!shouldCrossChapterForTesting(
      cueSec: cueSec,
      currentSec: currentSec,
      followAudio: _effectiveFollowAudio,
      hasPlayedOnce: _hasPlayedOnce,
      bypassPlayGuard: bypassPlayGuard,
    )) {
      return;
    }
    _chapterTransition = true;
    // 跨章期间歌词层只认这之后的真实 tick（发起跨章的可能是 skipToCue 的目标句，
    // 此前的 tick 位置已过时）。
    _playbackAllBookIdx = -1;
    // 跨章落地本身就把 reader 定到这一句（按句的学习单元锚导航），显式导航的一次性
    // reveal 登记到此为止，不留给落地之后的某次通知（那时用户可能已自己翻走）。
    _explicitNavigationRevealCue = null;
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

  /// 纯决策：正在播的 [cue] 没匹配上正文（textFragmentId 解不出 section）时，
  /// 文字该不该离开当前章 [currentSec]、去哪一章。返回目标章 index，`-1` = 保位。
  ///
  /// 判据只看**播放顺序**上的邻居（[playbackOrderedCues] 须按 audioFileIndex →
  /// startMs 排好）：
  ///   * 往前找最近一条匹配 cue `p`：不存在、或 `p` 不属于当前章 → 保位（本章还
  ///     没开始读 / 文字已被用户翻到别处 / 已经跨过去了，都不该再动）。
  ///   * 往后找最近一条匹配 cue `n`：`n` 仍属于当前章 → 保位（只是章中间一句没
  ///     匹配上）；`n` 属于更早的章（乱序数据）→ 保位不猜。
  ///   * 否则本章最后一句已播完 → 返回 `currentSec + 1`（下一章）。目标是不是目录
  ///     页 / 越界由 reader 的跨章处理照旧兜底（保位不跳）。
  ///
  /// 选「下一章」而不是「`n` 所在章」：中间若有整章没匹配上（图片章 / 后记），
  /// 音频此刻读的是它，文字跟到它才同步；之后的匹配 cue 到来时照旧再跨。
  /// SRT / SMIL 等全书都解不出 section 的 cue 集合：`p` 恒不存在 → 恒保位，与旧
  /// 行为一致（它们的跨章各走各的路径）。
  @visibleForTesting
  static int unmatchedCueCrossChapterTargetForTesting({
    required List<AudioCue> playbackOrderedCues,
    required AudioCue cue,
    required int currentSec,
  }) {
    if (currentSec < 0) return -1;
    final int idx = playbackOrderedCues.indexOf(cue);
    if (idx < 0) return -1;
    int? sectionOf(AudioCue c) =>
        SubtitleRematchCodec.tryDecode(c.textFragmentId)?.sectionIndex;
    int? prevSec;
    for (int i = idx - 1; i >= 0; i--) {
      prevSec = sectionOf(playbackOrderedCues[i]);
      if (prevSec != null) break;
    }
    if (prevSec == null || prevSec != currentSec) return -1;
    for (int i = idx + 1; i < playbackOrderedCues.length; i++) {
      final int? nextSec = sectionOf(playbackOrderedCues[i]);
      if (nextSec == null) continue;
      if (nextSec <= currentSec) return -1;
      break;
    }
    return currentSec + 1;
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
    // BUG-3798：显式 seek 已下发、平台还没返回时，`_player.position` /
    // `currentIndex` 仍可能是 seek 前的值。此刻按位置重算会解析出 seek 前那一句，
    // 再拿它判跨章 = 把刚落到新章的 reader 拽回旧章（面板「章节」tab 跳章回弹）。
    // 抑制窗保留到 seek 自己落定；跨章只按本次 seek 的目标句判。
    final bool deferredCrossChapter = _crossChapterDeferredToReceipt;
    _crossChapterDeferredToReceipt = false;
    if (_explicitSeekPlatformPending) {
      final AudioCue? target = _explicitSeekTargetCue;
      if (target != null) _maybeEmitCrossChapter(target);
      if (success) notifyListeners();
      return;
    }
    // 平台 seek 已返回：位置可信。章节恢复完成是上下文边界：复位显式 seek 抑制窗，
    // 避免暂停态下旧旗挡住重算（W-2）。
    _clearExplicitSeekSuppression();
    _updateCurrentCue(_player.position.inMilliseconds, forceNotify: success);
    // 守卫期间的跳句被挡下的那次跨章判定在这里补上（暂停态 _updateCurrentCue 不会
    // 对未变的当前句补判）。
    if (deferredCrossChapter) _maybeEmitCrossChapter(_currentCue);
  }

  /// 用户手动翻章时清 `_chapterTransition` 守卫，防止旧跨章逻辑卡死。
  void cancelChapterTransition() {
    _chapterTransition = false;
  }

  /// BUG-2529：reader 的**跨章导航中止**（章节装载抛错 / `_navigateToChapterAndWait`
  /// 等待超时 / content-ready 兜底超时）时解除守卫。
  ///
  /// [_chapterTransition] 是「为这一次在飞的跨章导航」竖起来的，唯一的正常解除路径
  /// 是 reader 在章节内容就绪后回调 [notifySectionRestoreCompleted]。导航中止意味着
  /// 那条回执**永远不会来**：守卫就此永久卡 true，[_updateCurrentCue] 与
  /// [setChapterCues] 此后全部早退，`_currentCue` / `_currentCueIndex` 冻结在旧章旧句，
  /// 于是上一句/下一句（底栏、媒体通知、耳机键、音量键、快捷键全部汇聚到
  /// [skipToCue] 同一漏斗）每次都算出同一个目标、seek 到同一处，高亮跟随也不再推进
  /// ——用户感知是「切出去再回来，上下句按了纹丝不动」，且没有任何自愈，直到重开书。
  ///
  /// 与 [cancelChapterTransition] 的差别只在图片章停留序列：序列自己用
  /// [holdChapterTransition] 持着守卫、并以 [_imageChapterPauseActive] 让中间章的
  /// 回执保持守卫不放（TODO-1037 的重入竞态修复）。序列在途时中止单章导航不得把
  /// 序列的守卫一起放掉，否则剩余图片章会被一步跳过；序列收尾自带 hold + 最终导航
  /// 的正常清守卫契约，那次若也中止，此时 `_imageChapterPauseActive` 已为 false，
  /// 本方法照常解除。
  void abortChapterTransition() {
    if (_imageChapterPauseActive) return;
    _chapterTransition = false;
  }

  /// Called by the reader for TOC/link/search/bookmark/page-turn jumps. It lets
  /// the manually selected reader section stay visible until the audio advances
  /// to a different cue or the user explicitly asks to follow audio again.
  void noteManualReaderNavigation() {
    _chapterTransition = false;
    _crossChapterDeferredToReceipt = false;
    _manualReaderOverrideCue = _currentCue;
    _explicitNavigationRevealCue = null;
    // BUG-903：手动翻页（TOC / 链接 / 搜索 / 书签 / 翻页）同样是取代 in-flight
    // 显式 seek 的新意图。复位抑制窗，否则暂停态下旧目标会继续抑制后续 tick，
    // 使 cue/高亮无法跟随新位置。
    _clearExplicitSeekSuppression();
    // BUG-890：图片等待自动暂停窗口内的手动翻页 → 标记为“用户已离开插图那句”，
    // 图片等待到点恢复时据此不强制 snap 回音频位（见 triggerImagePause）。
    if (isImagePaused) {
      _readerMovedDuringImagePause = true;
    }
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
  /// 歌词覆盖层在场期间的「正文强制跟随」（2026-10-04 覆盖层架构）。
  ///
  /// 歌词模式是盖在阅读器上的一层：阅读器在下面照常翻页 / 高亮，阅读统计（字数、
  /// 时长）也由阅读器这条路承担——字数来自阅读器滚动回传的页区间。用户关掉「跟随
  /// 音频」时正文不再跟着音频走，被覆盖的阅读器就会停在原地，整段听歌词字数为 0。
  /// 覆盖层期间正文看不见，「跟随」开关只管歌词列表自己滚不滚（`__lyricsSetCue` 的
  /// scroll 参数），正文必须跟随；退出歌词即撤销，恢复用户的开关语义。
  /// 不持久化、不改 [followAudio] 的值（图标 / 偏好不变）。
  bool _readerFollowOverride = false;

  bool get readerFollowOverride => _readerFollowOverride;

  /// 正文跟随判据 = 用户开关 || 覆盖层强制。
  bool get _effectiveFollowAudio => followAudio.value || _readerFollowOverride;

  /// 进入 / 退出歌词覆盖层时由阅读器调用。打开时立即把正文对齐到音频（与
  /// OFF→ON 翻跟随开关同一条 [snapReaderToAudio]），否则要等下一句才跟上。
  void setReaderFollowOverride(bool value) {
    if (_readerFollowOverride == value) return;
    _readerFollowOverride = value;
    if (value && !followAudio.value) snapReaderToAudio();
  }

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

  /// 把 reader 视口按「跟随音频」意图重新投影到当前 cue（不改任何播放状态）。
  ///
  /// 视口在跟随音频时只是播放位置的投影；投影会在两种场合丢失：App 在后台时 WebView
  /// 被节流、帧被冻结，跟随滚动没落地或被积压的 post-frame 回调覆盖（回前台）；跨章
  /// 恢复的重锚用的是「进章那一刻」的锚，提交时音频早已走远（恢复重锚落定后）。
  /// 只在正常跟随本就会 reveal 的条件下生效（[shouldRevealCurrentCue]：跟随开、按过
  /// 播放、正在播、非单句试听），并尊重手动翻页护栏——暂停态下用户自己滚走的阅读
  /// 位置不被拽回（BUG-2961）。
  ///
  /// 只做「跨章检查 + notify」，**不**置 [_forceNextReveal]：门控已保证
  /// [shouldRevealCurrentCue] 为真，reader 的 `_onCueChanged` 据此就会 reveal；强制
  /// 旗会越过歌词覆盖层「跟随音频关」的自由滚动（覆盖层下 [shouldRevealCurrentCue]
  /// 走的是恒真的生效跟随，歌词层自己再看原始开关），把用户滚开的歌词拽回居中。
  void resyncReaderToAudio() {
    if (!shouldRevealCurrentCue) return;
    if (_manualReaderOverrideCue != null) return;
    if (_chapterTransition) return;
    final AudioCue? cue = _currentCue;
    if (cue == null) return;
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

  /// [cues] 按 (audioFileIndex, startMs) 排好时，文件 [audioFileIndex] 的 cue 是连续
  /// 的一段 `[start, end)`；该文件没有 cue 时 `start == end` = 它在表里的插入点。
  static ({int start, int end}) _fileCueSpan(
    List<AudioCue> cues,
    int audioFileIndex,
  ) {
    int lowerBound(bool Function(AudioCue cue) before) {
      int lo = 0;
      int hi = cues.length;
      while (lo < hi) {
        final int mid = (lo + hi) >>> 1;
        if (before(cues[mid])) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return lo;
    }

    return (
      start: lowerBound((AudioCue c) => c.audioFileIndex < audioFileIndex),
      end: lowerBound((AudioCue c) => c.audioFileIndex <= audioFileIndex),
    );
  }

  /// 没有当前 cue 时，「播放器停在文件 [audioFileIndex] 的 [positionMs]」对应的全表
  /// 下标：只在该文件那一段里按位置找（[JsonAlignmentParser.findCueIndex]），命中
  /// 返回那一条；没命中（gap / 早于该文件首句 / 该文件没有 cue）返回该文件那一段的
  /// 起点（夹到表内）。单文件书里那一段就是整表，与原先「回到首句」一致。
  static int _cueIndexAtFilePosition({
    required List<AudioCue> cues,
    required int audioFileIndex,
    required int positionMs,
  }) {
    if (cues.isEmpty) return -1;
    final ({int start, int end}) span = _fileCueSpan(cues, audioFileIndex);
    final int local = JsonAlignmentParser.findCueIndex(
      cues: cues.sublist(span.start, span.end),
      positionMs: positionMs,
    );
    if (local >= 0) return span.start + local;
    return span.start < cues.length ? span.start : cues.length - 1;
  }

  static int? _nextCueIndex({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required int audioFileIndex,
    required int positionMs,
  }) {
    if (cues.isEmpty) return null;
    final int idx = currentCueIndex;
    if (idx < 0 || idx >= cues.length) {
      final ({int start, int end}) span = _fileCueSpan(cues, audioFileIndex);
      final int local = JsonAlignmentParser.findCueIndex(
        cues: cues.sublist(span.start, span.end),
        positionMs: positionMs,
      );
      // 没定位到 cue：跳到当前文件的首句（单文件书 = 全章首句）；当前文件之后
      // 已没有 cue 时是章边界。
      if (local < 0) return span.start < cues.length ? span.start : null;
      final int at = span.start + local;
      return at + 1 >= cues.length ? null : at + 1;
    }
    if (idx + 1 >= cues.length) return null;
    return idx + 1;
  }

  /// [skipToPrevCue] 的纯决策（与 [_nextCueIndex] 对称）。对齐上游 Sasayaki
  /// `prevCue()`：
  ///  - 已定位到当前 cue：取它的前一条；已在首句返回 null（= 触发跨章边界）。
  ///  - 未定位到 cue（gap / 开头）：在**当前文件**那一段里按位置二分，取"最近一条
  ///    起点早于当前位置"的 cue；早于该文件全部 cue 时取上一个文件的末句，已是全章
  ///    首个文件时回到首句（索引 0）。startMs 只在同一文件内单调，不能对整表二分。
  ///
  /// 注意：这里的 gap 回退**刻意**不等同于 [JsonAlignmentParser.findCueIndex]
  /// ——后者在 gap 内返回 -1（无高亮），而"上一句"导航需要落到 gap 之前的那条
  /// cue，二者是不同语义，不能互相替代。
  static int? _prevCueIndex({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required AudioCue? currentCue,
    required int audioFileIndex,
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
    // 在当前文件那一段里二分找第一条 startMs >= positionMs；上一条即为目标。
    final ({int start, int end}) span = _fileCueSpan(cues, audioFileIndex);
    int lo = span.start;
    int hi = span.end;
    while (lo < hi) {
      final int mid = (lo + hi) >>> 1;
      if (cues[mid].startMs < positionMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return 0;
    return (lo - 1).clamp(0, cues.length - 1);
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

  /// 首次激活载入窗口里一个 tick 的分类（BUG-3496）。纯函数，可单测。
  ///
  /// * [ActivationRestoreTick.transient]：平台仍在 loading（media_kit 在 `open()`
  ///   后、mpv 真 seek 前会回显一帧「恰为 initialPosition」的位置，不能信）、还没
  ///   报出时长（media_kit 在时长到达时才下发 seek），或位置低于落点−容差 / 还在
  ///   更前的文件——挡住。
  /// * [ActivationRestoreTick.unreachable]：同一文件、时长已知且落点超出时长，
  ///   平台永远到不了它（音频被换短 / 存档越界），放行并解除，免得当前句冻住。
  /// * [ActivationRestoreTick.landed]：平台已载入、位置到了落点（或已进到后面的
  ///   文件：多文件书恢复点贴近文件末尾时平台很快切到下一文件）。
  @visibleForTesting
  static ActivationRestoreTick classifyActivationTickForTesting({
    required bool platformLoading,
    required int? durationMs,
    required int currentFileIndex,
    required int posMs,
    required int targetFileIndex,
    required int targetMs,
    int toleranceMs = _kExplicitSeekToleranceMs,
  }) {
    if (platformLoading || durationMs == null || durationMs <= 0) {
      return ActivationRestoreTick.transient;
    }
    if (currentFileIndex > targetFileIndex) return ActivationRestoreTick.landed;
    if (currentFileIndex < targetFileIndex) {
      return ActivationRestoreTick.transient;
    }
    if (targetMs > durationMs) return ActivationRestoreTick.unreachable;
    if (posMs >= targetMs - toleranceMs) return ActivationRestoreTick.landed;
    return ActivationRestoreTick.transient;
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
    int audioFileIndex = 0,
  }) {
    return _nextCueIndex(
      cues: cues,
      currentCueIndex: currentCueIndex,
      audioFileIndex: audioFileIndex,
      positionMs: positionMs,
    );
  }

  @visibleForTesting
  static int? prevCueIndexForTesting({
    required List<AudioCue> cues,
    required int currentCueIndex,
    required AudioCue? currentCue,
    required int positionMs,
    int audioFileIndex = 0,
  }) {
    return _prevCueIndex(
      cues: cues,
      currentCueIndex: currentCueIndex,
      currentCue: currentCue,
      audioFileIndex: audioFileIndex,
      positionMs: positionMs,
    );
  }

  /// 测试钩子：[skipByCues] 没有当前 cue 时的起点解析（[_cueIndexAtFilePosition]）。
  @visibleForTesting
  static int cueIndexAtFilePositionForTesting({
    required List<AudioCue> cues,
    required int audioFileIndex,
    required int positionMs,
  }) {
    return _cueIndexAtFilePosition(
      cues: cues,
      audioFileIndex: audioFileIndex,
      positionMs: positionMs,
    );
  }

  @visibleForTesting
  static int allBookCueIndexForTesting({
    required List<AudioCue> allBookCues,
    required AudioCue currentCue,
  }) {
    return _allBookCueIndex(allBookCues: allBookCues, currentCue: currentCue);
  }

  // ── 生命周期 ───────────────────────────────────────────────────────────────

  /// 真正停播（止声）：先把主播放器仍持有的当前位置写穿，再停掉主播放器与
  /// clip 播放器并释放其 native 解码器。供退出/停止会话路径在 [dispose] 之前 `await`。
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
  Future<void> stopPlayback() {
    final Future<void>? existing = _stopPlaybackFuture;
    if (existing != null) return existing;
    // 同步立 fence，挡住 stop 调用后同一 event-loop 内到来的新 play/tick。
    _stopRequested = true;
    return _stopPlaybackFuture = _stopPlaybackOnce();
  }

  Future<void> _stopPlaybackOnce() async {
    // TODO-2389：退出阅读器是 reader 级作废（`_stopRequested` 已同步立起，续体
    // 即便被唤醒也不得恢复播放）。
    _invalidateReaderTransition();
    _resumeMainAfterClip = false;
    final AudioPlayer? clip = _clipPlayer;
    _finishClipPlayback(RangePlaybackEnd.interrupted);

    Object? firstError;
    StackTrace? firstStack;
    void remember(Object error, StackTrace stack) {
      firstError ??= error;
      firstStack ??= stack;
    }

    // BUG-1240 的不变式是「落库的位置必须是 stop 归零**之前**的位置」。位置采样
    // （`_player.position`）是**同步**的，所以在这里取值就已经满足该不变式，不需要
    // ——也绝不能——先 await 任何在途 Future。
    //
    // 尤其不能 `await _playActivationTail`：那会与下面的 `_player.stop()` 形成循环
    // 等待（后端差异与后果见 [_playActivationTail] 的文档）。顺序因此定为
    // 「同步采样 → 发出落库写 → 先止声 → 再 await 落库」：stop 反过来成为解开在途
    // play 的那一方，且音频停得更快（不被一次数据库写入挡在前面）。
    final String? uid = _audiobook?.bookKey;
    final int? sampledPosMs = uid == null
        ? null
        : globalPosition.inMilliseconds;

    // 位置写必须在 `_player.stop()` **之前发出**（这里只建链，不 await），真正的
    // await 放到 stop 之后 —— 两个位置都不能挪：
    //   * 在 stop 之前 **发出**：写的是 stop 归零前采样到的值（BUG-1240），且不让
    //     一次数据库写挡在止声前面。
    //   * 在 stop 之后 **await**：保证本方法返回时落库已完成。
    //   * 但**绝不能把 `_enqueuePositionWrite` 的调用本身挪到 stop 之后**。
    //     `_enqueuePositionWrite` 是往 `_positionWriteTail` 上 `.then()` 接链；在
    //     `_player.stop()` 之后才接链会挂死 —— `now_listening_mini_bar_exit_flash_test`
    //     的三条用例会各自吃满 10 分钟超时（该测试用 `tester.runAsync` 在真实异步区
    //     跑 stop，而尾链此前是在 widget 测试的 FakeAsync 时钟下建立的；stop 之后再
    //     往上接，新链就永远等不到那个不会被推进的时钟）。这条是实测结论，别凭
    //     「反正最后都要 await」把两者合并回一处。
    Future<void>? pendingWrite;
    _stopSampledGlobalMs = sampledPosMs;
    if (uid != null && sampledPosMs != null) {
      _lastSavedWholeSec = sampledPosMs ~/ 1000;
      pendingWrite = _enqueuePositionWrite(uid, sampledPosMs);
    }

    // stop 之后平台不会再回在途的显式 seek（Android 只在 READY / 下一次 seek 回执），
    // 窗口在这里关，不留给 dispose。
    _abandonUnansweredExplicitSeek();
    // 即使持久层失败，也必须尽力停掉两个播放器；错误在资源收束后再抛。
    try {
      final Future<void> Function()? stopForTesting =
          debugStopMainPlayerForTesting;
      await (stopForTesting?.call() ?? _player.stop());
    } catch (error, stack) {
      remember(error, stack);
    }
    if (clip != null) {
      try {
        await clip.stop();
      } catch (error, stack) {
        remember(error, stack);
      }
    }

    try {
      await (pendingWrite ?? _positionWriteTail);
    } catch (error, stack) {
      remember(error, stack);
    }

    final Object? error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack!);
    }
  }

  /// [stopPlayback] 同步采样到的全书毫秒（按采样那一刻手里的 cue 编码）；
  /// 未 stop 过为 null。供 [reencodeStoppedPositionForCues] 换编码用。
  int? _stopSampledGlobalMs;

  /// BUG-3197：会话期间字幕被整组替换（库里的 cue 已是新的、仓库层也已把存着的
  /// 进度换成新编码）时，[stopPlayback] 按控制器手里的**旧 cue** 落的那次位置是
  /// 旧编码。这里在 stop 之后把控制器的 cue 换成 [cues]，并把 stop 采样的位置按
  /// 新 cue 重新编码再落一次——真实时间位置（文件下标 + 文件内偏移）不变。
  ///
  /// 为什么不在 stop **之前**换 cue：那要先 await 一次读库，[stopPlayback] 的同步
  /// 采样 / 止声 fence / 位置写接链就都被推到一个异步缺口之后（见
  /// [_stopPlaybackOnce] 里「绝不能把 `_enqueuePositionWrite` 挪到 stop 之后」那段
  /// 实测结论）。两份 cue 推出的文件时长相同（没换字幕 / 只改文本）时是空操作。
  Future<void> reencodeStoppedPositionForCues(List<AudioCue> cues) async {
    final List<int> previous = _fileDurationsMs;
    final List<int> next = _positionDurationsFor(cues);
    if (listEquals(previous, next)) return;
    setAllBookCues(cues);
    final String? uid = _audiobook?.bookKey;
    final int? sampled = _stopSampledGlobalMs;
    if (uid == null || sampled == null) return;
    final int rebased = rebaseAudiobookGlobalPositionMs(
      sampled,
      previous,
      next,
    );
    _stopSampledGlobalMs = rebased;
    _lastSavedWholeSec = rebased ~/ 1000;
    await _enqueuePositionWrite(uid, rebased);
  }

  /// 会话期间库里的全书 cue 被整组替换（书架 / 互联「只更新字幕」重新导入字幕，
  /// BUG-3251）：改用新 cue，使之后的周期位置写入立即按新 cue 推出的文件时长编码。
  /// 播放器本身的（文件, 偏移）不动；仓库层已在同一事务里把库里的进度换成新编码。
  /// 两份 cue 推出的文件时长相同时什么都不做（返回 false）——那种替换不影响编码，
  /// 也就不去打扰阅读器按章节灌的 cue。
  bool adoptReplacedBookCues(List<AudioCue> cues) {
    if (cues.isEmpty) return false;
    if (listEquals(_fileDurationsMs, _positionDurationsFor(cues))) {
      return false;
    }
    setAllBookCues(cues);
    return true;
  }

  /// 测试钩子：主播放器是否处于播放态（just_audio 公开状态）。
  @visibleForTesting
  bool get debugMainPlayerPlaying => _player.playing;

  @override
  void dispose() {
    _teardownForDispose();
    // 同步 dispose 无法 await stop（会与 just_audio 异步平台切换竞争），止声职责
    // 交给停止路径（[AudiobookSession.stop] → [stopPlayback]）在 dispose 前完成；
    // 这里只做 just_audio 自身的资源释放。fire-and-forget（同步签名无法 await）——
    // 进程退出等不关心文件句柄何时真正放掉的路径用这条。
    _clipPlayer?.dispose();
    _clipPlayer = null;
    _player.dispose();
    super.dispose();
  }

  /// 可 await 的释放（TODO-1212）：先 `await` 掉底层 [AudioPlayer.dispose]（这一步才
  /// 真正释放 native/libmpv 音频文件句柄），再走 [dispose] 同样的同步清理。
  ///
  /// 根因：[dispose] 里 `_player.dispose()` 是 fire-and-forget（`void dispose()`
  /// 同步签名丢弃了 Future），返回给调用方时底层文件句柄仍在异步释放中。数据根迁移
  /// （桌面「数据存储位置」）要在停音频后立即 rename 数据根子树，此时句柄未放 →
  /// Windows 同盘 rename 撞「文件被占用」硬失败。本方法把释放做成可等待，
  /// [AudiobookSession.stop] 改调它，确保 stop 返回时音频文件句柄**真已放掉**。
  ///
  /// 与 [dispose] 二选一调用（都会 `super.dispose()`，不得对同一实例都调）。
  Future<void> disposeAndRelease() async {
    Object? firstError;
    StackTrace? firstStack;
    try {
      await stopPlayback();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    _teardownForDispose();
    // 先 await clip / 主播放器的底层释放——句柄真放掉再返回（迁移 rename 前提）。
    try {
      await _clipPlayer?.dispose();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    _clipPlayer = null;
    try {
      await _player.dispose();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    } finally {
      super.dispose();
    }
    final Object? error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack!);
    }
  }

  /// [dispose] 与 [disposeAndRelease] 共用的同步清理（取消订阅/定时器、dispose
  /// 各 notifier、force-flush 位置）；不含底层播放器释放（两条路径对它处理不同：
  /// 同步 fire-and-forget vs 可 await 释放）。
  void _teardownForDispose() {
    if (_teardownDone) return;
    _teardownDone = true;
    // stopPlayback 已写穿最终 live position；stop 后再 force-save 会把归零值覆盖回去。
    if (!_stopRequested) {
      _maybeSavePosition(force: true);
    }
    // TODO-2389：销毁是 reader 级作废；只 cancel Timer 会让在途
    // awaitImageChapterPause 永久挂起（且它的续体绝不能在 dispose 后 notify）。
    _invalidateReaderTransition();
    _explicitSeekPlatformOp = null;
    _positionSub?.cancel();
    _playingSub?.cancel();
    _playbackErrorSub?.cancel();
    _noisySub?.cancel();
    followAudio.dispose();
    delayMs.dispose();
    imagePauseSec.dispose();
    _clipStateSub?.cancel();
    _clipStateSub = null;
    _clipPositionSub?.cancel();
    _clipPositionSub = null;
    _finishClipPlayback(RangePlaybackEnd.interrupted);
  }

  /// 用临时片段播放器只放 [range] 这一段。返回 null = 区间无效、没起播；否则返回这段的
  /// [RangePlayback]：片段播到终点以 [RangePlaybackEnd.reachedEnd] 完成，被 [stopClip] /
  /// 下一次 [playRange] / [stopPlayback] / 销毁收掉以 [RangePlaybackEnd.interrupted] 完成。
  ///
  /// 注意本方法 `await clip.play()`，而 just_audio 的 `play()` 要到播完 / 暂停 / 停止才
  /// 返回——所以调用方拿到句柄时它多半已经结束；调用方的状态一律跟句柄走，不要拿「本
  /// 方法返回了」当「开始播了」。
  Future<RangePlayback?> playRange(AudioPlaybackRange range) async {
    if (range.audioFileIndex < 0 ||
        range.audioFileIndex >= _audioFiles.length) {
      return null;
    }
    if (range.endMs <= range.startMs) {
      return null;
    }
    final bool shouldResumeMain = _resumeMainAfterClip || _player.playing;
    await stopClip(resumeMain: false);

    _resumeMainAfterClip = shouldResumeMain;
    if (_player.playing) {
      await _player.pause();
    }

    final AudioPlayer clip = AudioPlayer();
    _clipPlayer = clip;
    final RangePlayback playback = RangePlayback();
    _clipPlayback = playback;

    final AudiobookRemotePlayback? remote = _remotePlayback;
    if (remote == null) {
      await clip.setAudioSource(
        ClippingAudioSource(
          child: AudioSource.file(_audioFiles[range.audioFileIndex].path),
          start: Duration(milliseconds: range.startMs),
          end: Duration(milliseconds: range.endMs),
        ),
      );
    } else {
      // 流式源不能交给 ClippingAudioSource（它只认 UriAudioSource）：整轨装进临时播放
      // 器，seek 到句首，再盯着位置在句尾停下。
      await clip.setAudioSource(remote.buildTrackSource(range.audioFileIndex));
      await clip.seek(Duration(milliseconds: range.startMs));
    }
    await clip.setSpeed(_player.speed);

    _clipStateSub?.cancel();
    _clipStateSub = clip.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        stopClip(reason: RangePlaybackEnd.reachedEnd);
      }
    });
    _clipPositionSub?.cancel();
    _clipPositionSub = null;
    if (remote != null) {
      final Duration end = Duration(milliseconds: range.endMs);
      _clipPositionSub = clip.positionStream.listen((Duration position) {
        if (position >= end) stopClip(reason: RangePlaybackEnd.reachedEnd);
      });
    }

    await clip.play();
    return playback;
  }

  /// 停掉 [playRange] 起的片段；[reason] 是交给调用方句柄的结局（片段自己播到终点时
  /// 由监听方传 [RangePlaybackEnd.reachedEnd]，其余一律算打断）。
  Future<void> stopClip({
    bool resumeMain = true,
    RangePlaybackEnd reason = RangePlaybackEnd.interrupted,
  }) async {
    _finishClipPlayback(reason);
    _clipStateSub?.cancel();
    _clipStateSub = null;
    _clipPositionSub?.cancel();
    _clipPositionSub = null;
    final AudioPlayer? old = _clipPlayer;
    if (old != null) {
      _clipPlayer = null;
      await old.stop();
      old.dispose();
    }
    if (resumeMain && _resumeMainAfterClip) {
      _resumeMainAfterClip = false;
      unawaited(_activateMainPlayer());
    }
  }

  /// [playRange] 句柄的唯一收尾点。
  void _finishClipPlayback(RangePlaybackEnd reason) {
    final RangePlayback? playback = _clipPlayback;
    _clipPlayback = null;
    playback?.finish(reason);
  }
}

/// [AudiobookPlayerController.classifyActivationTickForTesting] 的结论。
enum ActivationRestoreTick { transient, unreachable, landed }

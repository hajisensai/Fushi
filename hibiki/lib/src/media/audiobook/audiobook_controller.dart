import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';

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

  /// 由 reader 页面提供：返回 ttu 当前挂载的 section index（开书前 -1）。
  /// 对齐 Sasayaki SasayakiPlayer 构造时注入的 `getCurrentIndex` 闭包，
  /// 跨章判定的"参照系"必须是 reader 真实挂载的章节，而非"上一条 cue 的章"。
  /// 否则用户手动翻到错误章节后，cue 一直在原章，永远不会自动拉回。
  int Function()? getCurrentReaderSection;

  /// 对齐 Sasayaki `hasPlayedOnce`：true 之前不允许跨章自动翻页，避免
  /// 打开书 / 恢复位置瞬间 cue 与 reader 当前章不一致就立刻跳章，
  /// 把用户当前阅读位置吃掉。在首次 [play] 调用时翻为 true，不会复位
  /// （即使中途暂停）。换书走 [load] 显式复位。
  bool _hasPlayedOnce = false;

  /// 对齐 Sasayaki `chapterTransition`：跨章 await 期间为 true，期间
  /// [_updateCurrentCue] 直接 return，避免 cue 继续推进重复触发跨章
  /// 请求 / 把 pendingCue 反复覆盖。reader 完成跳章后调
  /// [notifySectionRestoreCompleted] 清回 false。
  bool _chapterTransition = false;

  /// 对齐 Sasayaki `pendingCue`：触发跨章的那条 cue。新章节 DOM 挂载完
  /// 之后 reader 调 [notifySectionRestoreCompleted]，控制器会重新尝试
  /// 高亮这条 cue（避免等到下一条 positionStream tick 才有视觉反馈）。
  AudioCue? _pendingCue;

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
  }) async {
    _audiobook = audiobook;
    // Follow audio / delay / speed 状态由调用方从 Hive 读出传入；不触发
    // persist 回调 —— 载入不是用户操作，又把同值写回 Hive 就是循环。
    followAudio.value = initialFollowAudio;
    delayMs.value = initialDelayMs;
    _hasPlayedOnce = false;
    _chapterTransition = false;
    _pendingCue = null;

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

    // 先应用持久化速度再启动跟踪：播放速度由 just_audio 的内部状态持有，
    // 不走 notifyListeners 也能在下次 setSpeed / UI 读 `speed` getter 时反映。
    if ((initialSpeed - 1.0).abs() > 0.001) {
      try {
        await _player.setSpeed(initialSpeed);
      } catch (e) {
        debugPrint('[hibiki-audiobook] initial setSpeed $initialSpeed failed: $e');
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
    // 对齐 Sasayaki：首次 play 之后才允许跨章自动翻页。打开书 / 恢复
    // 位置阶段 cue 与 reader 当前章不一致是常态，不应在用户没按播放时
    // 就把 reader 拉到音频章。
    _hasPlayedOnce = true;
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
    session.becomingNoisyEventStream.listen((_) {
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
    // 对齐 Sasayaki SasayakiPlayer.updateCue 开头的 `guard !chapterTransition`：
    // 跨章 await 期间不推进 cue，否则 reader 还没挂上新章 DOM 时 positionStream
    // 会连续推进若干条 cue，每条都触发 _maybeEmitCrossChapter，pendingCue 被
    // 反复覆盖、onCrossChapter 重复调用。
    if (_chapterTransition) return;
    if (_chapterCues.isEmpty) {
      return;
    }
    // 应用用户设置的音画延迟：delayMs 正值表示"音频比文字先播"，查询
    // cue 时要把位置往回拨；负值相反。下界 clamp 到 0 避免负位置查询。
    // 上界不 clamp（_player.duration 可能暂未就绪），超出时 findCueIndex
    // 自行返回最后一个 cue 即可。
    final int effectiveMs = (posMs - delayMs.value).clamp(0, 1 << 30);
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: _chapterCues,
      positionMs: effectiveMs,
    );
    final AudioCue? newCue = idx >= 0 ? _chapterCues[idx] : null;
    if (newCue?.textFragmentId != _currentCue?.textFragmentId) {
      _currentCue = newCue;
      _maybeEmitCrossChapter(newCue);
      notifyListeners();
    }
  }

  /// 对齐 Sasayaki `displayCue(cue, reveal: autoScroll && hasPlayedOnce)`：
  /// 高亮时是否把 cue 滚进视口。Follow audio OFF 或者还没按过 play 时，
  /// 即使 cue 切换也**只加高亮 class、不动视口**，让用户保持当前阅读位置
  /// 不被音频位置覆盖。
  ///
  /// reader 的 `_onCueChanged` 在调 AudiobookBridge.highlight 时读一次
  /// 这个值传过去。
  bool get shouldRevealCurrentCue => followAudio.value && _hasPlayedOnce;

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

  /// 对齐 Sasayaki SasayakiPlayer.updateCue 的 if/else 分支：
  /// `cue.chapterIndex == currentIndex` 走 displayCue，否则在 autoScroll +
  /// hasPlayedOnce 时缓存 pendingCue + 触发 loadChapter。
  ///
  /// 关键差异（修正点）：以前用 `_lastCueSectionIndex`（上一条 cue 的 sec）
  /// 判定跨章，结果用户手动翻到错误章节后 cue 持续在原章、prev == sec、
  /// 永不触发自动跳回。改为对比 [getCurrentReaderSection]——reader 实际
  /// 挂载的是哪一章，才是 Sasayaki 的判定参照系。
  ///
  /// SMIL/JSON 等非 sasayaki 路径 cue 的 textFragmentId 解码返回 null，
  /// 自然跳过这套逻辑（它们没有跨章同步概念）。
  void _maybeEmitCrossChapter(AudioCue? cue) {
    // 已在跨章 await 中直接忽略 —— 多个 caller 路径（_updateCurrentCue /
    // setFollowAudio / 未来其他入口）都可能在 transition 尚未完成时再次踩到
    // 这里；没守卫会把 _pendingCue 反复覆盖 + 重复 onCrossChapter，
    // ttu 被轮番 __ttuGoToSection，每次 scrollTop 都被清零到章首。
    if (_chapterTransition) return;
    if (cue == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag == null) return;
    final int cueSec = frag.sectionIndex;
    final int currentSec = getCurrentReaderSection?.call() ?? -1;
    if (currentSec < 0) {
      // reader 还没汇报过当前章（一般是开书前），先等等 —— 别按 0 假设
      // 否则 cue 在第 5 章会立刻请求跳章。
      return;
    }
    if (cueSec == currentSec) return;
    if (!followAudio.value) return;
    if (!_hasPlayedOnce) return;
    // 进入跨章状态：缓存 pendingCue，竖起 chapterTransition 守卫，
    // 通知 reader 跳章。reader 完成后调 notifySectionRestoreCompleted。
    _pendingCue = cue;
    _chapterTransition = true;
    onCrossChapter?.call(cueSec);
  }

  /// 由 reader 在 `__ttuGoToSection` 完成（或失败）后调用，对齐 Sasayaki
  /// `handleRestoreCompleted(currentIndex:)`：清 chapterTransition 守卫，
  /// 让 [_updateCurrentCue] 重新放行；如果 pendingCue 命中目标章节，
  /// 立刻 notifyListeners 让 reader 在新章上重画高亮，无需等 positionStream
  /// 下一 tick（暂停状态下 positionStream 不发事件，否则会黑屏几秒）。
  ///
  /// [success] = false 时（跳章请求超时 / reject）也务必调用，否则
  /// _chapterTransition 永远卡 true，cue 完全停止推进。
  void notifySectionRestoreCompleted({
    required int currentReaderSection,
    required bool success,
  }) {
    _chapterTransition = false;
    final AudioCue? pending = _pendingCue;
    _pendingCue = null;
    if (!success || pending == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(pending.textFragmentId);
    if (frag == null) return;
    if (frag.sectionIndex != currentReaderSection) return;
    // pendingCue 仍然是 currentCue，强制 notify 让 reader 在新章节 DOM
    // 上重新跑一次 highlight。
    notifyListeners();
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
    // 正处于跨章 await：让现有 transition 自己跑完、由
    // notifySectionRestoreCompleted 接力 notify，不重入
    // _maybeEmitCrossChapter（它自己也会守卫，这里再挡一层只是少走一遍
    // 解码 + reader section 闭包）。
    if (_chapterTransition) return;
    final AudioCue? cue = _currentCue;
    if (cue == null) return;
    // _maybeEmitCrossChapter 自带 _hasPlayedOnce / followAudio / 同段短路
    // 等守卫；跨段命中时它会把 _chapterTransition 翻为 true 并请跳章，
    // 跳章完的 notifySectionRestoreCompleted 自己会 notify，这里不重复。
    _maybeEmitCrossChapter(cue);
    if (_chapterTransition) return;
    notifyListeners();
  }

  /// 设置音画延迟（毫秒），带边界夹取。超出 ±30s 的值几乎不可能是
  /// 有意义的对齐偏移，截断防止 UI 意外把位置拨到负数/末尾。
  /// 写库走 [onDelayPersist]。相同值跳过 notify/写库。
  void setDelayMs(int ms) {
    final int clamped = ms.clamp(-30000, 30000);
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
    followAudio.dispose();
    delayMs.dispose();
    _player.dispose();
    super.dispose();
  }
}

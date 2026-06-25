import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/utils/misc/hibiki_audio_handler.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 进程级常驻有声书会话（TODO-291 阶段2）。
///
/// 根因：历史上 [AudiobookPlayerController] 由 reader 页 `State` 创建、`dispose()`
/// 销毁，cue→悬浮窗/媒体通知/位置落库的同步链路也全在 reader 页里。退出书籍页 =
/// reader `dispose` = 杀播放器 + 隐藏悬浮窗 → 「退出书籍后继续听书」做不到。
///
/// [AudiobookSession] 把控制器生命周期、当前书元数据、cue→悬浮窗/通知/落库的常驻
/// 同步从 reader 页里抽出来挂到 AppModel（Riverpod 全局生命周期），让它脱离 reader
/// 页的生命周期常驻运行。reader 在场时通过 [attachReader] 注册 WebView 侧回调
/// （正文跟随高亮 / 跨章 / 边界跳句 / cue 变化）；退出 reader 时 [detachReader] 把这些
/// 回调清成「无 reader」安全默认，但**不 dispose 控制器**——音频继续播、悬浮窗继续
/// 刷字、媒体通知继续更新。只有 [stop]（用户显式停止 / 切到另一本书）才真正销毁控制器
/// 并隐藏悬浮窗 + 清通知。
///
/// 唯一持有者：除本会话外，没有任何代码应当 `dispose()` 这个控制器。reader 页只读
/// [controller] 引用喂给 play bar / 查词等 UI，不再拥有它。
class AudiobookSession extends ChangeNotifier {
  AudiobookSession({
    required HibikiAudioHandler? Function() audioHandler,
    required bool Function() showFloatingLyric,
    required bool Function() showMediaNotification,
    required FloatingLyricStyle Function() floatingLyricStyle,
    required bool Function() floatingLyricClickLookup,
    required FloatingLyricLookupHandler onFloatingLyricLookup,
    required AudioControlStreams controlStreams,
  })  : _audioHandlerGetter = audioHandler,
        _showFloatingLyric = showFloatingLyric,
        _showMediaNotification = showMediaNotification,
        _floatingLyricStyle = floatingLyricStyle,
        _floatingLyricClickLookup = floatingLyricClickLookup,
        _onFloatingLyricLookup = onFloatingLyricLookup,
        _defaultFloatingLyricStyle = floatingLyricStyle,
        _defaultFloatingLyricLookup = onFloatingLyricLookup,
        _controlStreams = controlStreams;

  final HibikiAudioHandler? Function() _audioHandlerGetter;
  final bool Function() _showFloatingLyric;
  final bool Function() _showMediaNotification;
  final bool Function() _floatingLyricClickLookup;
  final AudioControlStreams _controlStreams;

  /// 悬浮窗样式来源。默认是 AppModel 注入的 app 级主题样式；reader attach 时换成
  /// reader 主题样式（深色书/竖排等），detach 时还原成默认，使后台听书也有合理样式。
  FloatingLyricStyle Function() _floatingLyricStyle;

  /// 悬浮窗（桌面）点词查词路由。app 级默认是 no-op（无 reader / 无弹窗宿主时点词忽略）；
  /// reader attach 时换成 reader 的弹窗查词，detach 时还原。
  FloatingLyricLookupHandler _onFloatingLyricLookup;

  /// app 级默认样式 / 查词（构造时固化），detach 时还原。
  final FloatingLyricStyle Function() _defaultFloatingLyricStyle;
  final FloatingLyricLookupHandler _defaultFloatingLyricLookup;

  /// 还原成 app 级默认样式 / 查词（reader detach 时调）。
  void restoreDefaultSurfaces() {
    _floatingLyricStyle = _defaultFloatingLyricStyle;
    _onFloatingLyricLookup = _defaultFloatingLyricLookup;
    if (_showFloatingLyric()) {
      unawaited(applyFloatingLyricStyle());
      _setupFloatingLyricHandlers();
    }
  }

  /// reader attach 时安装其主题样式 + 弹窗查词；detach 时调 [restoreDefaultSurfaces]
  /// 还原成 app 级默认。
  void installReaderSurfaces({
    required FloatingLyricStyle Function() floatingLyricStyle,
    required FloatingLyricLookupHandler onFloatingLyricLookup,
  }) {
    _floatingLyricStyle = floatingLyricStyle;
    _onFloatingLyricLookup = onFloatingLyricLookup;
    // 已经拉起的悬浮窗换成 reader 主题样式 + reader 查词处理器（reader 进/重建后生效）。
    if (_showFloatingLyric()) {
      unawaited(applyFloatingLyricStyle());
      _setupFloatingLyricHandlers();
    }
  }

  AudiobookPlayerController? _controller;

  /// 当前会话持有的控制器（null = 无会话）。reader / play bar / 查词只读引用。
  AudiobookPlayerController? get controller => _controller;

  SessionBookInfo? _book;

  /// 当前会话的书元数据（null = 无会话）。供首页迷你条 / 通知 / 悬浮窗读取。
  SessionBookInfo? get book => _book;

  /// 是否有正在运行的后台听书会话。
  bool get isActive => _controller != null;

  /// 当前是否有 reader 页 attach（决定 cue 同步是否驱动 WebView 高亮）。
  bool get hasReaderAttached => _reader != null;

  ReaderAudiobookView? _reader;

  // ── audioHandler 控制流订阅（进程级，脱离 reader） ─────────────────────────
  StreamSubscription<void>? _playStreamSub;
  StreamSubscription<Duration>? _seekStreamSub;
  StreamSubscription<void>? _skipNextSub;
  StreamSubscription<void>? _skipPrevSub;
  StreamSubscription<void>? _floatingLyricSub;

  /// 跳句/快进秒数：play bar 与控制流共用的步长读取（从 reader source 单例读，detach
  /// 后仍可读，故由调用方注入闭包，避免会话直接依赖 reader page）。
  int Function() skipActionSeconds = () => 0;

  /// 悬浮窗关闭后落偏好的回调（设置 show_floating_lyric=false），由 AppModel 注入。
  Future<void> Function()? onFloatingLyricClosePersist;

  /// 启动一个后台听书会话：创建并 load 控制器、装 persist 回调、订阅 cue 变化与
  /// audioHandler 控制流、按偏好拉起悬浮窗 / 媒体通知。
  ///
  /// 若已有同一本书（[SessionBookInfo.bookKey] 相同）的活动会话，直接复用既有控制器
  /// （reader 重进 / 书架重复点不重复加载）。切到另一本书时先 [stop] 旧会话再起新会话
  /// （用户决策：同一时刻只一本有声书会话）。
  ///
  /// 返回拿到的控制器；加载失败 rethrow（不留半成品会话）。
  Future<AudiobookPlayerController?> start({
    required SessionBookInfo info,
    required List<File> audioFiles,
    required SessionPrefs prefs,
    required SessionPersistCallbacks persist,
    List<AudioCue> cues = const <AudioCue>[],
  }) async {
    final AudiobookPlayerController? existing = _controller;
    if (existing != null && _book?.bookKey == info.bookKey) {
      // 同书复用：刷新元数据（封面/标题可能更新过）后直接返回。
      _book = info;
      _rewirePersist(existing, persist);
      notifyListeners();
      return existing;
    }
    if (existing != null) {
      // 切书：顶掉旧会话。
      await stop();
    }

    final AudiobookPlayerController controller = AudiobookPlayerController();
    try {
      await controller.load(
        audiobook: info.audiobook,
        audioFiles: audioFiles,
        initialFollowAudio: prefs.followAudio,
        initialDelayMs: prefs.delayMs,
        initialSpeed: prefs.speed,
        initialPositionMs: prefs.positionMs,
        initialImagePauseSec: prefs.imagePauseSec,
        initialVolume: prefs.volume,
      );
    } catch (e) {
      controller.dispose();
      rethrow;
    }

    // 后台听书无 reader 灌 cue。把解析好的全书 cue 喂进控制器：load() 已 seek 到
    // initialPositionMs，setChapterCues 内部立即按当前位置 _updateCurrentCue 解析
    // currentCue，使悬浮窗在首次开启（无需进书）即有字（TODO-354 根因②）。reader
    // 后续 attach 时仍会按章节重新 setChapterCues 覆盖，行为不变。cues 为空（如 reader
    // 自己接管 cue 加载的路径）时不动控制器，保留既有逻辑。
    if (cues.isNotEmpty) {
      controller.setAllBookCues(cues);
      controller.setChapterCues(cues);
    }

    _rewirePersist(controller, persist);
    controller.addListener(_onControllerChanged);
    _controller = controller;
    _book = info;

    _subscribeControlStreams(controller);
    await _startBackgroundSurfaces(controller);

    notifyListeners();
    return controller;
  }

  void _rewirePersist(
    AudiobookPlayerController controller,
    SessionPersistCallbacks persist,
  ) {
    controller.onPositionWrite = persist.onPositionWrite;
    controller.onDelayPersist = persist.onDelayPersist;
    controller.onSpeedPersist = persist.onSpeedPersist;
    controller.onVolumePersist = persist.onVolumePersist;
    controller.onImagePausePersist = persist.onImagePausePersist;
    controller.onFollowAudioPersist = persist.onFollowAudioPersist;
  }

  /// 装 reader WebView 侧回调：正文跟随高亮 / 跨章导航 / 边界跳句 / cue 变化。
  /// 只在 reader 在场期间生效。重复 attach（同一 reader 重建）覆盖即可。
  void attachReader(ReaderAudiobookView reader) {
    final AudiobookPlayerController? controller = _controller;
    _reader = reader;
    if (controller != null) {
      controller.getCurrentReaderSection = reader.getCurrentReaderSection;
      controller.onCrossChapter = reader.onCueCrossChapter;
      controller.onBoundarySkip = reader.onBoundarySkip;
    }
  }

  /// 退出 reader：把 WebView 侧回调清成「无 reader」安全默认，但不 dispose 控制器。
  ///
  /// - [getCurrentReaderSection] 返回 -1 → [AudiobookPlayerController]
  ///   `shouldCrossChapterForTesting` 的 `currentSec < 0` 分支命中，跨章守卫天然不动作
  ///   （没有 WebView 可跳）。
  /// - [onCrossChapter] / [onBoundarySkip] 置 null（边界跳句退化为不跨章）。
  /// 只清这个 reader（避免新 reader attach 后旧 reader 的 detach 误清）。
  void detachReader(ReaderAudiobookView reader) {
    if (!identical(_reader, reader)) return;
    _reader = null;
    final AudiobookPlayerController? controller = _controller;
    if (controller != null) {
      controller.getCurrentReaderSection = () => -1;
      controller.onCrossChapter = null;
      controller.onBoundarySkip = null;
      // 离开 reader 时把跨章守卫复位，避免 reader 在跳章 await 中途离开导致
      // _chapterTransition 卡 true，会话继续播却永不推进 cue。
      controller.cancelChapterTransition();
    }
    // 退 reader 后悬浮窗换回 app 级默认主题样式 + 默认查词（桌面后台听书点词无弹窗宿主）。
    restoreDefaultSurfaces();
  }

  /// 显式停止会话：dispose 控制器、隐藏悬浮窗、清媒体通知、取消订阅。
  Future<void> stop() async {
    final AudiobookPlayerController? controller = _controller;
    _reader = null;
    _controller = null;
    _book = null;
    // TODO-831：同步清空 _book/_controller 后立即通知一次，让监听者（书架
    // NowListeningMiniBar）在下面 await stopPlayback / _stopBackgroundSurfaces
    // 之前就见到空会话并收起，不必等末尾那次 notifyListeners。止声/释放解码器的
    // 既有顺序（stopPlayback→dispose，BUG-278/367）不变；末尾 notifyListeners
    // 保留，覆盖 await 期间可能产生的其它监听者。
    notifyListeners();

    _playStreamSub?.cancel();
    _seekStreamSub?.cancel();
    _skipNextSub?.cancel();
    _skipPrevSub?.cancel();
    _floatingLyricSub?.cancel();
    _playStreamSub = null;
    _seekStreamSub = null;
    _skipNextSub = null;
    _skipPrevSub = null;
    _floatingLyricSub = null;

    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      // BUG-278/TODO-367：dispose 前必须真正 stop（释放 native 解码器止声），不能
      // 只 pause（pause 保留解码器，紧随的同步 dispose 又抢不过异步平台拆除，
      // Android 上表现为停止后仍在响）。stopPlayback 可 await 到平台切换 settle，
      // 也 force-flush 位置；之后 dispose 不再与异步平台切换竞争。
      await controller.stopPlayback();
      controller.dispose();
    }

    await _stopBackgroundSurfaces();
    notifyListeners();
  }

  // ── 控制器 cue 变化的常驻同步 ────────────────────────────────────────────

  void _onControllerChanged() {
    final AudiobookPlayerController? controller = _controller;
    if (controller == null) return;
    // reader 在场：把 cue 变化转给 reader（WebView 高亮 / lyrics 等），由 reader 自己
    // 决定怎么动 WebView——保留全部既有行为（BUG-060/061/069/072 等）。
    _reader?.onReaderCueChanged();
    // 常驻同步：悬浮窗 + 媒体通知。即便没有 reader（退书后台听书）也照刷。
    _syncFloatingLyric(controller);
    _syncMediaNotification(controller);
    // 给迷你条 / 任何 session 监听者一次刷新（播放态 / cue 文本变了）。
    notifyListeners();
  }

  void _syncFloatingLyric(AudiobookPlayerController controller) {
    if (!_showFloatingLyric()) return;
    final AudioCue? cue = controller.currentCue;
    FloatingLyricChannel.updateText(cue?.text ?? '');
    FloatingLyricChannel.setPlaybackState(playing: controller.isPlaying);
  }

  void _syncMediaNotification(AudiobookPlayerController controller) {
    if (!_showMediaNotification()) return;
    final HibikiAudioHandler? handler = _audioHandlerGetter();
    if (handler == null) return;
    handler.updatePlaybackState(
      playing: controller.isPlaying,
      position: controller.position,
      speed: controller.speed,
      duration: controller.duration,
    );
    final AudioCue? cue = controller.currentCue;
    if (cue != null) {
      handler.updateNotificationSubtitle(
        title: _book?.title ?? 'Hibiki',
        subtitle: cue.text,
      );
    }
  }

  // ── 后台表面（悬浮窗 / 通知 / 控制流） ──────────────────────────────────

  Future<void> _startBackgroundSurfaces(
    AudiobookPlayerController controller,
  ) async {
    if (_showFloatingLyric()) {
      final bool canDraw = await FloatingLyricChannel.canDrawOverlays();
      if (canDraw) {
        await showFloatingLyricOverlay();
        _syncFloatingLyric(controller);
      }
    }
    if (_showMediaNotification()) {
      _setMediaItemWithCover(controller);
      _syncMediaNotification(controller);
    }
  }

  Future<void> _stopBackgroundSurfaces() async {
    FloatingLyricChannel.clearEventHandlers();
    await FloatingLyricChannel.hide();
    _audioHandlerGetter()?.clearNotification();
  }

  void _subscribeControlStreams(AudiobookPlayerController controller) {
    _playStreamSub?.cancel();
    _seekStreamSub?.cancel();
    _skipNextSub?.cancel();
    _skipPrevSub?.cancel();
    _floatingLyricSub?.cancel();
    _playStreamSub = _controlStreams.playStream.listen((_) {
      controller.togglePlayPause();
    });
    _seekStreamSub = _controlStreams.seekStream.listen((Duration pos) {
      controller.seekMs(pos.inMilliseconds);
    });
    _skipNextSub = _controlStreams.skipNextStream.listen((_) {
      final int s = skipActionSeconds();
      if (s == 0) {
        controller.skipToNextCue();
      } else {
        controller.seekRelative(s);
      }
    });
    _skipPrevSub = _controlStreams.skipPreviousStream.listen((_) {
      final int s = skipActionSeconds();
      if (s == 0) {
        controller.skipToPrevCue();
      } else {
        controller.seekRelative(-s);
      }
    });
    _floatingLyricSub = _controlStreams.toggleFloatingLyricStream.listen((_) {
      // 通知栏 custom action 翻转悬浮窗：当前显隐状态由偏好决定，调用方注入翻转逻辑。
      onToggleFloatingLyricFromNotification?.call();
    });
  }

  /// 通知栏「悬浮字幕」custom action 的翻转回调（AppModel 注入，含偏好读写 + 提示）。
  Future<void> Function()? onToggleFloatingLyricFromNotification;

  // ── 悬浮窗显隐（会话级，样式由注入的 styleGetter 提供） ─────────────────

  /// 拉起悬浮窗并装事件处理器。供 [start]（按偏好自动拉起）与 [toggleFloatingLyric]
  /// （用户手动开）共用。返回 false = 显示失败（缺权限 / 窗口创建失败）。
  Future<bool> showFloatingLyricOverlay() async {
    final FloatingLyricStyle style = _floatingLyricStyle();
    final bool shown = await FloatingLyricChannel.show(
      fontSize: style.fontSize,
      textColor: style.textColor,
      bgColor: style.bgColor,
      buttonTextColor: style.buttonTextColor,
      buttonBgColor: style.buttonBgColor,
      highlightColor: style.highlightColor,
      activeColor: style.activeColor,
      clickLookupEnabled: _floatingLyricClickLookup(),
    );
    if (!shown) return false;
    await _applyFloatingLyricStyle(style);
    _setupFloatingLyricHandlers();
    return true;
  }

  Future<void> _applyFloatingLyricStyle(FloatingLyricStyle style) async {
    await FloatingLyricChannel.updateStyle(
      fontSize: style.fontSize,
      textColor: style.textColor,
      bgColor: style.bgColor,
      buttonTextColor: style.buttonTextColor,
      buttonBgColor: style.buttonBgColor,
      highlightColor: style.highlightColor,
      activeColor: style.activeColor,
    );
    await FloatingLyricChannel.setClickLookupEnabled(
        _floatingLyricClickLookup());
    await FloatingLyricChannel.updateLabels(
      previous: t.floating_lyric_previous,
      playPause: t.floating_lyric_play_pause,
      next: t.floating_lyric_next,
      lock: t.floating_lyric_lock,
      unlock: t.floating_lyric_unlock,
      close: t.floating_lyric_close,
    );
  }

  /// 同步悬浮窗样式（reader 改主题 / 字号后调用）。无活动会话也允许（幂等）。
  Future<void> applyFloatingLyricStyle() => _applyFloatingLyricStyle(
        _floatingLyricStyle(),
      );

  void _setupFloatingLyricHandlers() {
    FloatingLyricChannel.setEventHandlers(
      onLookupText: _onFloatingLyricLookup,
      onPlayPause: () => _controller?.togglePlayPause(),
      onPreviousCue: () => _controller?.skipToPrevCue(),
      onNextCue: () => _controller?.skipToNextCue(),
      onClose: _onFloatingLyricClose,
      onLockChanged: (bool locked) {
        debugPrint('[Hibiki] floating-lyric position lock -> $locked');
      },
    );
  }

  Future<void> _onFloatingLyricClose() async {
    await FloatingLyricChannel.hide();
    FloatingLyricChannel.clearEventHandlers();
    await onFloatingLyricClosePersist?.call();
    notifyListeners();
  }

  /// 翻转悬浮窗显隐。返回 false 表示开启失败（如缺 overlay 权限），调用方据此提示。
  Future<bool> toggleFloatingLyric({required bool currentlyOn}) async {
    if (currentlyOn) {
      await FloatingLyricChannel.hide();
      FloatingLyricChannel.clearEventHandlers();
      notifyListeners();
      return true;
    }
    final bool shown = await showFloatingLyricOverlay();
    if (!shown) return false;
    final AudiobookPlayerController? controller = _controller;
    if (controller != null) {
      _syncFloatingLyric(controller);
    }
    notifyListeners();
    return true;
  }

  void _setMediaItemWithCover(AudiobookPlayerController controller) {
    final HibikiAudioHandler? handler = _audioHandlerGetter();
    if (handler == null) return;
    Uri? artUri;
    final String? coverPath = _book?.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      artUri = File(coverPath).uri;
    }
    handler.setMediaItemInfo(
      title: _book?.title ?? 'Hibiki',
      artist: _book?.author,
      duration: controller.duration,
      artUri: artUri,
    );
  }

  /// reader / 设置切换媒体通知时调用（开 → 装媒体卡片并同步；关 → 清通知）。
  void onMediaNotificationToggled({required bool enabled}) {
    final AudiobookPlayerController? controller = _controller;
    if (enabled && controller != null) {
      _setMediaItemWithCover(controller);
      _syncMediaNotification(controller);
    } else if (!enabled) {
      _audioHandlerGetter()?.clearNotification();
    }
  }

  @override
  void dispose() {
    // 进程退出：随 AppModel.dispose 一起清。stop 不能 await（dispose 同步），直接拆。
    final AudiobookPlayerController? controller = _controller;
    _playStreamSub?.cancel();
    _seekStreamSub?.cancel();
    _skipNextSub?.cancel();
    _skipPrevSub?.cancel();
    _floatingLyricSub?.cancel();
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      controller.dispose();
    }
    _controller = null;
    _book = null;
    _reader = null;
    super.dispose();
  }
}

/// reader 页向会话暴露的 WebView 侧接口。会话在 cue 变化 / 跨章 / 边界跳句时回调它，
/// 由 reader 自己操作 WebView（高亮 / 章节导航），从而保留全部既有 reader 行为。
abstract class ReaderAudiobookView {
  /// 当前 reader 挂载的章节 index（开书前 -1）。喂给控制器跨章判定参照系。
  int getCurrentReaderSection();

  /// 控制器请求跨章跟随（cue 所属章 != reader 当前章）。
  Future<void> onCueCrossChapter(int sectionIndex);

  /// 章首/章尾跳句越界，reader 负责加载相邻章并 seek。
  Future<void> onBoundarySkip(int delta);

  /// 控制器 cue / 播放态变化：reader 更新 WebView 正文高亮 / lyrics / 进度。
  void onReaderCueChanged();
}

/// 当前会话书的元数据快照（脱离 reader 页持有，供后台 / 迷你条 / 通知读取）。
class SessionBookInfo {
  const SessionBookInfo({
    required this.bookKey,
    required this.audiobook,
    required this.title,
    required this.mediaIdentifier,
    this.author,
    this.coverPath,
  });

  final String bookKey;
  final Audiobook audiobook;
  final String title;

  /// 媒体标识（用于「回到书」时按 source 打开，如 `reader_hibiki://book/<key>`）。
  final String mediaIdentifier;
  final String? author;
  final String? coverPath;
}

/// 控制器加载初值（从持久层读出）。
class SessionPrefs {
  const SessionPrefs({
    required this.followAudio,
    required this.delayMs,
    required this.speed,
    required this.positionMs,
    required this.imagePauseSec,
    required this.volume,
  });

  final bool followAudio;
  final int delayMs;
  final double speed;
  final int positionMs;
  final int imagePauseSec;
  final double volume;
}

/// 控制器 persist 回调集合（写库）。会话装到控制器上，使位置等设置在退 reader 后
/// 仍持续落库。
class SessionPersistCallbacks {
  const SessionPersistCallbacks({
    required this.onPositionWrite,
    required this.onDelayPersist,
    required this.onSpeedPersist,
    required this.onVolumePersist,
    required this.onImagePausePersist,
    required this.onFollowAudioPersist,
  });

  final Future<void> Function(String bookKey, int positionMs) onPositionWrite;
  final Future<void> Function(int ms) onDelayPersist;
  final Future<void> Function(double speed) onSpeedPersist;
  final Future<void> Function(double volume) onVolumePersist;
  final Future<void> Function(int sec) onImagePausePersist;
  final Future<void> Function(bool value) onFollowAudioPersist;
}

/// 悬浮窗样式快照（reader 主题相关，由 reader / 设置注入闭包提供，避免会话直接依赖
/// reader 主题状态）。
class FloatingLyricStyle {
  const FloatingLyricStyle({
    required this.fontSize,
    required this.textColor,
    required this.bgColor,
    required this.buttonTextColor,
    required this.buttonBgColor,
    required this.highlightColor,
    required this.activeColor,
  });

  final double fontSize;
  final int textColor;
  final int bgColor;
  final int buttonTextColor;
  final int buttonBgColor;
  final int highlightColor;
  final int activeColor;

  /// TODO-370: 按百分比（0..100）缩放某个 ARGB 颜色的 alpha 通道。100 = 原 alpha 不变
  /// （保持各表面历史观感），调小变更透明。两个悬浮字幕样式构造点（app 级 / reader 级）
  /// 共用此唯一实现，保证「同一个透明度设置，两处一致」。
  static int scaleAlpha(int argb, int opacityPercent) {
    final int pct = opacityPercent.clamp(0, 100);
    final int baseAlpha = (argb >> 24) & 0xFF;
    final int newAlpha = (baseAlpha * pct / 100).round().clamp(0, 255);
    return (newAlpha << 24) | (argb & 0x00FFFFFF);
  }
}

/// audioHandler 控制流集合（lock-screen / 通知按钮 → 控制器）。由 AppModel 的
/// `AudioController` 提供，会话订阅它在后台也能接 play/seek/skip。
class AudioControlStreams {
  const AudioControlStreams({
    required this.playStream,
    required this.seekStream,
    required this.skipNextStream,
    required this.skipPreviousStream,
    required this.toggleFloatingLyricStream,
  });

  final Stream<void> playStream;
  final Stream<Duration> seekStream;
  final Stream<void> skipNextStream;
  final Stream<void> skipPreviousStream;
  final Stream<void> toggleFloatingLyricStream;
}

import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/magpie_upscaling.dart';
import 'package:fushi/src/mining/magpie_upscaling_service.dart';
import 'package:fushi/src/media/sources/reader_hibiki_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';
import 'package:fushi/utils.dart';

typedef GalHookPreferenceReader = Object? Function(
  String key, {
  required Object? defaultValue,
});
typedef GalHookPreferenceWriter = Future<void> Function(
  String key,
  Object? value,
);

/// 「悬停即查词」开关的读取口（设置项 `hover_auto_lookup`）。真值在
/// [ReaderHibikiSource]（media source 偏好store，与本控制器用的 prefsRepo 不是同一
/// 个存储），所以单独开一条读取口而不是复用 [GalHookPreferenceReader]。
typedef GalHookHoverAutoLookupReader = bool Function();

/// App 级 Windows Hook 台词浮窗控制器。
class GalHookTextOverlayController extends ChangeNotifier {
  GalHookTextOverlayController._({
    GalHookSessionController? session,
    GalHookMiningCoordinator? miningCoordinator,
    GalHookPreferenceReader? preferenceReader,
    GalHookPreferenceWriter? preferenceWriter,
    GalHookHoverAutoLookupReader? hoverAutoLookupReader,
  })  : _session = session ?? GalHookSessionController.instance,
        _miningCoordinator =
            miningCoordinator ?? GalHookMiningCoordinator.instance,
        _preferenceReader = preferenceReader,
        _preferenceWriter = preferenceWriter,
        _hoverAutoLookupReader = hoverAutoLookupReader;

  static final GalHookTextOverlayController instance =
      GalHookTextOverlayController._();

  @visibleForTesting
  GalHookTextOverlayController.test({
    required GalHookSessionController session,
    GalHookMiningCoordinator? miningCoordinator,
    GalHookPreferenceReader? preferenceReader,
    GalHookPreferenceWriter? preferenceWriter,
    GalHookHoverAutoLookupReader? hoverAutoLookupReader,
  }) : this._(
          session: session,
          miningCoordinator: miningCoordinator,
          preferenceReader: preferenceReader,
          preferenceWriter: preferenceWriter,
          hoverAutoLookupReader: hoverAutoLookupReader,
        );

  static const String _rectPreferenceKey = 'gal_hook_text_window_rect';
  static const String _opacityPreferenceKey = 'gal_hook_text_window_bg_opacity';
  static const double _defaultOpacity = 0.88;

  /// BUG-1095：台词字号的持久化 key。与 [_rectPreferenceKey]（窗口几何）严格分开——
  /// 这两件事以前被 native 的「字号 = 基准 × 窗高比例」耦成一件，正是「放不下拖高
  /// 还是放不下」的根因。范围/默认值的唯一真值在 `PreferencesRepository`。
  static const String _fontSizePreferenceKey = 'gal_hook_text_font_size';

  final GalHookSessionController _session;
  final GalHookMiningCoordinator _miningCoordinator;
  final GalHookPreferenceReader? _preferenceReader;
  final GalHookPreferenceWriter? _preferenceWriter;
  final GalHookHoverAutoLookupReader? _hoverAutoLookupReader;

  AppModel? _appModel;
  bool _started = false;
  bool _visible = false;
  bool _following = true;
  bool _passThrough = false;
  bool _locked = false;
  bool _suppressedForSession = false;
  bool _syncing = false;
  bool _syncAgain = false;

  /// 当前行语音正在试听（浮窗「重播」按钮高亮）。
  bool _replaying = false;
  Timer? _replayResetTimer;

  /// 已推给 native 的语音控件状态，避免每轮 sync 都发一次 channel 调用。
  bool _pushedReplaying = false;
  bool _pushedRecapturing = false;

  /// 已推给 native 的「悬停即查词」值（show 载荷里带过的也算已推）。
  bool _pushedHoverAutoLookup = false;
  int? _sessionKey;
  String? _displayedLineId;
  double _opacity = _defaultOpacity;
  double _lastNonZeroOpacity = _defaultOpacity;
  double _fontSize = kGalHookTextFontSize;
  GalHookTextWindowRect? _savedRect;

  static bool get isSupported =>
      GalHookTextOverlayChannel.supportsCurrentPlatform;

  bool get isVisible => _visible;
  bool get isFollowing => _following;
  bool get isPassThrough => _passThrough;
  bool get isLocked => _locked;
  bool get isSuppressedForSession => _suppressedForSession;
  String? get displayedLineId => _displayedLineId;
  bool get isReplaying => _replaying;
  bool get isRecapturing => _session.isRecapturing;

  /// BUG-1095：当前台词字号（逻辑 px），与窗口高度无关。
  double get fontSize => _fontSize;

  /// 试听兜底复位上限：资源原件（OGG/WAV）时长未知时按它把按钮高亮收回，
  /// 与实时台词列表的行内试听同一上限。
  static const int _replayMaxMs = 15000;

  Future<void> start({required AppModel appModel}) async {
    if (_started || !isSupported) return;
    _started = true;
    _appModel = appModel;
    // 给会话控制器接上 DB：galgame hook 会话据此把游戏时长/字数落 activity_events
    // （首页「游戏」活动的唯一写入方）。惰性解析——flush 时 App 尚未初始化完
    // （或测试替身无 DB）则返回 null 跳过本次落库，不在 start 急切解引用 late 字段。
    _session.attachActivityDatabase(
      () => appModel.isInitialised ? appModel.database : null,
    );
    // 窗口超分编排器：唯一的注入点。档位**每局重新读**（每游戏各自一档，见下）。
    // Magpie 只从 Hibiki 随包归档安装，不持有下载确认 UI。未注入时会话侧全是
    // `?.` 空操作，故这里失败也不致命。
    final MagpieUpscalingService magpie = MagpieUpscalingService(
      modeReader: () => _upscalingModeForCurrentSession(appModel),
    );
    _session.attachMagpieUpscaling(magpie);
    // 每游戏捕获选择记忆（文本线程 / 语音轨 / BGM 排除集）：真值落偏好表，每游戏
    // 一个 key，值是 [GalCaptureMemory] 的 JSON。会话内 id（source_ptr、native
    // thread_id）跨启动全都会变，能持久化的只有弱指纹——错恢复可在工作台一键改，
    // 且用户一改就同步覆盖记忆，见 session 侧注释。
    _session.attachCaptureMemory(
      load: (String gameKey) {
        final Object? stored = appModel.prefsRepo
            .getPref('gal_capture_memory::$gameKey', defaultValue: '');
        if (stored is! String || stored.isEmpty) {
          return const GalCaptureMemory();
        }
        try {
          final Object? decoded = jsonDecode(stored);
          if (decoded is Map) {
            return GalCaptureMemory.fromJson(decoded.cast<Object?, Object?>());
          }
        } catch (_) {}
        return const GalCaptureMemory();
      },
      save: (String gameKey, GalCaptureMemory memory) {
        unawaited(
          appModel.prefsRepo.setPref(
            'gal_capture_memory::$gameKey',
            jsonEncode(memory.toJson()),
          ),
        );
      },
    );
    // 启动期对账：上次崩溃 / 被任务管理器结束时，退出清理根本没跑过，配置里会留着
    // `autoScale=Fullscreen` 的 `Hibiki: ` profile（外加可能还活着的 Magpie 进程）。
    // 不对账 = 用户下次不经 Hibiki 双击游戏也被自动全屏超分。fire-and-forget：它自身
    // 不抛，且没孤儿时是一次读文件的零成本早退。
    unawaited(magpie.reconcileOrphansOnStartup());
    _loadPreferences(appModel);
    GalHookTextOverlayChannel.setEventHandlers(
      onLookupText: _onLookupText,
      onToggleFollow: toggleFollowing,
      onTogglePassThrough: togglePassThrough,
      onToggleTransparency: toggleTransparency,
      onOpenWorkbench: openWorkbench,
      onClose: closeForCurrentSession,
      onReplayVoice: replayCurrentLine,
      onRecaptureVoice: recaptureCurrentLine,
      onLockChanged: _onLockChanged,
      onPassThroughChanged: _onPassThroughChanged,
      onBoundsChanged: _onBoundsChanged,
    );
    _session.addListener(_scheduleSync);
    _scheduleSync();
  }

  @visibleForTesting
  Future<void> stopForTesting() async {
    if (!_started) return;
    _session.removeListener(_scheduleSync);
    GalHookTextOverlayChannel.clearEventHandlers();
    await GalHookTextOverlayChannel.hide();
    _started = false;
    _visible = false;
  }

  /// 本局游戏的窗口超分档位（BUG-1191）。
  ///
  /// 身份取的是**本次会话的启动 exe 全路径**——这正是 galgame 库那一行的 `exePath`，
  /// 也是用户在库里右键改档时改的那一行，两边同一个真值、不会漂。
  ///
  /// 三条边界都落到「关闭」（裁决本身是纯函数 [resolveSessionUpscalingMode]）：
  /// ① 窗口附着捕获（没走启动路径）→ `launchExe` 为空 → 没有稳定游戏身份，不猜；
  /// ② 游戏不在库里（用户从别处拉起的）→ 没有那一行可读；
  /// ③ App 还没初始化完 → 没有 DB。
  /// 任何一条都不该替用户默默打开一个吃 GPU 的东西。
  MagpieUpscalingMode _upscalingModeForCurrentSession(AppModel appModel) {
    if (!appModel.isInitialised) return kMagpieDefaultUpscalingMode;
    final String? exe = _session.state.launchExe;
    final GalgameEntry? game = (exe == null || exe.isEmpty)
        ? null
        : appModel.galgameRepo.byExePath(exe);
    return resolveSessionUpscalingMode(
      launchExe: exe,
      storedModeKey: game?.upscalingMode,
    );
  }

  void _loadPreferences(AppModel appModel) {
    Object? read(String key, Object? fallback) => _preferenceReader != null
        ? _preferenceReader(key, defaultValue: fallback)
        : appModel.prefsRepo.getPref(key, defaultValue: fallback);
    final Object? storedOpacity = read(_opacityPreferenceKey, _defaultOpacity);
    final double stored =
        storedOpacity is num ? storedOpacity.toDouble() : _defaultOpacity;
    _opacity = stored.clamp(0.0, 1.0);
    if (_opacity > 0) _lastNonZeroOpacity = _opacity;
    _fontSize = _readFontSizePreference();
    final Object? storedRect = read(_rectPreferenceKey, '');
    final String encoded = storedRect is String ? storedRect : '';
    if (encoded.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is Map) {
        _savedRect = GalHookTextWindowRect.fromMap(
          decoded.cast<Object?, Object?>(),
        );
      }
    } catch (_) {
      _savedRect = null;
    }
  }

  /// BUG-1095：读台词字号偏好（逻辑 px）。范围钳位与默认值的唯一真值在
  /// [PreferencesRepository]；这里只负责取值并按同一区间收敛脏数据。
  double _readFontSizePreference() {
    const double fallback = PreferencesRepository.galHookTextFontSizeDefault;
    final AppModel? model = _appModel;
    final Object? stored = _preferenceReader != null
        ? _preferenceReader(_fontSizePreferenceKey, defaultValue: fallback)
        : model?.prefsRepo
            .getPref(_fontSizePreferenceKey, defaultValue: fallback);
    final double value = stored is num ? stored.toDouble() : fallback;
    return value.clamp(
      PreferencesRepository.galHookTextFontSizeMin,
      PreferencesRepository.galHookTextFontSizeMax,
    );
  }

  void _scheduleSync() {
    if (!_started) return;
    _syncAgain = true;
    if (_syncing) return;
    _syncing = true;
    unawaited(_drainSync());
  }

  Future<void> _drainSync() async {
    try {
      while (_syncAgain) {
        _syncAgain = false;
        await _syncFromSession();
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncFromSession() async {
    final GalHookSessionState state = _session.state;
    final int? nextSessionKey = state.sessionStartedAt?.microsecondsSinceEpoch;
    if (nextSessionKey != null && nextSessionKey != _sessionKey) {
      _sessionKey = nextSessionKey;
      _suppressedForSession = false;
      _following = true;
      _passThrough = false;
      _locked = false;
      _displayedLineId = null;
      // 新会话：上一局的试听计时不能把高亮留在新浮窗上。
      _replayResetTimer?.cancel();
      _replayResetTimer = null;
      _replaying = false;
      await GalHookTextOverlayChannel.setFollowing(true);
      await GalHookTextOverlayChannel.setPassThrough(false);
      await GalHookTextOverlayChannel.setLocked(false);
      notifyListeners();
    }

    final bool active = state.externalWindowMode &&
        nextSessionKey != null &&
        state.phase != GalHookSessionPhase.idle &&
        state.phase != GalHookSessionPhase.stopping &&
        state.phase != GalHookSessionPhase.error;
    if (!active) {
      if (_visible) {
        await GalHookTextOverlayChannel.hide();
        _visible = false;
        // 浮窗收起后试听高亮无处可显示，本地状态跟着收——否则下次 show 会把一个
        // 早已播完的试听态推给新窗口。
        _replayResetTimer?.cancel();
        _replayResetTimer = null;
        _replaying = false;
        notifyListeners();
      }
      if (nextSessionKey == null) _sessionKey = null;
      return;
    }
    if (_suppressedForSession) return;

    final List<TexthookerLineEntry> lines = _session.selectedSessionLines;
    if (lines.isEmpty) return;
    final TexthookerLineEntry latest = lines.last;
    if (!_visible) {
      await GalHookTextOverlayChannel.updateText(
        lineId: latest.id,
        text: latest.text,
        rubySpans: rubySpansToChannel(latest.rubySpans),
      );
      final bool hoverAutoLookup = _readHoverAutoLookup();
      _visible = await GalHookTextOverlayChannel.show(
        rect: _savedRect,
        fontSize: _fontSize,
        bgColor: _backgroundColor,
        following: _following,
        passThrough: _passThrough,
        locked: _locked,
        hoverAutoLookup: hoverAutoLookup,
      );
      _pushedHoverAutoLookup = hoverAutoLookup;
      // native 在 show 里把语音控件复位（见 flutter_window.cpp），本地镜像跟着复位，
      // 否则下一次 _syncVoiceState 会认为「已经推过了」而不再推。
      _pushedReplaying = false;
      _pushedRecapturing = false;
      if (_visible) _displayedLineId = latest.id;
      notifyListeners();
      await _syncVoiceState();
      return;
    }
    if (_following && latest.id != _displayedLineId) {
      await GalHookTextOverlayChannel.updateText(
        lineId: latest.id,
        text: latest.text,
        rubySpans: rubySpansToChannel(latest.rubySpans),
      );
      _displayedLineId = latest.id;
      notifyListeners();
    }
    // 补录窗口可能由 session 侧超时自行收束：每轮都比对一次，浮窗上的「录音中」
    // 高亮才不会停在已结束的状态上。
    await _syncVoiceState();
  }

  int get _backgroundColor {
    final int alpha = (_opacity.clamp(0.0, 1.0) * 255).round();
    return alpha << 24;
  }

  Future<void> showManually() async {
    if (!_started) return;
    _suppressedForSession = false;
    _visible = false;
    notifyListeners();
    _scheduleSync();
  }

  Future<void> closeForCurrentSession() async {
    if (!_started) return;
    _suppressedForSession = true;
    await GalHookTextOverlayChannel.hide();
    _visible = false;
    notifyListeners();
  }

  Future<void> toggleFollowing() async {
    _following = !_following;
    await GalHookTextOverlayChannel.setFollowing(_following);
    notifyListeners();
    if (_following) _scheduleSync();
  }

  Future<void> togglePassThrough() async {
    _passThrough = !_passThrough;
    await GalHookTextOverlayChannel.setPassThrough(_passThrough);
    notifyListeners();
  }

  Future<void> toggleTransparency() async {
    if (_opacity > 0) {
      _lastNonZeroOpacity = _opacity;
      _opacity = 0;
    } else {
      _opacity =
          _lastNonZeroOpacity > 0 ? _lastNonZeroOpacity : _defaultOpacity;
    }
    final AppModel? model = _appModel;
    if (model != null) {
      if (_preferenceWriter != null) {
        await _preferenceWriter(_opacityPreferenceKey, _opacity);
      } else {
        await model.prefsRepo.setPref(_opacityPreferenceKey, _opacity);
      }
    }
    await GalHookTextOverlayChannel.updateStyle(
      bgColor: _backgroundColor,
      fontSize: _fontSize,
    );
    notifyListeners();
  }

  /// BUG-1095：把字号偏好重新读进来并立刻推给 native 浮窗。
  ///
  /// 设置页写偏好（`AppModel.setGalHookTextFontSize`）后调用本方法，与悬浮字幕的
  /// 「setFloatingLyricFontSize + applyFloatingLyricStyle」同款纪律：漏掉这一步字号
  /// 只落了盘，浮窗要等下一次改透明度才顺带刷新。窗口几何完全不动——这正是修复的
  /// 要点：拖窗只改窗口大小（换来更多可见行），字号只由这条偏好决定。
  Future<void> applyFontSizeFromPreferences() async {
    // 未 start（非 Windows / 测试替身 / 初始化尚未走到）时没有偏好源也没有 native
    // 窗口可推；start() 自己会读一次最新值，这里静默返回即可。
    if (!_started) return;
    final double next = _readFontSizePreference();
    if (next == _fontSize) return;
    _fontSize = next;
    await GalHookTextOverlayChannel.updateStyle(
      bgColor: _backgroundColor,
      fontSize: next,
    );
    notifyListeners();
  }

  /// 「悬停即查词」当前值。默认真值在 [ReaderHibikiSource]（与阅读器 / 视频字幕
  /// 同一个开关），测试可注入替身。
  bool _readHoverAutoLookup() {
    final GalHookHoverAutoLookupReader? reader = _hoverAutoLookupReader;
    if (reader != null) return reader();
    return ReaderHibikiSource.instance.hoverAutoLookup;
  }

  /// BUG-756b 同款纪律：设置页改完「悬停即查词」后调用，把最新值推给已经开着的
  /// native 浮窗。漏掉这一步，用户得关掉浮窗重开才生效。
  ///
  /// Shift-悬停查词不受这个开关控制（它是查词的通用手势，始终可用）；本开关只决定
  /// 「不按 Shift 也查」。
  Future<void> applyHoverAutoLookupFromPreferences() async {
    if (!_started) return;
    final bool next = _readHoverAutoLookup();
    if (next == _pushedHoverAutoLookup) return;
    _pushedHoverAutoLookup = next;
    await GalHookTextOverlayChannel.setHoverAutoLookup(next);
  }

  Future<void> _onLockChanged(bool locked) async {
    _locked = locked;
    notifyListeners();
  }

  /// native 拒绝进入穿透（逃生工具条窗建不出来）时的对账（BUG-951）。不跟着退回，
  /// Dart 的标志会卡在 true，用户下一次按 `↗` 只会发一条 setPassThrough(false)
  /// 到已经是 false 的 native —— 表现成「点了没反应」。
  Future<void> _onPassThroughChanged(bool passThrough) async {
    if (_passThrough == passThrough) return;
    _passThrough = passThrough;
    notifyListeners();
  }

  Future<void> _onBoundsChanged(GalHookTextWindowRect rect) async {
    _savedRect = rect;
    final AppModel? model = _appModel;
    if (model != null) {
      final String value = jsonEncode(rect.toMap());
      if (_preferenceWriter != null) {
        await _preferenceWriter(_rectPreferenceKey, value);
      } else {
        await model.prefsRepo.setPref(_rectPreferenceKey, value);
      }
    }
  }

  /// 浮窗「重播」：试听当前显示行已配的语音；正在试听时再点即停止。
  /// 只读既有配对结果（资源原件直接播，PCM/loopback 冻结切片拼 WAV），不改行状态。
  Future<void> replayCurrentLine() async {
    if (!_started) return;
    if (_replaying) {
      await _stopReplay();
      return;
    }
    final String? lineId = _displayedLineId;
    if (lineId == null) {
      HibikiToast.show(
        msg: t.game_hook_line_unavailable,
        severity: ToastSeverity.error,
      );
      return;
    }
    final GalTrackPreview? preview =
        await _session.exportLineAudioPreview(lineId);
    if (preview == null) {
      HibikiToast.show(
        msg: t.game_line_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!await DesktopAudioPlayback.playFile(preview.filePath)) {
      HibikiToast.show(
        msg: t.game_line_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _replaying = true;
    _replayResetTimer?.cancel();
    _replayResetTimer = Timer(
      Duration(
        milliseconds:
            preview.durationMs > 0 ? preview.durationMs + 300 : _replayMaxMs,
      ),
      () {
        _replaying = false;
        unawaited(_syncVoiceState());
        notifyListeners();
      },
    );
    await _syncVoiceState();
    notifyListeners();
  }

  Future<void> _stopReplay() async {
    _replayResetTimer?.cancel();
    _replayResetTimer = null;
    _replaying = false;
    await DesktopAudioPlayback.stop();
    await _syncVoiceState();
    notifyListeners();
  }

  /// 浮窗「重播并录音」：为当前显示行开一段补录窗口——用户随后在游戏里重播这句
  /// 语音（回退/重听），窗口内录到的系统声音就绑定到这一行，覆盖此前配错或缺失的
  /// 语音。正在补录时再点即立刻收束。
  Future<void> recaptureCurrentLine() async {
    if (!_started) return;
    if (_session.isRecapturing) {
      final bool saved = await _session.finishLineRecapture();
      HibikiToast.show(
        msg: saved ? t.game_hook_recapture_saved : t.game_hook_recapture_empty,
        // 补录窗口空手而归不是崩溃，是「这次没录到」——warning 而非 error。
        severity: saved ? ToastSeverity.success : ToastSeverity.warning,
      );
      await _syncVoiceState();
      notifyListeners();
      return;
    }
    final String? lineId = _displayedLineId;
    if (lineId == null) {
      HibikiToast.show(
        msg: t.game_hook_line_unavailable,
        severity: ToastSeverity.error,
      );
      return;
    }
    final bool started = await _session.startLineRecapture(lineId);
    HibikiToast.show(
      msg: started
          ? t.game_hook_recapture_started
          : t.game_hook_recapture_unavailable,
      // 开录是「去游戏里重播这句」的操作指示（info）；开不起来是能力缺失（error）。
      severity: started ? ToastSeverity.info : ToastSeverity.error,
    );
    await _syncVoiceState();
    notifyListeners();
  }

  /// 把语音控件状态推给浮窗（只在变化时发 channel 调用）。补录窗口也可能由 session
  /// 侧超时自行收束，所以每轮 sync 都比对一次。
  Future<void> _syncVoiceState() async {
    final bool replaying = _replaying;
    final bool recapturing = _session.isRecapturing;
    if (replaying == _pushedReplaying && recapturing == _pushedRecapturing) {
      return;
    }
    _pushedReplaying = replaying;
    _pushedRecapturing = recapturing;
    await GalHookTextOverlayChannel.setVoiceState(
      replaying: replaying,
      recapturing: recapturing,
    );
  }

  Future<void> openWorkbench() async {
    homeShellTabNotifier.value = HomeTab.games;
    gameSectionNotifier.value = GameSection.monitor;
    await DesktopLookupService.instance.bringMainWindowToFront();
  }

  Future<void> _onLookupText(
    String lineId,
    String text,
    int index,
    Rect? wordRect,
  ) async {
    final AppModel? model = _appModel;
    final TexthookerLineEntry? entry = _session.entryById(lineId);
    if (model == null ||
        entry == null ||
        entry.text != text ||
        !_session.isLineInCurrentSession(entry)) {
      HibikiToast.show(
        msg: t.game_hook_line_unavailable,
        severity: ToastSeverity.error,
      );
      return;
    }
    final String term = JapaneseLanguage.instance
        .wordFromIndex(text: entry.text, index: index)
        .trim();
    if (term.isEmpty) return;
    await GlobalLookupController.instance.lookupText(
      term,
      sentence: entry.text,
      // 卡片锚在被点中的那个词上（native 给的屏幕逻辑 px 矩形），而不是鼠标位置：
      // 浮窗里点词跟阅读器/剪贴板面板一样是「点哪个词看哪个词」。老 native 不带
      // 矩形时为 null，自动回落到光标定位。
      anchorScreenRect: wordRect,
      miningHandler: ({
        required Map<String, String> fields,
        int? updateNoteId,
      }) =>
          _mineFromLookup(
        lineId: entry.id,
        fields: fields,
        updateNoteId: updateNoteId,
      ),
    );
  }

  Future<Map<String, Object?>> _mineFromLookup({
    required String lineId,
    required Map<String, String> fields,
    required int? updateNoteId,
  }) async {
    final AppModel? model = _appModel;
    if (model == null) {
      return const <String, Object?>{
        'ankiConnect': false,
        'noteId': null,
      };
    }
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final BaseAnkiRepository repo =
        model.platformServices.createAnkiRepository();
    final GalHookMiningResult result = await _miningCoordinator.mineLine(
      lineId: lineId,
      fields: fields,
      compression: MiningMediaCompression.resolve(
        imageTier: model.miningImageQuality,
        audioTier: model.miningAudioQuality,
        format: model.galMiningAnimatedFormat,
      ),
      repo: repo,
      updateNoteId: updateNoteId,
      addTitleTag: model.autoAddBookNameToTags,
      // gal 制卡有两个入口：本浮窗与 texthooker 页。两处必须逐字同形地透传同一组
      // 偏好，否则同一个设置在一个入口生效、另一个入口静默用默认值（协调器的
      // `imageMode`/`animatedFormat` 默认 gif 会把漏传吞成「看着正常的旧行为」）。
      imageMode: model.galMiningImageMode,
      animatedFormat: model.galMiningAnimatedFormat,
    );
    if (result.aborted) {
      HibikiToast.showMine(
        msg:
            '${t.external_window_capture_failed}：${result.failureReason ?? ''}',
        status: MineToastStatus.failed,
      );
      return result.toPopupReply();
    }
    final MineOutcome outcome = result.outcome!;
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(
      outcome,
      deckName: deckName,
      overwrite: updateNoteId != null,
    );
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (result.sentenceAudioMissing) {
      // 卡片建成了、只是缺句子音频 = 部分成功。
      HibikiToast.show(
        msg: t.game_card_sentence_audio_missing,
        severity: ToastSeverity.warning,
      );
    }
    if (result.unmappedTokens.isNotEmpty) {
      HibikiToast.show(
        msg: '${t.game_card_mapping_missing}: '
            '${result.unmappedTokens.join(', ')}',
        severity: ToastSeverity.warning,
      );
    }
    return result.toPopupReply();
  }
}

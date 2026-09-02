import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/magpie_upscaling.dart';
import 'package:fushi/src/mining/magpie_upscaling_service.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;

typedef GalHookPreferenceReader =
    Object? Function(String key, {required Object? defaultValue});
typedef GalHookPreferenceWriter =
    Future<void> Function(String key, Object? value);

/// 「悬停即查词」开关的读取口（设置项 `hover_auto_lookup`）。真值在
/// [ReaderFushiSource]（media source 偏好store，与本控制器用的 prefsRepo 不是同一
/// 个存储），所以单独开一条读取口而不是复用 [GalHookPreferenceReader]。
typedef GalHookHoverAutoLookupReader = bool Function();

/// App 级 Windows Hook 台词浮窗控制器。
class GalHookTextOverlayController extends ChangeNotifier {
  static const Duration _geometryAdmissionTimeout = Duration(seconds: 1);
  static const Duration _attachedSyncTimeout = Duration(seconds: 2);

  GalHookTextOverlayController._({
    GalHookSessionController? session,
    GalHookMiningCoordinator? miningCoordinator,
    GalHookPreferenceReader? preferenceReader,
    GalHookPreferenceWriter? preferenceWriter,
    GalHookHoverAutoLookupReader? hoverAutoLookupReader,
    GalIngameLookupController? ingameLookup,
    GalAttachedTextController? attachedText,
  }) : _session = session ?? GalHookSessionController.instance,
       _miningCoordinator =
           miningCoordinator ?? GalHookMiningCoordinator.instance,
       _preferenceReader = preferenceReader,
       _preferenceWriter = preferenceWriter,
       _hoverAutoLookupReader = hoverAutoLookupReader,
       _ingameLookup = ingameLookup ?? GalIngameLookupController.instance {
    _attachedText =
        attachedText ??
        GalAttachedTextController(
          preferenceReader: (String key) => _readPreference(key, ''),
          preferenceWriter: _writeAttachedPreference,
          onBeforeAttachedActivation: _beforeAttachedActivation,
          onLookup: _onAttachedLookupText,
        );
  }

  static final GalHookTextOverlayController instance =
      GalHookTextOverlayController._();

  @visibleForTesting
  GalHookTextOverlayController.test({
    required GalHookSessionController session,
    GalHookMiningCoordinator? miningCoordinator,
    GalHookPreferenceReader? preferenceReader,
    GalHookPreferenceWriter? preferenceWriter,
    GalHookHoverAutoLookupReader? hoverAutoLookupReader,
    GalIngameLookupController? ingameLookup,
    GalAttachedTextController? attachedText,
  }) : this._(
         session: session,
         miningCoordinator: miningCoordinator,
         preferenceReader: preferenceReader,
         preferenceWriter: preferenceWriter,
         hoverAutoLookupReader: hoverAutoLookupReader,
         ingameLookup: ingameLookup,
         attachedText: attachedText,
       );

  static const String _rectPreferenceKey = 'gal_hook_text_window_rect';
  static const String _opacityPreferenceKey = 'gal_hook_text_window_bg_opacity';

  /// 桌面歌词式重写：native 侧 hook 模式文字已自带描边 + 投影，可读性不再依赖
  /// 底板，默认背景与音乐播放器桌面歌词一致——全透明。存过偏好的用户保持原值
  /// （never break userspace）；`◐` 一键切底板时恢复到 [_defaultRestoreOpacity]。
  static const double _defaultOpacity = 0.0;
  static const double _defaultRestoreOpacity = 0.6;

  /// BUG-1095：台词字号的持久化 key。与 [_rectPreferenceKey]（窗口几何）严格分开——
  /// 这两件事以前被 native 的「字号 = 基准 × 窗高比例」耦成一件，正是「放不下拖高
  /// 还是放不下」的根因。范围/默认值的唯一真值在 `PreferencesRepository`。
  static const String _fontSizePreferenceKey = 'gal_hook_text_font_size';
  static const String _letterSpacingPreferenceKey =
      'gal_hook_text_letter_spacing';
  static const String _lineHeightPreferenceKey = 'gal_hook_text_line_height';
  static const String _boldPreferenceKey = 'gal_hook_text_bold';
  static const String _alignmentPreferenceKey = 'gal_hook_text_alignment';
  static const String _verticalAlignmentPreferenceKey =
      'gal_hook_text_vertical_alignment';
  static const String _textColorPreferenceKey = 'gal_hook_text_color';
  static const String _backgroundColorPreferenceKey =
      'gal_hook_text_background_color';
  static const String _outlineColorPreferenceKey =
      'gal_hook_text_outline_color';
  static const String _outlineWidthPreferenceKey =
      'gal_hook_text_outline_width';
  static const String _paddingPreferenceKey = 'gal_hook_text_padding';
  static const String _cornerRadiusPreferenceKey =
      'gal_hook_text_corner_radius';

  final GalHookSessionController _session;
  final GalHookMiningCoordinator _miningCoordinator;
  final GalHookPreferenceReader? _preferenceReader;
  final GalHookPreferenceWriter? _preferenceWriter;
  final GalHookHoverAutoLookupReader? _hoverAutoLookupReader;

  /// 游戏内查词编排器（KiriKiri in-game lookup）。本控制器是 galgame hook 在 Dart
  /// 侧的接线中心（持有 AppModel、会话监听与 gal channel 的 handler 表），所以由它
  /// 启动并喂养它——不另起第二条会话监听、不复制第二份制卡链。
  final GalIngameLookupController _ingameLookup;

  /// Per-game calibrated transparent hit layer. It is a child state machine of
  /// this controller and never subscribes to [GalHookSessionController] itself.
  late final GalAttachedTextController _attachedText;

  AppModel? _appModel;
  bool _started = false;
  bool _visible = false;
  bool _following = true;
  bool _passThrough = false;
  bool _locked = false;
  bool _suppressedForSession = false;
  bool _syncing = false;
  bool _syncAgain = false;
  int _syncRevision = 0;
  String _sessionSyncIdentity = '';
  String _attachedRoutingKey = '';
  Timer? _syncRetryTimer;
  int _syncRetryAttempt = 0;

  Future<void>? _attachedSyncInFlight;
  ({
    bool active,
    int? sessionEpoch,
    int targetPid,
    int targetHwnd,
    String sourceText,
    String launchExePath,
    bool inspectOnly,
  })?
  _attachedSyncDesiredRequest;
  bool _attachedSyncNeedsReconcile = false;

  /// 上一局查词 route 尚未退役完成。`_sessionKey` 可以先提交（台词浮窗不该被
  /// 查词侧连坐），退役由后续 sync 按这张单子继续重试；在它清掉之前本轮不许
  /// 武装任何新的查词 route。
  bool _lookupRetirementPending = false;

  Future<GalLookupCallResult>? _geometrySyncInFlight;
  ({GalLookupGeometryAdmissionMode mode, bool attachedReady})?
  _geometrySyncDesiredRequest;
  bool _geometrySyncNeedsReconcile = false;

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

  /// 与 [_displayedLineId] 配对的文本镜像：折叠后同一句的后续快照不产生新 id，
  /// 只比 id 的话浮窗会永远停在这句的第一段上。
  String? _displayedLineText;

  /// 游戏内查词用的「会话最新行」镜像，与 [_displayedLineId]（浮窗显示的那行）分开：
  /// 浮窗被关掉时仍要能观察新文本事件。ID 只是触发镜像；是否真换句
  /// 由 [GalIngameLookupController.onLineChanged] 用当前 submit 的句子内容裁决。
  String? _ingameLatestLineId;

  /// 与 [_ingameLatestLineId] 配对的文本镜像。同一句被引擎分多次吐出来时会**就地
  /// 扩写**（id 不变、文本变长），只比 id 会让游戏内卡片继续挂在旧排版的字形坐标上。
  String? _ingameLatestLineText;
  double _opacity = _defaultOpacity;
  double _lastNonZeroOpacity = _defaultRestoreOpacity;
  double _fontSize = kGalHookTextFontSize;
  double _letterSpacing = PreferencesRepository.galHookTextLetterSpacingDefault;
  double _lineHeight = PreferencesRepository.galHookTextLineHeightDefault;
  bool _bold = true;
  String _textAlignment = 'center';
  String _verticalAlignment = 'center';
  int _textColor = PreferencesRepository.galHookTextColorDefault;
  int _backgroundBaseColor =
      PreferencesRepository.galHookTextBackgroundColorDefault;
  int _outlineColor = PreferencesRepository.galHookTextOutlineColorDefault;
  double _outlineWidth = PreferencesRepository.galHookTextOutlineWidthDefault;
  double _textPadding = PreferencesRepository.galHookTextPaddingDefault;
  double _cornerRadius = PreferencesRepository.galHookTextCornerRadiusDefault;
  ({String family, String? path})? _fontSelection;
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
  GalAttachedTextController get attachedText => _attachedText;

  /// BUG-1095：当前台词字号（逻辑 px），与窗口高度无关。
  double get fontSize => _fontSize;

  /// First usable font selected for the managed `gameLookup` target. Imported
  /// files keep their path because the native DirectWrite renderer cannot see
  /// Flutter's process-private font registrations.
  ({String family, String? path})? get fontSelection => _fontSelection;

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
        final Object? stored = appModel.prefsRepo.getPref(
          'gal_capture_memory::$gameKey',
          defaultValue: '',
        );
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
    await _ingameLookup.start(
      appModel: appModel,
      miningResolver: _ingameMiningHandlerFor,
      preferenceReader: _preferenceReader,
    );
    GalHookTextOverlayChannel.setEventHandlers(
      onLookupText: _onLookupText,
      onToggleFollow: toggleFollowing,
      onTogglePassThrough: togglePassThrough,
      onToggleTransparency: toggleTransparency,
      onOpenWorkbench: openWorkbench,
      onClose: closeForCurrentSession,
      onOverlayDestroyed: _onOverlayDestroyed,
      onReplayVoice: replayCurrentLine,
      onRecaptureVoice: recaptureCurrentLine,
      onLockChanged: _onLockChanged,
      onPassThroughChanged: _onPassThroughChanged,
      onBoundsChanged: _onBoundsChanged,
      // 游戏内查词：hook 报命中 / 转发卡片内输入，两条都直通编排器，本控制器不解释。
      onGalLookupHit: _ingameLookup.handleHit,
      onGalLookupInput: _ingameLookup.handleInput,
      // attached surface 复用同一个 MethodChannel listener；子控制器只收类型化事件，
      // 不自行 setMethodCallHandler，也不订阅第二条 session listener。
      onAttachedLookupText: _attachedText.handleLookupText,
      onAttachedSurfaceStateChanged: _attachedText.handleSurfaceStateChanged,
      onAttachedCalibrationCommitted: _attachedText.handleCalibrationCommitted,
      onAttachedCalibrationCancelled: _attachedText.handleCalibrationCancelled,
      // 查词准入（v19）：与开关正交，runner 在会话在的时候一直报。设置页据此决定
      // 「游戏内查词」那一行灰不灰、说什么。
      onGalLookupAdmission: _ingameLookup.handleAdmission,
    );
    _attachedRoutingKey = _currentAttachedRoutingKey;
    _sessionSyncIdentity = _currentSessionSyncIdentity;
    _attachedText.addListener(_onAttachedRoutingChanged);
    _session.addListener(_scheduleSessionSync);
    // 上一轮 stop 若在拆解中途异常退出，这张单子可能还挂着；新一轮不继承旧债。
    _lookupRetirementPending = false;
    _scheduleSync();
  }

  @visibleForTesting
  Future<void> stopForTesting() async {
    if (!_started) return;
    _started = false;
    _syncRevision++;
    _syncRetryTimer?.cancel();
    _syncRetryTimer = null;
    _syncRetryAttempt = 0;
    _session.removeListener(_scheduleSessionSync);
    _attachedText.removeListener(_onAttachedRoutingChanged);
    GalHookTextOverlayChannel.clearEventHandlers();
    await _attachedText.detach();
    // 停机拆解是一串**互不依赖**的边，必须每条都走到：原来是裸串联，
    // setProviderAdmission 的严格退役一抛（截图静默窗内 requireNativeAck 没有
    // 成功路径），后面的 geometry disable / setSessionActive / hide / 状态复位
    // 就整段被跳过，浮窗留在屏上、镜像停在 true。逐条吞异常——这里已经在停机
    // 路径上，原始异常没有任何人能处置。
    await _setProviderAdmissionIsolated(false);
    for (final Future<void> Function() edge in <Future<void> Function()>[
      () => _ingameLookup.setGeometryAdmission(
        GalLookupGeometryAdmissionMode.disabled,
        attachedReady: false,
      ),
      () => _ingameLookup.setSessionActive(false),
      GalHookTextOverlayChannel.hide,
    ]) {
      try {
        await edge();
      } catch (error, stackTrace) {
        glog('gal-overlay: stop teardown edge EXCEPTION $error\n$stackTrace');
      }
    }
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
    final Object? storedOpacity = _readPreference(
      _opacityPreferenceKey,
      _defaultOpacity,
    );
    final double stored = storedOpacity is num
        ? storedOpacity.toDouble()
        : _defaultOpacity;
    _opacity = stored.clamp(0.0, 1.0);
    if (_opacity > 0) _lastNonZeroOpacity = _opacity;
    _readAppearancePreferences();
    _fontSelection = _readFontSelection();
    final Object? storedRect = _readPreference(_rectPreferenceKey, '');
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

  Object? _readPreference(String key, Object? fallback) {
    final GalHookPreferenceReader? reader = _preferenceReader;
    if (reader != null) return reader(key, defaultValue: fallback);
    return _appModel?.prefsRepo.getPref(key, defaultValue: fallback) ??
        fallback;
  }

  Future<void> _writeAttachedPreference(String key, Object? value) async {
    final GalHookPreferenceWriter? writer = _preferenceWriter;
    if (writer != null) {
      await writer(key, value);
      return;
    }
    await _appModel?.prefsRepo.setPref(key, value);
  }

  GalLookupTextLayoutV1 _attachedLayoutFor(
    GalLookupReferenceClientV1 referenceClient,
  ) {
    final double height = referenceClient.heightPx.toDouble();
    return GalLookupTextLayoutV1(
      fontFamily: _fontSelection?.family ?? '',
      fontSizePerClientHeight: _fontSize / height,
      letterSpacingPerClientHeight: _letterSpacing / height,
      lineHeight: _lineHeight,
      textAlign: _textAlignment,
      verticalAlign: _verticalAlignment,
      paddingPerClientHeight: _textPadding / height,
    );
  }

  double _readDouble(
    String key, {
    required double fallback,
    required double min,
    required double max,
  }) {
    final Object? stored = _readPreference(key, fallback);
    final double value = stored is num ? stored.toDouble() : fallback;
    return value.clamp(min, max);
  }

  int _readColor(String key, int fallback) {
    final Object? stored = _readPreference(key, fallback);
    return ((stored is num ? stored.toInt() : fallback) & 0xFFFFFFFF).toInt();
  }

  void _readAppearancePreferences() {
    _fontSize = _readFontSizePreference();
    _letterSpacing = _readDouble(
      _letterSpacingPreferenceKey,
      fallback: PreferencesRepository.galHookTextLetterSpacingDefault,
      min: PreferencesRepository.galHookTextLetterSpacingMin,
      max: PreferencesRepository.galHookTextLetterSpacingMax,
    );
    _lineHeight = _readDouble(
      _lineHeightPreferenceKey,
      fallback: PreferencesRepository.galHookTextLineHeightDefault,
      min: PreferencesRepository.galHookTextLineHeightMin,
      max: PreferencesRepository.galHookTextLineHeightMax,
    );
    _bold = _readPreference(_boldPreferenceKey, true) == true;
    _textAlignment =
        _readPreference(_alignmentPreferenceKey, 'center') == 'left'
        ? 'left'
        : 'center';
    _verticalAlignment =
        _readPreference(_verticalAlignmentPreferenceKey, 'center') == 'top'
        ? 'top'
        : 'center';
    _textColor = _readColor(
      _textColorPreferenceKey,
      PreferencesRepository.galHookTextColorDefault,
    );
    _backgroundBaseColor = _readColor(
      _backgroundColorPreferenceKey,
      PreferencesRepository.galHookTextBackgroundColorDefault,
    );
    _outlineColor = _readColor(
      _outlineColorPreferenceKey,
      PreferencesRepository.galHookTextOutlineColorDefault,
    );
    _outlineWidth = _readDouble(
      _outlineWidthPreferenceKey,
      fallback: PreferencesRepository.galHookTextOutlineWidthDefault,
      min: PreferencesRepository.galHookTextOutlineWidthMin,
      max: PreferencesRepository.galHookTextOutlineWidthMax,
    );
    _textPadding = _readDouble(
      _paddingPreferenceKey,
      fallback: PreferencesRepository.galHookTextPaddingDefault,
      min: PreferencesRepository.galHookTextPaddingMin,
      max: PreferencesRepository.galHookTextPaddingMax,
    );
    _cornerRadius = _readDouble(
      _cornerRadiusPreferenceKey,
      fallback: PreferencesRepository.galHookTextCornerRadiusDefault,
      min: PreferencesRepository.galHookTextCornerRadiusMin,
      max: PreferencesRepository.galHookTextCornerRadiusMax,
    );
  }

  /// BUG-1095：读台词字号偏好（逻辑 px）。范围钳位与默认值的唯一真值在
  /// [PreferencesRepository]；这里只负责取值并按同一区间收敛脏数据。
  double _readFontSizePreference() {
    const double fallback = PreferencesRepository.galHookTextFontSizeDefault;
    final AppModel? model = _appModel;
    final Object? stored = _preferenceReader != null
        ? _preferenceReader(_fontSizePreferenceKey, defaultValue: fallback)
        : model?.prefsRepo.getPref(
            _fontSizePreferenceKey,
            defaultValue: fallback,
          );
    final double value = stored is num ? stored.toDouble() : fallback;
    return value.clamp(
      PreferencesRepository.galHookTextFontSizeMin,
      PreferencesRepository.galHookTextFontSizeMax,
    );
  }

  ({String family, String? path})? _readFontSelection() {
    final AppModel? model = _appModel;
    final ReaderSettings? settings = ReaderFushiSource.readerSettings;
    if (model == null || settings == null) return null;
    return AppFontLoader.resolveForNativeOverlay(
      settings.gameLookupFonts,
      allowedDirectories: <String>[
        p.join(model.appDirectory.path, 'custom_fonts'),
      ],
    );
  }

  void _scheduleSync({bool resetRetryBackoff = true}) {
    if (!_started) return;
    if (resetRetryBackoff) {
      _syncRetryTimer?.cancel();
      _syncRetryTimer = null;
      _syncRetryAttempt = 0;
    }
    _syncRevision++;
    _queueSync();
  }

  void _scheduleSessionSync() {
    if (!_started) return;
    final String nextIdentity = _currentSessionSyncIdentity;
    if (nextIdentity != _sessionSyncIdentity) {
      _sessionSyncIdentity = nextIdentity;
      _syncRetryTimer?.cancel();
      _syncRetryTimer = null;
      _syncRetryAttempt = 0;
      _syncRevision++;
    }
    // Line/audio snapshots are intentionally coalesced without invalidating
    // the lifecycle round. Otherwise a chatty text hook can keep cancelling a
    // slower attached inspection before lookup_enabled is ever reconciled.
    _queueSync();
  }

  void _queueSync() {
    _syncAgain = true;
    if (_syncing) return;
    _syncing = true;
    unawaited(_drainSync());
  }

  void _scheduleSyncRetry() {
    if (!_started || _syncRetryTimer?.isActive == true) return;
    final int shift = _syncRetryAttempt > 4 ? 4 : _syncRetryAttempt;
    final Duration delay = Duration(milliseconds: 500 * (1 << shift));
    _syncRetryAttempt++;
    _syncRetryTimer = Timer(delay, () {
      _syncRetryTimer = null;
      _scheduleSync(resetRetryBackoff: false);
    });
  }

  void _clearSyncRetry() {
    _syncRetryTimer?.cancel();
    _syncRetryTimer = null;
    _syncRetryAttempt = 0;
  }

  String get _currentSessionSyncIdentity {
    final GalHookSessionState state = _session.state;
    return '${state.sessionStartedAt?.microsecondsSinceEpoch}:'
        '${state.phase.index}:${state.externalWindowMode}:'
        '${state.gamePid}:${state.boundWindow?.pid}:'
        '${state.boundWindow?.hwnd}:${state.launchExe}';
  }

  String get _currentAttachedRoutingKey =>
      '${(_attachedText.profile?.mode ?? GalLookupSurfaceMode.auto).wireName}:'
      '${_attachedText.status.name}:'
      '${_attachedText.attachedProviderClaimed}:'
      '${_attachedText.forceAttachedProvider}';

  void _onAttachedRoutingChanged() {
    final String next = _currentAttachedRoutingKey;
    if (next == _attachedRoutingKey) return;
    _attachedRoutingKey = next;
    // Child status/claim notifications are outputs of the current lifecycle
    // round, not a new session identity. Invalidating [_syncRevision] here
    // makes the in-flight inspect call fail its own `stillCurrent` guard as
    // soon as it publishes `resolvingTarget`. Coalesce one follow-up pass in
    // the same revision; real preference/session edges still use
    // [_scheduleSync] and invalidate stale work explicitly.
    _queueSync();
  }

  bool _nativeProviderAdmitted(
    GalLookupSurfaceMode mode,
    GalAttachedTextStatus status,
  ) {
    switch (mode) {
      case GalLookupSurfaceMode.off:
      case GalLookupSurfaceMode.attachedOnly:
        return false;
      case GalLookupSurfaceMode.nativeOnly:
      case GalLookupSurfaceMode.auto:
        // activeNative is assigned only after kind/id/status coherence and the
        // verified-or-per-exe-risk shield gate both pass. Pending, calibration,
        // risk and fault states therefore fail closed instead of accepting a
        // native hit merely because no attached box is currently visible.
        return status == GalAttachedTextStatus.activeNative;
    }
  }

  static GalLookupGeometryAdmissionMode _geometryAdmissionMode(
    GalLookupSurfaceMode mode, {
    required bool forceAttached,
  }) {
    if (forceAttached) return GalLookupGeometryAdmissionMode.attachedOnly;
    return switch (mode) {
      GalLookupSurfaceMode.off => GalLookupGeometryAdmissionMode.disabled,
      GalLookupSurfaceMode.auto => GalLookupGeometryAdmissionMode.auto,
      GalLookupSurfaceMode.nativeOnly =>
        GalLookupGeometryAdmissionMode.nativeOnly,
      GalLookupSurfaceMode.attachedOnly =>
        GalLookupGeometryAdmissionMode.attachedOnly,
    };
  }

  Future<void> _beforeAttachedActivation(
    GalLookupSurfaceMode profileMode, {
    required bool forceAttached,
  }) async {
    // setProviderAdmission(false) first publishes the native deny generation,
    // then retires the Dart route. The registry itself waits for down/up/tail;
    // the runner will not publish attached boxes until kind=4/id=11 is active.
    await _ingameLookup.setProviderAdmission(false);
    final GalLookupCallResult? result = await _setGeometryAdmissionBounded(
      _geometryAdmissionMode(profileMode, forceAttached: forceAttached),
      attachedReady: true,
      stage: 'attached-handoff',
    );
    if (result == null) {
      throw StateError('geometry_admission_unavailable');
    }
    // not_open still persists the desired control in VoiceHookReader and is
    // replayed when the mapping arrives. Other failures are permanent for the
    // current surface attempt and must fail closed.
    if (result.error == 'not_open') return;
    if (!_hasExplicitGeometryAck(result)) {
      throw StateError(result.error ?? 'geometry_admission_rejected');
    }
  }

  Future<GalLookupCallResult?> _setGeometryAdmissionBounded(
    GalLookupGeometryAdmissionMode mode, {
    required bool attachedReady,
    required String stage,
    bool Function()? stillCurrent,
  }) async {
    final request = (mode: mode, attachedReady: attachedReady);
    _geometrySyncDesiredRequest = request;
    final Future<GalLookupCallResult>? active = _geometrySyncInFlight;
    if (active != null) {
      _geometrySyncNeedsReconcile = true;
      _scheduleSyncRetry();
      return null;
    }

    final Future<GalLookupCallResult> operation = _ingameLookup
        .setGeometryAdmission(
          mode,
          attachedReady: attachedReady,
          stillCurrent: () =>
              _started &&
              _geometrySyncDesiredRequest == request &&
              (stillCurrent == null || stillCurrent()),
        );
    _geometrySyncInFlight = operation;
    _geometrySyncNeedsReconcile = false;
    unawaited(
      operation.then<void>(
        (_) => _completeGeometrySync(operation, request),
        onError: (Object error, StackTrace stackTrace) {
          _completeGeometrySync(operation, request);
        },
      ),
    );
    try {
      final GalLookupCallResult result = await operation.timeout(
        _geometryAdmissionTimeout,
      );
      if (_geometrySyncDesiredRequest != request ||
          (stillCurrent != null && !stillCurrent())) {
        return null;
      }
      return result;
    } on TimeoutException {
      if (identical(_geometrySyncInFlight, operation)) {
        _geometrySyncNeedsReconcile = true;
      }
      glog(
        'gal-ingame: geometryAdmission stage=$stage mode=${mode.name} '
        'geometryAdmission stage=$stage timed out; provider remains closed',
      );
    } catch (error, stackTrace) {
      glog(
        'gal-ingame: geometryAdmission stage=$stage mode=${mode.name} '
        'geometryAdmission stage=$stage EXCEPTION $error\n$stackTrace',
      );
    }
    return null;
  }

  void _completeGeometrySync(
    Future<GalLookupCallResult> operation,
    ({GalLookupGeometryAdmissionMode mode, bool attachedReady}) request,
  ) {
    if (!identical(_geometrySyncInFlight, operation)) return;
    final bool reconcile =
        _geometrySyncNeedsReconcile || _geometrySyncDesiredRequest != request;
    _geometrySyncInFlight = null;
    _geometrySyncNeedsReconcile = false;
    if (reconcile && _started) _scheduleSync();
  }

  Future<bool> _syncAttachedBounded({
    required bool active,
    required int? sessionEpoch,
    required int targetPid,
    required int targetHwnd,
    required String? sourceText,
    required String? launchExePath,
    required bool inspectOnly,
    required int syncRevision,
  }) async {
    final request = (
      active: active,
      sessionEpoch: sessionEpoch,
      targetPid: targetPid,
      targetHwnd: targetHwnd,
      sourceText: sourceText ?? '',
      launchExePath: launchExePath ?? '',
      inspectOnly: inspectOnly,
    );
    _attachedSyncDesiredRequest = request;
    final Future<void>? activeOperation = _attachedSyncInFlight;
    if (activeOperation != null) {
      _attachedSyncNeedsReconcile = true;
      _scheduleSyncRetry();
      return false;
    }

    final Future<void> operation = _attachedText.syncSession(
      active: active,
      sessionEpoch: sessionEpoch,
      targetPid: targetPid,
      targetHwnd: targetHwnd,
      sourceText: sourceText,
      launchExePath: launchExePath,
      inspectOnly: inspectOnly,
      stillCurrent: () =>
          _started &&
          _attachedSyncDesiredRequest == request &&
          _isSyncSnapshotCurrent(syncRevision, sessionEpoch),
    );
    _attachedSyncInFlight = operation;
    _attachedSyncNeedsReconcile = false;
    unawaited(
      operation.then<void>(
        (_) => _completeAttachedSync(operation, request),
        onError: (Object error, StackTrace stackTrace) {
          _completeAttachedSync(operation, request);
        },
      ),
    );
    try {
      await operation.timeout(_attachedSyncTimeout);
      return _attachedSyncDesiredRequest == request &&
          _isSyncSnapshotCurrent(syncRevision, sessionEpoch);
    } on TimeoutException {
      if (identical(_attachedSyncInFlight, operation)) {
        _attachedSyncNeedsReconcile = true;
      }
      glog(
        'gal-attached: syncSession timed out; the single in-flight operation '
        'will trigger current-state reconciliation when it completes',
      );
    } catch (error, stackTrace) {
      glog('gal-attached: syncSession EXCEPTION $error\n$stackTrace');
    }
    _scheduleSyncRetry();
    return false;
  }

  void _completeAttachedSync(
    Future<void> operation,
    ({
      bool active,
      int? sessionEpoch,
      int targetPid,
      int targetHwnd,
      String sourceText,
      String launchExePath,
      bool inspectOnly,
    })
    request,
  ) {
    if (!identical(_attachedSyncInFlight, operation)) return;
    final bool reconcile =
        _attachedSyncNeedsReconcile || _attachedSyncDesiredRequest != request;
    _attachedSyncInFlight = null;
    _attachedSyncNeedsReconcile = false;
    if (reconcile && _started) _scheduleSync();
  }

  Future<bool> _setLookupSessionActiveIsolated(
    bool active, {
    bool Function()? stillCurrent,
  }) async {
    try {
      final bool applied = await _ingameLookup.setSessionActive(
        active,
        stillCurrent: stillCurrent,
      );
      if (!applied) return false;
      final bool acknowledged = _ingameLookup.runtimeEnabledAcknowledged;
      if (!acknowledged) {
        glog(
          'gal-ingame: sessionActive=$active completed without matching '
          'native acknowledgement',
        );
        _scheduleSyncRetry();
      }
      return acknowledged;
    } catch (error, stackTrace) {
      // The controller records the desired lifecycle edge before awaiting the
      // platform reply, so a later central sync can retry it. A transient
      // channel failure must not also suppress the independent text overlay.
      glog('gal-ingame: sessionActive=$active EXCEPTION $error\n$stackTrace');
      _scheduleSyncRetry();
      return false;
    }
  }

  Future<bool> _setProviderAdmissionIsolated(
    bool admitted, {
    bool Function()? stillCurrent,
  }) async {
    try {
      return await _ingameLookup.setProviderAdmission(
        admitted,
        stillCurrent: stillCurrent,
      );
    } catch (error, stackTrace) {
      // setProviderAdmission closes its local gate before retiring an existing
      // route. The caller must not cross a provider/session handoff after a
      // failed retirement; a later sync can retry the same false edge.
      glog(
        'gal-ingame: providerAdmission=$admitted EXCEPTION '
        '$error\n$stackTrace',
      );
      _scheduleSyncRetry();
      return false;
    }
  }

  bool _isSyncSnapshotCurrent(int revision, int? sessionKey) {
    if (!_started || revision != _syncRevision) return false;
    return _session.state.sessionStartedAt?.microsecondsSinceEpoch ==
        sessionKey;
  }

  static bool _hasExplicitGeometryAck(GalLookupCallResult? result) {
    return result != null && result.ok && result.requestSeq > 0;
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
    // stopForTesting 之后已经排队的那一轮不该再跑：它会重新置位
    // `_lookupRetirementPending`、再往 native 打一次退役，最后才在快照检查处退出。
    if (!_started) return;
    final int syncRevision = _syncRevision;
    final GalHookSessionState state = _session.state;
    final int? nextSessionKey = state.sessionStartedAt?.microsecondsSinceEpoch;
    final bool sessionIdentityChanged = nextSessionKey != _sessionKey;
    final bool newSession = nextSessionKey != null && sessionIdentityChanged;

    if (sessionIdentityChanged) {
      // Advance the route namespace before touching the old card. The Reader
      // may already expose the replacement mapping for an active -> active
      // edge, so an old hit sequence is no longer safe to send.
      _ingameLookup.setSessionEpoch(nextSessionKey);
      _lookupRetirementPending = true;
    }
    if (_lookupRetirementPending) {
      // A provider route belongs to exactly one launch epoch, so the old route
      // must be retired before a new one may be armed. But retirement is a
      // *lookup* obligation: it must not also suppress the independent text
      // overlay — the exact rule this file already states on
      // [_setLookupSessionActiveIsolated]. 这三步以前是 `return`，而它们全部位于
      // 本函数末尾台词浮窗 updateText/show 之前：换局时 runner 只要没给明确 ack
      // （空回执、control_rejected 等），`_sessionKey` 就永不提交，整局游戏一个字
      // 都不显示，只有 0.5→8s 指数退避在空转。
      //
      // 改成记账：失败保留 [_lookupRetirementPending] 并排一次重试，后续 sync 按
      // 这张单子继续退役（不能再依赖 `sessionIdentityChanged`——`_sessionKey` 已经
      // 提交，那条边被消费掉了），本轮只把查词侧整体按下，浮窗照常跑。
      final bool providerClosed = await _setProviderAdmissionIsolated(false);
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      final bool runtimeClosed =
          providerClosed && await _setLookupSessionActiveIsolated(false);
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      GalLookupCallResult? disabledGeometry;
      if (runtimeClosed) {
        disabledGeometry = await _setGeometryAdmissionBounded(
          GalLookupGeometryAdmissionMode.disabled,
          attachedReady: false,
          stage: 'session-rollover',
          stillCurrent: () =>
              _isSyncSnapshotCurrent(syncRevision, nextSessionKey),
        );
        if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      }
      // not_open 仍会把期望值存进 VoiceHookReader 并replay 进替换 mapping，算退役成功。
      _lookupRetirementPending =
          !runtimeClosed ||
          (disabledGeometry?.error != 'not_open' &&
              !_hasExplicitGeometryAck(disabledGeometry));
      if (_lookupRetirementPending) _scheduleSyncRetry();
    }

    if (newSession) {
      _suppressedForSession = false;
      _following = true;
      _passThrough = false;
      _locked = false;
      _displayedLineId = null;
      _displayedLineText = null;
      _ingameLatestLineId = null;
      _ingameLatestLineText = null;
      // 新会话：上一局的试听计时不能把高亮留在新浮窗上。
      _replayResetTimer?.cancel();
      _replayResetTimer = null;
      _replaying = false;
      try {
        await GalHookTextOverlayChannel.setFollowing(true);
        if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
        await GalHookTextOverlayChannel.setPassThrough(false);
        if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
        await GalHookTextOverlayChannel.setLocked(false);
        if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
        // BUG-1981 家族（develop）：每局会话开始对账一次 `_visible` 与 native 的真实窗口
        // 状态。正常路径是 native 推 `overlayDestroyed`（见 [_onOverlayDestroyed]），这条
        // 兜底只覆盖「Dart 侧还没挂上 handler」的时间窗（热重启 / stopForTesting 后
        // 重新 start / App 启动时会话已在跑）。它也是一条会话重置边，失败同样得让
        // 本轮可重试，所以收在 try 内、在 `_sessionKey` 提交之前。
        await _reconcileVisibilityWithNative();
      } catch (error, stackTrace) {
        glog('gal-overlay: session reset EXCEPTION $error\n$stackTrace');
        _scheduleSyncRetry();
        return;
      }
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      // Commit only after old-provider retirement and all overlay reset edges
      // succeeded. Otherwise a transient platform failure remains retryable.
      _sessionKey = nextSessionKey;
      notifyListeners();
    } else if (sessionIdentityChanged) {
      _sessionKey = nextSessionKey;
    }

    final bool active =
        state.externalWindowMode &&
        nextSessionKey != null &&
        state.phase != GalHookSessionPhase.idle &&
        state.phase != GalHookSessionPhase.stopping &&
        state.phase != GalHookSessionPhase.error;
    final List<TexthookerLineEntry> lines = active
        ? _session.selectedSessionLines
        : const <TexthookerLineEntry>[];
    // v1 attached geometry deliberately excludes ruby. The selected line's
    // plain text has already had ruby markup removed, but its baseline no
    // longer proves the same glyph boxes as the game's two-level rendering.
    // Feed no source at all so the child withdraws every old hit box instead
    // of guessing a clickable layout.
    final TexthookerLineEntry? latestAttachedLine = lines.isEmpty
        ? null
        : lines.last;
    final String? attachedSourceText =
        latestAttachedLine == null || latestAttachedLine.rubySpans.isNotEmpty
        ? null
        : latestAttachedLine.text;
    final int targetPid = state.gamePid ?? state.boundWindow?.pid ?? 0;
    final int targetHwnd = state.boundWindow?.hwnd ?? 0;
    // 与 KiriKiri surface 一样，attached surface 跟会话而不是浮窗可见性走；但它不
    // 新增 listener，只消费这次 central sync 的不可变快照。
    final bool lookupPreferenceEnabled =
        _readPreference(
          GalIngameLookupController.enabledPreferenceKey,
          PreferencesRepository.galIngameLookupEnabledDefault,
        ) ==
        true;
    // 退役未完成时本轮一律不武装新 route：旧 route 还活着，新的绝不能叠上去。
    final bool lookupActive =
        active && lookupPreferenceEnabled && !_lookupRetirementPending;

    // Phase 1 only resolves the executable/profile. lookup_enabled and geometry
    // are still false here, so a persisted off profile can never pulse the
    // native input shield while inspection is in flight.
    final bool profileSynchronized = await _syncAttachedBounded(
      active: lookupActive,
      sessionEpoch: nextSessionKey,
      targetPid: targetPid,
      targetHwnd: targetHwnd,
      sourceText: attachedSourceText,
      // Launch sessions are keyed by the executable the user selected even
      // when an engine replaces itself with a child process. Attach sessions
      // leave this null so the runner resolves the PID's absolute image path.
      launchExePath: state.launchExe,
      inspectOnly: true,
      syncRevision: syncRevision,
    );
    if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;

    final GalLookupSurfaceMode lookupMode =
        _attachedText.profile?.mode ?? GalLookupSurfaceMode.auto;
    final bool preActivationForceAttached =
        profileSynchronized && _attachedText.forceAttachedProvider;
    final bool lookupSurfaceActive =
        lookupActive &&
        profileSynchronized &&
        (lookupMode != GalLookupSurfaceMode.off || preActivationForceAttached);

    bool stillCurrent() => _isSyncSnapshotCurrent(syncRevision, nextSessionKey);
    final bool sessionPushSucceeded = await _setLookupSessionActiveIsolated(
      lookupSurfaceActive,
      stillCurrent: lookupSurfaceActive ? stillCurrent : null,
    );
    if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;

    // Phase 2 may claim/configure a provider only after the resolved mode has
    // made the runtime decision above. In off mode it merely finalizes the
    // child's disabled status without ever opening lookup_enabled.
    final bool attachedSynchronized =
        profileSynchronized &&
        await _syncAttachedBounded(
          active: lookupActive,
          sessionEpoch: nextSessionKey,
          targetPid: targetPid,
          targetHwnd: targetHwnd,
          sourceText: attachedSourceText,
          launchExePath: state.launchExe,
          inspectOnly: false,
          syncRevision: syncRevision,
        );
    if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
    final bool forceAttached =
        attachedSynchronized && _attachedText.forceAttachedProvider;

    final bool attachedReady =
        lookupSurfaceActive && _attachedText.attachedProviderClaimed;
    final bool nativeProviderDesired =
        sessionPushSucceeded &&
        lookupSurfaceActive &&
        !forceAttached &&
        _nativeProviderAdmitted(lookupMode, _attachedText.status);
    // The Dart route must be ready before native input is armed. Opening this
    // local gate has no platform await; the v21 flag below is the final edge
    // that can actually consume a game click. On exclusion the order is the
    // reverse: close/retire the route first, then clear the native input flag.
    final bool providerUpdated = await _setProviderAdmissionIsolated(
      nativeProviderDesired,
      stillCurrent: nativeProviderDesired ? stillCurrent : null,
    );
    if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
    // 与换局退役同一条纪律：查词这一侧的任何一步失败只记账 + 重试，绝不 return
    // 把下面的台词浮窗一起带走。`providerUpdated` 为假时本地 route 门本来就没被
    // 打开（[GalIngameLookupController.setProviderAdmission] 只在成功路径上置位），
    // 所以跳过下面这段几何武装不会留下半开状态。
    bool geometryAcknowledged = false;
    bool providerRetireFailed = false;
    if (providerUpdated) {
      // Keep native geometry discovery alive while risk acceptance is pending:
      // the injected provider must be able to reach Ready before Dart can
      // report that the current executable supports native lookup. Click
      // consumption is a distinct v21 flag and stays false until
      // [_nativeProviderAdmitted] has passed the profile/risk gate. Attached
      // ownership remains independent.
      final GalLookupGeometryAdmissionMode geometryMode = lookupSurfaceActive
          ? _geometryAdmissionMode(lookupMode, forceAttached: forceAttached)
          : GalLookupGeometryAdmissionMode.disabled;
      final GalLookupCallResult? geometryResult =
          await _setGeometryAdmissionBounded(
            geometryMode,
            attachedReady: attachedReady,
            stage: 'central-sync',
            stillCurrent: stillCurrent,
          );
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) {
        // The native call may have crossed the revision edge after publishing
        // its payload. Close the local route immediately; the queued central
        // sync will clear nativeInputAllowed for the new snapshot.
        if (nativeProviderDesired) {
          await _setProviderAdmissionIsolated(false);
        }
        return;
      }
      // Missing/malformed replies used to parse as an empty "ok" result.
      // Require the runner's positive request sequence; if the final
      // native-input edge was not acknowledged, retire the already-open local
      // route again.
      geometryAcknowledged = _hasExplicitGeometryAck(geometryResult);
      if (nativeProviderDesired && !geometryAcknowledged) {
        final bool providerClosed = await _setProviderAdmissionIsolated(false);
        if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
        providerRetireFailed = !providerClosed;
      }
    }
    if (_lookupRetirementPending ||
        !providerUpdated ||
        providerRetireFailed ||
        !sessionPushSucceeded ||
        (lookupActive && !attachedSynchronized) ||
        (lookupSurfaceActive && !geometryAcknowledged)) {
      // `_lookupRetirementPending` 必须参与这个判据：退役块已经排过一次重试，
      // 这里再无条件 _clearSyncRetry() 就把它取消了，退役永远不会被重试。
      _scheduleSyncRetry();
    } else {
      _clearSyncRetry();
    }
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
    // 会话最新行 ID 变化时让游戏内控制器复核句子内容。不能直接把 ID
    // 当句界：KiriKiriZ 的人物动画/renderer 重绑会让 Luna 重发同句并分配新 ID。
    // 文本服务仍保留这些 occurrence（配音/制卡身份需要），只有查词 surface
    // 会把同句重发折叠为同一生命周期。
    final String? latestLineId = lines.isEmpty ? null : lines.last.id;
    final String? latestLineText = lines.isEmpty ? null : lines.last.text;
    // 文本也要比：就地扩写时 id 不变但屏上排版已经变了，卡片锚定的字形位置不再
    // 作数，必须一并消场。
    if (latestLineId != _ingameLatestLineId ||
        latestLineText != _ingameLatestLineText) {
      _ingameLatestLineId = latestLineId;
      _ingameLatestLineText = latestLineText;
      await _ingameLookup.onLineChanged(latestLineText);
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
    }

    if (_suppressedForSession) return;
    if (lines.isEmpty) return;
    final TexthookerLineEntry latest = lines.last;
    // BUG-1981：`_visible` 是**派生镜像**，不是 HWND 真值。窗口被系统 / 外部
    // WM_CLOSE 销毁后 session 仍会继续送文本；镜像不复位的话后续永远只发
    // updateText，工具栏的「显示 Hook 浮窗」也没有可见窗口可抬起。
    // 复位由 native 的 `overlayDestroyed` 事件推过来（见 [_onOverlayDestroyed]），
    // 这里不再每行打一次 isShowing() 往返 —— 那是拿 O(台词数) 次 MethodChannel
    // 轮询去问一个 native 本来就会主动告诉我们的事实，Zato 那种逐字重绘一句话
    // 就是十几次。兜底对账收在每局会话开始处（见 [_reconcileVisibilityWithNative]）。
    if (!_visible) {
      await GalHookTextOverlayChannel.updateText(
        lineId: latest.id,
        text: latest.text,
        rubySpans: rubySpansToChannel(latest.rubySpans),
      );
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      final bool hoverAutoLookup = _readHoverAutoLookup();
      _visible = await GalHookTextOverlayChannel.show(
        rect: _savedRect,
        fontSize: _fontSize,
        fontFamily: _fontSelection?.family ?? '',
        fontPath: _fontSelection?.path,
        letterSpacing: _letterSpacing,
        lineHeight: _lineHeight,
        bold: _bold,
        textAlignment: _textAlignment,
        verticalAlignment: _verticalAlignment,
        textColor: _textColor,
        bgColor: _backgroundColor,
        outlineColor: _outlineColor,
        outlineWidth: _outlineWidth,
        textPadding: _textPadding,
        cornerRadius: _cornerRadius,
        following: _following,
        passThrough: _passThrough,
        locked: _locked,
        hoverAutoLookup: hoverAutoLookup,
        clickLookupEnabled: _readClickLookupEnabled(),
        lookupTrigger: _readLookupTrigger(),
        toolbarAutoHide: _readToolbarAutoHide(),
        passThroughBlocksMouse: _readPassThroughBlocksMouse(),
        slotTooltips: _slotTooltips,
      );
      _pushedHoverAutoLookup = hoverAutoLookup;
      // native 在 show 里把语音控件复位（见 flutter_window.cpp），本地镜像跟着复位，
      // 否则下一次 _syncVoiceState 会认为「已经推过了」而不再推。
      _pushedReplaying = false;
      _pushedRecapturing = false;
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      if (_visible) {
        _displayedLineId = latest.id;
        _displayedLineText = latest.text;
      }
      notifyListeners();
      await _syncVoiceState();
      return;
    }
    // 换句（id 变）或就地扩写（id 不变、文本变长）都要重推。
    if (_following &&
        (latest.id != _displayedLineId || latest.text != _displayedLineText)) {
      await GalHookTextOverlayChannel.updateText(
        lineId: latest.id,
        text: latest.text,
        rubySpans: rubySpansToChannel(latest.rubySpans),
      );
      if (!_isSyncSnapshotCurrent(syncRevision, nextSessionKey)) return;
      _displayedLineId = latest.id;
      _displayedLineText = latest.text;
      notifyListeners();
    }
    // 补录窗口可能由 session 侧超时自行收束：每轮都比对一次，浮窗上的「录音中」
    // 高亮才不会停在已结束的状态上。
    await _syncVoiceState();
  }

  /// 工具条槽位悬停提示文案，**下标与 native `hook_toolbar::kSlotActions`
  /// 严格同序**（重播 / 重录 / 跟随 / 穿透 / 底板 / 锁定 / 工作台 / 置顶 /
  /// 关闭）。native 不持有 i18n，文案只能由这里按当前 locale 下发。
  List<String> get _slotTooltips => <String>[
    t.game_hook_btn_replay,
    t.game_hook_btn_recapture,
    t.game_hook_btn_follow,
    t.game_hook_btn_passthrough,
    t.game_hook_btn_transparency,
    t.game_hook_btn_lock,
    t.game_hook_btn_workbench,
    t.game_hook_btn_topmost,
    t.game_hook_btn_close,
  ];

  int get _backgroundColor {
    final int alpha = (_opacity.clamp(0.0, 1.0) * 255).round();
    return (alpha << 24) | (_backgroundBaseColor & 0x00FFFFFF);
  }

  Future<void> _pushStyle() async {
    await GalHookTextOverlayChannel.updateStyle(
      bgColor: _backgroundColor,
      fontSize: _fontSize,
      fontFamily: _fontSelection?.family ?? '',
      fontPath: _fontSelection?.path,
      letterSpacing: _letterSpacing,
      lineHeight: _lineHeight,
      bold: _bold,
      textAlignment: _textAlignment,
      verticalAlignment: _verticalAlignment,
      textColor: _textColor,
      outlineColor: _outlineColor,
      outlineWidth: _outlineWidth,
      textPadding: _textPadding,
      cornerRadius: _cornerRadius,
    );
    final GalLookupReferenceClientV1? client = _attachedText.currentClient;
    if (client != null) {
      await _attachedText.updateActiveStyle(_attachedLayoutFor(client));
    }
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
      _opacity = _lastNonZeroOpacity > 0
          ? _lastNonZeroOpacity
          : _defaultRestoreOpacity;
    }
    final AppModel? model = _appModel;
    if (model != null) {
      if (_preferenceWriter != null) {
        await _preferenceWriter(_opacityPreferenceKey, _opacity);
      } else {
        await model.prefsRepo.setPref(_opacityPreferenceKey, _opacity);
      }
    }
    await _pushStyle();
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
    await _pushStyle();
    notifyListeners();
  }

  /// Re-resolves the managed game-lookup font and repaints an already-open
  /// native overlay immediately. [CustomFontsPage] calls this after persisting
  /// the shared catalog; a controller that has not started yet simply picks up
  /// the latest target from [_loadPreferences] on startup.
  Future<void> applyFontFromSettings() async {
    if (!_started) return;
    final ({String family, String? path})? next = _readFontSelection();
    if (next == _fontSelection) return;
    _fontSelection = next;
    await _pushStyle();
    notifyListeners();
  }

  /// Reloads every visual preference and repaints an already-open overlay.
  /// The settings page uses this single entry point so related controls cannot
  /// accidentally update only part of the native style payload.
  Future<void> applyAppearanceFromPreferences() async {
    if (!_started) return;
    final double storedOpacity = _readDouble(
      _opacityPreferenceKey,
      fallback: _defaultOpacity,
      min: 0.0,
      max: 1.0,
    );
    _opacity = storedOpacity;
    if (_opacity > 0) _lastNonZeroOpacity = _opacity;
    _readAppearancePreferences();
    await _pushStyle();
    notifyListeners();
  }

  /// Reconciles the global in-game lookup switch across both native and
  /// attached providers. Keeping this at the central session owner prevents a
  /// disabled transparent surface from continuing to intercept bare clicks.
  Future<void> applyIngameLookupEnabledFromPreferences() async {
    await _ingameLookup.applyEnabledFromPreferences();
    _scheduleSync();
  }

  /// 「悬停即查词」当前值。默认真值在 [ReaderFushiSource]（与阅读器 / 视频字幕
  /// 同一个开关），测试可注入替身。
  /// hook 浮窗交互偏好四件套。走同一个 [_readPreference]（测试可注入），坏值一律
  /// 退回默认——一个越界的触发方式会让 native 的分派变成「哪个键都不触发」。
  bool _readClickLookupEnabled() {
    final Object? stored = _readPreference(
      'gal_hook_click_lookup',
      PreferencesRepository.galHookClickLookupDefault,
    );
    return stored is bool
        ? stored
        : PreferencesRepository.galHookClickLookupDefault;
  }

  int _readLookupTrigger() {
    final Object? stored = _readPreference(
      'gal_hook_lookup_trigger',
      PreferencesRepository.galHookLookupTriggerDefault,
    );
    final int value = stored is num
        ? stored.toInt()
        : PreferencesRepository.galHookLookupTriggerDefault;
    return value >= 0 && value <= 2
        ? value
        : PreferencesRepository.galHookLookupTriggerDefault;
  }

  bool _readToolbarAutoHide() {
    final Object? stored = _readPreference(
      'gal_hook_toolbar_auto_hide',
      PreferencesRepository.galHookToolbarAutoHideDefault,
    );
    return stored is bool
        ? stored
        : PreferencesRepository.galHookToolbarAutoHideDefault;
  }

  bool _readPassThroughBlocksMouse() {
    final Object? stored = _readPreference(
      'gal_hook_passthrough_blocks_mouse',
      PreferencesRepository.galHookPassThroughBlocksMouseDefault,
    );
    return stored is bool
        ? stored
        : PreferencesRepository.galHookPassThroughBlocksMouseDefault;
  }

  bool _readHoverAutoLookup() {
    final GalHookHoverAutoLookupReader? reader = _hoverAutoLookupReader;
    if (reader != null) return reader();
    return ReaderFushiSource.instance.hoverAutoLookup;
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

  /// native 报告浮窗 HWND 的生命周期结束（WM_NCDESTROY）。
  ///
  /// `_visible` 由此**被动**复位：窗口是 native 的事实，Dart 只持有它的镜像，
  /// 事实变了就该由持有事实的一侧推过来，而不是消费端定期回头问。复位后下一条
  /// 台词会走 [_syncFromSession] 的 `!_visible` 分支重新 show，工具栏的
  /// 「显示 Hook 浮窗」也重新有窗口可抬。
  ///
  /// 与用户主动关闭（`onClose` → [closeForCurrentSession]）严格分开：那条要置
  /// `_suppressedForSession`（本会话别再自动弹），这条**不能**——窗口被外部销毁
  /// 不代表用户不想要它。
  Future<void> _onOverlayDestroyed() async {
    if (!_visible) return;
    _visible = false;
    // 没有窗口就没有「正在显示的那一行」；不清的话重建后 `latest.id ==
    // _displayedLineId` 会让重推被跳过，新窗口停在空文本上。
    _displayedLineId = null;
    _displayedLineText = null;
    notifyListeners();
  }

  /// 兜底对账：把 `_visible` 与 native 的真实窗口状态校准一次。
  ///
  /// 正常路径是 [_onOverlayDestroyed] 的被动复位，本进程内不会丢。保留这条
  /// 兜底是因为事件依赖「Dart 侧已挂上 handler」：热重启、`stopForTesting()`
  /// 之后重新 `start()`、或 App 启动时游戏会话已经在跑，都会留下一段没有订阅者
  /// 的时间窗，那段时间里发生的销毁没人报。
  ///
  /// 只在**每局会话开始**打一次（不是每行）：staleness 因此被一局游戏封顶，而
  /// 代价从 O(台词数) 次 MethodChannel 往返降到 O(会话数) 次；且 `_visible`
  /// 为 false 时直接早退，实际开销通常是零。
  Future<void> _reconcileVisibilityWithNative() async {
    if (!_visible) return;
    if (await GalHookTextOverlayChannel.isShowing()) return;
    _visible = false;
    _displayedLineId = null;
    _displayedLineText = null;
    notifyListeners();
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
      FushiToast.show(
        msg: t.game_hook_line_unavailable,
        severity: ToastSeverity.error,
      );
      return;
    }
    final GalTrackPreview? preview = await _session.exportLineAudioPreview(
      lineId,
    );
    if (preview == null) {
      FushiToast.show(
        msg: t.game_line_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!await DesktopAudioPlayback.playFile(preview.filePath)) {
      FushiToast.show(
        msg: t.game_line_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _replaying = true;
    _replayResetTimer?.cancel();
    _replayResetTimer = Timer(
      Duration(
        milliseconds: preview.durationMs > 0
            ? preview.durationMs + 300
            : _replayMaxMs,
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
      FushiToast.show(
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
      FushiToast.show(
        msg: t.game_hook_line_unavailable,
        severity: ToastSeverity.error,
      );
      return;
    }
    final bool started = await _session.startLineRecapture(lineId);
    FushiToast.show(
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

  /// [consumeOutsideClicksOwnerHwnd]：attached 校准字形表面命中时传游戏
  /// HWND，桌面弹窗「点卡外关闭」的点击成对吞掉、不推进游戏；台词浮窗（C 表面）
  /// 不传，行为不变。
  Future<void> _onLookupText(
    String lineId,
    String text,
    int index,
    Rect? wordRect, {
    GalHookCaptureLeaseFactory? captureLeaseFactory,
    int? consumeOutsideClicksOwnerHwnd,
  }) async {
    final AppModel? model = _appModel;
    final TexthookerLineEntry? entry = _session.entryById(lineId);
    if (model == null ||
        entry == null ||
        entry.text != text ||
        !_session.isLineInCurrentSession(entry)) {
      FushiToast.show(
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
      // 台词浮窗本身已经显示完整句子；查词卡只保留词典正文。完整 sentence 仍会
      // 进入 mining 上下文（{sentence} 回落）。
      sentence: entry.text,
      // 卡片锚在被点中的那个词上（native 给的屏幕逻辑 px 矩形），而不是鼠标位置：
      // 浮窗里点词跟阅读器/剪贴板面板一样是「点哪个词看哪个词」。老 native 不带
      // 矩形时为 null，自动回落到光标定位。
      anchorScreenRect: wordRect,
      miningHandler:
          ({required Map<String, String> fields, int? updateNoteId}) =>
              _mineFromLookup(
                lineId: entry.id,
                fields: fields,
                updateNoteId: updateNoteId,
                captureLeaseFactory: captureLeaseFactory,
              ),
      consumeOutsideClicksOwnerHwnd: consumeOutsideClicksOwnerHwnd,
    );
  }

  Future<void> _onAttachedLookupText(GalAttachedLookupHitV19 hit) async {
    if (_readPreference(
          GalIngameLookupController.enabledPreferenceKey,
          PreferencesRepository.galIngameLookupEnabledDefault,
        ) !=
        true) {
      return;
    }
    final List<TexthookerLineEntry> lines = _session.selectedSessionLines;
    if (lines.isEmpty) return;
    final TexthookerLineEntry latest = lines.last;
    // attached hit 必须逐字对应 central sync 刚送出的当前正文。任何旧 epoch、旧
    // generation 或长度漂移已在子控制器丢弃；这里再以 session line identity 收口，
    // 从而完整复用既有查词/制卡链而不发明第二份上下文模型。
    if (latest.rubySpans.isNotEmpty || latest.text != hit.sourceText) return;
    // 点击与 Shift+悬浮（hit.hover）走同一条查词链：同一字簇的重复悬浮已在
    // runner 去重。attached 表面打开的桌面弹窗必须带游戏 HWND——点卡外关闭
    // 的 down/up 成对吞掉，不得穿透推进台词。
    await _onLookupText(
      latest.id,
      hit.sourceText,
      hit.charIndex,
      hit.wordRect,
      captureLeaseFactory: _acquireAttachedMiningCaptureLease,
      consumeOutsideClicksOwnerHwnd: hit.target.targetHwnd,
    );
  }

  /// Acquires one screenshot fence spanning both independently composited
  /// surfaces used by attached lookup: the 1/255-alpha glyph catch window and
  /// the visible global dictionary card. The two exact generation tokens are
  /// kept together so a late release cannot revive either an old sentence or
  /// an old card route.
  Future<GalHookCaptureLease> _acquireAttachedMiningCaptureLease() async {
    final GlobalLookupRoute route = GlobalLookupChannel.currentRoute;
    final GalAttachedMiningCaptureLease? attachedLease = await _attachedText
        .acquireMiningCaptureLease();
    if (attachedLease == null) {
      throw const GalHookCaptureSuppressionException(
        'the attached glyph surface is no longer current',
      );
    }

    try {
      final bool cardHidden = await GlobalLookupChannel.runWithRoute(
        route,
        () => GlobalLookupChannel.suspendForCapture(
          attachedLease.captureGeneration,
        ),
      );
      if (!cardHidden) {
        throw const GalHookCaptureSuppressionException(
          'the lookup card did not acknowledge capture suppression',
        );
      }
      return _AttachedCompositeCaptureLease(
        releaseCallback: () async {
          final Object? restoreError = await _restoreAttachedCaptureSurfaces(
            route,
            attachedLease,
          );
          if (restoreError != null) {
            throw GalHookCaptureSuppressionException(
              'attached capture restoration threw: $restoreError',
            );
          }
        },
      );
    } catch (error) {
      // The card call may have reached native even when the reply was lost.
      // Attempt the exact-token restore before releasing the attached surface,
      // then fail closed so no screenshot starts with ambiguous visibility.
      await _restoreAttachedCaptureSurfaces(route, attachedLease);
      if (error is GalHookCaptureSuppressionException) rethrow;
      throw GalHookCaptureSuppressionException(
        'attached capture suppression threw: $error',
      );
    }
  }

  Future<Object?> _restoreAttachedCaptureSurfaces(
    GlobalLookupRoute route,
    GalAttachedMiningCaptureLease attachedLease,
  ) async {
    Object? firstError;
    try {
      final bool restored = await GlobalLookupChannel.runWithRoute(
        route,
        () => GlobalLookupChannel.restoreAfterCapture(
          attachedLease.captureGeneration,
        ),
      );
      if (!restored) {
        firstError = StateError('lookup_card_capture_restore_rejected');
      }
    } catch (error) {
      firstError = error;
    }
    try {
      await _attachedText.releaseMiningCaptureLease(attachedLease);
    } catch (error) {
      firstError ??= error;
    }
    return firstError;
  }

  /// 游戏内查词的制卡 handler：按 native 文本代数回溯本局会话里的那一行，复用浮窗点词
  /// 完全相同的 [_mineFromLookup]（截图 / 语音 / 标签 / 压缩档全部同源）。
  ///
  /// [textGeneration] 与文本 IPC `TextSlot.seq` 同源；session controller 已把它保存到
  /// [TexthookerLineEntry.sourceSequence]。只在命中时的同一 session/HWND 内按这个身份
  /// 精确匹配，不能让重复台词或 containment 把当前截图/音频绑到另一 occurrence。
  /// 旧载荷没有 generation 时才保留原有的“当前最新行 exact → 受限 containment”回退。
  String? _resolveIngameMiningLineId(
    String line, {
    required int? textGeneration,
    required DateTime? sessionStartedAt,
    required int? targetHwnd,
  }) {
    final GalHookSessionState state = _session.state;
    if (sessionStartedAt == null ||
        targetHwnd == null ||
        state.sessionStartedAt != sessionStartedAt ||
        state.boundWindow?.hwnd != targetHwnd) {
      return null;
    }
    final List<TexthookerLineEntry> lines = _session.selectedSessionLines;
    if (lines.isEmpty) return null;
    if (textGeneration != null) {
      for (final TexthookerLineEntry entry in lines.reversed) {
        if (entry.sourceSequence == textGeneration) return entry.id;
      }
      // generation 是 occurrence 身份：有值但未命中时必须 fail closed，不能再拿相同或
      // 包含关系的文本冒充当前行。
      return null;
    }
    final TexthookerLineEntry latest = lines.last;
    if (latest.text == line) return latest.id;
    final String normalizedLine = line.replaceAll(RegExp(r'\s+'), '');
    final String normalizedLatest = latest.text.replaceAll(RegExp(r'\s+'), '');
    // 短串 containment 太容易误绑助词/人名；8 个 UTF-16 code unit 是保守门槛，
    // 当前真机的净句远高于此值。只有“当前最新行包含完整净句”才复用其 lineId。
    if (normalizedLine.length >= 8 &&
        normalizedLatest.contains(normalizedLine)) {
      return latest.id;
    }
    return null;
  }

  OverlayMiningHandler _ingameMiningHandlerFor(
    String line, {
    required int? textGeneration,
  }) {
    final DateTime? sessionStartedAt = _session.state.sessionStartedAt;
    final int? targetHwnd = _session.state.boundWindow?.hwnd;
    return ({required Map<String, String> fields, int? updateNoteId}) async {
      // resolver 在 popup 构造时被保存，而文本线程可能稍后才发布当前行。到真正点「制卡」
      // 时重新解析，既覆盖这段时序差，也会重新套用当前 thread 的筛选；但 session/HWND
      // 必须仍是命中时那一对，不能让迟到的 popup 借用下一局的同 seq 或同文行。
      final String? resolved = _resolveIngameMiningLineId(
        line,
        textGeneration: textGeneration,
        sessionStartedAt: sessionStartedAt,
        targetHwnd: targetHwnd,
      );
      if (resolved == null) {
        // BUG-1734：这里过去是**纯静默返回**——不 toast、不记录、不打日志。popup 侧收到
        // ankiConnect:false 同样什么都不做（assets/popup/popup.js 的 mine 分支只在
        // ankiConnect 为真时才有动作），于是用户点「制卡」后屏幕上零反馈，无法区分
        // 「制卡失败了」和「我没点到按钮」。真机上这一条把整轮 E2E 卡了很久。
        //
        // 两种失败原因必须分开报，因为用户要做的动作完全不同：
        //   本局一条台词都没有 → 多半选了一条只产出伪影的文本线程（见 BUG-1733），
        //                        要去工作台换线程；
        //   有台词但对不上当前这句 → 与浮窗点词路径同一种失败，沿用同一条文案。
        FushiToast.show(
          msg: _session.selectedSessionLines.isEmpty
              ? t.game_hook_mining_no_session_lines
              : t.game_hook_line_unavailable,
          severity: ToastSeverity.error,
        );
        return const <String, Object?>{'ankiConnect': false, 'noteId': null};
      }
      return _mineFromLookup(
        lineId: resolved,
        fields: fields,
        updateNoteId: updateNoteId,
        sentenceOverride: line,
        captureLeaseFactory: _ingameLookup.acquireMiningCaptureLease,
      );
    };
  }

  Future<Map<String, Object?>> _mineFromLookup({
    required String lineId,
    required Map<String, String> fields,
    required int? updateNoteId,
    String? sentenceOverride,
    GalHookCaptureLeaseFactory? captureLeaseFactory,
  }) async {
    final AppModel? model = _appModel;
    if (model == null) {
      return const <String, Object?>{'ankiConnect': false, 'noteId': null};
    }
    FushiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final BaseAnkiRepository repo = model.platformServices
        .createAnkiRepository();
    final GalHookMiningResult result = await _miningCoordinator.mineLine(
      lineId: lineId,
      fields: fields,
      sentenceOverride: sentenceOverride,
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
      stillFormat: model.galMiningStillFormat,
      captureLeaseFactory: captureLeaseFactory,
    );
    if (result.aborted) {
      // 截图已经成功后，resource-only 音频门禁也可能中止制卡。不要把所有
      // abort 都误报成“窗口截图失败”；与 texthooker 页入口保持同一分流。
      final String abortMessage = result.audioFallbackDisabled
          ? t.game_audio_fallback_disabled_missing
          : result.failureReason != null
          ? '${t.external_window_capture_failed}：${result.failureReason}'
          : t.external_window_capture_failed;
      FushiToast.showMine(msg: abortMessage, status: MineToastStatus.failed);
      // BUG-1908：同一句话也回给浮窗——游戏全屏时主 app 窗在后台，上面那个 toast
      // 用户看不见。
      return result.toPopupReply(message: abortMessage);
    }
    final MineOutcome outcome = result.outcome!;
    final described = describeMineOutcome(
      outcome,
      overwrite: updateNoteId != null,
    );
    FushiToast.showMine(msg: described.message, status: described.status);
    // BUG-1908：失败时把 describeMineOutcome 算出的**同一句**本地化文案回给浮窗。
    // 成功不带（浮窗靠 ➕→✓ 翻转表达成功，不需要多一条提示）。
    final String? failureMessage = result.success ? null : described.message;
    if (result.sentenceAudioMissing) {
      // 卡片建成了、只是缺句子音频 = 部分成功。
      FushiToast.show(
        msg: t.game_card_sentence_audio_missing,
        severity: ToastSeverity.warning,
      );
    }
    if (result.unmappedTokens.isNotEmpty) {
      FushiToast.show(
        msg:
            '${t.game_card_mapping_missing}: '
            '${result.unmappedTokens.join(', ')}',
        severity: ToastSeverity.warning,
      );
    }
    return result.toPopupReply(message: failureMessage);
  }
}

class _AttachedCompositeCaptureLease implements GalHookCaptureLease {
  _AttachedCompositeCaptureLease({required this.releaseCallback});

  final Future<void> Function() releaseCallback;
  bool _released = false;
  Future<void>? _releaseFuture;

  @override
  Future<void> release() {
    if (_released) return Future<void>.value();
    final Future<void>? pending = _releaseFuture;
    if (pending != null) return pending;
    final Future<void> operation = _releaseOnce();
    _releaseFuture = operation;
    return operation;
  }

  Future<void> _releaseOnce() async {
    try {
      await releaseCallback();
      _released = true;
    } finally {
      _releaseFuture = null;
    }
  }
}

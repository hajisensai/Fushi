import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/mining/gal_hook_activity_accumulator.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_hook_code_profile.dart';
import 'package:hibiki/src/mining/serial_job_queue.dart';
import 'package:hibiki/src/mining/galgame_system_ui_filter.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_manager.dart';
import 'package:hibiki/src/utils/misc/hibiki_time_format.dart';

/// 落 `activity_events` 的一条游戏活动写入契约。默认实现走 [HibikiDatabase.
/// addActivityEvent]（[kActivityGame] / [kActivityMediaGame]）；单测可注入假写入方
/// 断言 flush 时机与聚合值，无需真实 DB。
typedef GalHookActivityWriter = Future<void> Function({
  required String title,
  String? mediaKey,
  required String dateKey,
  required int timestampMs,
  required int durationMs,
  required int charsDelta,
});

enum GalHookSessionPhase {
  idle,
  resolving,
  launching,
  attaching,
  injecting,
  waitingSignals,
  running,
  degraded,
  stopping,
  error,
}

enum GalHookAudioBackend { none, gameResource, enginePcm, systemLoopback }

/// 「活跃音轨」空列表时的解释分支（BUG-1027，纯函数可单测）。
///
/// gameResource 模式语音按句直接提取资源文件、不进共享内存 PCM 环（native
/// `ListAudioTracks` 只枚举 PCM 环，voice_hook_reader.cpp:546），空列表是**常态**
/// 而非故障；systemLoopback 是整机混音单流，同样没有逐轨枚举。只有引擎 PCM /
/// 无音频后端时才保留通用「尚无音轨数据」空态。
enum GalTrackEmptyHint { generic, resourceMode, loopbackMode }

/// 按音频后端返回音轨空态解释分支。
GalTrackEmptyHint galTrackEmptyHintFor(GalHookAudioBackend backend) =>
    switch (backend) {
      GalHookAudioBackend.gameResource => GalTrackEmptyHint.resourceMode,
      GalHookAudioBackend.systemLoopback => GalTrackEmptyHint.loopbackMode,
      _ => GalTrackEmptyHint.generic,
    };

/// [GalHookSessionController.exportTrackPreview] 的产物：临时 WAV 路径 + 时长。
@immutable
class GalTrackPreview {
  const GalTrackPreview({required this.filePath, required this.durationMs});

  final String filePath;
  final int durationMs;
}

/// 试听临时 WAV 的文件名（纯函数，可单测）：轨指针十六进制 + 抓取用文本时间戳。
String galTrackPreviewFileName({
  required int sourcePtr,
  required int timestampMs,
}) =>
    'gal_track_preview_${sourcePtr.toRadixString(16)}_$timestampMs.wav';

enum GalHookEventSeverity { info, success, warning, error }

@immutable
class GalHookEvent {
  const GalHookEvent({
    required this.id,
    required this.timestamp,
    required this.severity,
    required this.stage,
    required this.code,
    required this.summary,
    this.details = const <String, Object?>{},
  });

  final int id;
  final DateTime timestamp;
  final GalHookEventSeverity severity;
  final String stage;
  final String code;
  final String summary;
  final Map<String, Object?> details;
}

@immutable
class GalHookSessionState {
  const GalHookSessionState({
    this.phase = GalHookSessionPhase.idle,
    this.externalWindowMode = false,
    this.allowAudioFallback = true,
    this.boundWindow,
    this.gamePid,
    this.launchExe,
    this.sessionStartedAt,
    this.audioBackend = GalHookAudioBackend.none,
    this.audioFormat,
    this.fallbackReason,
    this.lastError,
    this.textSignalReceived = false,
    this.textGapCount = 0,
    this.textDuplicateCount = 0,
    this.audioTracks = const <GalAudioTrack>[],
    this.selectedAudioSourcePtr = 0,
    this.excludedAudioSourcePtrs = const <int>{},
  });

  final GalHookSessionPhase phase;
  final bool externalWindowMode;
  final bool allowAudioFallback;
  final ExternalWindowInfo? boundWindow;
  final int? gamePid;
  final String? launchExe;
  final DateTime? sessionStartedAt;
  final GalHookAudioBackend audioBackend;
  final PcmFormat? audioFormat;
  final String? fallbackReason;
  final String? lastError;
  final bool textSignalReceived;
  final int textGapCount;
  final int textDuplicateCount;
  final List<GalAudioTrack> audioTracks;
  final int selectedAudioSourcePtr;
  final Set<int> excludedAudioSourcePtrs;

  bool get isActive =>
      phase != GalHookSessionPhase.idle && phase != GalHookSessionPhase.error;
  bool get hasText => textSignalReceived;
  bool get hasAudio => audioBackend != GalHookAudioBackend.none;
  bool get hasWindow => boundWindow != null;
  bool get isDegraded => phase == GalHookSessionPhase.degraded;

  GalHookSessionState copyWith({
    GalHookSessionPhase? phase,
    bool? externalWindowMode,
    bool? allowAudioFallback,
    ExternalWindowInfo? boundWindow,
    bool clearBoundWindow = false,
    int? gamePid,
    bool clearGamePid = false,
    String? launchExe,
    bool clearLaunchExe = false,
    DateTime? sessionStartedAt,
    bool clearSessionStartedAt = false,
    GalHookAudioBackend? audioBackend,
    PcmFormat? audioFormat,
    bool clearAudioFormat = false,
    String? fallbackReason,
    bool clearFallbackReason = false,
    String? lastError,
    bool clearLastError = false,
    bool? textSignalReceived,
    int? textGapCount,
    int? textDuplicateCount,
    List<GalAudioTrack>? audioTracks,
    int? selectedAudioSourcePtr,
    Set<int>? excludedAudioSourcePtrs,
  }) {
    return GalHookSessionState(
      phase: phase ?? this.phase,
      externalWindowMode: externalWindowMode ?? this.externalWindowMode,
      allowAudioFallback: allowAudioFallback ?? this.allowAudioFallback,
      boundWindow: clearBoundWindow ? null : boundWindow ?? this.boundWindow,
      gamePid: clearGamePid ? null : gamePid ?? this.gamePid,
      launchExe: clearLaunchExe ? null : launchExe ?? this.launchExe,
      sessionStartedAt: clearSessionStartedAt
          ? null
          : sessionStartedAt ?? this.sessionStartedAt,
      audioBackend: audioBackend ?? this.audioBackend,
      audioFormat: clearAudioFormat ? null : audioFormat ?? this.audioFormat,
      fallbackReason:
          clearFallbackReason ? null : fallbackReason ?? this.fallbackReason,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      textSignalReceived: textSignalReceived ?? this.textSignalReceived,
      textGapCount: textGapCount ?? this.textGapCount,
      textDuplicateCount: textDuplicateCount ?? this.textDuplicateCount,
      audioTracks: audioTracks ?? this.audioTracks,
      selectedAudioSourcePtr:
          selectedAudioSourcePtr ?? this.selectedAudioSourcePtr,
      excludedAudioSourcePtrs:
          excludedAudioSourcePtrs ?? this.excludedAudioSourcePtrs,
    );
  }
}

typedef GalEngineSourceFactory = EngineHookGalAudioSource Function({
  required int targetPid,
  required String? launchExe,
  required String injectorPath,
  required bool lunaPcHooks,
  int? lunaCodepage,
});
typedef GalLoopbackSourceFactory = LoopbackGalAudioSource Function();
typedef GalTargetWow64Probe = Future<bool?> Function(int pid);
typedef GalExe32BitProbe = Future<bool?> Function(String path);
typedef GalWindowListLoader = Future<List<ExternalWindowInfo>> Function();
typedef GalInjectorResolver = String? Function({required bool is32Bit});

/// App 级 galgame 捕获会话真相源。
///
/// 页面只发送 bind/launch/stop/select-track intent。音频源、文本轮询、稳定台词 id、
/// 句音缓存和结构化事件都在这里跨页面存活，避免切换侧边栏时隐式停止捕获。
class GalHookSessionController extends ChangeNotifier {
  GalHookSessionController({
    TexthookerService? textService,
    GalEngineSourceFactory? engineSourceFactory,
    GalLoopbackSourceFactory? loopbackSourceFactory,
    GalTargetWow64Probe? targetWow64Probe,
    GalExe32BitProbe? exe32BitProbe,
    GalWindowListLoader? windowListLoader,
    GalInjectorResolver? injectorResolver,
    DateTime Function()? now,
    bool? isWindows,
    Duration textPollInterval = const Duration(milliseconds: 400),
    Duration windowPollInterval = const Duration(milliseconds: 500),
    Duration resourceAudioWait = const Duration(milliseconds: 1200),
    Duration resourceAudioPollInterval = const Duration(milliseconds: 80),
    int windowPollAttempts = 20,
    Duration windowRebindInterval = const Duration(seconds: 2),
    Duration trackRefreshInterval = const Duration(seconds: 5),
    Listenable? endpointListenable,
    List<TexthookerEndpointStatus> Function()? endpointStatusLoader,
    GalHookActivityWriter? activityWriter,
  })  : _textService = textService ?? TexthookerService.instance,
        _activityWriter = activityWriter,
        _engineSourceFactory = engineSourceFactory ?? _defaultEngineFactory,
        _loopbackSourceFactory =
            loopbackSourceFactory ?? LoopbackGalAudioSource.new,
        _targetWow64Probe =
            targetWow64Probe ?? EngineHookGalAudioSource.targetIsWow64,
        _exe32BitProbe = exe32BitProbe ?? EngineHookGalAudioSource.exeIs32Bit,
        _windowListLoader =
            windowListLoader ?? WindowCaptureChannel.listWindows,
        _injectorResolver = injectorResolver ?? defaultInjectorResolver,
        _now = now ?? DateTime.now,
        _isWindows = isWindows ?? Platform.isWindows,
        _textPollInterval = textPollInterval,
        _windowPollInterval = windowPollInterval,
        _resourceAudioWait = resourceAudioWait,
        _resourceAudioPollInterval = resourceAudioPollInterval,
        _windowPollAttempts = windowPollAttempts,
        _windowRebindInterval = windowRebindInterval,
        _trackRefreshInterval = trackRefreshInterval,
        _endpointListenable =
            endpointListenable ?? TexthookerWsClientManager.instance,
        _endpointStatusLoader = endpointStatusLoader ??
            (() => TexthookerWsClientManager.instance.endpointStatuses) {
    final List<TexthookerLineEntry> initialEntries = _textService.entries;
    _lastObservedLineId =
        initialEntries.isEmpty ? null : initialEntries.last.id;
    _state = _state.copyWith(textSignalReceived: initialEntries.isNotEmpty);
    _textService.addListener(_onTextBufferChanged);
    _endpointListenable.addListener(_onEndpointStatusChanged);
  }

  static final GalHookSessionController instance = GalHookSessionController();
  static const int _voiceCacheMax = 200;
  static const int _galAudioBackMs = 8000;
  static const int _eventLimit = 400;

  final TexthookerService _textService;
  final GalEngineSourceFactory _engineSourceFactory;
  final GalLoopbackSourceFactory _loopbackSourceFactory;
  final GalTargetWow64Probe _targetWow64Probe;
  final GalExe32BitProbe _exe32BitProbe;
  final GalWindowListLoader _windowListLoader;
  final GalInjectorResolver _injectorResolver;
  final DateTime Function() _now;
  final bool _isWindows;
  final Duration _textPollInterval;
  final Duration _windowPollInterval;
  final Duration _resourceAudioWait;
  final Duration _resourceAudioPollInterval;
  final int _windowPollAttempts;
  final Duration _windowRebindInterval;
  final Duration _trackRefreshInterval;
  final Listenable _endpointListenable;
  final List<TexthookerEndpointStatus> Function() _endpointStatusLoader;

  GalHookSessionState _state = const GalHookSessionState();
  GalHookSessionState get state => _state;
  List<TexthookerLineEntry> get lines => _textService.entries;
  List<TexthookerTextThread> get textThreads => _textService.textThreads;
  String? get selectedTextThreadKey {
    final String? selected = _selectedTextThreadKey;
    if (selected == null) return null;
    return textThreads.any((thread) => thread.key == selected)
        ? selected
        : null;
  }

  int? get selectedNativeTextThreadId => _selectedNativeTextThreadId;
  String? get currentLaunchExecutable => _state.launchExe;
  TexthookerTextThread? get selectedTextThread {
    final String? key = selectedTextThreadKey;
    if (key == null) return null;
    for (final TexthookerTextThread thread in textThreads) {
      if (thread.key == key) return thread;
    }
    return null;
  }

  /// 当前捕获会话、当前线程的有效行。历史缓冲仍保留在 [lines]，但浮窗和场景
  /// 制卡只允许消费这里的行，防止跨会话或跨线程借用上下文。
  List<TexthookerLineEntry> get selectedSessionLines {
    final DateTime? startedAt = _state.sessionStartedAt;
    if (startedAt == null) return const <TexthookerLineEntry>[];
    return List<TexthookerLineEntry>.unmodifiable(
      _textService
          .entriesForTextThread(selectedTextThreadKey)
          .where((entry) => !entry.receivedAt.isBefore(startedAt)),
    );
  }

  TexthookerLineEntry? entryById(String lineId) =>
      _textService.entryById(lineId);

  bool isLineInCurrentSession(TexthookerLineEntry entry) {
    final DateTime? startedAt = _state.sessionStartedAt;
    return startedAt != null && !entry.receivedAt.isBefore(startedAt);
  }

  List<TexthookerEndpointStatus> get endpointStatuses =>
      _endpointStatusLoader();

  /// 当前是否存在引擎 hook 源。音轨选择 / 排除 / 试听等能力只在此时有意义；
  /// 诊断页据此把「选轨不生效」显式提示给用户（BUG-1027），不再静默失败。
  bool get hasEngineSource => _engineSource != null;

  final List<GalHookEvent> _events = <GalHookEvent>[];
  List<GalHookEvent> get events => List<GalHookEvent>.unmodifiable(_events);

  GalAudioSource? _audioSource;
  EngineHookGalAudioSource? _engineSource;
  Timer? _textPollTimer;
  Timer? _trackRefreshTimer;
  // BUG-1049：launch 后游戏窗口尚未出现时的重绑监视（见 [_startWindowRebindWatch]）。
  Timer? _windowRebindTimer;
  bool _windowRebindInFlight = false;
  bool _pollInFlight = false;
  int _lastTextSeq = 0;
  int _eventId = 0;
  int _operationGeneration = 0;
  String? _lastObservedLineId;
  String? _selectedTextThreadKey;
  int? _selectedNativeTextThreadId;
  final SerialJobQueue _audioQueue = SerialJobQueue();
  final Set<String> _loopbackCacheInFlight = <String>{};

  final Map<String, GalAudioSlice> _lineVoiceCache = <String, GalAudioSlice>{};
  final Map<String, int> _lineTimestampCache = <String, int>{};
  final Map<String, int> _lineTextEventIdCache = <String, int>{};
  final Map<String, ({int timestampMs, int textEventId})>
      _pendingResourceMatches =
      <String, ({int timestampMs, int textEventId})>{};

  // ── 游戏活动记账（首页「游戏」活动 = activity_events 的唯一写入方）─────────
  /// 纯累计器：把 hook 文本行累计成活跃时长 + 字符数（挂机间隔封顶，见其实现）。
  final GalHookActivityAccumulator _activityAccumulator =
      GalHookActivityAccumulator();

  /// 可注入的落库写入方（单测用假实现）；为 null 时经 [_activityDatabaseResolver]
  /// 惰性取 DB 走默认写入。
  final GalHookActivityWriter? _activityWriter;

  /// 由桌面启动流程注入的 DB 惰性解析器（见 [attachActivityDatabase]）。flush 时才
  /// 解析——App 未初始化完/未注入时解析到 null 静默不落库（累计保留，下次再试），
  /// 避免 start 时急切解引用未初始化的 late 字段。
  HibikiDatabase? Function()? _activityDatabaseResolver;

  /// 当前会话归属的游戏显示名（窗口标题 / 可执行文件名）；null = 无可归属标题。
  String? _activityGameTitle;

  /// 当前会话的稳定游戏 id（launch 模式为可执行文件路径），无稳定 id 时为 null。
  String? _activityGameKey;

  static EngineHookGalAudioSource _defaultEngineFactory({
    required int targetPid,
    required String? launchExe,
    required String injectorPath,
    required bool lunaPcHooks,
    int? lunaCodepage,
  }) {
    return EngineHookGalAudioSource(
      targetPid: targetPid,
      launchExe: launchExe,
      injectorPath: injectorPath,
      lunaPcHooks: lunaPcHooks,
      lunaCodepage: lunaCodepage,
    );
  }

  static String? defaultInjectorResolver({required bool is32Bit}) {
    if (!Platform.isWindows) return null;
    try {
      final String directory = File(Platform.resolvedExecutable).parent.path;
      final String arch = is32Bit ? 'x86' : 'x64';
      final String path =
          '$directory\\voice_hook\\$arch\\hibiki_voice_injector.exe';
      return File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _attachPersistedHookProfiles(
    EngineHookGalAudioSource engine,
  ) async {
    try {
      final LunaHookCodeProfileStore store =
          await LunaHookCodeProfileStore.openDefault();
      engine.lunaHookProfilePath = store.file.path;
    } catch (_) {
      // Profile persistence must never prevent capture; injector built-ins and
      // automatic Luna engine detection remain available.
    }
  }

  Future<void> setExternalWindowMode(bool enabled) async {
    if (!enabled) {
      await stopCapture(keepBinding: true);
      return;
    }
    _setState(_state.copyWith(externalWindowMode: true));
    final ExternalWindowInfo? bound = _state.boundWindow;
    if (bound == null) {
      _record(
        GalHookEventSeverity.info,
        'window',
        'window.binding_required',
        'Capture enabled; waiting for a game window binding',
      );
      return;
    }
    await startAttachedCapture(bound);
  }

  Future<void> bindWindow(ExternalWindowInfo? window) async {
    if (window == null) {
      _setState(_state.copyWith(clearBoundWindow: true));
      _record(
        GalHookEventSeverity.warning,
        'window',
        'window.unbound',
        'Game window binding was removed',
      );
      if (_state.externalWindowMode) await stopCapture(keepBinding: false);
      return;
    }
    _setState(_state.copyWith(boundWindow: window, gamePid: window.pid));
    _record(
      GalHookEventSeverity.success,
      'window',
      'window.bound',
      'Bound game window',
      details: <String, Object?>{
        'pid': window.pid,
        'hwnd': window.hwnd,
        'title': window.title,
      },
    );
    if (_state.externalWindowMode) await startAttachedCapture(window);
  }

  Future<void> startAttachedCapture(ExternalWindowInfo window) async {
    final int generation = ++_operationGeneration;
    await _stopSources();
    if (!_isWindows || generation != _operationGeneration) return;
    _selectedTextThreadKey = null;
    _selectedNativeTextThreadId = null;
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.resolving,
        externalWindowMode: true,
        boundWindow: window,
        gamePid: window.pid,
        sessionStartedAt: _now(),
        clearLaunchExe: true,
        clearLastError: true,
        clearFallbackReason: true,
        textSignalReceived: false,
      ),
    );
    // attach 模式无稳定可执行文件 id：以窗口标题作为游戏名，mediaKey 留空。
    _beginActivitySession(title: window.title, mediaKey: null);
    _record(
      GalHookEventSeverity.info,
      'resolve',
      'session.attach_resolving',
      'Resolving target process architecture',
      details: <String, Object?>{'pid': window.pid},
    );
    final bool? is32Bit = await _targetWow64Probe(window.pid);
    if (generation != _operationGeneration) return;
    final String? injector = _injectorResolver(is32Bit: is32Bit ?? false);
    if (injector != null && window.pid > 0) {
      _setState(_state.copyWith(phase: GalHookSessionPhase.injecting));
      final EngineHookGalAudioSource engine = _engineSourceFactory(
        targetPid: window.pid,
        launchExe: null,
        injectorPath: injector,
        lunaPcHooks: false,
      );
      await _attachPersistedHookProfiles(engine);
      final PcmFormat? format = await engine.start();
      if (generation != _operationGeneration) {
        await engine.stop();
        return;
      }
      if (format != null) {
        if (engine.rawVoiceReady) {
          await _activateResourceWithLoopback(
            generation,
            engine,
            gamePid: window.pid,
          );
        } else {
          _activateEngine(engine, format, gamePid: window.pid);
        }
        return;
      }
      if (engine.textHookReady) {
        await _activateTextWithLoopback(
          generation,
          engine,
          gamePid: window.pid,
        );
        return;
      }
      await engine.stop();
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.engine_attach_failed',
        'Engine audio hook failed; falling back to system loopback',
      );
    } else {
      _record(
        GalHookEventSeverity.warning,
        'helper',
        'helper.missing',
        'Matching voice-hook helper is unavailable; using loopback',
        details: <String, Object?>{'arch': is32Bit == true ? 'x86' : 'x64'},
      );
    }
    await _activateLoopback(
      generation,
      fallbackReason:
          injector == null ? 'helper_missing' : 'engine_attach_failed',
    );
  }

  Future<bool> launchGame(String executablePath) async {
    final int generation = ++_operationGeneration;
    await _stopSources();
    if (!_isWindows || generation != _operationGeneration) return false;
    _selectedTextThreadKey = null;
    _selectedNativeTextThreadId = null;
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.resolving,
        externalWindowMode: true,
        launchExe: executablePath,
        sessionStartedAt: _now(),
        clearBoundWindow: true,
        clearGamePid: true,
        clearLastError: true,
        clearFallbackReason: true,
        textSignalReceived: false,
      ),
    );
    // launch 模式可执行文件路径是稳定 id：文件名去扩展名作游戏名，路径作 mediaKey。
    _beginActivitySession(
      title: _displayNameForExecutable(executablePath),
      mediaKey: executablePath,
    );
    final bool? is32Bit = await _exe32BitProbe(executablePath);
    final String? injector = _injectorResolver(is32Bit: is32Bit ?? false);
    if (injector == null) {
      _fail(
        'helper',
        'helper.missing',
        'Voice-hook helper is missing for the selected executable architecture',
      );
      return false;
    }
    final bool lunaPcHooks = shouldUseLunaPcHooksForExecutable(executablePath);
    _setState(_state.copyWith(phase: GalHookSessionPhase.launching));
    _record(
      GalHookEventSeverity.info,
      'launch',
      'game.launch_started',
      'Launching game with early injection',
      details: <String, Object?>{
        'exe': executablePath,
        'arch': is32Bit == true ? 'x86' : 'x64',
        'lunaPcHooks': lunaPcHooks,
      },
    );
    final EngineHookGalAudioSource engine = _engineSourceFactory(
      targetPid: 0,
      launchExe: executablePath,
      injectorPath: injector,
      lunaPcHooks: lunaPcHooks,
    );
    await _attachPersistedHookProfiles(engine);
    _setState(_state.copyWith(phase: GalHookSessionPhase.injecting));
    final PcmFormat? format = await engine.start();
    if (generation != _operationGeneration) {
      await engine.stop();
      return false;
    }
    if (format == null && !engine.textHookReady) {
      await engine.stop();
      _fail(
        'inject',
        'engine.launch_or_inject_failed',
        'Game launch or early engine injection failed',
      );
      return false;
    }
    final int? gamePid = engine.gamePid;
    if (format != null) {
      if (engine.rawVoiceReady) {
        await _activateResourceWithLoopback(
          generation,
          engine,
          gamePid: gamePid,
        );
      } else {
        _activateEngine(engine, format, gamePid: gamePid);
      }
    } else if (!await _activateTextWithLoopback(
      generation,
      engine,
      gamePid: gamePid,
    )) {
      return false;
    }
    ExternalWindowInfo? window;
    if (gamePid != null) {
      for (int attempt = 0;
          attempt < _windowPollAttempts && window == null;
          attempt++) {
        final List<ExternalWindowInfo> windows = await _windowListLoader();
        for (final ExternalWindowInfo candidate in windows) {
          if (candidate.pid == gamePid) {
            window = candidate;
            break;
          }
        }
        if (window == null && attempt + 1 < _windowPollAttempts) {
          await Future<void>.delayed(_windowPollInterval);
        }
      }
    }
    if (generation != _operationGeneration) return false;
    if (window != null) {
      _setState(_state.copyWith(boundWindow: window, gamePid: gamePid));
      _record(
        GalHookEventSeverity.success,
        'window',
        'window.auto_bound',
        'Automatically bound the launched game window',
      );
    } else {
      _setState(
        _state.copyWith(
          phase: GalHookSessionPhase.degraded,
          gamePid: gamePid,
          fallbackReason: 'window_not_found',
        ),
      );
      _record(
        GalHookEventSeverity.warning,
        'window',
        'window.not_found',
        'Audio hook is active, but no game window was found for screenshots',
      );
      // BUG-1049：开场那 10 秒只是「窗口通常多快出现」的经验值，不是硬事实——带启动器 /
      // 壳解包 / 首次着色器编译的游戏常常更慢，而首帧一旦错过，旧实现就永久停在
      // window_not_found，用户只能自己去点「捕获目标」条手动选窗口（明明是 Hibiki 自己
      // 启动的进程）。绑定因此改成会话级监视：只要这条会话还活着且仍没有窗口，就继续
      // 按同一个 pid 找，找到即自动绑上。
      // gamePid 为空表示 hook 根本没拿到目标进程，没有可重试的匹配依据。
      if (gamePid != null) _startWindowRebindWatch(generation, gamePid);
    }
    return true;
  }

  /// launch 会话的窗口重绑监视：周期性按 [gamePid] 找顶层窗口，找到就补上绑定并把
  /// 因 `window_not_found` 降级的会话恢复回真实 phase（文本信号来了就是 running，
  /// 否则还在等信号）。绑定成功 / 会话被换代（stop、重启、attach）即自停。
  ///
  /// 只更新状态，不走 [bindWindow]——那条路径是给「用户手动改绑另一个窗口」用的，
  /// 会 [startAttachedCapture] 重启整条会话；这里 hook 已经在跑，重启只会丢台词。
  void _startWindowRebindWatch(int generation, int gamePid) {
    _windowRebindTimer?.cancel();
    _windowRebindTimer = Timer.periodic(_windowRebindInterval, (Timer timer) {
      if (generation != _operationGeneration ||
          _state.boundWindow != null ||
          _state.gamePid != gamePid) {
        timer.cancel();
        _windowRebindTimer = null;
        return;
      }
      if (_windowRebindInFlight) return;
      _windowRebindInFlight = true;
      unawaited(
        _tryRebindWindow(generation, gamePid).whenComplete(() {
          _windowRebindInFlight = false;
        }),
      );
    });
  }

  Future<void> _tryRebindWindow(int generation, int gamePid) async {
    final List<ExternalWindowInfo> windows = await _windowListLoader();
    if (generation != _operationGeneration ||
        _state.boundWindow != null ||
        _state.gamePid != gamePid) {
      return;
    }
    for (final ExternalWindowInfo candidate in windows) {
      if (candidate.pid != gamePid) continue;
      _windowRebindTimer?.cancel();
      _windowRebindTimer = null;
      final bool degradedForWindow =
          _state.phase == GalHookSessionPhase.degraded &&
              _state.fallbackReason == 'window_not_found';
      _setState(
        _state.copyWith(
          boundWindow: candidate,
          gamePid: gamePid,
          phase: degradedForWindow
              ? (_state.textSignalReceived
                  ? GalHookSessionPhase.running
                  : GalHookSessionPhase.waitingSignals)
              : _state.phase,
          clearFallbackReason: degradedForWindow,
        ),
      );
      _record(
        GalHookEventSeverity.success,
        'window',
        'window.auto_bound_late',
        'Bound the launched game window once it appeared',
        details: <String, Object?>{'pid': gamePid, 'hwnd': candidate.hwnd},
      );
      return;
    }
  }

  Future<void> stopCapture({bool keepBinding = true}) async {
    ++_operationGeneration;
    // 会话结束先把剩余累计落库，再复位记账并解除游戏归属（防停后串扰）。
    _flushGameActivity();
    _activityAccumulator.reset();
    _activityGameTitle = null;
    _activityGameKey = null;
    if (_state.phase == GalHookSessionPhase.idle && _audioSource == null) {
      _setState(
        _state.copyWith(
          externalWindowMode: false,
          clearBoundWindow: !keepBinding,
          textSignalReceived: false,
        ),
      );
      return;
    }
    _setState(_state.copyWith(phase: GalHookSessionPhase.stopping));
    _record(
      GalHookEventSeverity.info,
      'session',
      'session.stop_listening',
      'Stopping listeners and helper; injected game code may remain until exit',
    );
    await _stopSources();
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.idle,
        externalWindowMode: false,
        audioBackend: GalHookAudioBackend.none,
        clearAudioFormat: true,
        clearGamePid: true,
        clearLaunchExe: true,
        clearSessionStartedAt: true,
        clearFallbackReason: true,
        clearLastError: true,
        textSignalReceived: false,
        clearBoundWindow: !keepBinding,
        audioTracks: const <GalAudioTrack>[],
        selectedAudioSourcePtr: 0,
        excludedAudioSourcePtrs: const <int>{},
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'session',
      'session.listeners_stopped',
      'Capture listeners stopped',
    );
  }

  /// 两份音轨快照的「轨成员」是否一致（只比 sourcePtr 序列）。低频自动刷新下
  /// clipCount / 能量持续变化，若纳入判等，事件日志会被每轮刷新刷成噪音——
  /// 只有轨的出现/消失才值得记一条结构化事件。
  @visibleForTesting
  static bool sameTrackMembership(
    List<GalAudioTrack> a,
    List<GalAudioTrack> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].sourcePtr != b[i].sourcePtr) return false;
    }
    return true;
  }

  Future<void> refreshAudioTracks() async {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) {
      if (_state.audioTracks.isNotEmpty) {
        _setState(_state.copyWith(audioTracks: const <GalAudioTrack>[]));
      }
      return;
    }
    final int timestamp = _lineTimestampCache.values.isEmpty
        ? 0
        : _lineTimestampCache.values.last;
    final List<GalAudioTrack> tracks = await engine.listAudioTracks(timestamp);
    // await 期间会话可能已停止/重启：旧 engine 的快照不落地（同 BUG-950 范式）。
    if (engine != _engineSource) return;
    final bool membershipChanged =
        !sameTrackMembership(_state.audioTracks, tracks);
    _setState(_state.copyWith(audioTracks: tracks));
    // BUG-1027：刷新已由定时器/状态迁移自动驱动，只有轨成员变化才记事件，
    // 避免 5s 一条「已刷新」把事件日志淹掉。
    if (membershipChanged) {
      _record(
        GalHookEventSeverity.info,
        'audio',
        'audio.tracks_refreshed',
        'Audio track snapshot refreshed',
        details: <String, Object?>{'count': tracks.length},
      );
    }
  }

  /// BUG-1027：音轨快照不再依赖诊断页手动刷新。
  ///
  /// 每次会话激活 / 音频后端切换后（含 [_promoteLateResourceAudio]）先立即刷一次；
  /// 引擎 PCM 与「文本 + Loopback 混合」（engine 仍存活）两种形态另起**会话级**低频
  /// 定时器持续刷新。定时器挂在会话生命周期而非诊断页可见性上：控制器不感知页面
  /// 路由，且 [_trackRefreshInterval]（默认 5s）一次的共享内存枚举成本可忽略，为可见性
  /// 门控引入页面回调只会增加状态同步面。gameResource 模式语音走逐句资源文件、不进
  /// PCM 环（voice_hook_reader.cpp:546 只枚举 PCM 环），刷一次保持快照一致即可，不开
  /// 定时器。[_stopSources] 统一回收定时器。
  void _syncTrackAutoRefresh() {
    _trackRefreshTimer?.cancel();
    _trackRefreshTimer = null;
    if (_engineSource == null) return;
    unawaited(refreshAudioTracks());
    final GalHookAudioBackend backend = _state.audioBackend;
    if (backend == GalHookAudioBackend.enginePcm ||
        backend == GalHookAudioBackend.systemLoopback) {
      _trackRefreshTimer = Timer.periodic(
        _trackRefreshInterval,
        (_) => unawaited(refreshAudioTracks()),
      );
    }
  }

  /// 试听指定音轨（BUG-1027）：按最近一条 hook 台词时间戳，经既有 `grabUtterance`
  /// IPC 抓取该 [sourcePtr] 在 `[ts-200, ts+6000]` 窗口内的整句 PCM（native
  /// `GrabUtterance`，voice_hook_reader.cpp:408——`target_source` 非 0 时直接按轨过滤；
  /// exclude 传空集，试听已标记 BGM 的轨同样允许），拼成 WAV 写入系统临时目录，播放
  /// 器可直接播（无需 ffmpeg 转码）。无 engine / 尚无台词时间戳 / 该轨窗口内无 PCM /
  /// 写盘失败时返回 null 并记结构化事件（调用方 toast 提示，不静默）。
  Future<GalTrackPreview?> exportTrackPreview(int sourcePtr) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return null;
    final int timestamp = _lineTimestampCache.values.isEmpty
        ? 0
        : _lineTimestampCache.values.last;
    final GalAudioSlice? slice = await engine.grabUtterance(
      timestamp,
      sourcePtr: sourcePtr,
      exclude: const <int>[],
    );
    if (slice == null || slice.isEmpty) {
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.track_preview_empty',
        'No recent PCM was available on the selected track',
        details: <String, Object?>{'sourcePtr': sourcePtr, 'tsMs': timestamp},
      );
      return null;
    }
    try {
      final Directory dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'hibiki_gal_track_preview',
      );
      await dir.create(recursive: true);
      final File out = File(
        '${dir.path}${Platform.pathSeparator}'
        '${galTrackPreviewFileName(sourcePtr: sourcePtr, timestampMs: timestamp)}',
      );
      await out.writeAsBytes(buildWavBytes(slice.pcm, slice.format),
          flush: true);
      final int durationMs =
          pcmDurationMs(slice.pcm.length, slice.format.byteRate);
      _record(
        GalHookEventSeverity.info,
        'audio',
        'audio.track_preview_ready',
        'Track preview clip exported',
        details: <String, Object?>{
          'sourcePtr': sourcePtr,
          'durationMs': durationMs,
        },
      );
      return GalTrackPreview(filePath: out.path, durationMs: durationMs);
    } catch (error, stack) {
      _record(
        GalHookEventSeverity.error,
        'audio',
        'audio.track_preview_failed',
        'Track preview export failed',
        details: <String, Object?>{'error': '$error', 'stack': '$stack'},
      );
      return null;
    }
  }

  /// 测试缝：向行级 PCM 缓存注入一条冻结切片（[exportLineAudioPreview] 的 ② 路径
  /// 依赖会话期缓存，单测无真实引擎会话）。
  @visibleForTesting
  void debugCacheLineVoice(String lineId, GalAudioSlice slice) {
    _lineVoiceCache[lineId] = slice;
  }

  /// 试听指定台词行已配的音频（实时台词列表行内播放按钮）：
  ///  ① `game_resource` 行 → 直接返回 dump 目录里的原始资源文件路径（OGG/WAV，
  ///     播放器原生可解，**不走** ffmpeg 转码链；时长未知记 0，调用方按上限兜底复位）；
  ///  ② 引擎 PCM / loopback 兜底行 → [_lineVoiceCache] 冻结切片拼 WAV 写临时目录。
  /// 只读既有配对结果，不改行状态、不影响制卡链路；取不到返回 null 并记结构化事件。
  Future<GalTrackPreview?> exportLineAudioPreview(String lineId) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    final String? resourceId = _resourceIdForLine(lineId);
    if (engine != null && resourceId != null) {
      final String? path = engine.pairedVoiceFilePathForResourceId(resourceId);
      if (path != null) {
        return GalTrackPreview(filePath: path, durationMs: 0);
      }
    }
    final GalAudioSlice? slice = _lineVoiceCache[lineId];
    if (slice != null && !slice.isEmpty) {
      try {
        final Directory dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'hibiki_gal_track_preview',
        );
        await dir.create(recursive: true);
        final File out = File(
          '${dir.path}${Platform.pathSeparator}gal_line_preview_$lineId.wav',
        );
        await out.writeAsBytes(buildWavBytes(slice.pcm, slice.format),
            flush: true);
        return GalTrackPreview(
          filePath: out.path,
          durationMs: pcmDurationMs(slice.pcm.length, slice.format.byteRate),
        );
      } catch (error) {
        _record(
          GalHookEventSeverity.error,
          'audio',
          'audio.line_preview_failed',
          'Line preview export failed',
          details: <String, Object?>{'lineId': lineId, 'error': '$error'},
        );
        return null;
      }
    }
    _record(
      GalHookEventSeverity.warning,
      'audio',
      'audio.line_preview_unavailable',
      'No playable audio for the selected line',
      details: <String, Object?>{'lineId': lineId},
    );
    return null;
  }

  void selectVoiceTrack(int sourcePtr) {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) {
      // BUG-1027：此前静默 return，诊断页点 radio 毫无反馈。记结构化警告事件，
      // 页面另以 toast 明示「选轨需要引擎 hook 会话」。
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.voice_track_select_unavailable',
        'Voice-track selection requires an active engine hook session',
        details: <String, Object?>{'sourcePtr': sourcePtr},
      );
      return;
    }
    engine.selectedAudioSourcePtr = sourcePtr;
    _setState(_state.copyWith(selectedAudioSourcePtr: sourcePtr));
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.voice_track_selected',
      sourcePtr == 0
          ? 'Automatic voice-track selection enabled'
          : 'Voice track selected',
      details: <String, Object?>{'sourcePtr': sourcePtr},
    );
  }

  Future<bool> selectTextThread(
    int? threadId, {
    String? threadKey,
  }) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    // WebSocket/剪贴板等外部 Hook 线程没有 native helper，也仍需由 app 级状态
    // 驱动工作台与浮窗过滤；有 helper 时再同步其 native thread id。
    final bool selected =
        engine == null || await engine.selectTextThread(threadId);
    if (selected) {
      _selectedTextThreadKey =
          threadKey == null || threadKey.isEmpty ? null : threadKey;
      _selectedNativeTextThreadId =
          threadId == null || threadId == 0 ? null : threadId;
    }
    _record(
      selected ? GalHookEventSeverity.success : GalHookEventSeverity.warning,
      'text',
      selected ? 'text.thread_selected' : 'text.thread_select_failed',
      threadId == null || threadId == 0
          ? 'Automatic text-thread selection enabled'
          : 'Text thread selected',
      details: <String, Object?>{
        'threadId': threadId ?? 0,
        if (threadKey != null) 'threadKey': threadKey,
      },
    );
    if (selected) notifyListeners();
    return selected;
  }

  void setTrackExcluded(int sourcePtr, bool excluded) {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return;
    if (excluded) {
      engine.excludedAudioSourcePtrs.add(sourcePtr);
    } else {
      engine.excludedAudioSourcePtrs.remove(sourcePtr);
    }
    _setState(
      _state.copyWith(
        excludedAudioSourcePtrs: Set<int>.unmodifiable(
          engine.excludedAudioSourcePtrs,
        ),
      ),
    );
    _record(
      GalHookEventSeverity.info,
      'audio',
      excluded ? 'audio.track_excluded' : 'audio.track_restored',
      excluded ? 'Audio track marked as BGM/excluded' : 'Audio track restored',
      details: <String, Object?>{'sourcePtr': sourcePtr},
    );
  }

  Future<Uint8List?> captureAudioBytes({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) {
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    if (entry == null ||
        entry.text != sentence ||
        !isLineInCurrentSession(entry)) {
      _markLineAudioMissing(lineId, 'line_context_unavailable');
      return Future<Uint8List?>.value(null);
    }
    // 串行化 + 永不毒化（BUG-956）：单次语音采集异常（含事件记录自身抛）不得让后续采集永久挂起。
    return _audioQueue.enqueue<Uint8List?>(
      () => _captureAudioBytesNow(
        lineId: lineId,
        sentence: sentence,
        outputExtension: outputExtension,
      ),
      buildFailure: (Object error, StackTrace stack) => null,
      onError: (Object error, StackTrace stack) => _record(
        GalHookEventSeverity.error,
        'card',
        'card.audio_capture_exception',
        'Audio capture job failed',
        details: <String, Object?>{'error': '$error', 'stack': '$stack'},
      ),
    );
  }

  Future<Uint8List?> _captureAudioBytesNow({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) async {
    final GalAudioSource? source = _audioSource;
    final EngineHookGalAudioSource? engine = _engineSource;
    if (source == null && engine == null) {
      _markLineAudioMissing(lineId, 'audio_source_unavailable');
      return null;
    }
    final int timestamp = _lineTimestampCache[lineId] ?? 0;
    if (engine != null && _isWindows) {
      final Uint8List? paired = await _waitForPairedResourceAudio(
        engine,
        lineId: lineId,
        timestamp: timestamp,
        outputExtension: outputExtension,
      );
      if (paired != null && paired.isNotEmpty) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.encoded,
          // 资源来源可能是 Siglus OVK OGG，也可能是 Unity Addressables WAV；
          // 统一用不泄漏容器格式的名称，避免把 Unity 资源误报成 OGG。
          backend: 'game_resource',
        );
        _record(
          GalHookEventSeverity.success,
          'match',
          'audio.paired_voice_encoded',
          'Paired original voice audio encoded for mining',
          details: <String, Object?>{
            'lineId': lineId,
            'chars': sentence.length,
          },
        );
        return paired;
      }
      if (timestamp > 0) {
        _record(
          GalHookEventSeverity.warning,
          'match',
          'audio.paired_voice_not_found',
          'No paired original voice candidate; falling back to PCM',
          details: <String, Object?>{'lineId': lineId},
        );
      }
      if (!_state.allowAudioFallback) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.missing,
          backend: 'game_resource',
          fallbackReason: 'paired_voice_not_found_fallback_disabled',
        );
        _record(
          GalHookEventSeverity.warning,
          'match',
          'audio.fallback_disabled',
          'No paired game resource audio and fallback is disabled',
          details: <String, Object?>{'lineId': lineId},
        );
        return null;
      }
    }
    GalAudioSlice? slice = _lineVoiceCache[lineId];
    // 会话已经选用 Loopback 时，engine 仍需保活来提供文本/资源事件，但它的 PCM
    // 明确没有通过 readiness 门。此时绝不能因为共享内存里残留着可读 clip 就重新
    // 借用 engine PCM；否则会把错误格式/碎片缓存伪装成 system_loopback。
    if ((slice == null || slice.isEmpty) &&
        engine != null &&
        identical(source, engine) &&
        timestamp > 0) {
      slice = await engine.grabUtterance(timestamp) ??
          await engine.grabClipNear(timestamp);
    }
    if (slice == null || slice.isEmpty) {
      _markLineAudioMissing(lineId, 'line_audio_not_cached');
      return null;
    }
    final Directory jobDirectory = await Directory.systemTemp.createTemp(
      'hibiki-gal-mining-job-',
    );
    try {
      final Uint8List? encoded = await pcmSliceToAacBytes(
        pcm: slice.pcm,
        format: slice.format,
        tempDir: jobDirectory.path,
        outputExtension: outputExtension,
      );
      if (encoded == null || encoded.isEmpty) {
        _markLineAudioMissing(lineId, 'pcm_encode_failed');
        return null;
      }
      final String backend =
          identical(source, engine) ? 'engine_pcm' : 'system_loopback';
      _textService.updateLineAudio(
        lineId,
        status: TexthookerLineAudioStatus.encoded,
        backend: backend,
        durationMs: (slice.pcm.length * 1000) ~/ slice.format.byteRate,
        fallbackReason:
            timestamp > 0 ? 'paired_voice_not_found' : 'no_engine_timestamp',
      );
      _record(
        GalHookEventSeverity.success,
        'encode',
        'audio.pcm_encoded',
        'PCM fallback audio encoded for mining',
        details: <String, Object?>{'lineId': lineId, 'backend': backend},
      );
      return encoded;
    } finally {
      try {
        await jobDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 资源 hook 已就绪时，资源文件仍可能比文本环晚几十到几百毫秒落盘。制卡不能在第一次
  /// 未命中后立刻录 Loopback；先给资源一个短暂、有上限的等待窗口，超时后才走既有降级链。
  Future<Uint8List?> _waitForPairedResourceAudio(
    EngineHookGalAudioSource engine, {
    required String lineId,
    required int timestamp,
    required String outputExtension,
  }) async {
    final Stopwatch elapsed = Stopwatch()..start();
    final int waitUs = _resourceAudioWait.inMicroseconds;
    final int pollUs = _resourceAudioPollInterval.inMicroseconds;
    while (true) {
      String? resourceId = _resourceIdForLine(lineId);
      // BUG-955：mine 阶段解析具体某行，绝不走「最新语音」兜底——历史行时间戳被淘汰后 timestamp=0，
      // 借最新语音会把当前语音错配给旧台词。晚附着 live 行的资源已在捕获期固化到 _resourceIdForLine，
      // 这里只按精确 resourceId / 正时间戳窗口取，取不到就交给下游 PCM/loopback 或明确 missing。
      resourceId ??= engine.findPairedVoiceResourceId(
        timestamp,
        textEventId: _lineTextEventIdCache[lineId],
        allowLatestSessionFallback: false,
      );
      if (resourceId != null && _resourceIdForLine(lineId) == null) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.matched,
          backend: 'game_resource',
          resourceId: resourceId,
        );
      }
      final Uint8List? bytes = await engine.grabPairedVoiceBytes(
        timestamp,
        outputExtension: outputExtension,
        textEventId: _lineTextEventIdCache[lineId],
        resourceId: resourceId,
        allowLatestSessionFallback: false,
      );
      if (bytes != null && bytes.isNotEmpty) return bytes;
      if (!engine.rawVoiceReady ||
          waitUs <= 0 ||
          elapsed.elapsedMicroseconds >= waitUs) {
        return null;
      }
      final int remainingUs = waitUs - elapsed.elapsedMicroseconds;
      final int delayUs = pollUs <= 0
          ? remainingUs
          : (pollUs < remainingUs ? pollUs : remainingUs);
      if (delayUs <= 0) return null;
      await Future<void>.delayed(Duration(microseconds: delayUs));
    }
  }

  String? _resourceIdForLine(String lineId) {
    for (final TexthookerLineEntry line in _textService.entries) {
      if (line.id == lineId) return line.audioResourceId;
    }
    return null;
  }

  void setAllowAudioFallback(bool value) {
    if (_state.allowAudioFallback == value) return;
    _setState(_state.copyWith(allowAudioFallback: value));
    _record(
      GalHookEventSeverity.info,
      'audio',
      value ? 'audio.fallback_enabled' : 'audio.fallback_disabled_by_user',
      value
          ? 'Audio fallback enabled'
          : 'Audio fallback disabled; game resource audio is required',
    );
  }

  void clearEvents() {
    if (_events.isEmpty) return;
    _events.clear();
    notifyListeners();
  }

  Future<void> close() async {
    ++_operationGeneration;
    _flushGameActivity();
    _activityAccumulator.reset();
    _textService.removeListener(_onTextBufferChanged);
    _endpointListenable.removeListener(_onEndpointStatusChanged);
    await _stopSources();
    dispose();
  }

  /// 注入 activity_events 落库用的 DB 惰性解析器（桌面启动流程
  /// [GalHookTextOverlayController.start] 调用一次；解析在每次 flush 时发生，
  /// App 尚未初始化完则返回 null 跳过本次落库）。是首页「游戏」活动的唯一数据来源。
  void attachActivityDatabase(HibikiDatabase? Function() resolve) {
    _activityDatabaseResolver = resolve;
  }

  /// 开始一段游戏活动记账：先把上一段残留 flush（防上次异常未落），再复位累计器并
  /// 绑定本会话的游戏标题/稳定 id。会话开始（attach / launch）时调用。
  void _beginActivitySession({required String title, String? mediaKey}) {
    _flushGameActivity();
    _activityAccumulator.reset();
    final String trimmed = title.trim();
    _activityGameTitle = trimmed.isEmpty ? null : trimmed;
    _activityGameKey = mediaKey == null || mediaKey.isEmpty ? null : mediaKey;
  }

  /// 记一行 hook 文本到活动累计；命中中途 flush 阈值即落一条（防崩溃丢账）。
  /// 仅在已开始游戏活动会话（[_activityGameTitle] 非空）时记账——纯 WebSocket/剪贴板
  /// 文本流没有绑定游戏进程、无可归属标题，不计入「游戏」活动。
  void _recordActivityLine(String text) {
    if (text.isEmpty || _activityGameTitle == null) return;
    _activityAccumulator.recordLine(
      text.length,
      _now().millisecondsSinceEpoch,
    );
    if (_activityAccumulator.shouldFlush) _flushGameActivity();
  }

  /// 可执行文件路径 → 展示用游戏名：取文件名去扩展名（跨平台按 `/` 或 `\` 切分）。
  String _displayNameForExecutable(String path) {
    final String name = path.split(RegExp(r'[\\/]')).last;
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 把当前累计（活跃时长 + 字符数）落一条 activity_events。无可归属标题、无 DB/写入
  /// 方或无累计时不落（保留累计，等下一行或会话结束再试）；落库失败静默（try/catch）。
  void _flushGameActivity() {
    final String? title = _activityGameTitle;
    final GalHookActivityWriter? writer = _resolveActivityWriter();
    if (title == null || writer == null) return;
    if (!_activityAccumulator.hasPending) return;
    final (int charsDelta, int durationMs) = _activityAccumulator.drain();
    if (charsDelta <= 0 && durationMs <= 0) return;
    final String? mediaKey = _activityGameKey;
    final DateTime now = _now();
    unawaited(
      _safeWriteActivity(
        writer: writer,
        title: title,
        mediaKey: mediaKey,
        charsDelta: charsDelta,
        durationMs: durationMs,
        now: now,
      ),
    );
  }

  GalHookActivityWriter? _resolveActivityWriter() {
    final GalHookActivityWriter? injected = _activityWriter;
    if (injected != null) return injected;
    final HibikiDatabase? database = _activityDatabaseResolver?.call();
    if (database == null) return null;
    return ({
      required String title,
      String? mediaKey,
      required String dateKey,
      required int timestampMs,
      required int durationMs,
      required int charsDelta,
    }) =>
        database.addActivityEvent(
          eventType: kActivityGame,
          mediaType: kActivityMediaGame,
          title: title,
          mediaKey: mediaKey,
          dateKey: dateKey,
          timestampMs: timestampMs,
          durationMs: durationMs,
          charsDelta: charsDelta,
        );
  }

  Future<void> _safeWriteActivity({
    required GalHookActivityWriter writer,
    required String title,
    required String? mediaKey,
    required int charsDelta,
    required int durationMs,
    required DateTime now,
  }) async {
    try {
      await writer(
        title: title,
        mediaKey: mediaKey,
        dateKey: HibikiTimeFormat.dayKey(now),
        timestampMs: now.millisecondsSinceEpoch,
        durationMs: durationMs,
        charsDelta: charsDelta,
      );
    } catch (error, stack) {
      _record(
        GalHookEventSeverity.warning,
        'activity',
        'activity.write_failed',
        'Failed to persist game activity event',
        details: <String, Object?>{'error': '$error', 'stack': '$stack'},
        notify: false,
      );
    }
  }

  void _activateEngine(
    EngineHookGalAudioSource engine,
    PcmFormat format, {
    int? gamePid,
  }) {
    _audioSource = engine;
    _startEngineTextPolling(engine);
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.enginePcm,
        audioFormat: format,
        gamePid: gamePid,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'inject',
      'engine.hook_ready',
      'Engine hook and IPC are ready; waiting for text signals',
      details: <String, Object?>{
        'pid': gamePid,
        'sampleRate': format.sampleRate,
        'channels': format.channels,
      },
    );
    _syncTrackAutoRefresh();
  }

  /// 原始游戏资源音频是首选，系统回环只作为某句没有资源文件时的兜底。资源 hook 本身
  /// 不提供 PCM 环，因此两条来源必须同时保活：[_engineSource] 负责文本/资源配对，
  /// [_audioSource] 优先持回环（启动失败则保留 engine 空 PCM 源，资源制卡仍可继续）。
  Future<void> _activateResourceWithLoopback(
    int generation,
    EngineHookGalAudioSource engine, {
    int? gamePid,
  }) async {
    final LoopbackGalAudioSource loopback = _loopbackSourceFactory();
    final PcmFormat? fallbackFormat = await loopback.start();
    if (generation != _operationGeneration) {
      await loopback.stop();
      await engine.stop();
      return;
    }
    if (fallbackFormat == null) await loopback.stop();
    _audioSource = fallbackFormat == null ? engine : loopback;
    _startEngineTextPolling(engine);
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.gameResource,
        clearAudioFormat: true,
        gamePid: gamePid,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.game_resource_ready',
      'Game resource audio is primary; system loopback is fallback only',
      details: <String, Object?>{
        'pid': gamePid,
        'loopbackAvailable': fallbackFormat != null,
      },
    );
    _syncTrackAutoRefresh();
  }

  /// 保留已就绪的引擎文本 helper，同时以系统 Loopback 作为独立音频源。
  ///
  /// Unity/IL2CPP 游戏可能让 Luna 文本 hook 正常工作，却不经过当前 XAudio2/
  /// DirectSound PCM 钩子。文本与音频是两项独立能力，不能因为引擎 PCM 缺失就关闭
  /// helper、退化成“只有混音但没有台词”。
  Future<bool> _activateTextWithLoopback(
    int generation,
    EngineHookGalAudioSource engine, {
    int? gamePid,
  }) async {
    final LoopbackGalAudioSource loopback = _loopbackSourceFactory();
    final PcmFormat? format = await loopback.start();
    if (generation != _operationGeneration) {
      await loopback.stop();
      await engine.stop();
      return false;
    }
    if (format == null) {
      await loopback.stop();
    }
    _audioSource = format == null ? null : loopback;
    _startEngineTextPolling(engine);
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.degraded,
        audioBackend: format == null
            ? GalHookAudioBackend.none
            : GalHookAudioBackend.systemLoopback,
        audioFormat: format,
        clearAudioFormat: format == null,
        gamePid: gamePid,
        fallbackReason: format == null
            ? 'all_audio_sources_failed'
            : 'engine_pcm_unavailable',
        lastError: format == null
            ? 'Text hook is ready, but no audio capture source could be started'
            : null,
        clearLastError: format != null,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'text',
      'engine.text_hook_ready',
      'Engine text hook is ready',
      details: <String, Object?>{'pid': gamePid, 'audioMode': 'text_only'},
    );
    _record(
      format == null
          ? GalHookEventSeverity.error
          : GalHookEventSeverity.warning,
      'audio',
      format == null
          ? 'audio.all_sources_failed'
          : 'audio.hybrid_loopback_active',
      format == null
          ? 'Text capture is active, but no audio source is available'
          : 'Text hook is active with system loopback audio',
      details: <String, Object?>{
        if (format != null) 'sampleRate': format.sampleRate,
        if (format != null) 'channels': format.channels,
      },
    );
    _syncTrackAutoRefresh();
    return true;
  }

  void _startEngineTextPolling(EngineHookGalAudioSource engine) {
    _engineSource = engine;
    _lastTextSeq = 0;
    _pollInFlight = false;
    _lineVoiceCache.clear();
    _lineTimestampCache.clear();
    _lineTextEventIdCache.clear();
    _loopbackCacheInFlight.clear();
    _pendingResourceMatches.clear();
    unawaited(engine.pruneVoiceDump());
    _textPollTimer?.cancel();
    _textPollTimer = Timer.periodic(
      _textPollInterval,
      (_) => unawaited(_pollHookedText()),
    );
  }

  Future<void> _activateLoopback(
    int generation, {
    required String fallbackReason,
  }) async {
    final LoopbackGalAudioSource loopback = _loopbackSourceFactory();
    final PcmFormat? format = await loopback.start();
    if (generation != _operationGeneration) {
      await loopback.stop();
      return;
    }
    if (format == null) {
      await loopback.stop();
      _setState(
        _state.copyWith(
          phase: GalHookSessionPhase.degraded,
          audioBackend: GalHookAudioBackend.none,
          fallbackReason: 'all_audio_sources_failed',
          lastError: 'No audio capture source could be started',
          clearAudioFormat: true,
        ),
      );
      _record(
        GalHookEventSeverity.error,
        'audio',
        'audio.all_sources_failed',
        'Engine hook and system loopback are both unavailable',
      );
      return;
    }
    _audioSource = loopback;
    _engineSource = null;
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.degraded,
        audioBackend: GalHookAudioBackend.systemLoopback,
        audioFormat: format,
        fallbackReason: fallbackReason,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.warning,
      'audio',
      'audio.loopback_active',
      'System loopback is active; captured audio may include BGM and effects',
      details: <String, Object?>{
        'fallbackReason': fallbackReason,
        'sampleRate': format.sampleRate,
        'channels': format.channels,
      },
    );
  }

  Future<void> _stopSources() async {
    _textPollTimer?.cancel();
    _textPollTimer = null;
    _trackRefreshTimer?.cancel();
    _trackRefreshTimer = null;
    _windowRebindTimer?.cancel();
    _windowRebindTimer = null;
    _windowRebindInFlight = false;
    _pollInFlight = false;
    final EngineHookGalAudioSource? engine = _engineSource;
    _engineSource = null;
    _lastTextSeq = 0;
    _lineVoiceCache.clear();
    _lineTimestampCache.clear();
    _lineTextEventIdCache.clear();
    _loopbackCacheInFlight.clear();
    _pendingResourceMatches.clear();
    final GalAudioSource? source = _audioSource;
    _audioSource = null;
    if (engine != null && !identical(engine, source)) {
      await engine.stop();
    }
    await source?.stop();
  }

  Future<void> _pollHookedText() async {
    if (_pollInFlight) return;
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return;
    _pollInFlight = true;
    try {
      final bool hadResourceAudio = engine.rawVoiceReady;
      await engine.refreshReadiness();
      if (engine != _engineSource) return;
      if (!hadResourceAudio && engine.rawVoiceReady) {
        _promoteLateResourceAudio(engine);
      }
      final GalTextPoll? poll = await engine.pollText(_lastTextSeq);
      if (poll == null || engine != _engineSource) return;
      final List<GalHookedLine> ordered = List<GalHookedLine>.from(poll.lines)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      int cursor = _lastTextSeq;
      bool receivedTextLine = false;
      for (final GalHookedLine line in ordered) {
        if (line.seq <= cursor) {
          _setState(
            _state.copyWith(textDuplicateCount: _state.textDuplicateCount + 1),
          );
          continue;
        }
        if (line.seq > cursor + 1) {
          _setState(
            _state.copyWith(
              textGapCount: _state.textGapCount + line.seq - cursor - 1,
            ),
          );
          _record(
            GalHookEventSeverity.warning,
            'text',
            'text.sequence_gap',
            'Text sequence gap detected',
            details: <String, Object?>{'from': cursor, 'to': line.seq},
          );
        }
        if (line.eventKind == GalTextEventKind.threadDiscovered) {
          final String? threadKey = line.textThreadKey;
          final String? threadLabel = line.textThreadLabel;
          if (threadKey != null && threadLabel != null) {
            _textService.registerTextThread(
              key: threadKey,
              label: threadLabel,
              hookCode: line.hookCode.isEmpty ? null : line.hookCode,
              nativeThreadId: line.threadId,
            );
          }
          cursor = line.seq;
          continue;
        }
        // 系统 UI 文字（读/存档菜单确认句、存档槽号/时间戳）在 native hook 侧无法与台词区分，
        // 会被 injector 的 hook 赢家选择放行——在喂进文本服务/查词面板前用实证启发式剔除。
        // 推进 cursor 消费掉该 seq，但不置 receivedTextLine（菜单文字不算收到台词信号）。
        if (isGalgameSystemUiLine(line.text)) {
          cursor = line.seq;
          continue;
        }
        final TexthookerLineEntry? entry = _textService.appendLine(
          line.text,
          source: TexthookerLineSource.engineHook,
          sourceLabel: 'engine_hook',
          sourceSequence: line.seq,
          hookTimestampMs: line.timestampMs,
          textThreadKey: line.textThreadKey,
          textThreadLabel: line.textThreadLabel,
          textHookCode: line.hookCode.isEmpty ? null : line.hookCode,
          nativeTextThreadId: line.threadId == 0 ? null : line.threadId,
          audioStatus: TexthookerLineAudioStatus.pending,
        );
        if (entry == null) {
          cursor = line.seq;
          continue;
        }
        receivedTextLine = true;
        _recordActivityLine(entry.text);
        _lineTimestampCache[entry.id] = line.timestampMs;
        _trimCache(_lineTimestampCache);
        _lineTextEventIdCache[entry.id] = line.seq;
        _trimCache(_lineTextEventIdCache);
        GalAudioSlice? clip;
        final String? resourceId = engine.rawVoiceReady
            ? engine.findPairedVoiceResourceId(
                line.timestampMs,
                textEventId: line.seq,
              )
            : null;
        final bool resourceMatched = resourceId != null;
        if (resourceMatched) {
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.matched,
            backend: 'game_resource',
            resourceId: resourceId,
          );
          _record(
            GalHookEventSeverity.success,
            'match',
            'audio.game_resource_matched',
            'Original game resource audio matched to captured line',
            details: <String, Object?>{'lineId': entry.id, 'seq': line.seq},
          );
        } else if (engine.rawVoiceReady) {
          _pendingResourceMatches[entry.id] = (
            timestampMs: line.timestampMs,
            textEventId: line.seq,
          );
          _trimCache(_pendingResourceMatches);
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.pending,
            backend: 'game_resource',
          );
        } else if (identical(_audioSource, engine)) {
          // 只有 readiness 已选择 engine PCM 作为当前音频源时才读取 engine clip。
          // 文本 helper 在 Loopback 降级会话中仍然保活，但它暴露的残留/未通过门控
          // PCM 不能覆盖真正的逐行 Loopback 缓存（BUG-1060）。
          clip = await engine.grabUtterance(line.timestampMs) ??
              await engine.grabClipNear(line.timestampMs);
        }
        if (!resourceMatched && clip != null && !clip.isEmpty) {
          _lineVoiceCache[entry.id] = clip;
          _trimCache(_lineVoiceCache);
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.matched,
            backend: 'engine_pcm',
            durationMs: (clip.pcm.length * 1000) ~/ clip.format.byteRate,
          );
          _record(
            GalHookEventSeverity.success,
            'match',
            'audio.utterance_locked',
            'Audio utterance locked to captured line',
            details: <String, Object?>{'lineId': entry.id, 'seq': line.seq},
          );
        } else if (!resourceMatched && _audioSource is LoopbackGalAudioSource) {
          // Loopback 必须在台词到达时冻结对应环形片段；制卡时再抓“最近声音”会把
          // 后续台词/BGM 错配给旧行。资源音频尚未落盘时也先保留这份逐行兜底，
          // 稍后若资源匹配成功会覆盖为 game_resource。
          await _cacheLoopbackForLine(entry);
        } else if (!engine.rawVoiceReady) {
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.missing,
            fallbackReason: 'utterance_not_found',
          );
          _record(
            GalHookEventSeverity.warning,
            'match',
            'audio.utterance_not_found',
            'No engine utterance matched the captured line',
            details: <String, Object?>{'lineId': entry.id, 'seq': line.seq},
          );
        }
        // BUG-950：上面 grabUtterance / grabClipNear / _cacheLoopbackForLine 的 await 可能
        // 跨越一次 stop/重启。期间 engine 被换掉则当前迭代属于旧会话，立即收手——绝不再推进
        // cursor（否则把新会话已重置的 _lastTextSeq 覆写成旧大值，新文本全被判 duplicate 丢弃）。
        if (engine != _engineSource) {
          return;
        }
        cursor = line.seq;
      }
      _refreshPendingResourceMatches(engine);
      // 只推进到实际看见并处理完成的最大 seq；不能盲用 native header count 跳过未提交槽。
      if (cursor > _lastTextSeq) _lastTextSeq = cursor;
      if (receivedTextLine) {
        _setState(
          _state.copyWith(
            phase: _state.fallbackReason == null
                ? GalHookSessionPhase.running
                : GalHookSessionPhase.degraded,
            textSignalReceived: true,
          ),
        );
      }
    } finally {
      _pollInFlight = false;
    }
  }

  void _promoteLateResourceAudio(EngineHookGalAudioSource engine) {
    if (_state.audioBackend == GalHookAudioBackend.gameResource) return;
    for (final MapEntry<String, int> line in _lineTimestampCache.entries) {
      final int? textEventId = _lineTextEventIdCache[line.key];
      if (textEventId == null) continue;
      _pendingResourceMatches[line.key] = (
        timestampMs: line.value,
        textEventId: textEventId,
      );
    }
    _trimCache(_pendingResourceMatches);
    _setState(
      _state.copyWith(
        phase: _state.textSignalReceived
            ? GalHookSessionPhase.running
            : GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.gameResource,
        clearAudioFormat: true,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.game_resource_late_ready',
      'Late game resource hook is ready and is now the primary audio source',
      details: <String, Object?>{'pid': _state.gamePid},
    );
    _refreshPendingResourceMatches(engine);
    // audioBackend 已切到 gameResource：立即重刷一次音轨快照并停掉 PCM 低频定时器
    //（BUG-1027，资源模式不进 PCM 环，快照保持一致的空/残留态即可）。
    _syncTrackAutoRefresh();
  }

  void _refreshPendingResourceMatches(EngineHookGalAudioSource engine) {
    if (!engine.rawVoiceReady || _pendingResourceMatches.isEmpty) return;
    final List<String> matched = <String>[];
    for (final MapEntry<String, ({int timestampMs, int textEventId})> pending
        in _pendingResourceMatches.entries) {
      final String? resourceId = engine.findPairedVoiceResourceId(
        pending.value.timestampMs,
        textEventId: pending.value.textEventId,
      );
      if (resourceId == null) continue;
      _textService.updateLineAudio(
        pending.key,
        status: TexthookerLineAudioStatus.matched,
        backend: 'game_resource',
        resourceId: resourceId,
      );
      matched.add(pending.key);
    }
    for (final String lineId in matched) {
      _pendingResourceMatches.remove(lineId);
    }
  }

  void _onTextBufferChanged() {
    final List<TexthookerLineEntry> entries = _textService.entries;
    final String? latestId = entries.isEmpty ? null : entries.last.id;
    if (latestId != null && latestId != _lastObservedLineId) {
      final TexthookerLineEntry latest = entries.last;
      if (latest.source != TexthookerLineSource.engineHook) {
        _record(
          GalHookEventSeverity.success,
          'text',
          'text.external_line_received',
          'Text line received from external source',
          details: <String, Object?>{
            'lineId': latest.id,
            'source': latest.sourceLabel ?? latest.source.name,
          },
          notify: false,
        );
        if (_state.phase == GalHookSessionPhase.waitingSignals) {
          _state = _state.copyWith(
            phase: GalHookSessionPhase.running,
            textSignalReceived: true,
          );
        } else {
          _state = _state.copyWith(textSignalReceived: true);
        }
        _recordActivityLine(latest.text);
        unawaited(_cacheLoopbackForLine(latest));
      }
    }
    _lastObservedLineId = latestId;
    notifyListeners();
  }

  void _onEndpointStatusChanged() => notifyListeners();

  Future<void> _cacheLoopbackForLine(TexthookerLineEntry entry) async {
    final GalAudioSource? source = _audioSource;
    if (source is! LoopbackGalAudioSource ||
        !isLineInCurrentSession(entry) ||
        !_loopbackCacheInFlight.add(entry.id)) {
      return;
    }
    try {
      final GalAudioSlice? slice = await source.grabRecent(_galAudioBackMs);
      if (slice == null || slice.isEmpty || _audioSource != source) {
        _markLineAudioMissing(entry.id, 'loopback_line_slice_unavailable');
        return;
      }
      _lineVoiceCache[entry.id] = slice;
      _trimCache(_lineVoiceCache);
      _textService.updateLineAudio(
        entry.id,
        status: TexthookerLineAudioStatus.fallback,
        backend: 'system_loopback',
        durationMs: (slice.pcm.length * 1000) ~/ slice.format.byteRate,
        fallbackReason: 'engine_utterance_unavailable',
      );
      _record(
        GalHookEventSeverity.info,
        'match',
        'audio.loopback_line_locked',
        'System loopback audio was locked to the captured line',
        details: <String, Object?>{'lineId': entry.id},
      );
    } finally {
      _loopbackCacheInFlight.remove(entry.id);
    }
  }

  void _markLineAudioMissing(String lineId, String reason) {
    _textService.updateLineAudio(
      lineId,
      status: TexthookerLineAudioStatus.missing,
      fallbackReason: reason,
    );
    _record(
      GalHookEventSeverity.warning,
      'audio',
      'audio.capture_missing',
      'No audio was available for the selected line',
      details: <String, Object?>{'lineId': lineId, 'reason': reason},
    );
  }

  void _fail(String stage, String code, String message) {
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.error,
        lastError: message,
        audioBackend: GalHookAudioBackend.none,
        clearAudioFormat: true,
      ),
    );
    _record(GalHookEventSeverity.error, stage, code, message);
  }

  void _setState(GalHookSessionState next) {
    _state = next;
    notifyListeners();
  }

  void _record(
    GalHookEventSeverity severity,
    String stage,
    String code,
    String summary, {
    Map<String, Object?> details = const <String, Object?>{},
    bool notify = true,
  }) {
    _events.add(
      GalHookEvent(
        id: _eventId++,
        timestamp: _now(),
        severity: severity,
        stage: stage,
        code: code,
        summary: summary,
        details: Map<String, Object?>.unmodifiable(details),
      ),
    );
    if (_events.length > _eventLimit) {
      _events.removeRange(0, _events.length - _eventLimit);
    }
    if (notify) notifyListeners();
  }

  void _trimCache<T>(Map<String, T> cache) {
    while (cache.length > _voiceCacheMax) {
      cache.remove(cache.keys.first);
    }
  }
}

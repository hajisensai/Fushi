import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/serial_job_queue.dart';
import 'package:hibiki/src/mining/galgame_system_ui_filter.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_manager.dart';

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
    Listenable? endpointListenable,
    List<TexthookerEndpointStatus> Function()? endpointStatusLoader,
  })  : _textService = textService ?? TexthookerService.instance,
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

  final List<GalHookEvent> _events = <GalHookEvent>[];
  List<GalHookEvent> get events => List<GalHookEvent>.unmodifiable(_events);

  GalAudioSource? _audioSource;
  EngineHookGalAudioSource? _engineSource;
  Timer? _textPollTimer;
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
  final Map<String, int> _pendingResourceTimestamps = <String, int>{};

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
    }
    return true;
  }

  Future<void> stopCapture({bool keepBinding = true}) async {
    ++_operationGeneration;
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

  Future<void> refreshAudioTracks() async {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) {
      _setState(_state.copyWith(audioTracks: const <GalAudioTrack>[]));
      return;
    }
    final int timestamp = _lineTimestampCache.values.isEmpty
        ? 0
        : _lineTimestampCache.values.last;
    final List<GalAudioTrack> tracks = await engine.listAudioTracks(timestamp);
    _setState(_state.copyWith(audioTracks: tracks));
    _record(
      GalHookEventSeverity.info,
      'audio',
      'audio.tracks_refreshed',
      'Audio track snapshot refreshed',
      details: <String, Object?>{'count': tracks.length},
    );
  }

  void selectVoiceTrack(int sourcePtr) {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return;
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
    if ((slice == null || slice.isEmpty) && engine != null && timestamp > 0) {
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
      resourceId ??= engine.findPairedVoiceResourceId(timestamp);
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
        resourceId: resourceId,
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
    _textService.removeListener(_onTextBufferChanged);
    _endpointListenable.removeListener(_onEndpointStatusChanged);
    await _stopSources();
    dispose();
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
    return true;
  }

  void _startEngineTextPolling(EngineHookGalAudioSource engine) {
    _engineSource = engine;
    _lastTextSeq = 0;
    _pollInFlight = false;
    _lineVoiceCache.clear();
    _lineTimestampCache.clear();
    _loopbackCacheInFlight.clear();
    _pendingResourceTimestamps.clear();
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
    _pollInFlight = false;
    final EngineHookGalAudioSource? engine = _engineSource;
    _engineSource = null;
    _lastTextSeq = 0;
    _lineVoiceCache.clear();
    _lineTimestampCache.clear();
    _loopbackCacheInFlight.clear();
    _pendingResourceTimestamps.clear();
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
        _lineTimestampCache[entry.id] = line.timestampMs;
        _trimCache(_lineTimestampCache);
        GalAudioSlice? clip;
        final String? resourceId = engine.rawVoiceReady
            ? engine.findPairedVoiceResourceId(line.timestampMs)
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
          _pendingResourceTimestamps[entry.id] = line.timestampMs;
          _trimCache(_pendingResourceTimestamps);
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.pending,
            backend: 'game_resource',
          );
        } else {
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
    _pendingResourceTimestamps.addAll(_lineTimestampCache);
    _trimCache(_pendingResourceTimestamps);
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
  }

  void _refreshPendingResourceMatches(EngineHookGalAudioSource engine) {
    if (!engine.rawVoiceReady || _pendingResourceTimestamps.isEmpty) return;
    final List<String> matched = <String>[];
    for (final MapEntry<String, int> pending
        in _pendingResourceTimestamps.entries) {
      final String? resourceId =
          engine.findPairedVoiceResourceId(pending.value);
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
      _pendingResourceTimestamps.remove(lineId);
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

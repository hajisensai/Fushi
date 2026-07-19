import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_host.dart';

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

enum GalHookAudioBackend { none, pairedVoice, enginePcm, systemLoopback }

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
        _windowPollAttempts = windowPollAttempts,
        _endpointListenable =
            endpointListenable ?? TexthookerWsClientHost.instance,
        _endpointStatusLoader = endpointStatusLoader ??
            (() => TexthookerWsClientHost.instance.endpointStatuses) {
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
  final int _windowPollAttempts;
  final Listenable _endpointListenable;
  final List<TexthookerEndpointStatus> Function() _endpointStatusLoader;

  GalHookSessionState _state = const GalHookSessionState();
  GalHookSessionState get state => _state;
  List<TexthookerLineEntry> get lines => _textService.entries;
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
  Future<void> _miningTail = Future<void>.value();

  final Map<String, GalAudioSlice> _lineVoiceCache = <String, GalAudioSlice>{};
  final Map<String, int> _lineTimestampCache = <String, int>{};

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
        _activateEngine(engine, format, gamePid: window.pid);
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
    if (format == null) {
      await engine.stop();
      _fail(
        'inject',
        'engine.launch_or_inject_failed',
        'Game launch or early engine injection failed',
      );
      return false;
    }
    final int? gamePid = engine.gamePid;
    _activateEngine(engine, format, gamePid: gamePid);
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
    final Completer<Uint8List?> completer = Completer<Uint8List?>();
    _miningTail = _miningTail.then((_) async {
      try {
        completer.complete(
          await _captureAudioBytesNow(
            lineId: lineId,
            sentence: sentence,
            outputExtension: outputExtension,
          ),
        );
      } catch (error, stack) {
        _record(
          GalHookEventSeverity.error,
          'card',
          'card.audio_capture_exception',
          'Audio capture job failed',
          details: <String, Object?>{'error': '$error', 'stack': '$stack'},
        );
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<Uint8List?> _captureAudioBytesNow({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) async {
    final GalAudioSource? source = _audioSource;
    if (source == null) {
      _markLineAudioMissing(lineId, 'audio_source_unavailable');
      return null;
    }
    final EngineHookGalAudioSource? engine = _engineSource;
    final int timestamp = _lineTimestampCache[lineId] ?? 0;
    if (engine != null && _isWindows) {
      final Uint8List? paired = await engine.grabPairedVoiceBytes(
        timestamp,
        outputExtension: outputExtension,
      );
      if (paired != null && paired.isNotEmpty) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.encoded,
          backend: 'paired_voice_ogg',
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
    }
    GalAudioSlice? slice = _lineVoiceCache[lineId];
    if ((slice == null || slice.isEmpty) && engine != null && timestamp > 0) {
      slice = await engine.grabUtterance(timestamp) ??
          await engine.grabClipNear(timestamp);
    }
    slice ??= await source.grabRecent(_galAudioBackMs);
    if (slice == null || slice.isEmpty) {
      _markLineAudioMissing(lineId, 'pcm_unavailable_or_silent');
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
          _state.audioBackend == GalHookAudioBackend.enginePcm
              ? 'engine_pcm'
              : 'system_loopback';
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
    _engineSource = engine;
    _lastTextSeq = 0;
    _pollInFlight = false;
    _lineVoiceCache.clear();
    _lineTimestampCache.clear();
    unawaited(engine.pruneVoiceDump());
    _textPollTimer?.cancel();
    _textPollTimer = Timer.periodic(
      _textPollInterval,
      (_) => unawaited(_pollHookedText()),
    );
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
    _engineSource = null;
    _lastTextSeq = 0;
    _lineVoiceCache.clear();
    _lineTimestampCache.clear();
    final GalAudioSource? source = _audioSource;
    _audioSource = null;
    await source?.stop();
  }

  Future<void> _pollHookedText() async {
    if (_pollInFlight) return;
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return;
    _pollInFlight = true;
    try {
      final GalTextPoll? poll = await engine.pollText(_lastTextSeq);
      if (poll == null || engine != _engineSource) return;
      final List<GalHookedLine> ordered = List<GalHookedLine>.from(poll.lines)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      int cursor = _lastTextSeq;
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
        final TexthookerLineEntry? entry = _textService.appendLine(
          line.text,
          source: TexthookerLineSource.engineHook,
          sourceLabel: 'engine_hook',
          sourceSequence: line.seq,
          hookTimestampMs: line.timestampMs,
          audioStatus: TexthookerLineAudioStatus.pending,
        );
        if (entry == null) {
          cursor = line.seq;
          continue;
        }
        _lineTimestampCache[entry.id] = line.timestampMs;
        _trimCache(_lineTimestampCache);
        final GalAudioSlice? clip =
            await engine.grabUtterance(line.timestampMs) ??
                await engine.grabClipNear(line.timestampMs);
        if (clip != null && !clip.isEmpty) {
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
        } else {
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
        cursor = line.seq;
      }
      // 只推进到实际看见并处理完成的最大 seq；不能盲用 native header count 跳过未提交槽。
      if (cursor > _lastTextSeq) _lastTextSeq = cursor;
      if (ordered.isNotEmpty) {
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
      }
    }
    _lastObservedLineId = latestId;
    notifyListeners();
  }

  void _onEndpointStatusChanged() => notifyListeners();

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

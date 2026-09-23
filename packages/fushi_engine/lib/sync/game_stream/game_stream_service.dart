/// Host-side session registry for the LAN game-stream protocol.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_library.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

typedef GameStreamInputHandler =
    Future<void> Function(
      GameStreamInputEvent event,
      GameStreamSession session,
    );
typedef GameStreamMineHandler =
    Future<GameStreamMineResult> Function(
      GameStreamMineRequest request,
      GameStreamTextEvent line,
    );
typedef GameStreamSignalHandler =
    Future<void> Function(GameStreamSignal signal);
typedef GameStreamTextHandler =
    Future<void> Function(GameStreamTextEvent event);
typedef GameStreamSettingsHandler =
    Future<GameStreamVideoSettings> Function(GameStreamVideoSettings settings);

class FushiRemoteGameStreamService {
  FushiRemoteGameStreamService({
    this.onInput,
    this.onMine,
    this.onSignal,
    this.onText,
    this.onStop,
    this.onSettings,
    this.library,
    List<String>? baseFeatures,
    DateTime Function()? now,
    this.sessionTtl = const Duration(minutes: 10),
    Duration sweepInterval = const Duration(seconds: 30),
    String Function()? sessionIdGenerator,
  }) : _now = now ?? DateTime.now,
       _sessionIdGenerator = sessionIdGenerator ?? _defaultSessionId,
       _baseFeatures = List<String>.unmodifiable(
         baseFeatures ??
             <String>[
               for (final String feature in GameStreamFeature.all)
                 if (feature != GameStreamFeature.remoteLaunch) feature,
             ],
       ) {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => pruneExpired());
  }

  GameStreamInputHandler? onInput;
  GameStreamMineHandler? onMine;
  GameStreamSignalHandler? onSignal;
  GameStreamTextHandler? onText;
  Future<void> Function()? onStop;

  /// Called when a joining receiver asks for new stream parameters.
  GameStreamSettingsHandler? onSettings;

  /// App-owned host library; null keeps the library/launch routes off.
  GameStreamLibraryHost? library;
  final List<String> _baseFeatures;
  GameStreamLaunchStatus? _launch;
  String? _launchPeerIdentity;
  String? _launchClientId;

  /// Capabilities advertised on newly created sessions.
  List<String> get features => <String>[
    ..._baseFeatures,
    if (library != null) GameStreamFeature.remoteLaunch,
  ];

  GameStreamLaunchStatus? get launch => _launch;
  final DateTime Function() _now;
  final Duration sessionTtl;
  final String Function() _sessionIdGenerator;
  Timer? _sweepTimer;
  GameStreamSession? session;
  String? _peerIdentity;
  String? _clientId;
  int _lastInputSequence = -1;
  final Map<int, GameStreamInputAck> _inputAcks = <int, GameStreamInputAck>{};
  final Map<String, GameStreamTextEvent> _lines =
      <String, GameStreamTextEvent>{};
  final List<GameStreamTextEvent> textEvents = <GameStreamTextEvent>[];
  final List<GameStreamSignal> _signals = <GameStreamSignal>[];
  int _lastHostSignalSequence = -1;
  int _lastClientSignalSequence = -1;
  static const int _maxInputAcks = 256;
  static const int _maxSignals = 256;

  Iterable<GameStreamSession> get sessions =>
      session == null || session!.state.isTerminal
      ? const <GameStreamSession>[]
      : <GameStreamSession>[session!];

  List<GameStreamSignal> signalsFromClient({int after = -1}) =>
      <GameStreamSignal>[
        for (final GameStreamSignal signal in _signals)
          if (signal.senderRole == GameStreamPeerRole.client &&
              signal.sequence > after)
            signal,
      ];

  /// [launchId] names the remote launch this session serves; the session is
  /// then reserved for the peer that asked for the launch, so another paired
  /// device cannot take over the game the requester just started.
  GameStreamSession createSession({
    String windowId = 'unknown',
    String? gameId,
    String? gameTitle,
    GameStreamVideoSettings? settings,
    String? launchId,
  }) {
    final GameStreamSession? previous = session;
    if (previous != null && !previous.state.isTerminal) {
      stop(sessionId: previous.sessionId, reason: 'replaced');
    }
    final DateTime now = _now().toUtc();
    final GameStreamSession created = GameStreamSession.create(
      sessionId: _sessionIdGenerator(),
      now: now,
      windowId: windowId,
      expiresAt: now.add(sessionTtl),
      gameId: gameId,
      gameTitle: gameTitle,
      features: features,
      settings: settings,
    );
    session = created;
    final bool reserved =
        launchId != null &&
        _launch?.launchId == launchId &&
        _launchPeerIdentity != null;
    _peerIdentity = reserved ? _launchPeerIdentity : null;
    _clientId = null;
    _lastInputSequence = -1;
    _inputAcks.clear();
    _lines.clear();
    textEvents.clear();
    _signals.clear();
    _lastHostSignalSequence = -1;
    _lastClientSignalSequence = -1;
    return created;
  }

  void joinSession({required String sessionId, required String clientId}) {
    final GameStreamSession current = _requireSession(sessionId);
    if (current.state.isTerminal) throw StateError('Session is stopped');
    if (_clientId != null && _clientId != clientId) {
      throw StateError('A different client is already connected');
    }
    if (current.state == GameStreamSessionState.connected &&
        _clientId == clientId) {
      _touch(current);
      return;
    }
    _clientId = clientId;
    current.clientId = clientId;
    current.state = GameStreamSessionState.connecting;
    _touch(current);
  }

  void markConnected({required String sessionId, String? clientId}) {
    final GameStreamSession current = _requireSession(sessionId);
    if (current.state.isTerminal) throw StateError('Session is stopped');
    if (clientId != null && _clientId != clientId) {
      throw StateError('Unknown session client');
    }
    current.state = GameStreamSessionState.connected;
    _touch(current);
  }

  void publishSignal(GameStreamSignal signal) {
    final GameStreamSession current = _requireSession(signal.sessionId);
    if (current.state.isTerminal) throw StateError('Session is stopped');
    if (signal.senderRole != GameStreamPeerRole.host) {
      throw StateError('Only the host may publish host signals');
    }
    if (signal.sequence <= _lastHostSignalSequence) return;
    _lastHostSignalSequence = signal.sequence;
    _signals.add(signal);
    _trimSignals();
    _touch(current);
    unawaited(onSignal?.call(signal));
  }

  void publishText(GameStreamTextEvent event) {
    final GameStreamSession current = _requireSession(event.sessionId);
    if (current.state.isTerminal) return;
    _lines[event.lineId] = event;
    while (_lines.length > 128) {
      _lines.remove(_lines.keys.first);
    }
    textEvents.add(event);
    if (textEvents.length > 128) textEvents.removeAt(0);
    unawaited(onText?.call(event));
  }

  Future<GameStreamInputAck> handleInput(GameStreamInputEvent event) async {
    final GameStreamSession current = _requireSession(event.sessionId);
    if (current.state != GameStreamSessionState.connected ||
        event.clientId != _clientId) {
      return GameStreamInputAck(
        sequence: event.sequence,
        accepted: false,
        reason: 'session_not_connected',
      );
    }
    final GameStreamInputAck? prior = _inputAcks[event.sequence];
    if (prior != null) {
      if (!prior.accepted) return prior;
      return GameStreamInputAck(
        sequence: event.sequence,
        accepted: false,
        reason: 'duplicate',
      );
    }
    if (event.sequence <= _lastInputSequence) {
      final GameStreamInputAck ack = GameStreamInputAck(
        sequence: event.sequence,
        accepted: false,
        reason: event.sequence == _lastInputSequence
            ? 'duplicate'
            : 'out_of_order',
      );
      _inputAcks[event.sequence] = ack;
      _trimInputAcks();
      return ack;
    }
    _lastInputSequence = event.sequence;
    GameStreamInputAck ack = GameStreamInputAck(
      sequence: event.sequence,
      accepted: true,
    );
    _inputAcks[event.sequence] = ack;
    _trimInputAcks();
    try {
      await onInput?.call(event, current);
    } catch (error) {
      ack = GameStreamInputAck(
        sequence: event.sequence,
        accepted: false,
        reason: error is GameStreamInputRejected
            ? error.code
            : 'input_handler_failed',
      );
      _inputAcks[event.sequence] = ack;
      _trimInputAcks();
      return ack;
    }
    _touch(current);
    return ack;
  }

  Future<GameStreamMineResult> mine(GameStreamMineRequest request) async {
    final GameStreamSession current = _requireSession(request.sessionId);
    final GameStreamTextEvent? line = _lines[request.lineId];
    if (current.state != GameStreamSessionState.connected ||
        request.clientId != _clientId ||
        line == null ||
        request.sentence != line.text) {
      throw const FormatException('Unknown or stale game-stream line');
    }
    final GameStreamMineHandler? handler = onMine;
    if (handler == null) {
      return const GameStreamMineResult(
        ok: false,
        message: 'Remote game mining is not configured on this host',
      );
    }
    return handler(request, line);
  }

  void stop({required String sessionId, String? reason}) {
    final GameStreamSession current = _requireSession(sessionId);
    if (current.state.isTerminal) return;
    current.state = GameStreamSessionState.stopped;
    current.reason = reason ?? 'stopped';
    current.updatedAt = _now().toUtc();
    _peerIdentity = null;
    _clientId = null;
    _inputAcks.clear();
    _lines.clear();
    textEvents.clear();
    _signals.clear();
    _lastClientSignalSequence = -1;
    unawaited(onStop?.call());
  }

  /// App-side launch progress. Updates for a superseded [launchId] are ignored
  /// so a slow old launch can never overwrite the current one.
  void updateLaunch(
    String launchId, {
    required GameStreamLaunchState state,
    String? sessionId,
    String? reason,
  }) {
    final GameStreamLaunchStatus? current = _launch;
    if (current == null ||
        current.launchId != launchId ||
        current.state.isTerminal) {
      return;
    }
    _launch = current.copyWith(
      state: state,
      updatedAt: _now().millisecondsSinceEpoch,
      sessionId: sessionId,
      reason: reason,
    );
  }

  Future<Response> _handleLibrary(
    Request request,
    String method,
    String path,
    String peerIdentity,
  ) async {
    final GameStreamLibraryHost? host = library;
    if (host == null) return Response.notFound('Game library off');
    if (path == '/api/game-stream/library') {
      if (method != 'GET' && method != 'POST') return Response(405);
      final List<GameStreamLibraryGame> games = await host.listGames();
      return _json(<String, Object?>{
        'version': kGameStreamWireVersion,
        'launchEnabled': host.launchEnabled,
        'games': <Map<String, Object?>>[
          for (final GameStreamLibraryGame game in games) game.toJson(),
        ],
      });
    }
    if (method != 'POST') return Response(405);
    final Map<String, dynamic> body;
    try {
      body = await _readObject(request);
    } on FormatException catch (error) {
      return _error(400, error.message);
    }
    switch (path) {
      case '/api/game-stream/library/cover':
        final String? gameId = _optionalString(body['gameId'], 'gameId');
        if (gameId == null) return _error(400, 'gameId is required');
        final GameStreamLibraryCover? cover = await host.cover(gameId);
        if (cover == null) return _error(404, 'Cover not found');
        return _json(<String, Object?>{
          'version': kGameStreamWireVersion,
          'contentType': cover.contentType,
          'data': base64Encode(cover.bytes),
        });
      case '/api/game-stream/launch':
        final String? clientId = _optionalString(body['clientId'], 'clientId');
        final String? gameId = _optionalString(body['gameId'], 'gameId');
        if (clientId == null || gameId == null) {
          return _error(400, 'clientId and gameId are required');
        }
        if (!host.launchEnabled) {
          return _error(
            403,
            'Remote launch is disabled on this host',
            code: GameStreamLaunchFailure.disabled,
          );
        }
        final GameStreamSession? live = session;
        if (live != null &&
            !live.state.isTerminal &&
            _peerIdentity != null &&
            _peerIdentity != peerIdentity) {
          return _error(
            409,
            'Another device is streaming from this host',
            code: GameStreamLaunchFailure.busy,
          );
        }
        final GameStreamLaunchStatus? pending = _launch;
        if (pending != null && !pending.state.isTerminal) {
          if (_launchPeerIdentity == peerIdentity &&
              _launchClientId == clientId &&
              pending.gameId == gameId) {
            return _json(<String, Object?>{'launch': pending.toJson()});
          }
          return _error(
            409,
            'Another launch is in progress',
            code: GameStreamLaunchFailure.busy,
          );
        }
        final GameStreamLaunchStatus started = GameStreamLaunchStatus(
          launchId: _sessionIdGenerator(),
          gameId: gameId,
          state: GameStreamLaunchState.starting,
          updatedAt: _now().millisecondsSinceEpoch,
        );
        _launch = started;
        _launchPeerIdentity = peerIdentity;
        _launchClientId = clientId;
        final GameStreamVideoSettings settings =
            GameStreamVideoSettings.fromJson(body['settings']);
        unawaited(
          Future<void>(
            () => host.launch(
              launchId: started.launchId,
              gameId: gameId,
              settings: settings,
            ),
          ).catchError((Object error, StackTrace stack) {
            if (error is! GameStreamLaunchRejected) {
              engineLog.log('GameStream.launch', error, stack);
            }
            updateLaunch(
              started.launchId,
              state: GameStreamLaunchState.failed,
              reason: error is GameStreamLaunchRejected
                  ? error.code
                  : GameStreamLaunchFailure.launchFailed,
            );
          }),
        );
        return _json(<String, Object?>{
          'launch': started.toJson(),
        }, status: 202);
      case '/api/game-stream/launch/status':
        final String? launchId = _optionalString(body['launchId'], 'launchId');
        final GameStreamLaunchStatus? status = _launch;
        if (launchId == null || status == null || status.launchId != launchId) {
          return _error(404, 'Unknown launch');
        }
        if (_launchPeerIdentity != peerIdentity) {
          return _error(403, 'Unknown launch peer');
        }
        return _json(<String, Object?>{'launch': status.toJson()});
      default:
        return Response.notFound('Game stream route not found');
    }
  }

  void pruneExpired() {
    final GameStreamSession? current = session;
    if (current == null || current.state.isTerminal) return;
    if (!_now().toUtc().isBefore(current.updatedAt.add(sessionTtl))) {
      stop(sessionId: current.sessionId, reason: 'expired');
    }
  }

  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  Future<Response> handleRequest(
    Request request,
    String method,
    String path, {
    String peerIdentity = 'authenticated-peer',
  }) async {
    pruneExpired();
    if (path == '/api/game-stream/library' ||
        path == '/api/game-stream/library/cover' ||
        path == '/api/game-stream/launch' ||
        path == '/api/game-stream/launch/status') {
      return _handleLibrary(request, method, path, peerIdentity);
    }
    if (path == '/api/game-stream/sessions' &&
        (method == 'GET' || method == 'POST')) {
      return _json(<String, Object?>{
        'version': kGameStreamWireVersion,
        'sessions': <Map<String, Object?>>[
          for (final GameStreamSession s in sessions) s.toJson(),
        ],
      });
    }
    // Keep the short paths used by early mobile clients as aliases. They are
    // normalized before the same session/auth checks below.
    if (path == '/api/game-stream/join' ||
        path == '/api/game-stream/signal' ||
        path == '/api/game-stream/stop' ||
        path == '/api/game-stream/mine') {
      final Map<String, dynamic> aliasBody;
      try {
        aliasBody = await _readObject(
          request,
          maxBytes: path == '/api/game-stream/mine'
              ? _maxMineBodyBytes
              : _maxControlBodyBytes,
        );
      } on FormatException catch (error) {
        return _error(400, error.message);
      }
      final String? aliasSessionId = _optionalString(
        aliasBody['sessionId'],
        'sessionId',
      );
      if (aliasSessionId == null || aliasSessionId.isEmpty) {
        return _error(400, 'sessionId is required');
      }
      final String suffix = path.substring('/api/game-stream'.length);
      final Request normalized = Request(
        method,
        request.requestedUri,
        headers: request.headers,
        body: jsonEncode(aliasBody),
      );
      return handleRequest(
        normalized,
        method,
        '/api/game-stream/sessions/$aliasSessionId$suffix',
        peerIdentity: peerIdentity,
      );
    }
    const String prefix = '/api/game-stream/sessions/';
    if (!path.startsWith(prefix)) {
      return Response.notFound('Game stream route not found');
    }
    final List<String> parts = path.substring(prefix.length).split('/');
    if (parts.length != 2 || parts[0].isEmpty) {
      return Response.notFound('Game stream session not found');
    }
    final GameStreamSession current;
    try {
      current = _requireSession(parts[0]);
    } on StateError catch (error) {
      return _error(404, error.message);
    }
    Map<String, dynamic> body = <String, dynamic>{};
    if (method == 'POST') {
      try {
        body = await _readObject(
          request,
          maxBytes: parts[1] == 'mine'
              ? _maxMineBodyBytes
              : _maxControlBodyBytes,
        );
      } on FormatException catch (error) {
        return _error(400, error.message);
      }
    }
    switch (parts[1]) {
      case 'join':
        if (method != 'POST') return Response(405);
        final String? clientId = _optionalString(body['clientId'], 'clientId');
        if (clientId == null || clientId.isEmpty) {
          return _error(400, 'clientId is required');
        }
        if (_peerIdentity != null && _peerIdentity != peerIdentity) {
          return _error(409, 'A different peer is connected');
        }
        try {
          joinSession(sessionId: current.sessionId, clientId: clientId);
        } on StateError catch (error) {
          return _error(409, error.message);
        }
        _peerIdentity = peerIdentity;
        final String? clientName = _optionalString(
          body['clientName'],
          'clientName',
        );
        if (clientName != null && clientName.length <= 256) {
          current.clientName = clientName;
        }
        final Object? rawSettings = body['settings'];
        final GameStreamSettingsHandler? applySettings = onSettings;
        if (rawSettings is Map && applySettings != null) {
          final GameStreamVideoSettings requested =
              GameStreamVideoSettings.fromJson(rawSettings);
          try {
            current.settings = await applySettings(requested);
          } catch (error, stack) {
            // The stream still works with the previous parameters; the
            // returned session shows which ones are in effect.
            engineLog.log('GameStream.settings', error, stack);
          }
        }
        return _json(<String, Object?>{'session': current.toJson()});
      case 'signal':
        if (method != 'POST') return Response(405);
        final String? signalClientId = _optionalString(
          body['clientId'],
          'clientId',
        );
        if (!_isPeer(peerIdentity, signalClientId)) {
          return _error(403, 'Unknown game-stream peer');
        }
        _touch(current);
        final Object? rawSignal = body['signal'];
        if (rawSignal != null) {
          try {
            final GameStreamSignal signal = GameStreamSignal.fromJson(
              rawSignal,
            );
            if (signal.senderRole != GameStreamPeerRole.client ||
                signal.senderId != _clientId) {
              return _error(403, 'Invalid signal sender');
            }
            if (signal.sessionId != current.sessionId) {
              return _error(400, 'Signal session does not match route');
            }
            if (current.state.isTerminal) {
              return _error(409, 'Session is stopped');
            }
            if (signal.sequence <= _lastClientSignalSequence) {
              return _error(409, 'Duplicate or out-of-order signal');
            }
            _lastClientSignalSequence = signal.sequence;
            _signals.add(signal);
            _trimSignals();
          } on FormatException catch (error) {
            return _error(400, error.message);
          }
        }
        final int after = _optionalInt(body['after']) ?? -1;
        return _json(<String, Object?>{
          'version': kGameStreamWireVersion,
          'signals': <Map<String, Object?>>[
            for (final GameStreamSignal signal in _signals)
              if (signal.senderRole == GameStreamPeerRole.host &&
                  signal.sequence > after)
                signal.toJson(),
          ],
        });
      case 'stop':
        if (method != 'POST') return Response(405);
        final String? stopClientId = _optionalString(
          body['clientId'],
          'clientId',
        );
        if (!_isPeer(peerIdentity, stopClientId)) {
          return _error(403, 'Unknown game-stream peer');
        }
        stop(
          sessionId: current.sessionId,
          reason: _optionalString(body['reason'], 'reason'),
        );
        return _json(<String, Object?>{'session': current.toJson()});
      case 'mine':
        if (method != 'POST') return Response(405);
        final String? mineClientId = _optionalString(
          body['clientId'],
          'clientId',
        );
        if (!_isPeer(peerIdentity, mineClientId)) {
          return _error(403, 'Unknown game-stream peer');
        }
        try {
          final GameStreamMineRequest mineRequest =
              GameStreamMineRequest.fromJson(body);
          if (mineRequest.sessionId != current.sessionId) {
            return _error(400, 'Mine session does not match route');
          }
          final GameStreamMineResult result = await mine(mineRequest);
          return _json(<String, Object?>{'result': result.toJson()});
        } on FormatException catch (error) {
          return _error(409, error.message);
        } catch (error, stack) {
          engineLog.log('GameStream.mine', error, stack);
          return _error(500, 'Game stream mine handler failed');
        }
      default:
        return Response.notFound('Game stream route not found');
    }
  }

  bool _isPeer(String identity, Object? clientId) =>
      _peerIdentity == identity && clientId == _clientId;

  void _trimInputAcks() {
    while (_inputAcks.length > _maxInputAcks) {
      _inputAcks.remove(_inputAcks.keys.first);
    }
  }

  void _trimSignals() {
    if (_signals.length > _maxSignals) {
      _signals.removeRange(0, _signals.length - _maxSignals);
    }
  }

  void _touch(GameStreamSession current) {
    final DateTime now = _now().toUtc();
    current.updatedAt = now;
    current.expiresAt = now.add(sessionTtl);
  }

  GameStreamSession _requireSession(String sessionId) {
    final GameStreamSession? current = session;
    if (current == null || current.sessionId != sessionId) {
      throw StateError('Unknown game-stream session');
    }
    return current;
  }
}

String _defaultSessionId() {
  final Random random = Random.secure();
  return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
}

/// Control bodies are tiny; a mine body carries the popup's rendered glossary
/// HTML for every dictionary (plus `singleGlossaries` and dictionary media
/// descriptors), which routinely exceeds 512 KiB with several dictionaries.
const int _maxControlBodyBytes = 512 * 1024;
const int _maxMineBodyBytes = 8 * 1024 * 1024;

Future<Map<String, dynamic>> _readObject(
  Request request, {
  int maxBytes = _maxControlBodyBytes,
}) async {
  final BytesBuilder bytes = BytesBuilder(copy: false);
  await for (final List<int> chunk in request.read()) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Game-stream request is too large');
    }
    bytes.add(chunk);
  }
  final Object? value = jsonDecode(utf8.decode(bytes.takeBytes()));
  if (value is! Map) {
    throw const FormatException('Game-stream body must be an object');
  }
  return Map<String, dynamic>.from(value);
}

Response _json(Object body, {int status = 200}) => Response(
  status,
  headers: const <String, String>{
    'content-type': 'application/json; charset=utf-8',
  },
  body: jsonEncode(body),
);

Response _error(int status, String message, {String? code}) =>
    _json(<String, Object?>{
      'version': kGameStreamWireVersion,
      'code':
          code ??
          switch (status) {
            400 => 'invalid_request',
            403 => 'unauthorized_peer',
            404 => 'session_not_found',
            409 => 'session_conflict',
            _ => 'stream_error',
          },
      'error': message,
    }, status: status);

String? _optionalString(Object? value, String _) =>
    value is String && value.isNotEmpty && value.length <= 4096 ? value : null;

int? _optionalInt(Object? value) => value is int ? value : null;

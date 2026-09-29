import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_library.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:http/http.dart' as http;

export 'package:fushi_engine/sync/game_stream/game_stream_library.dart'
    show
        GameStreamLaunchFailure,
        GameStreamLaunchState,
        GameStreamLaunchStatus,
        GameStreamLibraryCover,
        GameStreamLibraryGame;

/// Thin transport seam for the game-stream HTTP endpoints.
///
/// Production uses [InterconnectGameStreamTransport]. Tests can inject a small
/// in-memory implementation without building a database-backed [SyncRepository].
abstract class GameStreamTransport {
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  });
}

class GameStreamPostResult {
  const GameStreamPostResult({required this.json, this.peer});

  final Map<String, dynamic>? json;
  final FushiClientUrl? peer;
}

class GameStreamUnreachableError implements Exception {
  const GameStreamUnreachableError(this.message);

  final String message;

  @override
  String toString() => 'GameStreamUnreachableError: $message';
}

/// A reachable host rejected an operation or returned an invalid response.
/// Only protocol codes are exposed; raw response bodies may contain host data.
class GameStreamRequestError implements Exception {
  const GameStreamRequestError({required this.statusCode, required this.code});

  final int? statusCode;
  final String code;

  @override
  String toString() => 'GameStreamRequestError: $code (HTTP $statusCode)';
}

class InterconnectGameStreamTransport implements GameStreamTransport {
  InterconnectGameStreamTransport({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
  }) : _transport = InterconnectPostTransport(
         repo: repo,
         httpClient: httpClient,
         pinnedClientFactory: pinnedClientFactory,
       );

  final InterconnectPostTransport _transport;
  FushiClientUrl? _boundPeer;

  FushiClientUrl? get boundPeer => _boundPeer;

  void bindPeer(FushiClientUrl peer) {
    _boundPeer = peer;
  }

  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    GameStreamRequestError? rejection;
    final InterconnectPostOutcome outcome = await _transport.post(
      path: path,
      body: body,
      timeout: timeout,
      authErrorMessage: 'Fushi server rejected game-stream token',
      onlyCandidate: _boundPeer,
      onRejectedResponse: (int status, Map<String, dynamic>? json) {
        const Set<String> codes = <String>{
          'invalid_request',
          'unauthorized_peer',
          'session_not_found',
          'session_conflict',
          'stream_error',
          GameStreamLaunchFailure.disabled,
          GameStreamLaunchFailure.busy,
        };
        final Object? code = json?['code'];
        rejection = GameStreamRequestError(
          statusCode: status,
          code:
              json?['version'] == kGameStreamWireVersion &&
                  code is String &&
                  codes.contains(code)
              ? code
              : (status >= 200 && status < 300
                    ? 'invalid_response'
                    : 'http_rejected'),
        );
      },
    );
    if (outcome.allUnreachable) {
      throw GameStreamUnreachableError(
        'all enabled paired candidates failed for $path',
      );
    }
    if (outcome.json == null) {
      throw rejection ??
          const GameStreamRequestError(
            statusCode: null,
            code: 'peer_unavailable',
          );
    }
    return GameStreamPostResult(json: outcome.json, peer: outcome.candidate);
  }
}

class FushiGameStreamClient {
  FushiGameStreamClient({
    required GameStreamTransport transport,
    Duration timeout = const Duration(seconds: 3),
  }) : _transport = transport,
       _timeout = timeout;

  final GameStreamTransport _transport;
  final Duration _timeout;
  FushiClientUrl? _boundPeer;

  FushiClientUrl? get boundPeer => _boundPeer;

  void bindPeer(FushiClientUrl peer) {
    _boundPeer = peer;
    final GameStreamTransport transport = _transport;
    if (transport is InterconnectGameStreamTransport) {
      transport.bindPeer(peer);
    }
  }

  Future<List<GameStreamSession>> listSessions({
    required String clientId,
  }) async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/sessions',
      <String, dynamic>{'clientId': clientId},
    );
    final Map<String, dynamic>? json = result.json;
    final Object? sessions = json?['sessions'];
    if (sessions is! List) return const <GameStreamSession>[];
    return <GameStreamSession>[
      for (final Object? raw in sessions) GameStreamSession.fromJson(raw),
    ];
  }

  /// [settings] is sent only when the host advertises
  /// [GameStreamFeature.videoSettings]; the returned session carries the
  /// parameters the host actually applied.
  Future<GameStreamSession?> join({
    required String sessionId,
    required String clientId,
    String? clientName,
    GameStreamVideoSettings? settings,
  }) async {
    final GameStreamPostResult result =
        await _post('/api/game-stream/join', <String, dynamic>{
          'sessionId': sessionId,
          'clientId': clientId,
          if (clientName != null && clientName.isNotEmpty)
            'clientName': clientName,
          if (settings != null) 'settings': settings.toJson(),
        });
    if (result.peer != null) bindPeer(result.peer!);
    final Map<String, dynamic>? json = result.json;
    final GameStreamSession? session = _sessionFromResponse(json);
    if (session?.clientId != null && session!.clientId != clientId) {
      _effectiveClientId = session.clientId!;
    }
    return session;
  }

  String? _effectiveClientId;

  String effectiveClientId(String requested) => _effectiveClientId ?? requested;

  Future<List<GameStreamSignal>> pollSignals({
    required String sessionId,
    required String clientId,
    int after = -1,
  }) async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/signal',
      <String, dynamic>{
        'sessionId': sessionId,
        'clientId': effectiveClientId(clientId),
        'after': after,
      },
    );
    final Object? signals = result.json?['signals'];
    if (signals is! List) return const <GameStreamSignal>[];
    return <GameStreamSignal>[
      for (final Object? raw in signals) GameStreamSignal.fromJson(raw),
    ];
  }

  Future<List<GameStreamSignal>> sendSignal(
    GameStreamSignal signal, {
    int after = -1,
  }) async {
    final GameStreamPostResult result =
        await _post('/api/game-stream/signal', <String, dynamic>{
          'sessionId': signal.sessionId,
          'clientId': effectiveClientId(signal.senderId),
          'signal': signal.toJson(),
          'after': after,
        });
    final Object? signals = result.json?['signals'];
    if (signals is! List) return const <GameStreamSignal>[];
    return <GameStreamSignal>[
      for (final Object? raw in signals) GameStreamSignal.fromJson(raw),
    ];
  }

  Future<GameStreamSession?> stop({
    required String sessionId,
    required String clientId,
    String? reason,
  }) async {
    final GameStreamPostResult result =
        await _post('/api/game-stream/stop', <String, dynamic>{
          'sessionId': sessionId,
          'clientId': effectiveClientId(clientId),
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        });
    return _sessionFromResponse(result.json);
  }

  Future<GameStreamMineResult?> mine(GameStreamMineRequest request) async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/mine',
      request.toJson(),
      timeout: const Duration(seconds: 90),
    );
    final Object? resultJson = result.json?['result'];
    if (resultJson == null) return null;
    return GameStreamMineResult.fromJson(resultJson);
  }

  /// Duplicate check against the host's Anki, which is where stream cards are
  /// written — the phone's own AnkiDroid is the wrong collection to ask.
  /// Fails soft to false so a flaky host never blocks the popup.
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    try {
      final GameStreamPostResult result = await _post(
        '/api/duplicate',
        <String, dynamic>{'expression': expression, 'reading': reading},
      );
      return result.json?['duplicate'] == true;
    } on Object {
      return false;
    }
  }

  /// Host library for remote launch. A host without the library routes answers
  /// 404, surfaced as [GameStreamRequestError] with `http_rejected`.
  Future<GameStreamLibrary> listLibrary() async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/library',
      const <String, dynamic>{},
      timeout: const Duration(seconds: 10),
    );
    final Map<String, dynamic>? json = result.json;
    final Object? games = json?['games'];
    return GameStreamLibrary(
      launchEnabled: json?['launchEnabled'] == true,
      games: <GameStreamLibraryGame>[
        if (games is List)
          for (final Object? raw in games)
            if (_tryLibraryGame(raw) case final GameStreamLibraryGame game)
              game,
      ],
    );
  }

  Future<GameStreamLibraryCover?> libraryCover(String gameId) async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/library/cover',
      <String, dynamic>{'gameId': gameId},
      timeout: const Duration(seconds: 15),
    );
    final Object? data = result.json?['data'];
    final Object? contentType = result.json?['contentType'];
    if (data is! String || contentType is! String) return null;
    try {
      return GameStreamLibraryCover(
        bytes: base64Decode(data),
        contentType: contentType,
      );
    } on FormatException {
      return null;
    }
  }

  Future<GameStreamLaunchStatus> launch({
    required String gameId,
    required String clientId,
    required GameStreamVideoSettings settings,
  }) async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/launch',
      <String, dynamic>{
        'gameId': gameId,
        'clientId': clientId,
        'settings': settings.toJson(),
      },
      timeout: const Duration(seconds: 10),
    );
    return GameStreamLaunchStatus.fromJson(result.json?['launch']);
  }

  Future<GameStreamLaunchStatus> launchStatus(String launchId) async {
    final GameStreamPostResult result = await _post(
      '/api/game-stream/launch/status',
      <String, dynamic>{'launchId': launchId},
    );
    return GameStreamLaunchStatus.fromJson(result.json?['launch']);
  }

  static GameStreamLibraryGame? _tryLibraryGame(Object? raw) {
    try {
      return GameStreamLibraryGame.fromJson(raw);
    } on FormatException {
      return null;
    }
  }

  Future<GameStreamPostResult> _post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
  }) async {
    final GameStreamPostResult result = await _transport.post(
      path: path,
      body: body,
      timeout: timeout ?? _timeout,
    );
    if (result.peer != null && _boundPeer == null) {
      bindPeer(result.peer!);
    }
    return result;
  }

  GameStreamSession? _sessionFromResponse(Map<String, dynamic>? json) {
    final Object? session = json?['session'];
    if (session == null) return null;
    return GameStreamSession.fromJson(session);
  }
}

class GameStreamLibrary {
  const GameStreamLibrary({required this.launchEnabled, required this.games});

  final bool launchEnabled;
  final List<GameStreamLibraryGame> games;
}

abstract class GameStreamDictionaryLookup {
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  });
}

/// Remote dictionary lookup constrained to the peer that accepted the stream.
class InterconnectGameStreamDictionaryLookup
    implements GameStreamDictionaryLookup {
  InterconnectGameStreamDictionaryLookup({
    required SyncRepository repo,
    required FushiClientUrl peer,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration timeout = const Duration(seconds: 3),
  }) : _lookup = FushiRemoteLookupClient(
         repo: repo,
         onlyCandidate: peer,
         httpClient: httpClient,
         pinnedClientFactory: pinnedClientFactory,
         timeout: timeout,
       );

  final FushiRemoteLookupClient _lookup;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) {
    return _lookup.searchDictionary(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
    );
  }
}

class GameStreamPointerMapper {
  const GameStreamPointerMapper(this.videoSize);

  final Size videoSize;

  Offset normalize(Offset localPosition) {
    if (videoSize.width <= 0 || videoSize.height <= 0) {
      return Offset.zero;
    }
    final double x = (localPosition.dx / videoSize.width).clamp(0.0, 1.0);
    final double y = (localPosition.dy / videoSize.height).clamp(0.0, 1.0);
    return Offset(x, y);
  }
}

enum GameStreamVirtualButton {
  up,
  down,
  left,
  right,
  confirm,
  cancel,
  menu,
  shoulderLeft,
  shoulderRight,
}

extension GameStreamVirtualButtonWire on GameStreamVirtualButton {
  String get wireName => switch (this) {
    GameStreamVirtualButton.up => 'dpad_up',
    GameStreamVirtualButton.down => 'dpad_down',
    GameStreamVirtualButton.left => 'dpad_left',
    GameStreamVirtualButton.right => 'dpad_right',
    GameStreamVirtualButton.confirm => 'confirm',
    GameStreamVirtualButton.cancel => 'cancel',
    GameStreamVirtualButton.menu => 'menu',
    GameStreamVirtualButton.shoulderLeft => 'shoulder_left',
    GameStreamVirtualButton.shoulderRight => 'shoulder_right',
  };
}

typedef GameStreamInputSender =
    Future<GameStreamInputAck?> Function(GameStreamInputEvent event);

class GameStreamInputComposer extends ChangeNotifier {
  GameStreamInputComposer({
    required this.sessionId,
    required this.clientId,
    required GameStreamInputSender sender,
    DateTime Function()? now,
  }) : _sender = sender,
       _now = now ?? DateTime.now;

  final String sessionId;
  final String clientId;
  final GameStreamInputSender _sender;
  final DateTime Function() _now;

  int _nextSequence = 1;
  int _lastAcceptedSequence = 0;
  int _lastRejectedSequence = 0;
  String? _lastRejectionReason;
  bool _disposed = false;

  int get nextSequence => _nextSequence;
  int get lastAcceptedSequence => _lastAcceptedSequence;
  int get lastRejectedSequence => _lastRejectedSequence;
  String? get lastRejectionReason => _lastRejectionReason;

  /// [button] other than left is only valid for hosts advertising
  /// [GameStreamFeature.pointerButtons]; left stays implicit on the wire so
  /// older hosts keep accepting ordinary taps.
  Future<GameStreamInputAck?> pointer({
    required GameStreamInputAction action,
    required Offset normalized,
    String button = 'left',
  }) {
    return _send(
      kind: GameStreamInputKind.pointer,
      action: action,
      x: normalized.dx.clamp(0.0, 1.0),
      y: normalized.dy.clamp(0.0, 1.0),
      button: button == 'left' ? null : button,
    );
  }

  /// Wheel notches at [normalized] (host must advertise
  /// [GameStreamFeature.wheel]).
  Future<GameStreamInputAck?> wheel({
    required Offset normalized,
    double? dx,
    double? dy,
  }) {
    return _send(
      kind: GameStreamInputKind.pointer,
      action: GameStreamInputAction.wheel,
      x: normalized.dx.clamp(0.0, 1.0),
      y: normalized.dy.clamp(0.0, 1.0),
      dx: dx,
      dy: dy,
    );
  }

  Future<GameStreamInputAck?> gamepad({
    required GameStreamVirtualButton button,
    required GameStreamInputAction action,
  }) {
    return _send(
      kind: GameStreamInputKind.gamepad,
      action: action,
      button: button.wireName,
    );
  }

  Future<GameStreamInputAck?> key({
    required String key,
    required GameStreamInputAction action,
  }) {
    return _send(kind: GameStreamInputKind.key, action: action, key: key);
  }

  void applyAck(GameStreamInputAck ack) {
    if (_disposed) return;
    if (ack.sequence < math.max(_lastAcceptedSequence, _lastRejectedSequence)) {
      return;
    }
    if (ack.accepted) {
      _lastAcceptedSequence = ack.sequence;
      if (_lastRejectedSequence <= ack.sequence) {
        _lastRejectionReason = null;
      }
    } else {
      _lastRejectedSequence = ack.sequence;
      _lastRejectionReason = ack.reason;
    }
    notifyListeners();
  }

  Future<GameStreamInputAck?> _send({
    required GameStreamInputKind kind,
    required GameStreamInputAction action,
    double? x,
    double? y,
    String? key,
    String? button,
    double? dx,
    double? dy,
  }) async {
    final GameStreamInputEvent event = GameStreamInputEvent(
      sessionId: sessionId,
      clientId: clientId,
      sequence: _nextSequence++,
      kind: kind,
      action: action,
      timestampMs: _now().toUtc().millisecondsSinceEpoch,
      x: x,
      y: y,
      key: key,
      button: button,
      dx: dx,
      dy: dy,
    );
    final GameStreamInputAck? ack = await _sender(event);
    if (ack != null) applyAck(ack);
    return ack;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class GameStreamLookupController extends ChangeNotifier {
  GameStreamLookupController({
    required GameStreamDictionaryLookup lookupClient,
    required FushiGameStreamClient streamClient,
    required String clientId,
  }) : _lookupClient = lookupClient,
       _streamClient = streamClient,
       _clientId = clientId;

  final GameStreamDictionaryLookup _lookupClient;
  final FushiGameStreamClient _streamClient;
  final String _clientId;

  GameStreamTextEvent? _currentLine;
  GameStreamTextEvent? _resultLine;
  DictionarySearchResult? _result;
  String? _selectedTerm;
  bool _searching = false;
  String? _error;
  int _lookupGeneration = 0;

  GameStreamTextEvent? get currentLine => _currentLine;
  DictionarySearchResult? get result => _result;
  String? get selectedTerm => _selectedTerm;
  bool get searching => _searching;
  String? get error => _error;

  void applyTextEvent(GameStreamTextEvent event) {
    if (_currentLine?.lineId == event.lineId &&
        _currentLine?.text == event.text) {
      return;
    }
    _currentLine = event;
    ++_lookupGeneration;
    _searching = false;
    _resultLine = null;
    _result = null;
    _selectedTerm = null;
    _error = null;
    notifyListeners();
  }

  Future<void> lookup(String term, {String? displayTerm}) async {
    final String query = term.trim();
    if (query.isEmpty) return;
    final int generation = ++_lookupGeneration;
    final GameStreamTextEvent? lookupLine = _currentLine;
    _searching = true;
    _selectedTerm = displayTerm ?? query;
    _error = null;
    notifyListeners();
    try {
      final DictionarySearchResult? next = await _lookupClient.searchDictionary(
        term: query,
        wildcards: false,
        maximumTerms: 20,
      );
      if (generation != _lookupGeneration) return;
      _result = next;
      _resultLine = lookupLine;
      if (next != null && next.bestLength > 0) {
        // The host scans prefixes of the sentence suffix and returns the
        // normalized source span in UTF-16 units (including inflected forms).
        _selectedTerm = next.searchTerm.substring(
          0,
          next.bestLength.clamp(0, next.searchTerm.length),
        );
      }
    } catch (error) {
      if (generation != _lookupGeneration) return;
      _error = error.toString();
      _result = null;
    } finally {
      if (generation == _lookupGeneration) {
        _searching = false;
        notifyListeners();
      }
    }
  }

  /// Line the current dictionary result was looked up from; mining always
  /// targets this line, never a newer one that arrived meanwhile.
  GameStreamTextEvent? get resultLine => _resultLine;

  Future<bool> isDuplicate(String expression, String reading) =>
      _streamClient.isDuplicate(expression: expression, reading: reading);

  Future<GameStreamMineResult?> mine(Map<String, String> fields) {
    final GameStreamTextEvent? line = _resultLine;
    if (line == null) {
      throw StateError('No game-stream line is selected');
    }
    return _streamClient.mine(
      GameStreamMineRequest(
        sessionId: line.sessionId,
        clientId: _clientId,
        lineId: line.lineId,
        fields: fields,
        sentence: line.text,
      ),
    );
  }

  @override
  void dispose() {
    ++_lookupGeneration;
    super.dispose();
  }
}

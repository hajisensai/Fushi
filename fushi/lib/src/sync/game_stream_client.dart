import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:http/http.dart' as http;

/// Thin transport seam for the game-stream HTTP endpoints.
///
/// Production uses [InterconnectGameStreamTransport]. Tests can inject a small
/// in-memory implementation without building a database-backed [SyncRepository].
abstract class GameStreamTransport {
  Future<Map<String, dynamic>?> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  });
}

class GameStreamUnreachableError implements Exception {
  const GameStreamUnreachableError(this.message);

  final String message;

  @override
  String toString() => 'GameStreamUnreachableError: $message';
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

  @override
  Future<Map<String, dynamic>?> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    final InterconnectPostOutcome outcome = await _transport.post(
      path: path,
      body: body,
      timeout: timeout,
      authErrorMessage: 'Fushi server rejected game-stream token',
    );
    if (outcome.allUnreachable) {
      throw GameStreamUnreachableError(
        'all enabled paired candidates failed for $path',
      );
    }
    return outcome.json;
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

  Future<List<GameStreamSession>> listSessions({
    required String clientId,
  }) async {
    final Map<String, dynamic>? json = await _post(
      '/api/game-stream/sessions',
      <String, dynamic>{'clientId': clientId},
    );
    final Object? sessions = json?['sessions'];
    if (sessions is! List) return const <GameStreamSession>[];
    return <GameStreamSession>[
      for (final Object? raw in sessions) GameStreamSession.fromJson(raw),
    ];
  }

  Future<GameStreamSession?> join({
    required String sessionId,
    required String clientId,
    String? clientName,
  }) async {
    final Map<String, dynamic>? json =
        await _post('/api/game-stream/join', <String, dynamic>{
          'sessionId': sessionId,
          'clientId': clientId,
          if (clientName != null && clientName.isNotEmpty)
            'clientName': clientName,
        });
    return _sessionFromResponse(json);
  }

  Future<GameStreamSignal?> sendSignal(GameStreamSignal signal) async {
    final Map<String, dynamic>? json = await _post(
      '/api/game-stream/signal',
      signal.toJson(),
    );
    final Object? responseSignal = json?['signal'];
    if (responseSignal == null) return null;
    return GameStreamSignal.fromJson(responseSignal);
  }

  Future<GameStreamSession?> stop({
    required String sessionId,
    required String clientId,
    String? reason,
  }) async {
    final Map<String, dynamic>? json =
        await _post('/api/game-stream/stop', <String, dynamic>{
          'sessionId': sessionId,
          'clientId': clientId,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        });
    return _sessionFromResponse(json);
  }

  Future<GameStreamMineResult?> mine(GameStreamMineRequest request) async {
    final Map<String, dynamic>? json = await _post(
      '/api/game-stream/mine',
      request.toJson(),
      timeout: const Duration(seconds: 12),
    );
    final Object? result = json?['result'];
    if (result == null) return null;
    return GameStreamMineResult.fromJson(result);
  }

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
  }) {
    return _transport.post(
      path: path,
      body: body,
      timeout: timeout ?? _timeout,
    );
  }

  GameStreamSession? _sessionFromResponse(Map<String, dynamic>? json) {
    final Object? session = json?['session'];
    if (session == null) return null;
    return GameStreamSession.fromJson(session);
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

  int get nextSequence => _nextSequence;
  int get lastAcceptedSequence => _lastAcceptedSequence;
  int get lastRejectedSequence => _lastRejectedSequence;
  String? get lastRejectionReason => _lastRejectionReason;

  Future<GameStreamInputAck?> pointer({
    required GameStreamInputAction action,
    required Offset normalized,
  }) {
    return _send(
      kind: GameStreamInputKind.pointer,
      action: action,
      x: normalized.dx.clamp(0.0, 1.0),
      y: normalized.dy.clamp(0.0, 1.0),
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
    );
    final GameStreamInputAck? ack = await _sender(event);
    if (ack != null) applyAck(ack);
    return ack;
  }
}

class GameStreamLookupController extends ChangeNotifier {
  GameStreamLookupController({
    required FushiRemoteLookupClient lookupClient,
    required FushiGameStreamClient streamClient,
    required String clientId,
  }) : _lookupClient = lookupClient,
       _streamClient = streamClient,
       _clientId = clientId;

  final FushiRemoteLookupClient _lookupClient;
  final FushiGameStreamClient _streamClient;
  final String _clientId;

  GameStreamTextEvent? _currentLine;
  DictionarySearchResult? _result;
  String? _selectedTerm;
  bool _searching = false;
  String? _error;

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
    _result = null;
    _selectedTerm = null;
    _error = null;
    notifyListeners();
  }

  Future<void> lookup(String term) async {
    final String query = term.trim();
    if (query.isEmpty) return;
    _searching = true;
    _selectedTerm = query;
    _error = null;
    notifyListeners();
    try {
      _result = await _lookupClient.searchDictionary(
        term: query,
        wildcards: false,
        maximumTerms: 20,
      );
    } catch (error) {
      _error = error.toString();
      _result = null;
    } finally {
      _searching = false;
      notifyListeners();
    }
  }

  Future<GameStreamMineResult?> mine(Map<String, String> fields) {
    final GameStreamTextEvent? line = _currentLine;
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
}

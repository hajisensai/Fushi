/// Versioned wire contracts for the Fushi LAN game-stream session.
///
/// This library intentionally contains no transport or Flutter dependencies. The
/// sync server can use [toJson] maps as HTTP payloads while a WebRTC adapter uses
/// [GameStreamSignal.payload] for SDP/ICE data.
library;

import 'dart:convert';

/// Bump when a field is removed or changes meaning. Additive optional fields do
/// not require a bump because decoders ignore fields they do not understand.
const int kGameStreamWireVersion = 1;

/// Encodes one protocol value for a JSON HTTP body.
String encodeGameStreamJson(Object value) => jsonEncode(value);

/// Decodes a JSON object, rejecting arrays and scalar values.
Map<String, dynamic> decodeGameStreamJsonObject(String value) {
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    throw const FormatException('Invalid game-stream JSON');
  }
  if (decoded is! Map) {
    throw const FormatException('Game-stream JSON must be an object');
  }
  return _stringMap(decoded);
}

enum GameStreamSessionState {
  waiting,
  connecting,
  connected,
  stopping,
  stopped,
  failed;

  bool get isTerminal => this == stopped || this == failed;
}

enum GameStreamSignalType { offer, answer, iceCandidate, renegotiation, bye }

enum GameStreamPeerRole { host, client }

enum GameStreamInputKind { pointer, key, gamepad }

enum GameStreamInputAction { down, move, up, button }

/// A platform adapter can reject a target without exposing Flutter exceptions
/// to the shared session service.
class GameStreamInputRejected implements Exception {
  const GameStreamInputRejected(this.code);
  final String code;
}

/// Host/client session metadata shared by the HTTP endpoints and UI.
class GameStreamSession {
  GameStreamSession({
    required this.sessionId,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    this.windowId,
    this.clientId,
    this.clientName,
    this.reason,
    this.expiresAt,
  });

  factory GameStreamSession.create({
    required String sessionId,
    required DateTime now,
    String? windowId,
    DateTime? expiresAt,
  }) {
    _nonEmpty(sessionId, 'sessionId');
    return GameStreamSession(
      sessionId: sessionId,
      createdAt: now,
      updatedAt: now,
      state: GameStreamSessionState.waiting,
      windowId: _optionalNonEmpty(windowId, 'windowId'),
      expiresAt: expiresAt,
    );
  }

  factory GameStreamSession.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'session');
    _version(json);
    final String sessionId = _requiredString(json, 'sessionId');
    final GameStreamSessionState state = _enumValue(
      json['state'],
      GameStreamSessionState.values,
      'state',
    );
    final String? clientId = _optionalNonEmpty(json['clientId'], 'clientId');
    return GameStreamSession(
      sessionId: sessionId,
      createdAt: _date(json, 'createdAt'),
      updatedAt: _date(json, 'updatedAt'),
      state: state,
      windowId: _optionalNonEmpty(json['windowId'], 'windowId'),
      clientId: clientId,
      clientName: _optionalNonEmpty(json['clientName'], 'clientName'),
      reason: _optionalString(json['reason'], 'reason'),
      expiresAt: _optionalDate(json, 'expiresAt'),
    );
  }

  final String sessionId;
  final DateTime createdAt;
  DateTime updatedAt;
  GameStreamSessionState state;
  String? windowId;
  String? clientId;
  String? clientName;
  String? reason;
  DateTime? expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'sessionId': sessionId,
    'state': state.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (windowId != null) 'windowId': windowId,
    if (clientId != null) 'clientId': clientId,
    if (clientName != null) 'clientName': clientName,
    if (reason != null) 'reason': reason,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };
}

/// SDP/ICE envelope. The payload is deliberately opaque to the engine.
class GameStreamSignal {
  GameStreamSignal({
    required this.sessionId,
    required this.senderId,
    required this.senderRole,
    required this.type,
    required this.sequence,
    required Map<String, Object?> payload,
  }) : payload = Map<String, Object?>.unmodifiable(payload);

  factory GameStreamSignal.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'signal');
    _version(json);
    final Object? payload = json['payload'];
    if (payload is! Map) throw const FormatException('Invalid signal payload');
    final Map<String, dynamic> map = _stringMap(payload);
    _assertJsonValue(map);
    return GameStreamSignal(
      sessionId: _requiredString(json, 'sessionId'),
      senderId: _requiredString(json, 'senderId'),
      senderRole: _enumValue(
        json['senderRole'],
        GameStreamPeerRole.values,
        'senderRole',
      ),
      type: _enumValue(json['type'], GameStreamSignalType.values, 'type'),
      sequence: _nonNegativeInt(json, 'sequence'),
      payload: Map<String, Object?>.from(map),
    );
  }

  final String sessionId;
  final String senderId;
  final GameStreamPeerRole senderRole;
  final GameStreamSignalType type;
  final int sequence;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'sessionId': sessionId,
    'senderId': senderId,
    'senderRole': senderRole.name,
    'type': type.name,
    'sequence': sequence,
    'payload': payload,
  };
}

/// Input sent over the reliable, ordered data channel.
class GameStreamInputEvent {
  GameStreamInputEvent({
    required this.sessionId,
    required this.clientId,
    required this.sequence,
    required this.kind,
    required this.action,
    required this.timestampMs,
    this.x,
    this.y,
    this.key,
    this.button,
  }) {
    _validateInputFields();
  }

  factory GameStreamInputEvent.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'input');
    _version(json);
    final GameStreamInputEvent event = GameStreamInputEvent(
      sessionId: _requiredString(json, 'sessionId'),
      clientId: _requiredString(json, 'clientId'),
      sequence: _nonNegativeInt(json, 'sequence'),
      kind: _enumValue(json['kind'], GameStreamInputKind.values, 'kind'),
      action: _enumValue(
        json['action'],
        GameStreamInputAction.values,
        'action',
      ),
      timestampMs: _positiveInt(json, 'timestampMs'),
      x: _optionalNumber(json['x'], 'x')?.toDouble(),
      y: _optionalNumber(json['y'], 'y')?.toDouble(),
      key: _optionalString(json['key'], 'key'),
      button: _optionalString(json['button'], 'button'),
    );
    return event;
  }

  final String sessionId;
  final String clientId;
  final int sequence;
  final GameStreamInputKind kind;
  final GameStreamInputAction action;
  final int timestampMs;
  final double? x;
  final double? y;
  final String? key;
  final String? button;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'sessionId': sessionId,
    'clientId': clientId,
    'sequence': sequence,
    'kind': kind.name,
    'action': action.name,
    'timestampMs': timestampMs,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (key != null) 'key': key,
    if (button != null) 'button': button,
  };

  void _validateInputFields() {
    if (kind == GameStreamInputKind.pointer) {
      if (x == null || y == null || !x!.isFinite || !y!.isFinite) {
        throw const FormatException('Pointer input requires finite x/y');
      }
      if (x! < 0 || x! > 1 || y! < 0 || y! > 1) {
        throw const FormatException('Pointer coordinates must be normalized');
      }
      if (action == GameStreamInputAction.button) {
        throw const FormatException('Invalid pointer action');
      }
    } else if (kind == GameStreamInputKind.key) {
      if (_optionalNonEmpty(key, 'key') == null ||
          (action != GameStreamInputAction.down &&
              action != GameStreamInputAction.up)) {
        throw const FormatException('Key input requires down/up and key');
      }
    } else {
      if (_optionalNonEmpty(button, 'button') == null ||
          (action != GameStreamInputAction.down &&
              action != GameStreamInputAction.up &&
              action != GameStreamInputAction.button)) {
        throw const FormatException('Gamepad input requires a button');
      }
    }
  }
}

class GameStreamInputAck {
  const GameStreamInputAck({
    required this.sequence,
    required this.accepted,
    this.reason,
  });

  factory GameStreamInputAck.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'input ack');
    _version(json);
    final Object? accepted = json['accepted'];
    if (accepted is! bool) throw const FormatException('Invalid input ack');
    return GameStreamInputAck(
      sequence: _nonNegativeInt(json, 'sequence'),
      accepted: accepted,
      reason: _optionalString(json['reason'], 'reason'),
    );
  }

  final int sequence;
  final bool accepted;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'sequence': sequence,
    'accepted': accepted,
    if (reason != null) 'reason': reason,
  };
}

/// A line emitted by the host hook. [lineId] is the stable join key used by a
/// remote mine request; it must be retained even when the displayed text repeats.
class GameStreamTextEvent {
  GameStreamTextEvent({
    required this.sessionId,
    required this.lineId,
    required this.text,
    required this.timestampMs,
    this.thread,
    this.audioResourceId,
  }) {
    _nonEmpty(lineId, 'lineId');
    if (text.length > 100000) throw const FormatException('Text too long');
    if (timestampMs <= 0) throw const FormatException('Invalid timestampMs');
  }

  factory GameStreamTextEvent.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'text event');
    _version(json);
    final String text = _requiredString(json, 'text');
    return GameStreamTextEvent(
      sessionId: _requiredString(json, 'sessionId'),
      lineId: _requiredString(json, 'lineId'),
      text: text,
      timestampMs: _positiveInt(json, 'timestampMs'),
      thread: _optionalString(json['thread'], 'thread'),
      audioResourceId: _optionalString(
        json['audioResourceId'],
        'audioResourceId',
      ),
    );
  }

  final String sessionId;
  final String lineId;
  final String text;
  final int timestampMs;
  final String? thread;
  final String? audioResourceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'sessionId': sessionId,
    'lineId': lineId,
    'text': text,
    'timestampMs': timestampMs,
    if (thread != null) 'thread': thread,
    if (audioResourceId != null) 'audioResourceId': audioResourceId,
  };
}

class GameStreamMineRequest {
  GameStreamMineRequest({
    required this.sessionId,
    required this.clientId,
    required this.lineId,
    required Map<String, String> fields,
    required this.sentence,
  }) : fields = Map<String, String>.unmodifiable(fields) {
    _nonEmpty(sessionId, 'sessionId');
    _nonEmpty(clientId, 'clientId');
    _nonEmpty(lineId, 'lineId');
    if (sentence.length > 100000) {
      throw const FormatException('Sentence too long');
    }
  }

  factory GameStreamMineRequest.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'mine request');
    _version(json);
    final Object? fields = json['fields'];
    if (fields is! Map ||
        fields.keys.any((Object? k) => k is! String) ||
        fields.values.any((Object? v) => v is! String)) {
      throw const FormatException('Invalid mine fields');
    }
    return GameStreamMineRequest(
      sessionId: _requiredString(json, 'sessionId'),
      clientId: _requiredString(json, 'clientId'),
      lineId: _requiredString(json, 'lineId'),
      fields: Map<String, String>.from(fields),
      sentence: _requiredString(json, 'sentence'),
    );
  }

  final String sessionId;
  final String clientId;
  final String lineId;
  final Map<String, String> fields;
  final String sentence;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'sessionId': sessionId,
    'clientId': clientId,
    'lineId': lineId,
    'fields': fields,
    'sentence': sentence,
  };
}

class GameStreamMineResult {
  const GameStreamMineResult({required this.ok, this.message, this.detail});

  factory GameStreamMineResult.fromJson(Object? raw) {
    final Map<String, dynamic> json = _object(raw, 'mine result');
    _version(json);
    final Object? ok = json['ok'];
    if (ok is! bool) throw const FormatException('Invalid mine result');
    return GameStreamMineResult(
      ok: ok,
      message: _optionalString(json['message'], 'message'),
      detail: _optionalString(json['detail'], 'detail'),
    );
  }

  final bool ok;
  final String? message;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'ok': ok,
    if (message != null) 'message': message,
    if (detail != null) 'detail': detail,
  };
}

Map<String, dynamic> _object(Object? value, String name) {
  if (value is! Map) throw FormatException('Invalid $name');
  return _stringMap(value);
}

Map<String, dynamic> _stringMap(Map value) {
  if (value.keys.any((Object? key) => key is! String)) {
    throw const FormatException('JSON object keys must be strings');
  }
  return Map<String, dynamic>.from(value);
}

void _version(Map<String, dynamic> json) {
  if (json['version'] != kGameStreamWireVersion) {
    throw const FormatException('Unsupported game-stream wire version');
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! String) throw FormatException('Missing or invalid $key');
  return _nonEmpty(value, key);
}

String _nonEmpty(String value, String name) {
  if (value.trim().isEmpty || value.length > 4096) {
    throw FormatException('Missing or invalid $name');
  }
  return value;
}

String? _optionalNonEmpty(Object? value, String name) {
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $name');
  return _nonEmpty(value, name);
}

String? _optionalString(Object? value, String name) {
  if (value == null) return null;
  if (value is! String || value.length > 100000) {
    throw FormatException('Invalid $name');
  }
  return value;
}

int _nonNegativeInt(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

int _positiveInt(Map<String, dynamic> json, String key) {
  final int value = _nonNegativeInt(json, key);
  if (value == 0) throw FormatException('Invalid $key');
  return value;
}

num? _optionalNumber(Object? value, String name) {
  if (value == null) return null;
  if (value is! num || !value.isFinite) throw FormatException('Invalid $name');
  return value;
}

DateTime _date(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! String) throw FormatException('Missing or invalid $key');
  final DateTime? date = DateTime.tryParse(value);
  if (date == null) throw FormatException('Invalid $key');
  return date.toUtc();
}

DateTime? _optionalDate(Map<String, dynamic> json, String key) {
  if (json[key] == null) return null;
  return _date(json, key);
}

T _enumValue<T extends Enum>(Object? value, List<T> values, String name) {
  if (value is! String) throw FormatException('Missing or invalid $name');
  for (final T candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('Invalid $name');
}

void _assertJsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) return;
  if (value is List) {
    for (final Object? item in value) {
      _assertJsonValue(item);
    }
    return;
  }
  if (value is Map) {
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('JSON object keys must be strings');
      }
      _assertJsonValue(entry.value);
    }
    return;
  }
  throw const FormatException('Invalid JSON value');
}

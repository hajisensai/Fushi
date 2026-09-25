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

/// Signalling cadence shared by host and receiver. Negotiation is polled fast
/// so offer → answer → ICE completes in a few hundred milliseconds; once
/// connected only liveness, late candidates and `bye` remain, at the slower
/// cadence.
const Duration kGameStreamNegotiationPoll = Duration(milliseconds: 100);
const Duration kGameStreamConnectedPoll = Duration(milliseconds: 350);

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

/// [wheel] is only sent to hosts advertising [GameStreamFeature.wheel]; an
/// older host rejects the unknown action instead of misreading it.
enum GameStreamInputAction { down, move, up, button, wheel }

/// Optional host capabilities advertised on [GameStreamSession.features].
/// Clients gate every newer input kind and request field on these strings so a
/// newer phone never sends something an older host would mis-handle.
abstract final class GameStreamFeature {
  /// Join/launch bodies may carry a [GameStreamVideoSettings] object.
  static const String videoSettings = 'videoSettings';

  /// Pointer events may name `right` / `middle` in [GameStreamInputEvent.button].
  static const String pointerButtons = 'pointerButtons';

  /// Pointer [GameStreamInputAction.wheel] with [GameStreamInputEvent.dx]/`dy`.
  static const String wheel = 'wheel';

  /// Input reaches the window while it stays in the background.
  static const String backgroundInput = 'backgroundInput';

  /// `/api/game-stream/library` and `/api/game-stream/launch` are served.
  static const String remoteLaunch = 'remoteLaunch';

  static const List<String> all = <String>[
    videoSettings,
    pointerButtons,
    wheel,
    backgroundInput,
    remoteLaunch,
  ];
}

/// Pointer buttons accepted with [GameStreamFeature.pointerButtons].
const Set<String> kGameStreamPointerButtons = <String>{
  'left',
  'right',
  'middle',
};

/// How the host encoder trades quality when bandwidth drops. Wire names match
/// WebRTC's `RTCDegradationPreference`.
enum GameStreamDegradation {
  balanced('balanced'),
  maintainFramerate('maintain-framerate'),
  maintainResolution('maintain-resolution');

  const GameStreamDegradation(this.wireName);
  final String wireName;

  static GameStreamDegradation parse(Object? value) {
    for (final GameStreamDegradation candidate in values) {
      if (candidate.wireName == value || candidate.name == value) {
        return candidate;
      }
    }
    return balanced;
  }
}

/// Whether input may reach a background window ([background], window
/// messages only) or the host first brings the game to the front
/// ([foreground]) for engines that ignore input while unfocused.
enum GameStreamInputFocus {
  background,
  foreground;

  static GameStreamInputFocus parse(Object? value) =>
      value == foreground.name ? foreground : background;
}

/// Preferred video codec. Applied by the receiving side through
/// `setCodecPreferences` before it answers, so hosts need no support for it.
enum GameStreamCodec {
  auto,
  h264,
  vp8,
  vp9,
  av1;

  /// SDP `mimeType` subtype (`video/<subtype>`), or null for [auto].
  String? get mimeSubtype => switch (this) {
    auto => null,
    h264 => 'H264',
    vp8 => 'VP8',
    vp9 => 'VP9',
    av1 => 'AV1',
  };

  static GameStreamCodec parse(Object? value) {
    for (final GameStreamCodec candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return auto;
  }
}

/// Moonlight-style stream parameters chosen on the receiver. Every field is
/// clamped into a safe range when decoded: a hostile or buggy peer can ask for
/// less, never for an unbounded encoder.
class GameStreamVideoSettings {
  const GameStreamVideoSettings({
    this.maxHeight = 1080,
    this.maxFps = 60,
    this.bitrateKbps = 20000,
    this.adaptiveBitrate = true,
    this.degradation = GameStreamDegradation.balanced,
    this.codec = GameStreamCodec.auto,
    this.inputFocus = GameStreamInputFocus.background,
    this.audio = true,
  });

  factory GameStreamVideoSettings.fromJson(Object? raw) {
    if (raw is! Map) return const GameStreamVideoSettings();
    int integer(Object? value, int fallback) =>
        value is num && value.isFinite ? value.round() : fallback;
    return GameStreamVideoSettings(
      maxHeight: integer(raw['maxHeight'], 1080),
      maxFps: integer(raw['maxFps'], 60),
      bitrateKbps: integer(raw['bitrateKbps'], 20000),
      adaptiveBitrate: raw['adaptiveBitrate'] != false,
      degradation: GameStreamDegradation.parse(raw['degradation']),
      codec: GameStreamCodec.parse(raw['codec']),
      inputFocus: GameStreamInputFocus.parse(raw['inputFocus']),
      audio: raw['audio'] != false,
    ).clamped();
  }

  static const List<int> heightChoices = <int>[360, 480, 720, 1080, 1440, 2160];
  static const List<int> fpsChoices = <int>[30, 60, 90, 120];
  static const int minBitrateKbps = 500;
  static const int maxBitrateKbps = 150000;
  static const int minFps = 15;
  static const int maxFpsLimit = 120;
  static const int minHeight = 360;
  static const int maxHeightLimit = 2160;

  /// Height cap of the encoded picture; width follows the window aspect.
  final int maxHeight;
  final int maxFps;
  final int bitrateKbps;

  /// When false the host holds [bitrateKbps] instead of following estimates.
  final bool adaptiveBitrate;
  final GameStreamDegradation degradation;
  final GameStreamCodec codec;
  final GameStreamInputFocus inputFocus;

  /// Receiver-side playback of the loopback audio track.
  final bool audio;

  /// Width cap matching [maxHeight] at 16:9, rounded to even pixels.
  int get maxWidth => ((maxHeight * 16 / 9) / 2).round() * 2;

  GameStreamVideoSettings clamped() => GameStreamVideoSettings(
    maxHeight: maxHeight.clamp(minHeight, maxHeightLimit),
    maxFps: maxFps.clamp(minFps, maxFpsLimit),
    bitrateKbps: bitrateKbps.clamp(minBitrateKbps, maxBitrateKbps),
    adaptiveBitrate: adaptiveBitrate,
    degradation: degradation,
    codec: codec,
    inputFocus: inputFocus,
    audio: audio,
  );

  GameStreamVideoSettings copyWith({
    int? maxHeight,
    int? maxFps,
    int? bitrateKbps,
    bool? adaptiveBitrate,
    GameStreamDegradation? degradation,
    GameStreamCodec? codec,
    GameStreamInputFocus? inputFocus,
    bool? audio,
  }) => GameStreamVideoSettings(
    maxHeight: maxHeight ?? this.maxHeight,
    maxFps: maxFps ?? this.maxFps,
    bitrateKbps: bitrateKbps ?? this.bitrateKbps,
    adaptiveBitrate: adaptiveBitrate ?? this.adaptiveBitrate,
    degradation: degradation ?? this.degradation,
    codec: codec ?? this.codec,
    inputFocus: inputFocus ?? this.inputFocus,
    audio: audio ?? this.audio,
  ).clamped();

  /// Moonlight-like default bitrate for [maxHeight] × [maxFps].
  static int recommendedBitrateKbps({
    required int maxHeight,
    required int maxFps,
  }) {
    final int base = switch (maxHeight) {
      <= 480 => 2000,
      <= 720 => 5000,
      <= 1080 => 10000,
      <= 1440 => 20000,
      _ => 40000,
    };
    return (base * (maxFps / 30).clamp(1, 4)).round().clamp(
      minBitrateKbps,
      maxBitrateKbps,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'maxHeight': maxHeight,
    'maxFps': maxFps,
    'bitrateKbps': bitrateKbps,
    'adaptiveBitrate': adaptiveBitrate,
    'degradation': degradation.wireName,
    'codec': codec.name,
    'inputFocus': inputFocus.name,
    'audio': audio,
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamVideoSettings &&
      other.maxHeight == maxHeight &&
      other.maxFps == maxFps &&
      other.bitrateKbps == bitrateKbps &&
      other.adaptiveBitrate == adaptiveBitrate &&
      other.degradation == degradation &&
      other.codec == codec &&
      other.inputFocus == inputFocus &&
      other.audio == audio;

  @override
  int get hashCode => Object.hash(
    maxHeight,
    maxFps,
    bitrateKbps,
    adaptiveBitrate,
    degradation,
    codec,
    inputFocus,
    audio,
  );
}

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
    this.gameId,
    this.gameTitle,
    List<String> features = const <String>[],
    this.settings,
  }) : features = List<String>.unmodifiable(features);

  factory GameStreamSession.create({
    required String sessionId,
    required DateTime now,
    String? windowId,
    DateTime? expiresAt,
    String? gameId,
    String? gameTitle,
    List<String> features = const <String>[],
    GameStreamVideoSettings? settings,
  }) {
    _nonEmpty(sessionId, 'sessionId');
    return GameStreamSession(
      sessionId: sessionId,
      createdAt: now,
      updatedAt: now,
      state: GameStreamSessionState.waiting,
      windowId: _optionalNonEmpty(windowId, 'windowId'),
      expiresAt: expiresAt,
      gameId: _optionalNonEmpty(gameId, 'gameId'),
      gameTitle: _optionalNonEmpty(gameTitle, 'gameTitle'),
      features: features,
      settings: settings,
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
      gameId: _optionalNonEmpty(json['gameId'], 'gameId'),
      gameTitle: _optionalNonEmpty(json['gameTitle'], 'gameTitle'),
      // Unknown feature strings are kept; callers only test for known ones.
      features: <String>[
        if (json['features'] is List)
          for (final Object? feature in json['features'] as List)
            if (feature is String && feature.length <= 64) feature,
      ],
      settings: json['settings'] is Map
          ? GameStreamVideoSettings.fromJson(json['settings'])
          : null,
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

  /// Host library id when the session was started for a library game.
  String? gameId;
  String? gameTitle;

  /// Capabilities of the host that created this session ([GameStreamFeature]).
  final List<String> features;

  /// Effective stream parameters after the host applied a client request.
  GameStreamVideoSettings? settings;

  bool supports(String feature) => features.contains(feature);

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
    if (gameId != null) 'gameId': gameId,
    if (gameTitle != null) 'gameTitle': gameTitle,
    if (features.isNotEmpty) 'features': features,
    if (settings != null) 'settings': settings!.toJson(),
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
    this.dx,
    this.dy,
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
      dx: _optionalNumber(json['dx'], 'dx')?.toDouble(),
      dy: _optionalNumber(json['dy'], 'dy')?.toDouble(),
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

  /// Wheel deltas in notches (positive = right / down).
  final double? dx;
  final double? dy;

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
    if (dx != null) 'dx': dx,
    if (dy != null) 'dy': dy,
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
      if (button != null && !kGameStreamPointerButtons.contains(button)) {
        throw const FormatException('Invalid pointer button');
      }
      if (action == GameStreamInputAction.wheel) {
        final double h = dx ?? 0;
        final double v = dy ?? 0;
        if (h.abs() > 20 || v.abs() > 20) {
          throw const FormatException('Invalid wheel delta');
        }
      } else if (dx != null || dy != null) {
        throw const FormatException('Only wheel input carries deltas');
      }
    } else if (dx != null || dy != null) {
      throw const FormatException('Only wheel input carries deltas');
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

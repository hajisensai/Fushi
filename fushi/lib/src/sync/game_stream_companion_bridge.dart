import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';

/// Messages between the stream page (main engine, the single source of truth)
/// and the companion panel on a second display (its own engine, render only).
///
/// The main engine pushes [GameStreamCompanionHostMessage]s: the light
/// [GameStreamCompanionState] on every change, the heavier
/// [GameStreamCompanionResult] only when the lookup result changes, controller
/// [GameStreamCompanionCommand]s for the dictionary that lives in the
/// companion, and [GameStreamCompanionReply]s to its requests. The companion
/// sends back coarse [GameStreamCompanionMessage]s: taps and requests.
///
/// Everything crosses as one JSON string per message.
const String _typeKey = 'type';

Map<String, Object?> _decodeObject(String raw) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw FormatException('game stream companion message is not an object');
  }
  return Map<String, Object?>.from(decoded);
}

String? _string(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is String ? value : null;
}

int? _int(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is int ? value : null;
}

int _requireInt(Map<String, Object?> json, String key) {
  final int? value = _int(json, key);
  if (value == null) throw FormatException('missing int "$key"');
  return value;
}

String _requireString(Map<String, Object?> json, String key) {
  final String? value = _string(json, key);
  if (value == null) throw FormatException('missing string "$key"');
  return value;
}

GameStreamInputMode _mode(Object? name) =>
    name == GameStreamInputMode.lookup.name
    ? GameStreamInputMode.lookup
    : GameStreamInputMode.game;

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final MapEntry<Object?, Object?> entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key! as String: entry.value! as String,
  };
}

// ---------------------------------------------------------------------------
// Main engine → companion
// ---------------------------------------------------------------------------

@immutable
sealed class GameStreamCompanionHostMessage {
  const GameStreamCompanionHostMessage();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static GameStreamCompanionHostMessage decode(String raw) {
    final Map<String, Object?> json = _decodeObject(raw);
    return switch (json[_typeKey]) {
      GameStreamCompanionState.type => GameStreamCompanionState.fromJson(json),
      GameStreamCompanionResult.type => GameStreamCompanionResult.fromJson(
        json,
      ),
      GameStreamCompanionCommand.type => GameStreamCompanionCommand.fromJson(
        json,
      ),
      GameStreamCompanionReply.type => GameStreamCompanionReply.fromJson(json),
      final Object? other => throw FormatException(
        'unknown companion host message "$other"',
      ),
    };
  }
}

/// What the companion panel shows, minus the lookup result.
class GameStreamCompanionState extends GameStreamCompanionHostMessage {
  const GameStreamCompanionState({
    this.lineId,
    this.lineText,
    this.caret,
    this.highlightStart,
    this.highlightCount,
    this.mode = GameStreamInputMode.game,
    this.controllerUsed = false,
    this.searching = false,
    this.error,
    this.mineMessage,
    this.mineFailed = false,
  });

  factory GameStreamCompanionState.fromJson(Map<String, Object?> json) =>
      GameStreamCompanionState(
        lineId: _string(json, 'lineId'),
        lineText: _string(json, 'lineText'),
        caret: _int(json, 'caret'),
        highlightStart: _int(json, 'highlightStart'),
        highlightCount: _int(json, 'highlightCount'),
        mode: _mode(json['mode']),
        controllerUsed: json['controllerUsed'] == true,
        searching: json['searching'] == true,
        error: _string(json, 'error'),
        mineMessage: _string(json, 'mineMessage'),
        mineFailed: json['mineFailed'] == true,
      );

  static const String type = 'state';

  /// Current Hook line; null before the first line arrives.
  final String? lineId;
  final String? lineText;

  /// Lookup-mode cursor in graphemes; null outside lookup mode.
  final int? caret;

  /// The word the last lookup matched (graphemes); null without a match.
  final int? highlightStart;
  final int? highlightCount;

  final GameStreamInputMode mode;

  /// Whether a controller button was pressed this session (only then does a
  /// tap on a word switch to lookup mode and the mode chip show).
  final bool controllerUsed;
  final bool searching;
  final String? error;
  final String? mineMessage;
  final bool mineFailed;

  ({int start, int count})? get highlight =>
      highlightStart == null || highlightCount == null
      ? null
      : (start: highlightStart!, count: highlightCount!);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'lineId': lineId,
    'lineText': lineText,
    'caret': caret,
    'highlightStart': highlightStart,
    'highlightCount': highlightCount,
    'mode': mode.name,
    'controllerUsed': controllerUsed,
    'searching': searching,
    'error': error,
    'mineMessage': mineMessage,
    'mineFailed': mineFailed,
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamCompanionState &&
      other.lineId == lineId &&
      other.lineText == lineText &&
      other.caret == caret &&
      other.highlightStart == highlightStart &&
      other.highlightCount == highlightCount &&
      other.mode == mode &&
      other.controllerUsed == controllerUsed &&
      other.searching == searching &&
      other.error == error &&
      other.mineMessage == mineMessage &&
      other.mineFailed == mineFailed;

  @override
  int get hashCode => Object.hash(
    lineId,
    lineText,
    caret,
    highlightStart,
    highlightCount,
    mode,
    controllerUsed,
    searching,
    error,
    mineMessage,
    mineFailed,
  );
}

/// The current lookup result, sent only when it changes. [resultJson] is
/// `DictionarySearchResult.toJson()`; [popupJson] and [dictionaryStyles] are
/// the host-rendered entries and the host's dictionary CSS, which
/// `toJson()` leaves out. A null [resultJson] clears the panel.
class GameStreamCompanionResult extends GameStreamCompanionHostMessage {
  const GameStreamCompanionResult({
    required this.revision,
    this.resultJson,
    this.popupJson,
    this.dictionaryStyles = const <String, String>{},
  });

  factory GameStreamCompanionResult.fromJson(Map<String, Object?> json) =>
      GameStreamCompanionResult(
        revision: _requireInt(json, 'revision'),
        resultJson: _string(json, 'result'),
        popupJson: _string(json, 'popupJson'),
        dictionaryStyles: _stringMap(json['styles']),
      );

  static const String type = 'result';

  /// Increases with every result the main engine sends.
  final int revision;
  final String? resultJson;
  final String? popupJson;
  final Map<String, String> dictionaryStyles;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'revision': revision,
    'result': resultJson,
    'popupJson': popupJson,
    'styles': dictionaryStyles,
  };
}

/// A controller button aimed at the dictionary, which lives in the companion.
enum GameStreamCompanionDictionaryCommand {
  entryNext,
  entryPrevious,
  mineFirstVisible,
  playFirstVisibleAudio,
}

class GameStreamCompanionCommand extends GameStreamCompanionHostMessage {
  const GameStreamCompanionCommand(this.command);

  factory GameStreamCompanionCommand.fromJson(Map<String, Object?> json) {
    final String name = _requireString(json, 'command');
    for (final GameStreamCompanionDictionaryCommand command
        in GameStreamCompanionDictionaryCommand.values) {
      if (command.name == name) return GameStreamCompanionCommand(command);
    }
    throw FormatException('unknown companion command "$name"');
  }

  static const String type = 'command';

  final GameStreamCompanionDictionaryCommand command;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'command': command.name,
  };
}

/// Answer to the companion request with the same [id]. [value] is plain JSON
/// whose shape depends on the request (see the request classes).
class GameStreamCompanionReply extends GameStreamCompanionHostMessage {
  const GameStreamCompanionReply({required this.id, this.value});

  factory GameStreamCompanionReply.fromJson(Map<String, Object?> json) =>
      GameStreamCompanionReply(
        id: _requireInt(json, 'id'),
        value: json['value'],
      );

  static const String type = 'reply';

  final int id;
  final Object? value;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'value': value,
  };
}

// ---------------------------------------------------------------------------
// Companion → main engine
// ---------------------------------------------------------------------------

@immutable
sealed class GameStreamCompanionMessage {
  const GameStreamCompanionMessage();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static GameStreamCompanionMessage decode(String raw) {
    final Map<String, Object?> json = _decodeObject(raw);
    return switch (json[_typeKey]) {
      GameStreamCompanionReady.type => const GameStreamCompanionReady(),
      GameStreamCompanionLookupAt.type => GameStreamCompanionLookupAt(
        lineId: _requireString(json, 'lineId'),
        index: _requireInt(json, 'index'),
      ),
      GameStreamCompanionLookupText.type => GameStreamCompanionLookupText(
        _requireString(json, 'text'),
      ),
      GameStreamCompanionSetMode.type => GameStreamCompanionSetMode(
        _mode(json['mode']),
      ),
      GameStreamCompanionMineRequest.type => GameStreamCompanionMineRequest(
        id: _requireInt(json, 'id'),
        fields: _stringMap(json['fields']),
      ),
      GameStreamCompanionDuplicateRequest.type =>
        GameStreamCompanionDuplicateRequest(
          id: _requireInt(json, 'id'),
          expression: _requireString(json, 'expression'),
          reading: _requireString(json, 'reading'),
        ),
      GameStreamCompanionMediaRequest.type => GameStreamCompanionMediaRequest(
        id: _requireInt(json, 'id'),
        dictionary: _requireString(json, 'dictionary'),
        path: _requireString(json, 'path'),
      ),
      GameStreamCompanionAudioRequest.type => GameStreamCompanionAudioRequest(
        id: _requireInt(json, 'id'),
        expression: _requireString(json, 'expression'),
        reading: _requireString(json, 'reading'),
      ),
      final Object? other => throw FormatException(
        'unknown companion message "$other"',
      ),
    };
  }
}

/// The companion's Dart side is listening: send it everything again.
class GameStreamCompanionReady extends GameStreamCompanionMessage {
  const GameStreamCompanionReady();

  static const String type = 'ready';

  @override
  Map<String, Object?> toJson() => <String, Object?>{_typeKey: type};
}

/// A tap on grapheme [index] of line [lineId].
class GameStreamCompanionLookupAt extends GameStreamCompanionMessage {
  const GameStreamCompanionLookupAt({
    required this.lineId,
    required this.index,
  });

  static const String type = 'lookupAt';

  final String lineId;
  final int index;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'lineId': lineId,
    'index': index,
  };
}

/// Text selected or a link tapped inside the dictionary.
class GameStreamCompanionLookupText extends GameStreamCompanionMessage {
  const GameStreamCompanionLookupText(this.text);

  static const String type = 'lookupText';

  final String text;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'text': text,
  };
}

/// The mode chip on the companion was tapped.
class GameStreamCompanionSetMode extends GameStreamCompanionMessage {
  const GameStreamCompanionSetMode(this.mode);

  static const String type = 'setMode';

  final GameStreamInputMode mode;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'mode': mode.name,
  };
}

/// A message the main engine must answer with a [GameStreamCompanionReply]
/// carrying the same [id].
sealed class GameStreamCompanionRequest extends GameStreamCompanionMessage {
  const GameStreamCompanionRequest({required this.id});

  final int id;
}

/// Mine a card from these popup [fields] (the host writes it). Reply value:
/// a [GameStreamCompanionMineOutcome] name.
class GameStreamCompanionMineRequest extends GameStreamCompanionRequest {
  const GameStreamCompanionMineRequest({
    required super.id,
    required this.fields,
  });

  static const String type = 'mine';

  final Map<String, String> fields;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'fields': fields,
  };
}

/// Is this word already in Anki? Reply value: a bool.
class GameStreamCompanionDuplicateRequest extends GameStreamCompanionRequest {
  const GameStreamCompanionDuplicateRequest({
    required super.id,
    required this.expression,
    required this.reading,
  });

  static const String type = 'isDuplicate';

  final String expression;
  final String reading;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'expression': expression,
    'reading': reading,
  };
}

/// A dictionary media file. Reply value: see
/// [encodeGameStreamCompanionMedia].
class GameStreamCompanionMediaRequest extends GameStreamCompanionRequest {
  const GameStreamCompanionMediaRequest({
    required super.id,
    required this.dictionary,
    required this.path,
  });

  static const String type = 'media';

  final String dictionary;
  final String path;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'dictionary': dictionary,
    'path': path,
  };
}

/// A playable reference for a word's audio. Reply value: a string or null.
class GameStreamCompanionAudioRequest extends GameStreamCompanionRequest {
  const GameStreamCompanionAudioRequest({
    required super.id,
    required this.expression,
    required this.reading,
  });

  static const String type = 'wordAudio';

  final String expression;
  final String reading;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'expression': expression,
    'reading': reading,
  };
}

/// How a mine request ended, as the popup needs to know it.
enum GameStreamCompanionMineOutcome {
  ok,
  duplicate,
  error;

  static GameStreamCompanionMineOutcome fromValue(Object? value) {
    for (final GameStreamCompanionMineOutcome outcome in values) {
      if (outcome.name == value) return outcome;
    }
    return error;
  }
}

/// Media reply value: `{bytes, contentType}`, or null when missing. Size is
/// the pipe's business ([GameStreamCompanionPipe] hands a big reply over as
/// a file).
Object? encodeGameStreamCompanionMedia(DictionaryPopupMedia? media) =>
    media == null
    ? null
    : <String, Object?>{
        'bytes': base64Encode(media.bytes),
        'contentType': media.contentType,
      };

/// Reads a media reply.
DictionaryPopupMedia? decodeGameStreamCompanionMedia(Object? value) {
  if (value is! Map) return null;
  final Object? contentType = value['contentType'];
  final Object? bytes = value['bytes'];
  if (contentType is! String || bytes is! String) return null;
  return DictionaryPopupMedia(
    bytes: Uint8List.fromList(base64Decode(bytes)),
    contentType: contentType,
  );
}

// ---------------------------------------------------------------------------
// The pipe: what actually crosses the process boundary
// ---------------------------------------------------------------------------

/// Longest message (UTF-16 code units) handed to the relay as is.
///
/// Android relays each message as a `Bundle` string in one oneway Binder
/// transaction. `Bundle.putString` writes UTF-16 (two bytes a unit), and
/// oneway transactions share an async buffer of about half the 1 MB Binder
/// buffer with everything else in flight. 64K units (128 KB on the wire)
/// keeps a burst of messages well inside it; anything longer (a big result
/// with its dictionary CSS, a large media reply) goes through a file.
const int kGameStreamCompanionInlineMessageUnits = 64 * 1024;

/// A relayed message that stands for the file after the prefix. Messages
/// themselves are JSON objects, so they never start with it.
const String _spilledPrefix = '@file:';

/// Where both ends of the pipe spill big messages: the app's temporary
/// directory, which both processes share. The stream page's side deletes it
/// when the session ends ([GameStreamCompanionPipe.clearSpills]), so a
/// message nobody read (a panel that closed first) does not stay behind.
Directory gameStreamCompanionSpillRoot() => Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}game_stream_companion',
);

/// One end of the pipe between the stream page and the companion panel.
///
/// [send] delivers a message or throws: the relay reports whether it took
/// the message (`post` returns true), and a message too big for one Binder
/// transaction is written to a file under [spillDirectory] first. [receive]
/// turns what arrives back into the message, in arrival order.
class GameStreamCompanionPipe {
  GameStreamCompanionPipe({
    required Future<bool?> Function(String raw) post,
    required this.spillDirectory,
    this.inlineLimit = kGameStreamCompanionInlineMessageUnits,
  }) : _post = post;

  final Future<bool?> Function(String raw) _post;
  final Directory spillDirectory;
  final int inlineLimit;
  int _spillCount = 0;
  Future<void> _inbound = Future<void>.value();

  Future<void> send(String message) async {
    File? spilled;
    String raw = message;
    if (message.length > inlineLimit) {
      await spillDirectory.create(recursive: true);
      spilled = File(
        '${spillDirectory.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}-${_spillCount++}.json',
      );
      await spilled.writeAsString(message, flush: true);
      raw = '$_spilledPrefix${spilled.path}';
    }
    final bool? delivered = await _post(raw);
    if (delivered == true) return;
    if (spilled != null && spilled.existsSync()) await spilled.delete();
    throw StateError(
      'game stream companion: the relay did not take the message',
    );
  }

  /// Hands each received [raw] to [onMessage] as the message it stands for,
  /// strictly in arrival order (a spilled one is read back and its file
  /// deleted). A message that cannot be read goes to [onError].
  void receive(
    String raw,
    void Function(String message) onMessage,
    void Function(Object error, StackTrace stack) onError,
  ) {
    _inbound = _inbound.then((_) async {
      try {
        onMessage(await _open(raw));
      } catch (error, stack) {
        onError(error, stack);
      }
    });
  }

  static Future<String> _open(String raw) async {
    if (!raw.startsWith(_spilledPrefix)) return raw;
    final File file = File(raw.substring(_spilledPrefix.length));
    try {
      return await file.readAsString();
    } finally {
      if (file.existsSync()) await file.delete();
    }
  }

  /// Deletes [root] and every spilled message in it.
  static Future<void> clearSpills(Directory root) async {
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// Companion side: request bookkeeping and the relayed popup resources
// ---------------------------------------------------------------------------

/// The companion's end of the bridge: sends messages, matches replies to
/// requests and hands every other host message to [onHostMessage].
class GameStreamCompanionLink {
  GameStreamCompanionLink({
    required Future<void> Function(String raw) send,
    required this.onHostMessage,
  }) : _send = send;

  final Future<void> Function(String raw) _send;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 1;

  /// Every host message except replies.
  final void Function(GameStreamCompanionHostMessage message) onHostMessage;

  Future<void> send(GameStreamCompanionMessage message) =>
      _send(message.encode());

  /// Feeds one raw message from the main engine.
  void receive(String raw) {
    final GameStreamCompanionHostMessage message =
        GameStreamCompanionHostMessage.decode(raw);
    if (message is GameStreamCompanionReply) {
      _pending.remove(message.id)?.complete(message.value);
      return;
    }
    onHostMessage(message);
  }

  /// Sends a request built by [build] (given a fresh id) and waits for the
  /// main engine's reply value.
  Future<Object?> request(
    GameStreamCompanionRequest Function(int id) build,
  ) async {
    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      await send(build(id));
    } catch (error, stack) {
      _pending.remove(id);
      completer.completeError(error, stack);
    }
    return completer.future;
  }

  /// The main engine went away: pending requests fail instead of hanging.
  void close() {
    final List<Completer<Object?>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<Object?> completer in pending) {
      completer.completeError(StateError('game stream companion disconnected'));
    }
  }

  Future<GameStreamCompanionMineOutcome> mine(
    Map<String, String> fields,
  ) async => GameStreamCompanionMineOutcome.fromValue(
    await request(
      (int id) => GameStreamCompanionMineRequest(id: id, fields: fields),
    ),
  );

  Future<bool> isDuplicate(String expression, String reading) async =>
      await request(
        (int id) => GameStreamCompanionDuplicateRequest(
          id: id,
          expression: expression,
          reading: reading,
        ),
      ) ==
      true;
}

/// Popup resources on the companion: the styles come with each result, media
/// and audio are fetched by the main engine (which holds the host
/// connection) and relayed.
class GameStreamCompanionResources implements DictionaryPopupResourceSource {
  GameStreamCompanionResources(this._link);

  final GameStreamCompanionLink _link;
  Map<String, String> _styles = const <String, String>{};

  @override
  Map<String, String> get dictionaryStyles => _styles;

  /// A new map instance only when the styles actually changed (the WebView
  /// re-injects on identity change).
  void updateStyles(Map<String, String> styles) {
    if (mapEquals(styles, _styles)) return;
    _styles = Map<String, String>.unmodifiable(styles);
  }

  @override
  Future<DictionaryPopupMedia?> mediaFile(
    String dictionary,
    String path,
  ) async => decodeGameStreamCompanionMedia(
    await _link.request(
      (int id) => GameStreamCompanionMediaRequest(
        id: id,
        dictionary: dictionary,
        path: path,
      ),
    ),
  );

  @override
  Future<String?> wordAudioRef(String expression, String reading) async {
    final Object? value = await _link.request(
      (int id) => GameStreamCompanionAudioRequest(
        id: id,
        expression: expression,
        reading: reading,
      ),
    );
    return value is String ? value : null;
  }
}

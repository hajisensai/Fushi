/// Wire types for streaming a game straight from the host library.
///
/// A paired receiver lists the host's games, asks the host to launch one, and
/// polls the launch until the host has opened a stream session for it. Host
/// paths, launch arguments and window handles never leave the host.
library;

import 'dart:typed_data';

import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// One host library game as seen by a receiver.
class GameStreamLibraryGame {
  const GameStreamLibraryGame({
    required this.id,
    required this.title,
    this.hasCover = false,
    this.lastPlayedAt,
    this.playSeconds = 0,
    this.running = false,
  });

  factory GameStreamLibraryGame.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid library game');
    final Object? id = raw['id'];
    final Object? title = raw['title'];
    if (id is! String || id.isEmpty || id.length > 256) {
      throw const FormatException('Invalid library game id');
    }
    if (title is! String || title.length > 4096) {
      throw const FormatException('Invalid library game title');
    }
    final Object? lastPlayedAt = raw['lastPlayedAt'];
    final Object? playSeconds = raw['playSeconds'];
    return GameStreamLibraryGame(
      id: id,
      title: title,
      hasCover: raw['hasCover'] == true,
      lastPlayedAt: lastPlayedAt is int && lastPlayedAt > 0
          ? lastPlayedAt
          : null,
      playSeconds: playSeconds is int && playSeconds > 0 ? playSeconds : 0,
      running: raw['running'] == true,
    );
  }

  final String id;
  final String title;
  final bool hasCover;

  /// Epoch milliseconds of the last host play session.
  final int? lastPlayedAt;
  final int playSeconds;

  /// The host's current Hook session is this game.
  final bool running;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'hasCover': hasCover,
    if (lastPlayedAt != null) 'lastPlayedAt': lastPlayedAt,
    if (playSeconds > 0) 'playSeconds': playSeconds,
    if (running) 'running': running,
  };
}

/// Cover bytes served for [GameStreamLibraryGame.hasCover].
class GameStreamLibraryCover {
  const GameStreamLibraryCover({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}

enum GameStreamLaunchState {
  /// The host accepted the request and is starting the game.
  starting,

  /// The game process runs; the host waits for its window and Hook session.
  waitingWindow,

  /// A stream session exists for the game; [GameStreamLaunchStatus.sessionId]
  /// can be joined.
  streaming,
  failed;

  bool get isTerminal => this == streaming || this == failed;
}

class GameStreamLaunchStatus {
  const GameStreamLaunchStatus({
    required this.launchId,
    required this.gameId,
    required this.state,
    required this.updatedAt,
    this.sessionId,
    this.reason,
  });

  factory GameStreamLaunchStatus.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid launch status');
    final Object? launchId = raw['launchId'];
    final Object? gameId = raw['gameId'];
    final Object? updatedAt = raw['updatedAt'];
    if (launchId is! String || launchId.isEmpty || launchId.length > 256) {
      throw const FormatException('Invalid launchId');
    }
    if (gameId is! String || gameId.isEmpty || gameId.length > 256) {
      throw const FormatException('Invalid gameId');
    }
    GameStreamLaunchState? state;
    for (final GameStreamLaunchState candidate
        in GameStreamLaunchState.values) {
      if (candidate.name == raw['state']) state = candidate;
    }
    if (state == null) throw const FormatException('Invalid launch state');
    final Object? sessionId = raw['sessionId'];
    final Object? reason = raw['reason'];
    return GameStreamLaunchStatus(
      launchId: launchId,
      gameId: gameId,
      state: state,
      updatedAt: updatedAt is int ? updatedAt : 0,
      sessionId: sessionId is String && sessionId.isNotEmpty ? sessionId : null,
      reason: reason is String && reason.length <= 256 ? reason : null,
    );
  }

  final String launchId;
  final String gameId;
  final GameStreamLaunchState state;

  /// Epoch milliseconds of the last state change.
  final int updatedAt;
  final String? sessionId;

  /// Stable machine code when [state] is [GameStreamLaunchState.failed].
  final String? reason;

  GameStreamLaunchStatus copyWith({
    GameStreamLaunchState? state,
    required int updatedAt,
    String? sessionId,
    String? reason,
  }) => GameStreamLaunchStatus(
    launchId: launchId,
    gameId: gameId,
    state: state ?? this.state,
    updatedAt: updatedAt,
    sessionId: sessionId ?? this.sessionId,
    reason: reason ?? this.reason,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kGameStreamWireVersion,
    'launchId': launchId,
    'gameId': gameId,
    'state': state.name,
    'updatedAt': updatedAt,
    if (sessionId != null) 'sessionId': sessionId,
    if (reason != null) 'reason': reason,
  };
}

/// Stable failure codes of a remote launch.
abstract final class GameStreamLaunchFailure {
  static const String disabled = 'launch_disabled';
  static const String unknownGame = 'unknown_game';
  static const String busy = 'host_busy';
  static const String exeMissing = 'exe_missing';
  static const String helperMissing = 'helper_missing';
  static const String launchFailed = 'launch_failed';
  static const String windowMissing = 'window_missing';
  static const String streamFailed = 'stream_failed';
  static const String superseded = 'superseded';
}

/// Rejection surfaced synchronously by [GameStreamLibraryHost.launch].
class GameStreamLaunchRejected implements Exception {
  const GameStreamLaunchRejected(this.code);
  final String code;

  @override
  String toString() => 'GameStreamLaunchRejected($code)';
}

/// App-side host library. The engine owns the HTTP contract; the app owns the
/// galgame repository, the Hook launcher and the capture host.
abstract interface class GameStreamLibraryHost {
  /// Host owner opted in to remote launches.
  bool get launchEnabled;

  Future<List<GameStreamLibraryGame>> listGames();

  Future<GameStreamLibraryCover?> cover(String gameId);

  /// Starts [gameId] and reports progress through
  /// `FushiRemoteGameStreamService.updateLaunch` for [launchId]. Throws
  /// [GameStreamLaunchRejected] when the launch cannot start at all.
  Future<void> launch({
    required String launchId,
    required String gameId,
    required GameStreamVideoSettings settings,
  });
}

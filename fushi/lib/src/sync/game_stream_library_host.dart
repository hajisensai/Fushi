import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable;
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_library.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:path/path.dart' as p;

/// Starts [game] under the Hook session; throws [GameStreamLaunchRejected].
typedef GameStreamGameLauncher = Future<void> Function(GalgameEntry game);

/// Opens the capture session once the game window is bound.
typedef GameStreamSessionStarter =
    Future<GameStreamSession> Function({
      required int hwnd,
      required GameStreamVideoSettings settings,
      required String gameId,
      required String gameTitle,
      required String launchId,
    });

/// Windows host side of "stream a game from the library": lists the galgame
/// library for paired receivers and runs a launch end to end — start the game
/// through the same Hook launcher the library page uses, wait for its window,
/// then open a stream session reserved for the requesting device.
///
/// Remote launch is off unless the host owner enabled it; the receiver can
/// only name a library id, never a path, arguments or window.
class FushiGameStreamLibraryHost implements GameStreamLibraryHost {
  FushiGameStreamLibraryHost({
    required Future<List<GalgameEntry>> Function() loadGames,
    required bool Function() isLaunchEnabled,
    required FushiRemoteGameStreamService service,
    required GameStreamSessionStarter startStream,
    GameStreamGameLauncher? launchGame,
    GalHookSessionState Function()? readHookState,
    Listenable? hookChanges,
    this.windowTimeout = const Duration(seconds: 90),
  }) : _loadGames = loadGames,
       _isLaunchEnabled = isLaunchEnabled,
       _service = service,
       _startStream = startStream,
       _readHookState =
           readHookState ?? (() => GalHookSessionController.instance.state),
       _hookChanges = hookChanges ?? GalHookSessionController.instance,
       _launchGameOverride = launchGame;

  final Future<List<GalgameEntry>> Function() _loadGames;
  final bool Function() _isLaunchEnabled;
  final FushiRemoteGameStreamService _service;
  final GameStreamSessionStarter _startStream;
  final GalHookSessionState Function() _readHookState;
  final Listenable _hookChanges;
  final GameStreamGameLauncher? _launchGameOverride;
  final Duration windowTimeout;

  @override
  bool get launchEnabled => _isLaunchEnabled();

  @override
  Future<List<GameStreamLibraryGame>> listGames() async {
    final List<GalgameEntry> games = await _loadGames();
    return <GameStreamLibraryGame>[
      for (final GalgameEntry game in games)
        GameStreamLibraryGame(
          id: game.id,
          title: game.displayName,
          hasCover: _coverFile(game) != null,
          lastPlayedAt: game.lastPlayedMs > 0 ? game.lastPlayedMs : null,
          playSeconds: game.totalPlaySeconds,
          running: _isRunning(game),
        ),
    ];
  }

  @override
  Future<GameStreamLibraryCover?> cover(String gameId) async {
    final GalgameEntry? game = await _find(gameId);
    final File? file = game == null ? null : _coverFile(game);
    if (file == null) return null;
    final String? contentType = gameStreamCoverContentType(file.path);
    if (contentType == null) return null;
    final Uint8List bytes = await file.readAsBytes();
    // Covers are thumbnails; refuse anything absurd rather than shipping it
    // base64-encoded over the control channel.
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) return null;
    return GameStreamLibraryCover(bytes: bytes, contentType: contentType);
  }

  @override
  Future<void> launch({
    required String launchId,
    required String gameId,
    required GameStreamVideoSettings settings,
  }) async {
    if (!Platform.isWindows) {
      throw const GameStreamLaunchRejected(
        GameStreamLaunchFailure.launchFailed,
      );
    }
    final GalgameEntry? game = await _find(gameId);
    if (game == null) {
      throw const GameStreamLaunchRejected(GameStreamLaunchFailure.unknownGame);
    }
    final GameStreamSession? live = _service.session;
    if (live != null &&
        !live.state.isTerminal &&
        live.gameId == game.id &&
        live.state == GameStreamSessionState.waiting) {
      // A stream for this game is already waiting (e.g. the host started it
      // locally); joining it is the whole job.
      _service.updateLaunch(
        launchId,
        state: GameStreamLaunchState.streaming,
        sessionId: live.sessionId,
      );
      return;
    }
    // 主机主人正在本地玩另一款游戏：launchGame 会先 _stopSources /
    // _stopPlayTracker，把他的文本 Hook、制卡与学习计时整个拆掉。远端只能等他关掉
    // 或加入那款游戏的串流，不能替他换游戏。
    if (_readHookState().isActive && !_isRunning(game)) {
      throw const GameStreamLaunchRejected(GameStreamLaunchFailure.busy);
    }
    if (!_isRunning(game) || _readHookState().boundWindow == null) {
      await (_launchGameOverride ?? launchGalgameForStream)(game);
    }
    _service.updateLaunch(launchId, state: GameStreamLaunchState.waitingWindow);
    final int hwnd = await _waitForWindow(game);
    try {
      final GameStreamSession session = await _startStream(
        hwnd: hwnd,
        settings: settings,
        gameId: game.id,
        gameTitle: game.displayName,
        launchId: launchId,
      );
      _service.updateLaunch(
        launchId,
        state: GameStreamLaunchState.streaming,
        sessionId: session.sessionId,
      );
    } catch (error, stack) {
      ErrorLogService.instance.log('GameStream.launchStream', error, stack);
      throw const GameStreamLaunchRejected(
        GameStreamLaunchFailure.streamFailed,
      );
    }
  }

  Future<int> _waitForWindow(GalgameEntry game) async {
    int? ready() {
      final GalHookSessionState state = _readHookState();
      final int hwnd = state.boundWindow?.hwnd ?? 0;
      return state.isActive && hwnd != 0 && _isRunning(game) ? hwnd : null;
    }

    final int? immediate = ready();
    if (immediate != null) return immediate;
    final Completer<int> bound = Completer<int>();
    void check() {
      final int? hwnd = ready();
      if (hwnd != null && !bound.isCompleted) bound.complete(hwnd);
    }

    _hookChanges.addListener(check);
    try {
      return await bound.future.timeout(
        windowTimeout,
        onTimeout: () => throw const GameStreamLaunchRejected(
          GameStreamLaunchFailure.windowMissing,
        ),
      );
    } finally {
      _hookChanges.removeListener(check);
    }
  }

  /// The same launch path as the library page, minus the toasts: the
  /// requesting device shows the outcome.
  Future<void> launchGalgameForStream(GalgameEntry game) async {
    if (!File(game.exePath).existsSync()) {
      throw const GameStreamLaunchRejected(GameStreamLaunchFailure.exeMissing);
    }
    final bool is32Bit =
        await EngineHookGalAudioSource.exeIs32Bit(game.exePath) ?? false;
    final bool installed = await GalgameHelperInstaller()
        .ensureInjectorHeadless(is32Bit: is32Bit);
    if (!installed) {
      throw const GameStreamLaunchRejected(
        GameStreamLaunchFailure.helperMissing,
      );
    }
    final GalHookLaunchResult result = await GalHookSessionController.instance
        .launchGame(
          game.exePath,
          launchArguments: game.launchArgumentTokens,
          workdir: game.workdir,
          gameId: game.id,
          gameTitle: game.displayName,
          japaneseLocaleMode: galJapaneseLocaleModeFromKey(
            game.japaneseLocaleMode,
          ),
          contentLanguage: game.language,
        );
    if (!result.launched) {
      throw GameStreamLaunchRejected(
        result.reason == GalHookLaunchFailureReason.superseded
            ? GameStreamLaunchFailure.superseded
            : GameStreamLaunchFailure.launchFailed,
      );
    }
  }

  Future<GalgameEntry?> _find(String gameId) async {
    for (final GalgameEntry game in await _loadGames()) {
      if (game.id == gameId) return game;
    }
    return null;
  }

  bool _isRunning(GalgameEntry game) {
    final GalHookSessionState state = _readHookState();
    final String? exe = state.launchExe;
    return state.isActive &&
        exe != null &&
        p.equals(
          p.normalize(exe).toLowerCase(),
          p.normalize(game.exePath).toLowerCase(),
        );
  }

  static File? _coverFile(GalgameEntry game) {
    final String? path = game.coverPath;
    if (path == null || path.isEmpty) return null;
    final File file = File(path);
    return file.existsSync() && gameStreamCoverContentType(path) != null
        ? file
        : null;
  }
}

/// Image content type by extension; null for anything that is not a cover.
String? gameStreamCoverContentType(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.bmp' => 'image/bmp',
      '.avif' => 'image/avif',
      _ => null,
    };

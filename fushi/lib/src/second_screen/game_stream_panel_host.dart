import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi/src/second_screen/second_screen_host.dart'
    show SecondScreenDisplayInfo, SecondScreenResets;

/// The stream page's handle on the second display: which displays exist,
/// whether its lookup panel is up on one, and the message pipe to it. The
/// game stream is one mode of the shared [SecondScreenHost]; while it wants
/// the panel it takes the second screen from the companion, which comes back
/// when the stream page lets go.
///
/// Only Android has an implementation ([forCurrentPlatform] is null
/// elsewhere); widget tests pass a fake.
abstract class GameStreamPanelHost {
  /// The Android implementation, or null where a second display is not
  /// supported.
  static GameStreamPanelHost? forCurrentPlatform() {
    final SecondScreenHost? host = SecondScreenHost.forCurrentPlatform();
    return host == null ? null : SecondScreenGameStreamPanelHost(host);
  }

  /// Displays the panel could go on (never the app's own display).
  ValueListenable<List<SecondScreenDisplayInfo>> get displays;

  /// The game stream panel is up on a display and can receive messages.
  ValueListenable<bool> get attached;

  /// Messages the panel sends.
  Stream<GameStreamCompanionMessage> get messages;

  /// Fires when the platform side was replaced (Android: the main Activity
  /// was recreated while the page kept running on the cached engine).
  /// Whatever the page placed before is gone, including a panel that was
  /// launched but had not come up yet (so [attached] never turned true and
  /// will not turn false either): the page must place it again.
  Listenable get resets;

  /// Starts watching displays. Call once before anything else.
  Future<void> start();

  /// Shows the panel on [displayId]; [attached] turns true once it is up.
  Future<void> show(int displayId);

  /// Closes the panel ([attached] turns false).
  Future<void> dismiss();

  /// Delivers [message] to the panel, or throws when it could not (no panel
  /// attached, the panel process gone).
  Future<void> send(GameStreamCompanionHostMessage message);

  /// Stops watching and lets go of the second screen.
  void dispose();
}

/// The game stream's client of the shared [SecondScreenHost]. One per stream
/// session; disposing it gives the second screen back.
class SecondScreenGameStreamPanelHost implements GameStreamPanelHost {
  SecondScreenGameStreamPanelHost(this._host, {Directory? spillRoot})
    : _spillRoot = spillRoot ?? gameStreamCompanionSpillRoot() {
    _pipe = GameStreamCompanionPipe(
      post: (String raw) => _host.post(_mode, raw),
      spillDirectory: Directory(
        '${_spillRoot.path}${Platform.pathSeparator}host',
      ),
    );
  }

  static const SecondScreenPanelMode _mode = SecondScreenPanelMode.gameStream;

  final SecondScreenHost _host;

  /// Both ends' spilled messages; this session owns (and removes) it.
  final Directory _spillRoot;
  late final GameStreamCompanionPipe _pipe;
  final ValueNotifier<bool> _attached = ValueNotifier<bool>(false);
  final StreamController<GameStreamCompanionMessage> _messages =
      StreamController<GameStreamCompanionMessage>.broadcast();
  StreamSubscription<SecondScreenPanelMessage>? _hostMessages;
  bool _listening = false;

  @override
  ValueListenable<List<SecondScreenDisplayInfo>> get displays => _host.displays;

  @override
  ValueListenable<bool> get attached => _attached;

  @override
  Stream<GameStreamCompanionMessage> get messages => _messages.stream;

  @override
  Listenable get resets => _host.resets;

  @override
  Future<void> start() async {
    if (!_listening) {
      _listening = true;
      _host.panel.addListener(_onPanel);
      _hostMessages = _host.messages.listen(_onHostMessage);
      _onPanel();
    }
    // Leftovers of a session that was killed before it could clean up.
    await GameStreamCompanionPipe.clearSpills(_spillRoot);
    await _host.start();
  }

  void _onPanel() {
    _attached.value = _host.panel.value?.mode == _mode;
  }

  void _onHostMessage(SecondScreenPanelMessage message) {
    if (message.mode != _mode) return;
    _pipe.receive(
      message.raw,
      (String raw) {
        if (_messages.isClosed) return;
        _messages.add(GameStreamCompanionMessage.decode(raw));
      },
      (Object error, StackTrace stack) => ErrorLogService.instance.log(
        'GameStreamPanelHost.message',
        error,
        stack,
      ),
    );
  }

  @override
  Future<void> show(int displayId) => _host.request(_mode, displayId);

  @override
  Future<void> dismiss() => _host.request(_mode, null);

  @override
  Future<void> send(GameStreamCompanionHostMessage message) =>
      _pipe.send(message.encode());

  @override
  void dispose() {
    if (_listening) _host.panel.removeListener(_onPanel);
    unawaited(_hostMessages?.cancel());
    unawaited(
      _host
          .request(_mode, null)
          .catchError(
            (Object error, StackTrace stack) => ErrorLogService.instance.log(
              'GameStreamPanelHost.dispose',
              error,
              stack,
            ),
          ),
    );
    _attached.dispose();
    unawaited(_messages.close());
    unawaited(GameStreamCompanionPipe.clearSpills(_spillRoot));
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// A display other than the one the app runs on.
@immutable
class GameStreamCompanionDisplayInfo {
  const GameStreamCompanionDisplayInfo({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
  });

  static GameStreamCompanionDisplayInfo? fromMap(Object? value) {
    if (value is! Map) return null;
    final Object? id = value['id'];
    if (id is! int) return null;
    final Object? name = value['name'];
    final Object? width = value['width'];
    final Object? height = value['height'];
    return GameStreamCompanionDisplayInfo(
      id: id,
      name: name is String ? name : '',
      width: width is int ? width : 0,
      height: height is int ? height : 0,
    );
  }

  final int id;
  final String name;

  /// Physical pixels.
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is GameStreamCompanionDisplayInfo &&
      other.id == id &&
      other.name == name &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(id, name, width, height);
}

/// The stream page's handle on the second display: which displays exist,
/// whether the companion panel is up on one, and the message pipe to it.
///
/// Only Android has an implementation ([forCurrentPlatform] is null
/// elsewhere); widget tests pass a fake.
abstract class GameStreamCompanionDisplay {
  /// The Android implementation, or null where a second display is not
  /// supported.
  static GameStreamCompanionDisplay? forCurrentPlatform() =>
      !kIsWeb && Platform.isAndroid
      ? MethodChannelGameStreamCompanionDisplay()
      : null;

  /// Displays the companion could go on (never the app's own display).
  ValueListenable<List<GameStreamCompanionDisplayInfo>> get displays;

  /// The companion panel is up on a display and can receive messages.
  ValueListenable<bool> get attached;

  /// Messages the companion sends.
  Stream<GameStreamCompanionMessage> get messages;

  /// Fires when the platform side was replaced (Android: the main Activity
  /// was recreated while the page kept running on the cached engine).
  /// Whatever the page placed before is gone, including a panel that was
  /// launched but had not come up yet (so [attached] never turned true and
  /// will not turn false either): the page must place it again.
  Listenable get resets;

  /// Starts watching displays. Call once before anything else.
  Future<void> start();

  /// Shows the companion panel on [displayId]; [attached] turns true once it
  /// is up.
  Future<void> show(int displayId);

  /// Closes the companion panel ([attached] turns false).
  Future<void> dismiss();

  /// Delivers [message] to the panel, or throws when it could not (no panel
  /// attached, the panel process gone).
  Future<void> send(GameStreamCompanionHostMessage message);

  /// Stops watching and closes the companion.
  void dispose();
}

/// [GameStreamCompanionDisplay.resets] as a plain event: listeners run on
/// every [fire], with no value to compare.
class GameStreamCompanionResets extends ChangeNotifier {
  /// Tells the listeners the platform side was replaced.
  void fire() => notifyListeners();
}

/// Android: `GameStreamCompanionDisplay.java` launches the companion as its
/// own activity on the second display and relays messages and controller
/// keys between the two processes.
class MethodChannelGameStreamCompanionDisplay
    implements GameStreamCompanionDisplay {
  MethodChannelGameStreamCompanionDisplay({
    MethodChannel channel = FushiChannels.gameStreamCompanion,
    Directory? spillRoot,
  }) : _channel = channel,
       _spillRoot = spillRoot ?? gameStreamCompanionSpillRoot() {
    _pipe = GameStreamCompanionPipe(
      post: (String raw) => _channel.invokeMethod<bool>('send', raw),
      spillDirectory: Directory(
        '${_spillRoot.path}${Platform.pathSeparator}host',
      ),
    );
  }

  final MethodChannel _channel;

  /// Both ends' spilled messages; this session owns (and removes) it.
  final Directory _spillRoot;
  late final GameStreamCompanionPipe _pipe;
  final ValueNotifier<List<GameStreamCompanionDisplayInfo>> _displays =
      ValueNotifier<List<GameStreamCompanionDisplayInfo>>(
        const <GameStreamCompanionDisplayInfo>[],
      );
  final ValueNotifier<bool> _attached = ValueNotifier<bool>(false);
  final StreamController<GameStreamCompanionMessage> _messages =
      StreamController<GameStreamCompanionMessage>.broadcast();
  final GameStreamCompanionResets _resets = GameStreamCompanionResets();

  @override
  ValueListenable<List<GameStreamCompanionDisplayInfo>> get displays =>
      _displays;

  @override
  Listenable get resets => _resets;

  @override
  ValueListenable<bool> get attached => _attached;

  @override
  Stream<GameStreamCompanionMessage> get messages => _messages.stream;

  @override
  Future<void> start() async {
    // Leftovers of a session that was killed before it could clean up.
    await GameStreamCompanionPipe.clearSpills(_spillRoot);
    _channel.setMethodCallHandler(_onCall);
    _displays.value = _parseDisplays(
      await _channel.invokeMethod<List<Object?>>('listDisplays'),
    );
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'displaysChanged':
        _displays.value = _parseDisplays(call.arguments as List<Object?>?);
      case 'companionAttached':
        _attached.value = call.arguments == true;
      case 'companionReset':
        // A new platform instance: no panel is up or on its way any more.
        _attached.value = false;
        _displays.value = _parseDisplays(call.arguments as List<Object?>?);
        _resets.fire();
      case 'companionMessage':
        _pipe.receive(
          call.arguments as String,
          (String raw) {
            if (_messages.isClosed) return;
            _messages.add(GameStreamCompanionMessage.decode(raw));
          },
          (Object error, StackTrace stack) => ErrorLogService.instance.log(
            'GameStreamCompanionDisplay.message',
            error,
            stack,
          ),
        );
    }
    return null;
  }

  static List<GameStreamCompanionDisplayInfo> _parseDisplays(
    List<Object?>? raw,
  ) => <GameStreamCompanionDisplayInfo>[
    for (final Object? entry in raw ?? const <Object?>[])
      ?GameStreamCompanionDisplayInfo.fromMap(entry),
  ];

  @override
  Future<void> show(int displayId) => _channel.invokeMethod<void>(
    'show',
    <String, Object?>{'displayId': displayId},
  );

  @override
  Future<void> dismiss() async {
    await _channel.invokeMethod<void>('dismiss');
  }

  @override
  Future<void> send(GameStreamCompanionHostMessage message) =>
      _pipe.send(message.encode());

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_channel.invokeMethod<void>('dismiss'));
    _displays.dispose();
    _attached.dispose();
    _resets.dispose();
    unawaited(_messages.close());
    unawaited(GameStreamCompanionPipe.clearSpills(_spillRoot));
  }
}

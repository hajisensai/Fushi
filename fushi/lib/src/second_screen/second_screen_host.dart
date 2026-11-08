import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// What the panel on the second display is: the companion (module panels,
/// lookups) or the game stream's lookup panel. One panel at a time; the game
/// stream wins while it wants the panel.
enum SecondScreenPanelMode {
  companion,
  gameStream;

  /// The name on the wire (Android intent extra, channel arguments).
  String get wire => name;

  static SecondScreenPanelMode? fromWire(Object? value) {
    for (final SecondScreenPanelMode mode in SecondScreenPanelMode.values) {
      if (mode.wire == value) return mode;
    }
    return null;
  }
}

/// A display other than the one the app runs on that the panel can go on.
@immutable
class SecondScreenDisplayInfo {
  const SecondScreenDisplayInfo({
    required this.id,
    required this.name,
    required this.widthPx,
    required this.heightPx,
    required this.widthDp,
    required this.heightDp,
    required this.densityDpi,
  });

  static SecondScreenDisplayInfo? fromMap(Object? value) {
    if (value is! Map) return null;
    final Object? id = value['id'];
    if (id is! int) return null;
    final Object? name = value['name'];
    int intOf(Object? v) => v is int ? v : 0;
    double doubleOf(Object? v) => v is num ? v.toDouble() : 0;
    return SecondScreenDisplayInfo(
      id: id,
      name: name is String ? name : '',
      widthPx: intOf(value['widthPx']),
      heightPx: intOf(value['heightPx']),
      widthDp: doubleOf(value['widthDp']),
      heightDp: doubleOf(value['heightDp']),
      densityDpi: intOf(value['densityDpi']),
    );
  }

  final int id;
  final String name;

  /// Physical pixels.
  final int widthPx;
  final int heightPx;

  /// Logical pixels at the display's own density.
  final double widthDp;
  final double heightDp;
  final int densityDpi;

  /// Stable-enough identity for "the user approved this screen": a built-in
  /// second screen keeps its name and size across boots, a TV does not match.
  String get fingerprint => '$name|${widthDp.round()}x${heightDp.round()}';

  @override
  bool operator ==(Object other) =>
      other is SecondScreenDisplayInfo &&
      other.id == id &&
      other.name == name &&
      other.widthPx == widthPx &&
      other.heightPx == heightPx &&
      other.widthDp == widthDp &&
      other.heightDp == heightDp &&
      other.densityDpi == densityDpi;

  @override
  int get hashCode =>
      Object.hash(id, name, widthPx, heightPx, widthDp, heightDp, densityDpi);
}

/// The panel that is up: its mode and display.
@immutable
class SecondScreenPanelPlacement {
  const SecondScreenPanelPlacement({
    required this.mode,
    required this.displayId,
  });

  static SecondScreenPanelPlacement? fromMap(Object? value) {
    if (value is! Map) return null;
    final SecondScreenPanelMode? mode = SecondScreenPanelMode.fromWire(
      value['mode'],
    );
    final Object? displayId = value['displayId'];
    if (mode == null || displayId is! int) return null;
    return SecondScreenPanelPlacement(mode: mode, displayId: displayId);
  }

  final SecondScreenPanelMode mode;
  final int displayId;

  @override
  bool operator ==(Object other) =>
      other is SecondScreenPanelPlacement &&
      other.mode == mode &&
      other.displayId == displayId;

  @override
  int get hashCode => Object.hash(mode, displayId);

  @override
  String toString() => 'SecondScreenPanelPlacement($mode, $displayId)';
}

/// One raw message from the panel, tagged with the mode of the panel that
/// was up when it arrived.
@immutable
class SecondScreenPanelMessage {
  const SecondScreenPanelMessage({required this.mode, required this.raw});

  final SecondScreenPanelMode mode;
  final String raw;
}

/// [SecondScreenHost.resets] as a plain event: listeners run on every [fire],
/// with no value to compare.
class SecondScreenResets extends ChangeNotifier {
  /// Tells the listeners the platform side was replaced.
  void fire() => notifyListeners();
}

/// What the platform side reports (decoded channel calls).
sealed class SecondScreenPlatformEvent {
  const SecondScreenPlatformEvent();
}

class SecondScreenDisplaysChanged extends SecondScreenPlatformEvent {
  const SecondScreenDisplaysChanged(this.displays);
  final List<SecondScreenDisplayInfo> displays;
}

class SecondScreenPanelAttached extends SecondScreenPlatformEvent {
  const SecondScreenPanelAttached(this.placement);

  /// Null: the panel went away.
  final SecondScreenPanelPlacement? placement;
}

class SecondScreenPanelMessageReceived extends SecondScreenPlatformEvent {
  const SecondScreenPanelMessageReceived(this.raw);
  final String raw;
}

class SecondScreenHostReset extends SecondScreenPlatformEvent {
  const SecondScreenHostReset(this.displays);
  final List<SecondScreenDisplayInfo> displays;
}

/// The native host, one call per channel method. Tests pass a fake.
abstract interface class SecondScreenPlatform {
  /// Installs (or with null removes) the receiver of platform events.
  void setEventHandler(void Function(SecondScreenPlatformEvent event)? onEvent);

  /// Displays the panel can go on; also starts watching them.
  Future<List<SecondScreenDisplayInfo>> listDisplays();

  /// Wants the panel in [mode] on [displayId]. False when it could not be
  /// launched.
  Future<bool> show(int displayId, SecondScreenPanelMode mode);

  /// Wants no panel.
  Future<void> dismiss();

  /// Hands [raw] to the panel that is up; false when none is.
  Future<bool> send(String raw);
}

/// Android: `SecondScreenDisplay.java` on [FushiChannels.secondScreen].
class MethodChannelSecondScreenPlatform implements SecondScreenPlatform {
  MethodChannelSecondScreenPlatform({
    MethodChannel channel = FushiChannels.secondScreen,
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setEventHandler(
    void Function(SecondScreenPlatformEvent event)? onEvent,
  ) {
    if (onEvent == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((MethodCall call) async {
      final SecondScreenPlatformEvent? event = decode(call);
      if (event != null) onEvent(event);
      return null;
    });
  }

  /// The event a platform call stands for; null for an unknown method.
  static SecondScreenPlatformEvent? decode(MethodCall call) =>
      switch (call.method) {
        'displaysChanged' => SecondScreenDisplaysChanged(
          parseDisplays(call.arguments),
        ),
        'panelAttached' => SecondScreenPanelAttached(
          SecondScreenPanelPlacement.fromMap(call.arguments),
        ),
        'panelMessage' => SecondScreenPanelMessageReceived(
          call.arguments as String,
        ),
        'hostReset' => SecondScreenHostReset(parseDisplays(call.arguments)),
        _ => null,
      };

  static List<SecondScreenDisplayInfo> parseDisplays(
    Object? raw,
  ) => <SecondScreenDisplayInfo>[
    if (raw is List)
      for (final Object? entry in raw) ?SecondScreenDisplayInfo.fromMap(entry),
  ];

  @override
  Future<List<SecondScreenDisplayInfo>> listDisplays() async =>
      parseDisplays(await _channel.invokeMethod<List<Object?>>('listDisplays'));

  @override
  Future<bool> show(int displayId, SecondScreenPanelMode mode) async =>
      await _channel.invokeMethod<bool>('show', <String, Object?>{
        'displayId': displayId,
        'mode': mode.wire,
      }) ??
      false;

  @override
  Future<void> dismiss() => _channel.invokeMethod<void>('dismiss');

  @override
  Future<bool> send(String raw) async =>
      await _channel.invokeMethod<bool>('send', raw) ?? false;
}

/// The main engine's single handle on the second-screen host: which displays
/// exist, which panel is up, and the message pipe to it.
///
/// Clients (the companion controller, the game stream page) each [request] a
/// display for their own mode; the host puts up the one that wins (the game
/// stream over the companion) and falls back to the other when the winner
/// lets go. Only Android has a platform side ([forCurrentPlatform] is null
/// elsewhere, so single-screen platforms run today's code path).
class SecondScreenHost {
  SecondScreenHost(this._platform);

  static SecondScreenHost? _shared;

  /// The app-wide host on Android, null where a second display is not
  /// supported.
  static SecondScreenHost? forCurrentPlatform() {
    if (kIsWeb || !Platform.isAndroid) return null;
    return _shared ??= SecondScreenHost(MethodChannelSecondScreenPlatform());
  }

  final SecondScreenPlatform _platform;

  final ValueNotifier<List<SecondScreenDisplayInfo>> _displays =
      ValueNotifier<List<SecondScreenDisplayInfo>>(
        const <SecondScreenDisplayInfo>[],
      );
  final ValueNotifier<SecondScreenPanelPlacement?> _panel =
      ValueNotifier<SecondScreenPanelPlacement?>(null);
  final StreamController<SecondScreenPanelMessage> _messages =
      StreamController<SecondScreenPanelMessage>.broadcast();
  final SecondScreenResets _resets = SecondScreenResets();

  /// Each client's wanted display; absent / null = it wants no panel.
  final Map<SecondScreenPanelMode, int> _wishes =
      <SecondScreenPanelMode, int>{};

  /// What the platform side was last asked for (null: nothing); only trusted
  /// while [_issuedKnown]. Unknown after the panel went away (the platform
  /// side may still want it back, e.g. while the app is in the background, or
  /// want nothing after a crash) or the platform side was replaced: the next
  /// request then always reaches it.
  SecondScreenPanelPlacement? _issued;
  bool _issuedKnown = true;
  Future<void>? _starting;

  /// Displays the panel could go on (never the app's own display).
  ValueListenable<List<SecondScreenDisplayInfo>> get displays => _displays;

  /// The panel that is up and can receive messages; null when none is.
  ValueListenable<SecondScreenPanelPlacement?> get panel => _panel;

  /// Messages from the panel.
  Stream<SecondScreenPanelMessage> get messages => _messages.stream;

  /// Fires when whatever was placed is gone without an attached edge (the
  /// Android Activity was recreated while the engine kept running, or the
  /// wanted panel could not come back when the app returned to the
  /// foreground): clients place again.
  Listenable get resets => _resets;

  /// The mode that wins among the current wishes, with its display.
  SecondScreenPanelPlacement? get wanted {
    for (final SecondScreenPanelMode mode in _priority) {
      final int? display = _wishes[mode];
      if (display != null) {
        return SecondScreenPanelPlacement(mode: mode, displayId: display);
      }
    }
    return null;
  }

  static const List<SecondScreenPanelMode> _priority = <SecondScreenPanelMode>[
    SecondScreenPanelMode.gameStream,
    SecondScreenPanelMode.companion,
  ];

  /// Starts listening and watching displays. Safe to call from every client;
  /// they share one start.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _platform.setEventHandler(_onEvent);
    try {
      _displays.value = await _platform.listDisplays();
    } catch (_) {
      // Let the next client try again (e.g. the Activity was being recreated).
      _starting = null;
      rethrow;
    }
  }

  /// [mode] wants the panel on [displayId], or (null) wants none. Throws when
  /// the call did not reach the platform side; nothing was placed then.
  Future<void> request(SecondScreenPanelMode mode, int? displayId) async {
    if (displayId == null) {
      _wishes.remove(mode);
    } else {
      _wishes[mode] = displayId;
    }
    await _sync();
  }

  Future<void> _sync() async {
    final SecondScreenPanelPlacement? target = wanted;
    if (_issuedKnown && target == _issued) return;
    _issued = target;
    _issuedKnown = true;
    try {
      if (target == null) {
        await _platform.dismiss();
        return;
      }
      final bool launched = await _platform.show(target.displayId, target.mode);
      // Not launched: nothing is wanted on the platform side, so the next
      // request for the same placement must ask again.
      if (!launched && _issued == target) _issuedKnown = false;
    } catch (_) {
      if (_issued == target) _issuedKnown = false;
      rethrow;
    }
  }

  /// Hands [raw] to the panel when the one that is up is [mode]'s. False when
  /// it is not, or the platform side did not take it.
  Future<bool> post(SecondScreenPanelMode mode, String raw) async {
    if (_panel.value?.mode != mode) return false;
    return _platform.send(raw);
  }

  void _onEvent(SecondScreenPlatformEvent event) {
    switch (event) {
      case SecondScreenDisplaysChanged(
        :final List<SecondScreenDisplayInfo> displays,
      ):
        _displays.value = displays;
      case SecondScreenPanelAttached(
        :final SecondScreenPanelPlacement? placement,
      ):
        // Up: this is what the platform side has. Gone: unknown whether it
        // still wants it (see [_issued]), so the next request asks again.
        _issued = placement;
        _issuedKnown = placement != null;
        _panel.value = placement;
      case SecondScreenPanelMessageReceived(:final String raw):
        final SecondScreenPanelMode? mode = _panel.value?.mode;
        // The platform side only relays messages of the registered panel.
        if (mode != null && !_messages.isClosed) {
          _messages.add(SecondScreenPanelMessage(mode: mode, raw: raw));
        }
      case SecondScreenHostReset(:final List<SecondScreenDisplayInfo> displays):
        // A new platform instance: no panel is up or on its way any more.
        _issued = null;
        _issuedKnown = false;
        _panel.value = null;
        _displays.value = displays;
        _resets.fire();
    }
  }

  /// Tests only: the shared host is app-lifetime in the app.
  @visibleForTesting
  void dispose() {
    _platform.setEventHandler(null);
    _displays.dispose();
    _panel.dispose();
    _resets.dispose();
    unawaited(_messages.close());
  }
}

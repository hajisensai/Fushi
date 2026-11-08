/// Client for `org.freedesktop.portal.GlobalShortcuts` (XDG desktop portal),
/// the only way a Wayland client gets app-outside hotkeys.
///
/// Flow (portal spec, interface version 1–2):
///
///  1. host installs only: `org.freedesktop.host.portal.Registry.Register`
///     ties this D-Bus connection to the app id — the GlobalShortcuts frontend
///     refuses `CreateSession` without one ("An app id is required"). Inside a
///     Flatpak the id comes from the sandbox; Register would fail there.
///  2. `CreateSession` → Request → `Response(session_handle)`.
///  3. `BindShortcuts(session, [(id, {description, preferred_trigger})])` →
///     Request → `Response(shortcuts: [(id, {description,
///     trigger_description})])`. The desktop may show a dialog first; the user
///     dismissing it is response code 1.
///  4. `Activated` / `Deactivated(session, id, timestamp, {activation_token})`
///     and `ShortcutsChanged(session, shortcuts)` signals.
///  5. `Session.Close` on exit; the desktop may end it first (`Closed`).
///
/// Inside a Flatpak this needs no extra `finish-args`: every sandbox may talk
/// to `org.freedesktop.portal.Desktop`.
///
/// Pure Dart: tests drive it against an in-process D-Bus server with a fake
/// portal object.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dbus/dbus.dart';

const String kPortalBusName = 'org.freedesktop.portal.Desktop';
const String kPortalObjectPath = '/org/freedesktop/portal/desktop';
const String kGlobalShortcutsInterface =
    'org.freedesktop.portal.GlobalShortcuts';
const String kPortalRequestInterface = 'org.freedesktop.portal.Request';
const String kPortalSessionInterface = 'org.freedesktop.portal.Session';
const String kHostRegistryInterface = 'org.freedesktop.host.portal.Registry';

/// One shortcut the app asks the desktop to bind.
class PortalShortcut {
  const PortalShortcut({
    required this.id,
    required this.description,
    this.preferredTrigger,
  });

  final String id;
  final String description;

  /// XDG shortcuts spec trigger (`CTRL+ALT+d`); only a hint.
  final String? preferredTrigger;
}

/// One shortcut as the desktop reports it back.
class PortalBoundShortcut {
  const PortalBoundShortcut({
    required this.id,
    required this.description,
    required this.triggerDescription,
  });

  final String id;
  final String description;

  /// Human-readable trigger (`Ctrl+Alt+D`); empty = no key assigned.
  final String triggerDescription;
}

/// An `Activated` signal.
class PortalActivation {
  const PortalActivation({
    required this.sessionHandle,
    required this.shortcutId,
    required this.timestamp,
    this.activationToken,
  });

  final String sessionHandle;
  final String shortcutId;
  final int timestamp;
  final String? activationToken;
}

/// A `ShortcutsChanged` signal.
class PortalShortcutsChanged {
  const PortalShortcutsChanged({
    required this.sessionHandle,
    required this.shortcuts,
  });

  final String sessionHandle;
  final List<PortalBoundShortcut> shortcuts;
}

/// How a portal call failed.
enum PortalFailure {
  /// Request response 1: the user dismissed the desktop's dialog.
  cancelled,

  /// Request response 2, or a D-Bus error from the call itself.
  failed,

  /// `org.freedesktop.portal.Error.NotAllowed` — for GlobalShortcuts this is
  /// "An app id is required".
  notAllowed,
}

class GlobalShortcutsPortalException implements Exception {
  const GlobalShortcutsPortalException(this.failure, this.message);

  final PortalFailure failure;
  final String message;

  @override
  String toString() =>
      'GlobalShortcutsPortalException(${failure.name}): $message';
}

/// The portal operations the hotkey backend needs.
abstract interface class GlobalShortcutsPortal {
  /// Connects and returns the GlobalShortcuts interface version, or null when
  /// this desktop has no GlobalShortcuts portal (no session bus, no
  /// xdg-desktop-portal, or no backend implementing the interface).
  /// [appId] is registered for host installs first (see library doc).
  Future<int?> open({required String appId});

  /// Returns the session handle.
  Future<String> createSession();

  Future<List<PortalBoundShortcut>> bindShortcuts(
    String sessionHandle,
    List<PortalShortcut> shortcuts,
  );

  Future<List<PortalBoundShortcut>> listShortcuts(String sessionHandle);

  /// Interface version 2 only.
  Future<void> configureShortcuts(
    String sessionHandle, {
    String? activationToken,
  });

  Future<void> closeSession(String sessionHandle);

  Stream<PortalActivation> get activated;

  Stream<PortalShortcutsChanged> get shortcutsChanged;

  /// Session handles the desktop closed.
  Stream<String> get sessionClosed;

  Future<void> close();
}

/// **Pure**: decode `a(sa{sv})`.
List<PortalBoundShortcut> decodePortalShortcuts(DBusValue value) {
  final List<PortalBoundShortcut> out = <PortalBoundShortcut>[];
  for (final DBusValue entry in value.asArray()) {
    final List<DBusValue> pair = entry.asStruct();
    final Map<String, DBusValue> props = pair[1].asStringVariantDict();
    out.add(
      PortalBoundShortcut(
        id: pair[0].asString(),
        description: _stringOf(props['description']),
        triggerDescription: _stringOf(props['trigger_description']),
      ),
    );
  }
  return out;
}

/// **Pure**: encode the `a(sa{sv})` argument of `BindShortcuts`.
DBusArray encodePortalShortcuts(List<PortalShortcut> shortcuts) =>
    DBusArray(DBusSignature('(sa{sv})'), <DBusValue>[
      for (final PortalShortcut s in shortcuts)
        DBusStruct(<DBusValue>[
          DBusString(s.id),
          DBusDict.stringVariant(<String, DBusValue>{
            'description': DBusString(s.description),
            if (s.preferredTrigger != null && s.preferredTrigger!.isNotEmpty)
              'preferred_trigger': DBusString(s.preferredTrigger!),
          }),
        ]),
    ]);

/// **Pure**: the object path a portal Request for [token] lives at, given this
/// connection's unique bus name (`:1.42` → `1_42`).
String portalRequestPath(String uniqueName, String token) {
  final String sender = uniqueName.replaceFirst(':', '').replaceAll('.', '_');
  return '$kPortalObjectPath/request/$sender/$token';
}

String _stringOf(DBusValue? value) => value is DBusString ? value.value : '';

/// [GlobalShortcutsPortal] over the session bus.
class DBusGlobalShortcutsPortal implements GlobalShortcutsPortal {
  /// [connect] makes the dedicated connection (default: the session bus).
  /// It must be a fresh connection: the host Registry only accepts a
  /// registration before any other portal call on that connection.
  /// [sandboxed] defaults to "this process runs inside a Flatpak".
  DBusGlobalShortcutsPortal({
    DBusClient Function()? connect,
    bool? sandboxed,
    void Function(String message)? log,
  }) : _connect = connect ?? DBusClient.session,
       _sandboxed = sandboxed ?? File('/.flatpak-info').existsSync(),
       _log = log ?? ((String _) {});

  final DBusClient Function() _connect;
  final bool _sandboxed;
  final void Function(String message) _log;

  DBusClient? _client;
  DBusRemoteObject? _portal;
  String? _portalOwner;
  final List<StreamSubscription<DBusSignal>> _subscriptions =
      <StreamSubscription<DBusSignal>>[];
  final Map<String, StreamSubscription<DBusSignal>> _sessionClosedSubs =
      <String, StreamSubscription<DBusSignal>>{};
  final StreamController<PortalActivation> _activated =
      StreamController<PortalActivation>.broadcast();
  final StreamController<PortalShortcutsChanged> _changed =
      StreamController<PortalShortcutsChanged>.broadcast();
  final StreamController<String> _closed = StreamController<String>.broadcast();
  final String _tokenPrefix =
      'fushi${math.Random().nextInt(1 << 30).toRadixString(36)}';
  int _tokenSerial = 0;

  @override
  Stream<PortalActivation> get activated => _activated.stream;

  @override
  Stream<PortalShortcutsChanged> get shortcutsChanged => _changed.stream;

  @override
  Stream<String> get sessionClosed => _closed.stream;

  DBusClient get _bus {
    final DBusClient? client = _client;
    if (client == null) {
      throw StateError('GlobalShortcuts portal used before open()');
    }
    return client;
  }

  @override
  Future<int?> open({required String appId}) async {
    final DBusClient client = _connect();
    _client = client;
    final DBusRemoteObject portal = DBusRemoteObject(
      client,
      name: kPortalBusName,
      path: DBusObjectPath(kPortalObjectPath),
    );
    _portal = portal;
    try {
      if (!_sandboxed) await _registerHostApp(portal, appId);
      final DBusValue version = await portal.getProperty(
        kGlobalShortcutsInterface,
        'version',
        signature: DBusSignature('u'),
      );
      _portalOwner = await client.getNameOwner(kPortalBusName);
      _listenToPortalSignals(client);
      return version.asUint32();
    } on DBusMethodResponseException catch (e) {
      // No portal service, or a portal without a GlobalShortcuts backend
      // (frontend only exports the interface when a backend implements it).
      _log('portal: GlobalShortcuts not available ($e)');
      return null;
    } on SocketException catch (e) {
      _log('portal: no session bus ($e)');
      return null;
    } on DBusClosedException catch (e) {
      _log('portal: session bus closed ($e)');
      return null;
    }
  }

  /// Host installs only. Failure is not fatal: an older portal has no
  /// Registry (then the app id comes from the systemd scope a desktop launcher
  /// started us in), and a registration the portal rejects (no matching
  /// `.desktop` file) shows up as the `notAllowed` failure of CreateSession,
  /// which the settings page explains.
  Future<void> _registerHostApp(DBusRemoteObject portal, String appId) async {
    try {
      await portal.callMethod(kHostRegistryInterface, 'Register', <DBusValue>[
        DBusString(appId),
        DBusDict.stringVariant(const {}),
      ], replySignature: DBusSignature(''));
      _log('portal: registered host app id $appId');
    } on DBusMethodResponseException catch (e) {
      _log('portal: host app id registration skipped ($e)');
    }
  }

  void _listenToPortalSignals(DBusClient client) {
    final DBusObjectPath path = DBusObjectPath(kPortalObjectPath);
    _subscriptions.add(
      DBusSignalStream(
        client,
        interface: kGlobalShortcutsInterface,
        name: 'Activated',
        path: path,
        signature: DBusSignature('osta{sv}'),
      ).listen((DBusSignal signal) {
        if (!_fromPortal(signal)) return;
        final Map<String, DBusValue> options = signal.values[3]
            .asStringVariantDict();
        final DBusValue? token = options['activation_token'];
        _activated.add(
          PortalActivation(
            sessionHandle: signal.values[0].asObjectPath().value,
            shortcutId: signal.values[1].asString(),
            timestamp: signal.values[2].asUint64(),
            activationToken: token is DBusString && token.value.isNotEmpty
                ? token.value
                : null,
          ),
        );
      }, onError: (Object e) => _log('portal: bad Activated signal ($e)')),
    );
    _subscriptions.add(
      DBusSignalStream(
        client,
        interface: kGlobalShortcutsInterface,
        name: 'ShortcutsChanged',
        path: path,
        signature: DBusSignature('oa(sa{sv})'),
      ).listen((DBusSignal signal) {
        if (!_fromPortal(signal)) return;
        _changed.add(
          PortalShortcutsChanged(
            sessionHandle: signal.values[0].asObjectPath().value,
            shortcuts: decodePortalShortcuts(signal.values[1]),
          ),
        );
      }, onError: (Object e) => _log('portal: bad ShortcutsChanged ($e)')),
    );
  }

  /// Signals are matched by path + interface only; any peer on the session bus
  /// could emit one with the same shape, so only the portal's own are taken.
  bool _fromPortal(DBusSignal signal) {
    final String? owner = _portalOwner;
    return owner == null || signal.sender == owner;
  }

  String _nextToken() => '${_tokenPrefix}_${++_tokenSerial}';

  /// One Request round trip: subscribe to `Response` on the request path the
  /// portal will use, make the call, wait for the response.
  Future<Map<String, DBusValue>> _request(
    String method,
    List<DBusValue> Function(String token) arguments,
  ) async {
    final DBusClient client = _bus;
    final String token = _nextToken();
    final String expected = portalRequestPath(client.uniqueName, token);
    final Completer<DBusSignal> response = Completer<DBusSignal>();
    StreamSubscription<DBusSignal> watch(String path) =>
        DBusSignalStream(
          client,
          interface: kPortalRequestInterface,
          name: 'Response',
          path: DBusObjectPath(path),
          signature: DBusSignature('ua{sv}'),
        ).listen((DBusSignal signal) {
          if (_fromPortal(signal) && !response.isCompleted) {
            response.complete(signal);
          }
        }, onError: (Object e) => _log('portal: bad $method Response ($e)'));
    final List<StreamSubscription<DBusSignal>> watches =
        <StreamSubscription<DBusSignal>>[watch(expected)];
    try {
      // The match rule is added asynchronously when the stream is listened
      // to. A ping to the bus is answered only after every earlier message on
      // this connection was processed, so the rule is in place before the
      // portal can answer the call below.
      await client.ping();
      final DBusMethodSuccessResponse reply;
      try {
        reply = await _portal!.callMethod(
          kGlobalShortcutsInterface,
          method,
          arguments(token),
          replySignature: DBusSignature('o'),
        );
      } on DBusMethodResponseException catch (e) {
        throw GlobalShortcutsPortalException(
          e.errorName == 'org.freedesktop.portal.Error.NotAllowed'
              ? PortalFailure.notAllowed
              : PortalFailure.failed,
          e.toString(),
        );
      }
      final String handle = reply.returnValues.first.asObjectPath().value;
      if (handle != expected) {
        // Portals before 0.9 did not derive the path from handle_token.
        _log('portal: $method request at unexpected path $handle');
        watches.add(watch(handle));
      }
      final DBusSignal signal = await response.future;
      final int code = signal.values[0].asUint32();
      final Map<String, DBusValue> results = signal.values[1]
          .asStringVariantDict();
      if (code == 0) return results;
      throw GlobalShortcutsPortalException(
        code == 1 ? PortalFailure.cancelled : PortalFailure.failed,
        '$method response $code',
      );
    } finally {
      for (final StreamSubscription<DBusSignal> s in watches) {
        unawaited(s.cancel());
      }
    }
  }

  @override
  Future<String> createSession() async {
    final Map<String, DBusValue> results = await _request(
      'CreateSession',
      (String token) => <DBusValue>[
        DBusDict.stringVariant(<String, DBusValue>{
          'handle_token': DBusString(token),
          'session_handle_token': DBusString('${token}_s'),
        }),
      ],
    );
    final DBusValue? handle = results['session_handle'];
    // Spec: type `s` for backwards compatibility; some backends send `o`.
    final String session = handle is DBusString ? handle.value : '';
    if (session.isEmpty) {
      throw const GlobalShortcutsPortalException(
        PortalFailure.failed,
        'CreateSession returned no session_handle',
      );
    }
    _sessionClosedSubs[session] =
        DBusSignalStream(
          _bus,
          interface: kPortalSessionInterface,
          name: 'Closed',
          path: DBusObjectPath(session),
        ).listen((DBusSignal signal) {
          if (!_fromPortal(signal)) return;
          unawaited(_sessionClosedSubs.remove(session)?.cancel());
          _closed.add(session);
        });
    return session;
  }

  @override
  Future<List<PortalBoundShortcut>> bindShortcuts(
    String sessionHandle,
    List<PortalShortcut> shortcuts,
  ) async {
    final Map<String, DBusValue> results = await _request(
      'BindShortcuts',
      (String token) => <DBusValue>[
        DBusObjectPath(sessionHandle),
        encodePortalShortcuts(shortcuts),
        // No parent window handle: the main window may be an XWayland window
        // or not focused at all when the desktop shows its dialog.
        const DBusString(''),
        DBusDict.stringVariant(<String, DBusValue>{
          'handle_token': DBusString(token),
        }),
      ],
    );
    final DBusValue? list = results['shortcuts'];
    return list == null
        ? const <PortalBoundShortcut>[]
        : decodePortalShortcuts(list);
  }

  @override
  Future<List<PortalBoundShortcut>> listShortcuts(String sessionHandle) async {
    final Map<String, DBusValue> results = await _request(
      'ListShortcuts',
      (String token) => <DBusValue>[
        DBusObjectPath(sessionHandle),
        DBusDict.stringVariant(<String, DBusValue>{
          'handle_token': DBusString(token),
        }),
      ],
    );
    final DBusValue? list = results['shortcuts'];
    return list == null
        ? const <PortalBoundShortcut>[]
        : decodePortalShortcuts(list);
  }

  @override
  Future<void> configureShortcuts(
    String sessionHandle, {
    String? activationToken,
  }) async {
    try {
      await _portal!.callMethod(
        kGlobalShortcutsInterface,
        'ConfigureShortcuts',
        <DBusValue>[
          DBusObjectPath(sessionHandle),
          const DBusString(''),
          DBusDict.stringVariant(<String, DBusValue>{
            if (activationToken != null)
              'activation_token': DBusString(activationToken),
          }),
        ],
        replySignature: DBusSignature(''),
      );
    } on DBusMethodResponseException catch (e) {
      throw GlobalShortcutsPortalException(PortalFailure.failed, e.toString());
    }
  }

  @override
  Future<void> closeSession(String sessionHandle) async {
    unawaited(_sessionClosedSubs.remove(sessionHandle)?.cancel());
    try {
      await DBusRemoteObject(
        _bus,
        name: kPortalBusName,
        path: DBusObjectPath(sessionHandle),
      ).callMethod(
        kPortalSessionInterface,
        'Close',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
    } on DBusMethodResponseException catch (e) {
      // Already closed by the desktop: nothing left to release.
      _log('portal: session close ignored ($e)');
    }
  }

  @override
  Future<void> close() async {
    for (final StreamSubscription<DBusSignal> s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    for (final StreamSubscription<DBusSignal> s in _sessionClosedSubs.values) {
      await s.cancel();
    }
    _sessionClosedSubs.clear();
    await _client?.close();
    _client = null;
    _portal = null;
  }
}

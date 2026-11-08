// package:dbus reads socket control messages (RawSocket.readMessage), which
// dart:io implements on POSIX only: on Windows its client and server never get
// past the handshake. The portal itself only exists on Linux anyway.
@TestOn('linux')
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:fushi/src/shortcuts/global_shortcuts_portal.dart';
import 'package:test/test.dart';

/// The GlobalShortcuts portal client over real D-Bus wire traffic: an
/// in-process bus (package:dbus's DBusServer on loopback TCP) with a fake
/// `org.freedesktop.portal.Desktop` that speaks the Request/Response
/// protocol the way xdg-desktop-portal does.
void main() {
  late DBusServer server;
  late DBusAddress address;
  late DBusClient portalSide;
  late _FakeDesktopPortal fake;
  late DBusGlobalShortcutsPortal portal;
  bool started = false;

  Future<void> startPortal({
    bool sandboxed = false,
    bool exportPortal = true,
    bool hasGlobalShortcuts = true,
  }) async {
    started = true;
    server = DBusServer();
    address = await server.listenAddress(
      DBusAddress.tcp('localhost', family: DBusAddressTcpFamily.ipv4),
    );
    portalSide = DBusClient(address);
    fake = _FakeDesktopPortal(hasGlobalShortcuts: hasGlobalShortcuts);
    if (exportPortal) {
      await portalSide.requestName(kPortalBusName);
      await portalSide.registerObject(fake);
    }
    portal = DBusGlobalShortcutsPortal(
      connect: () => DBusClient(address),
      sandboxed: sandboxed,
    );
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    await portal.close();
    await portalSide.close();
    await server.close();
  });

  test('request path follows the spec (sender without ":" and "." → "_")', () {
    expect(
      portalRequestPath(':1.42', 'fushi_1'),
      '/org/freedesktop/portal/desktop/request/1_42/fushi_1',
    );
  });

  test('host install: Register(app id) first, then the version', () async {
    await startPortal();
    expect(await portal.open(appId: 'app.fushi.reader'), 2);
    expect(fake.calls.first, 'Register(app.fushi.reader)');
  });

  test('Flatpak: no Register (the sandbox already carries the id)', () async {
    await startPortal(sandboxed: true);
    expect(await portal.open(appId: 'app.fushi.reader'), 2);
    expect(fake.calls.where((String c) => c.startsWith('Register')), isEmpty);
  });

  test('no portal service → null (fall back, do not throw)', () async {
    await startPortal(exportPortal: false);
    expect(await portal.open(appId: 'app.fushi.reader'), isNull);
  });

  test('portal without a GlobalShortcuts backend → null', () async {
    await startPortal(hasGlobalShortcuts: false);
    expect(await portal.open(appId: 'app.fushi.reader'), isNull);
  });

  test('CreateSession + BindShortcuts round trips, Response before the method '
      'reply included', () async {
    await startPortal();
    await portal.open(appId: 'app.fushi.reader');
    fake.triggers = <String, String>{'lookup': 'Ctrl+Alt+D'};

    final String session = await portal.createSession();
    expect(session, startsWith('/org/freedesktop/portal/desktop/session/'));

    final List<PortalBoundShortcut> bound = await portal
        .bindShortcuts(session, const <PortalShortcut>[
          PortalShortcut(
            id: 'lookup',
            description: 'Look up selection',
            preferredTrigger: 'CTRL+ALT+d',
          ),
          PortalShortcut(id: 'page', description: 'Open lookup page'),
        ]);
    expect(fake.lastBind, <String, Map<String, String>>{
      'lookup': <String, String>{
        'description': 'Look up selection',
        'preferred_trigger': 'CTRL+ALT+d',
      },
      'page': <String, String>{'description': 'Open lookup page'},
    });
    expect(
      bound.map((PortalBoundShortcut b) => '${b.id}=${b.triggerDescription}'),
      <String>['lookup=Ctrl+Alt+D', 'page='],
    );
  });

  test('dismissed dialog (response 1) → cancelled', () async {
    await startPortal();
    await portal.open(appId: 'app.fushi.reader');
    final String session = await portal.createSession();
    fake.bindResponseCode = 1;
    await expectLater(
      portal.bindShortcuts(session, const <PortalShortcut>[
        PortalShortcut(id: 'lookup', description: 'Look up'),
      ]),
      throwsA(
        isA<GlobalShortcutsPortalException>().having(
          (GlobalShortcutsPortalException e) => e.failure,
          'failure',
          PortalFailure.cancelled,
        ),
      ),
    );
  });

  test('"An app id is required" → notAllowed', () async {
    await startPortal();
    await portal.open(appId: 'app.fushi.reader');
    fake.createSessionError = 'org.freedesktop.portal.Error.NotAllowed';
    await expectLater(
      portal.createSession(),
      throwsA(
        isA<GlobalShortcutsPortalException>().having(
          (GlobalShortcutsPortalException e) => e.failure,
          'failure',
          PortalFailure.notAllowed,
        ),
      ),
    );
  });

  test('Activated / ShortcutsChanged / Closed signals; a spoofing peer is '
      'ignored', () async {
    await startPortal();
    await portal.open(appId: 'app.fushi.reader');
    final String session = await portal.createSession();
    final List<PortalActivation> activations = <PortalActivation>[];
    final List<PortalShortcutsChanged> changes = <PortalShortcutsChanged>[];
    final List<String> closed = <String>[];
    final List<StreamSubscription<Object>> subs = <StreamSubscription<Object>>[
      portal.activated.listen(activations.add),
      portal.shortcutsChanged.listen(changes.add),
      portal.sessionClosed.listen(closed.add),
    ];
    addTearDown(() async {
      for (final StreamSubscription<Object> s in subs) {
        await s.cancel();
      }
    });

    final DBusClient spoofer = DBusClient(address);
    addTearDown(spoofer.close);
    await _emitActivated(spoofer, session, 'lookup', token: 'evil');
    await _emitActivated(portalSide, session, 'lookup', token: 'tok-1');
    await portalSide.emitSignal(
      path: DBusObjectPath(kPortalObjectPath),
      interface: kGlobalShortcutsInterface,
      name: 'ShortcutsChanged',
      values: <DBusValue>[
        DBusObjectPath(session),
        encodeBound(<String, String>{'lookup': 'Meta+L'}),
      ],
    );
    await portalSide.emitSignal(
      path: DBusObjectPath(session),
      interface: kPortalSessionInterface,
      name: 'Closed',
      values: <DBusValue>[DBusDict.stringVariant(const <String, DBusValue>{})],
    );
    await _settle(portalSide);

    expect(activations, hasLength(1));
    expect(activations.single.sessionHandle, session);
    expect(activations.single.shortcutId, 'lookup');
    expect(activations.single.activationToken, 'tok-1');
    expect(changes.single.shortcuts.single.triggerDescription, 'Meta+L');
    expect(closed, <String>[session]);
  });

  test('closeSession calls Session.Close; ConfigureShortcuts passes the '
      'activation token', () async {
    await startPortal();
    await portal.open(appId: 'app.fushi.reader');
    final String session = await portal.createSession();
    await portal.configureShortcuts(session, activationToken: 'tok');
    await portal.closeSession(session);
    expect(fake.calls, contains('ConfigureShortcuts(tok)'));
    expect(fake.calls, contains('Close($session)'));
  });
}

/// Lets queued signals reach the client under test: a ping round trip through
/// the bus is answered after everything sent before it was routed.
Future<void> _settle(DBusClient client) async {
  await client.ping();
  await pumpEventQueue();
}

Future<void> _emitActivated(
  DBusClient from,
  String session,
  String id, {
  String? token,
}) => from.emitSignal(
  path: DBusObjectPath(kPortalObjectPath),
  interface: kGlobalShortcutsInterface,
  name: 'Activated',
  values: <DBusValue>[
    DBusObjectPath(session),
    DBusString(id),
    const DBusUint64(42),
    DBusDict.stringVariant(<String, DBusValue>{
      if (token != null) 'activation_token': DBusString(token),
    }),
  ],
);

DBusArray encodeBound(Map<String, String> triggers) =>
    DBusArray(DBusSignature('(sa{sv})'), <DBusValue>[
      for (final MapEntry<String, String> e in triggers.entries)
        DBusStruct(<DBusValue>[
          DBusString(e.key),
          DBusDict.stringVariant(<String, DBusValue>{
            'description': DBusString(e.key),
            'trigger_description': DBusString(e.value),
          }),
        ]),
    ]);

class _FakeDesktopPortal extends DBusObject {
  _FakeDesktopPortal({required this.hasGlobalShortcuts})
    : super(DBusObjectPath(kPortalObjectPath));

  final bool hasGlobalShortcuts;
  final List<String> calls = <String>[];
  Map<String, String> triggers = <String, String>{};
  Map<String, Map<String, String>>? lastBind;
  int bindResponseCode = 0;
  String? createSessionError;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (hasGlobalShortcuts &&
        interface == kGlobalShortcutsInterface &&
        name == 'version') {
      return DBusGetPropertyResponse(const DBusUint32(2));
    }
    return DBusMethodErrorResponse.unknownInterface();
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    final String sender = call.sender ?? '';
    if (call.interface == kHostRegistryInterface && call.name == 'Register') {
      calls.add('Register(${call.values[0].asString()})');
      return DBusMethodSuccessResponse();
    }
    if (call.interface != kGlobalShortcutsInterface || !hasGlobalShortcuts) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'CreateSession':
        final Map<String, DBusValue> options = call.values[0]
            .asStringVariantDict();
        final String token = options['handle_token']!.asString();
        final String sessionToken = options['session_handle_token']!.asString();
        calls.add('CreateSession');
        final String? error = createSessionError;
        if (error != null) {
          return DBusMethodErrorResponse(error, <DBusValue>[
            const DBusString('An app id is required'),
          ]);
        }
        final String requestPath = portalRequestPath(sender, token);
        final String sessionPath =
            '$kPortalObjectPath/session/${sender.replaceFirst(':', '').replaceAll('.', '_')}/$sessionToken';
        await client!.registerObject(_FakeSession(sessionPath, calls));
        // Emitted BEFORE the method reply: the client must already listen.
        await _respond(requestPath, 0, <String, DBusValue>{
          'session_handle': DBusString(sessionPath),
        });
        return DBusMethodSuccessResponse(<DBusValue>[
          DBusObjectPath(requestPath),
        ]);
      case 'BindShortcuts':
        final Map<String, DBusValue> options = call.values[3]
            .asStringVariantDict();
        final String requestPath = portalRequestPath(
          sender,
          options['handle_token']!.asString(),
        );
        lastBind = <String, Map<String, String>>{
          for (final DBusValue entry in call.values[1].asArray())
            entry.asStruct()[0].asString(): <String, String>{
              for (final MapEntry<String, DBusValue> p
                  in entry.asStruct()[1].asStringVariantDict().entries)
                p.key: p.value.asString(),
            },
        };
        calls.add('BindShortcuts');
        // After the reply, like a portal waiting for the user's dialog.
        unawaited(
          Future<void>(() async {
            await _respond(
              requestPath,
              bindResponseCode,
              bindResponseCode != 0
                  ? const <String, DBusValue>{}
                  : <String, DBusValue>{
                      'shortcuts': encodeBound(<String, String>{
                        for (final String id in lastBind!.keys)
                          id: triggers[id] ?? '',
                      }),
                    },
            );
          }),
        );
        return DBusMethodSuccessResponse(<DBusValue>[
          DBusObjectPath(requestPath),
        ]);
      case 'ConfigureShortcuts':
        final Map<String, DBusValue> options = call.values[2]
            .asStringVariantDict();
        calls.add(
          'ConfigureShortcuts(${options['activation_token']?.asString()})',
        );
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  Future<void> _respond(
    String requestPath,
    int code,
    Map<String, DBusValue> results,
  ) => client!.emitSignal(
    path: DBusObjectPath(requestPath),
    interface: kPortalRequestInterface,
    name: 'Response',
    values: <DBusValue>[DBusUint32(code), DBusDict.stringVariant(results)],
  );
}

class _FakeSession extends DBusObject {
  _FakeSession(String path, this.calls) : super(DBusObjectPath(path));

  final List<String> calls;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == kPortalSessionInterface && call.name == 'Close') {
      calls.add('Close(${path.value})');
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

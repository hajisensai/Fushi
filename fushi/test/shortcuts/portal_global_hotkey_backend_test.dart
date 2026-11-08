import 'dart:async';

import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/global_shortcuts_portal.dart';
import 'package:fushi/src/shortcuts/portal_global_hotkey_backend.dart';
import 'package:test/test.dart';

/// Linux Wayland app-outside hotkeys: the GlobalShortcuts portal backend's
/// session lifecycle and dispatch, against an in-memory portal.
void main() {
  group('session type / backend choice', () {
    test('XDG_SESSION_TYPE decides; WAYLAND_DISPLAY only without it', () {
      expect(
        linuxDesktopIsWayland(<String, String>{'XDG_SESSION_TYPE': 'wayland'}),
        isTrue,
      );
      expect(
        linuxDesktopIsWayland(<String, String>{
          'XDG_SESSION_TYPE': 'x11',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        isFalse,
      );
      expect(
        linuxDesktopIsWayland(<String, String>{'WAYLAND_DISPLAY': 'wayland-0'}),
        isTrue,
      );
      expect(linuxDesktopIsWayland(<String, String>{'DISPLAY': ':0'}), isFalse);
    });

    test('X11 keeps keybinder (native); Wayland uses the portal', () {
      GlobalHotKeyBackendKind? linux(Map<String, String> env) =>
          globalHotKeyBackendKindFor(
            isWindows: false,
            isMacOS: false,
            isLinux: true,
            environment: env,
          );
      expect(
        linux(<String, String>{'XDG_SESSION_TYPE': 'x11', 'DISPLAY': ':0'}),
        GlobalHotKeyBackendKind.native,
      );
      expect(
        linux(<String, String>{'XDG_SESSION_TYPE': 'wayland'}),
        GlobalHotKeyBackendKind.portal,
      );
      // The Flatpak pins GDK_BACKEND=x11 (draws through XWayland) on a
      // Wayland desktop: an X11 grab would only see keys while an X11 window
      // has focus, so the desktop session decides, not the GTK backend.
      expect(
        linux(<String, String>{
          'XDG_SESSION_TYPE': 'wayland',
          'GDK_BACKEND': 'x11',
          'DISPLAY': ':1',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        GlobalHotKeyBackendKind.portal,
      );
      for (final bool win in <bool>[true, false]) {
        expect(
          globalHotKeyBackendKindFor(
            isWindows: win,
            isMacOS: !win,
            isLinux: false,
            environment: const <String, String>{'XDG_SESSION_TYPE': 'wayland'},
          ),
          GlobalHotKeyBackendKind.native,
        );
      }
      expect(
        globalHotKeyBackendKindFor(
          isWindows: false,
          isMacOS: false,
          isLinux: false,
          environment: const <String, String>{},
        ),
        isNull,
      );
    });

    test('preferred trigger uses the XDG shortcuts format', () {
      expect(
        const GlobalHotKeyChord(
          physicalUsage: 0x00070007,
          keysym: 'd',
          modifiers: <GlobalHotKeyModifier>{
            GlobalHotKeyModifier.alt,
            GlobalHotKeyModifier.ctrl,
          },
          label: 'Ctrl+Alt+D',
        ).portalTrigger,
        'CTRL+ALT+d',
      );
      expect(
        const GlobalHotKeyChord(
          physicalUsage: 0x0007003e,
          keysym: 'F5',
          modifiers: <GlobalHotKeyModifier>{
            GlobalHotKeyModifier.meta,
            GlobalHotKeyModifier.shift,
          },
          label: 'Shift+Meta+F5',
        ).portalTrigger,
        'SHIFT+LOGO+F5',
      );
      expect(
        const GlobalHotKeyChord(
          physicalUsage: 1,
          modifiers: <GlobalHotKeyModifier>{},
          label: '?',
        ).portalTrigger,
        isNull,
      );
    });
  });

  group('PortalGlobalHotKeyBackend', () {
    late _FakePortal portal;
    late List<String> errors;
    late PortalGlobalHotKeyBackend backend;

    setUp(() {
      portal = _FakePortal();
      errors = <String>[];
      backend = PortalGlobalHotKeyBackend(
        portal: portal,
        appId: 'app.fushi.reader',
        onError: (String context, Object error, StackTrace? _) =>
            errors.add('$context: $error'),
      );
    });

    tearDown(() async {
      await backend.dispose();
    });

    test('first apply: open → CreateSession → BindShortcuts; status carries '
        'the triggers the desktop reports', () async {
      portal.triggers = <String, String>{'lookup': 'Ctrl+Alt+D', 'page': ''};
      await backend.apply(<GlobalHotKeyRequest>[
        _request('lookup', 'Look up selection', trigger: 'CTRL+ALT+d'),
        _request('page', 'Open lookup page'),
      ]);

      expect(portal.openedWith, 'app.fushi.reader');
      expect(portal.sessionsCreated, 1);
      expect(portal.binds, hasLength(1));
      final List<PortalShortcut> bound = portal.binds.single;
      expect(bound.map((PortalShortcut s) => s.id), <String>['lookup', 'page']);
      expect(bound.first.description, 'Look up selection');
      expect(bound.first.preferredTrigger, 'CTRL+ALT+d');
      expect(bound.last.preferredTrigger, isNull);

      expect(backend.status.kind, GlobalHotKeyBackendKind.portal);
      expect(backend.status.problem, isNull);
      expect(backend.status.bound, isTrue);
      expect(backend.status.canConfigure, isTrue);
      expect(backend.status.triggers, <String, String>{
        'lookup': 'Ctrl+Alt+D',
        'page': '',
      });
    });

    test('Activated → the action runs with the activation token; foreign '
        'sessions and unknown ids are ignored', () async {
      final List<String?> fired = <String?>[];
      await backend.apply(<GlobalHotKeyRequest>[
        _request('lookup', 'Look up', onActivated: fired.add),
      ]);
      final String session = portal.lastSession!;

      portal.activate(session, 'lookup', token: 'xdg-token-1');
      portal.activate('/other/session', 'lookup');
      portal.activate(session, 'nope');
      await pumpEventQueue();

      expect(fired, <String?>['xdg-token-1']);
    });

    test('same set again re-binds nothing but swaps the handlers', () async {
      final List<String> fired = <String>[];
      await backend.apply(<GlobalHotKeyRequest>[
        _request('lookup', 'Look up', onActivated: (_) => fired.add('old')),
      ]);
      await backend.apply(<GlobalHotKeyRequest>[
        // A different preferred trigger alone is only a hint the desktop
        // would ignore for a shortcut it already knows.
        _request(
          'lookup',
          'Look up',
          trigger: 'CTRL+ALT+x',
          onActivated: (_) => fired.add('new'),
        ),
      ]);
      expect(portal.binds, hasLength(1));

      portal.activate(portal.lastSession!, 'lookup');
      await pumpEventQueue();
      expect(fired, <String>['new']);
    });

    test(
      'a changed set (description / ids) re-binds on the same session',
      () async {
        await backend.apply(<GlobalHotKeyRequest>[
          _request('lookup', 'Look up'),
        ]);
        await backend.apply(<GlobalHotKeyRequest>[
          _request('lookup', '選択を辞書で引く'),
          _request('page', 'Open lookup page'),
        ]);
        expect(portal.sessionsCreated, 1, reason: 'one session per app run');
        expect(portal.binds, hasLength(2));
        expect(portal.binds.last.map((PortalShortcut s) => s.id), <String>[
          'lookup',
          'page',
        ]);
      },
    );

    test('dialog dismissed → dialogCancelled, no automatic re-prompt; '
        'rebind() asks again', () async {
      portal.bindResponse = PortalFailure.cancelled;
      final List<GlobalHotKeyRequest> set = <GlobalHotKeyRequest>[
        _request('lookup', 'Look up'),
      ];
      await backend.apply(set);
      expect(backend.status.problem, GlobalHotKeyProblem.dialogCancelled);
      expect(backend.status.bound, isFalse);
      expect(errors, isEmpty, reason: 'a user choice is not an error');

      await backend.apply(set);
      expect(portal.binds, hasLength(1), reason: 'no dialog loop');

      portal.bindResponse = null;
      portal.triggers = <String, String>{'lookup': 'Ctrl+Alt+D'};
      await backend.rebind();
      expect(portal.binds, hasLength(2));
      expect(backend.status.problem, isNull);
      expect(backend.status.triggers['lookup'], 'Ctrl+Alt+D');
    });

    test(
      'no GlobalShortcuts portal → portalMissing, nothing else is called',
      () async {
        portal.version = null;
        await backend.apply(<GlobalHotKeyRequest>[
          _request('lookup', 'Look up'),
        ]);
        expect(backend.status.problem, GlobalHotKeyProblem.portalMissing);
        expect(portal.sessionsCreated, 0);
        expect(portal.binds, isEmpty);
        // Later rounds do not hammer the bus.
        await backend.apply(<GlobalHotKeyRequest>[_request('lookup', 'x')]);
        expect(portal.openCount, 1);
      },
    );

    test('portal refuses the app id → portalNeedsAppId, logged', () async {
      portal.createSessionFailure = PortalFailure.notAllowed;
      await backend.apply(<GlobalHotKeyRequest>[_request('lookup', 'Look up')]);
      expect(backend.status.problem, GlobalHotKeyProblem.portalNeedsAppId);
      expect(errors, hasLength(1));
    });

    test('portal error → portalFailed with detail, logged', () async {
      portal.bindResponse = PortalFailure.failed;
      await backend.apply(<GlobalHotKeyRequest>[_request('lookup', 'Look up')]);
      expect(backend.status.problem, GlobalHotKeyProblem.portalFailed);
      expect(backend.status.detail, isNotEmpty);
      expect(errors, hasLength(1));
    });

    test('ShortcutsChanged (user rebinds in system settings) updates the '
        'triggers', () async {
      await backend.apply(<GlobalHotKeyRequest>[_request('lookup', 'Look up')]);
      final List<GlobalHotKeyStatus> seen = <GlobalHotKeyStatus>[];
      final StreamSubscription<GlobalHotKeyStatus> sub = backend.statusChanges
          .listen(seen.add);
      addTearDown(sub.cancel);

      portal.changed(portal.lastSession!, <String, String>{'lookup': 'Meta+L'});
      portal.changed('/other/session', <String, String>{'lookup': 'nope'});
      await pumpEventQueue();

      expect(backend.status.triggers, <String, String>{'lookup': 'Meta+L'});
      expect(seen, hasLength(1));
    });

    test('session closed by the desktop → sessionClosed; the next apply '
        'creates a new session', () async {
      final List<GlobalHotKeyRequest> set = <GlobalHotKeyRequest>[
        _request('lookup', 'Look up'),
      ];
      await backend.apply(set);
      portal.closeFromDesktop(portal.lastSession!);
      await pumpEventQueue();
      expect(backend.status.problem, GlobalHotKeyProblem.sessionClosed);

      await backend.apply(set);
      expect(portal.sessionsCreated, 2);
      expect(backend.status.problem, isNull);
    });

    test('configure: version 2 asks the desktop, version 1 cannot', () async {
      await backend.apply(<GlobalHotKeyRequest>[_request('lookup', 'Look up')]);
      expect(await backend.configure(activationToken: 't'), isTrue);
      expect(portal.configured, <String?>['t']);

      final _FakePortal v1 = _FakePortal()..version = 1;
      final PortalGlobalHotKeyBackend old = PortalGlobalHotKeyBackend(
        portal: v1,
        appId: 'app.fushi.reader',
      );
      await old.apply(<GlobalHotKeyRequest>[_request('lookup', 'Look up')]);
      expect(old.status.canConfigure, isFalse);
      expect(await old.configure(), isFalse);
      expect(v1.configured, isEmpty);
      await old.dispose();
    });

    test('dispose closes the session and the connection', () async {
      await backend.apply(<GlobalHotKeyRequest>[_request('lookup', 'Look up')]);
      final String session = portal.lastSession!;
      await backend.dispose();
      expect(portal.closedSessions, <String>[session]);
      expect(portal.closed, isTrue);
    });
  });
}

GlobalHotKeyRequest _request(
  String id,
  String description, {
  String? trigger,
  void Function(String? token)? onActivated,
}) {
  final String? keysym = trigger?.split('+').last;
  return GlobalHotKeyRequest(
    id: id,
    description: description,
    chord: trigger == null
        ? null
        : GlobalHotKeyChord(
            physicalUsage: 0,
            keysym: keysym,
            modifiers: <GlobalHotKeyModifier>{
              if (trigger.contains('CTRL')) GlobalHotKeyModifier.ctrl,
              if (trigger.contains('ALT')) GlobalHotKeyModifier.alt,
            },
            label: trigger,
          ),
    onActivated: (GlobalHotKeyActivation activation) async =>
        onActivated?.call(activation.activationToken),
  );
}

class _FakePortal implements GlobalShortcutsPortal {
  int? version = 2;
  String? openedWith;
  int openCount = 0;
  int sessionsCreated = 0;
  String? lastSession;
  PortalFailure? createSessionFailure;
  PortalFailure? bindResponse;
  Map<String, String> triggers = <String, String>{};
  final List<List<PortalShortcut>> binds = <List<PortalShortcut>>[];
  final List<String?> configured = <String?>[];
  final List<String> closedSessions = <String>[];
  bool closed = false;

  final StreamController<PortalActivation> _activated =
      StreamController<PortalActivation>.broadcast(sync: true);
  final StreamController<PortalShortcutsChanged> _changed =
      StreamController<PortalShortcutsChanged>.broadcast(sync: true);
  final StreamController<String> _closed = StreamController<String>.broadcast(
    sync: true,
  );

  void activate(String session, String id, {String? token}) => _activated.add(
    PortalActivation(
      sessionHandle: session,
      shortcutId: id,
      timestamp: 1,
      activationToken: token,
    ),
  );

  void changed(String session, Map<String, String> next) => _changed.add(
    PortalShortcutsChanged(
      sessionHandle: session,
      shortcuts: <PortalBoundShortcut>[
        for (final MapEntry<String, String> e in next.entries)
          PortalBoundShortcut(
            id: e.key,
            description: e.key,
            triggerDescription: e.value,
          ),
      ],
    ),
  );

  void closeFromDesktop(String session) => _closed.add(session);

  @override
  Stream<PortalActivation> get activated => _activated.stream;

  @override
  Stream<PortalShortcutsChanged> get shortcutsChanged => _changed.stream;

  @override
  Stream<String> get sessionClosed => _closed.stream;

  @override
  Future<int?> open({required String appId}) async {
    openCount++;
    openedWith = appId;
    return version;
  }

  @override
  Future<String> createSession() async {
    final PortalFailure? failure = createSessionFailure;
    if (failure != null) {
      throw GlobalShortcutsPortalException(failure, 'An app id is required');
    }
    sessionsCreated++;
    return lastSession =
        '/org/freedesktop/portal/desktop/session/1_1/s$sessionsCreated';
  }

  @override
  Future<List<PortalBoundShortcut>> bindShortcuts(
    String sessionHandle,
    List<PortalShortcut> shortcuts,
  ) async {
    binds.add(shortcuts);
    final PortalFailure? failure = bindResponse;
    if (failure != null) {
      throw GlobalShortcutsPortalException(failure, 'BindShortcuts response');
    }
    return <PortalBoundShortcut>[
      for (final PortalShortcut s in shortcuts)
        PortalBoundShortcut(
          id: s.id,
          description: s.description,
          triggerDescription: triggers[s.id] ?? '',
        ),
    ];
  }

  @override
  Future<List<PortalBoundShortcut>> listShortcuts(String sessionHandle) async =>
      const <PortalBoundShortcut>[];

  @override
  Future<void> configureShortcuts(
    String sessionHandle, {
    String? activationToken,
  }) async {
    configured.add(activationToken);
  }

  @override
  Future<void> closeSession(String sessionHandle) async {
    closedSessions.add(sessionHandle);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

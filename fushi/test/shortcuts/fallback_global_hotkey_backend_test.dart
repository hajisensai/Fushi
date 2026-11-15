import 'dart:async';

import 'package:fushi/src/shortcuts/fallback_global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:test/test.dart';

/// Linux Wayland desktop without GlobalShortcuts (GNOME < 48, Gamescope) while
/// GTK draws through XWayland (Flatpak / Steam Game Mode launcher): the portal
/// answers `portalMissing`, and the hotkeys must go back to the X11 grab they
/// had before the portal backend existed instead of being reported dead.
void main() {
  GlobalHotKeyRequest request(String id) => GlobalHotKeyRequest(
    id: id,
    description: id,
    onActivated: (GlobalHotKeyActivation _) async {},
  );

  group('portalShouldFallBackToX11Grab', () {
    const GlobalHotKeyStatus missing = GlobalHotKeyStatus(
      kind: GlobalHotKeyBackendKind.portal,
      problem: GlobalHotKeyProblem.portalMissing,
    );

    test('only a missing portal with GTK on X11 falls back', () {
      expect(portalShouldFallBackToX11Grab(missing, gtkDrawsOnX11: true), true);
      // Native Wayland GTK: an X11 grab cannot see any key.
      expect(
        portalShouldFallBackToX11Grab(missing, gtkDrawsOnX11: false),
        false,
      );
      // Problems the user can resolve on the desktop keep the portal.
      for (final GlobalHotKeyProblem problem in <GlobalHotKeyProblem>[
        GlobalHotKeyProblem.portalNeedsAppId,
        GlobalHotKeyProblem.dialogCancelled,
        GlobalHotKeyProblem.portalFailed,
        GlobalHotKeyProblem.sessionClosed,
      ]) {
        expect(
          portalShouldFallBackToX11Grab(
            GlobalHotKeyStatus(
              kind: GlobalHotKeyBackendKind.portal,
              problem: problem,
            ),
            gtkDrawsOnX11: true,
          ),
          false,
          reason: problem.name,
        );
      }
      expect(
        portalShouldFallBackToX11Grab(
          const GlobalHotKeyStatus(kind: GlobalHotKeyBackendKind.portal),
          gtkDrawsOnX11: true,
        ),
        false,
      );
    });
  });

  group('FallbackGlobalHotKeyBackend', () {
    bool decide(GlobalHotKeyStatus s) =>
        portalShouldFallBackToX11Grab(s, gtkDrawsOnX11: true);

    test('portal missing: primary disposed once, the same set applied to the '
        'fallback, status and kind follow the fallback', () async {
      final _FakeBackend portal = _FakeBackend(
        GlobalHotKeyBackendKind.portal,
        afterApply: const GlobalHotKeyStatus(
          kind: GlobalHotKeyBackendKind.portal,
          problem: GlobalHotKeyProblem.portalMissing,
        ),
      );
      final _FakeBackend native = _FakeBackend(GlobalHotKeyBackendKind.native);
      int created = 0;
      final FallbackGlobalHotKeyBackend backend = FallbackGlobalHotKeyBackend(
        primary: portal,
        createFallback: () {
          created++;
          return native;
        },
        shouldFallBack: decide,
      );
      final List<GlobalHotKeyStatus> seen = <GlobalHotKeyStatus>[];
      final StreamSubscription<GlobalHotKeyStatus> sub = backend.statusChanges
          .listen(seen.add);

      await backend.apply(<GlobalHotKeyRequest>[request('a'), request('b')]);
      await Future<void>.delayed(Duration.zero);

      expect(backend.fellBack, isTrue);
      expect(created, 1);
      expect(portal.disposeCalls, 1);
      expect(
        native.applied.single.map((GlobalHotKeyRequest r) => r.id).toList(),
        <String>['a', 'b'],
      );
      expect(backend.kind, GlobalHotKeyBackendKind.native);
      expect(backend.status.kind, GlobalHotKeyBackendKind.native);
      // The triggering "portal missing" never reaches the settings page.
      expect(
        seen.where(
          (GlobalHotKeyStatus s) =>
              s.problem == GlobalHotKeyProblem.portalMissing,
        ),
        isEmpty,
      );
      expect(seen.last.kind, GlobalHotKeyBackendKind.native);

      // Later rounds go to the fallback only; no second switch.
      await backend.apply(<GlobalHotKeyRequest>[request('c')]);
      expect(portal.applied, hasLength(1));
      expect(native.applied, hasLength(2));
      expect(created, 1);

      await backend.dispose();
      expect(native.disposeCalls, 1);
      expect(portal.disposeCalls, 1);
      await sub.cancel();
    });

    test('a working portal stays; dispose releases it once', () async {
      final _FakeBackend portal = _FakeBackend(
        GlobalHotKeyBackendKind.portal,
        afterApply: const GlobalHotKeyStatus(
          kind: GlobalHotKeyBackendKind.portal,
          bound: true,
        ),
      );
      int created = 0;
      final FallbackGlobalHotKeyBackend backend = FallbackGlobalHotKeyBackend(
        primary: portal,
        createFallback: () {
          created++;
          return _FakeBackend(GlobalHotKeyBackendKind.native);
        },
        shouldFallBack: decide,
      );
      await backend.apply(<GlobalHotKeyRequest>[request('a')]);
      await backend.rebind();
      expect(backend.fellBack, isFalse);
      expect(created, 0);
      expect(portal.applied, hasLength(1));
      expect(portal.rebindCalls, 1);
      expect(backend.kind, GlobalHotKeyBackendKind.portal);
      await backend.dispose();
      expect(portal.disposeCalls, 1);
    });

    test('dispose while a round waits on the primary does not hang and does '
        'not start the fallback', () async {
      final Completer<void> dialog = Completer<void>();
      final _FakeBackend portal = _FakeBackend(
        GlobalHotKeyBackendKind.portal,
        afterApply: const GlobalHotKeyStatus(
          kind: GlobalHotKeyBackendKind.portal,
          problem: GlobalHotKeyProblem.portalMissing,
        ),
        // Like a portal bind waiting on the user's dialog: only the
        // backend's own dispose ends it.
        applyGate: dialog,
      );
      int created = 0;
      final FallbackGlobalHotKeyBackend backend = FallbackGlobalHotKeyBackend(
        primary: portal,
        createFallback: () {
          created++;
          return _FakeBackend(GlobalHotKeyBackendKind.native);
        },
        shouldFallBack: decide,
      );
      final Future<void> round = backend.apply(<GlobalHotKeyRequest>[
        request('a'),
      ]);
      await Future<void>.delayed(Duration.zero);
      await backend.dispose().timeout(const Duration(seconds: 1));
      await round;
      expect(portal.disposeCalls, 1);
      expect(created, 0);
    });
  });
}

class _FakeBackend implements GlobalHotKeyBackend {
  _FakeBackend(this.kind, {this.afterApply, this.applyGate})
    : _status = GlobalHotKeyStatus.idle(kind);

  @override
  final GlobalHotKeyBackendKind kind;
  final GlobalHotKeyStatus? afterApply;

  /// When set, [apply] waits for it; [dispose] completes it.
  final Completer<void>? applyGate;

  GlobalHotKeyStatus _status;
  final StreamController<GlobalHotKeyStatus> _changes =
      StreamController<GlobalHotKeyStatus>.broadcast();
  final List<List<GlobalHotKeyRequest>> applied = <List<GlobalHotKeyRequest>>[];
  int rebindCalls = 0;
  int disposeCalls = 0;

  @override
  GlobalHotKeyStatus get status => _status;

  @override
  Stream<GlobalHotKeyStatus> get statusChanges => _changes.stream;

  void _set(GlobalHotKeyStatus next) {
    _status = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  @override
  Future<void> apply(List<GlobalHotKeyRequest> requests) async {
    applied.add(requests);
    final Completer<void>? gate = applyGate;
    if (gate != null) await gate.future;
    final GlobalHotKeyStatus? next = afterApply;
    if (next != null) _set(next);
  }

  @override
  Future<void> rebind() async => rebindCalls++;

  @override
  Future<bool> configure({String? activationToken}) async => false;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final Completer<void>? gate = applyGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await _changes.close();
  }
}

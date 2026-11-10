/// A [GlobalHotKeyBackend] that starts on a primary backend and switches, once
/// and for the rest of the run, to a fallback when the primary reports a state
/// the fallback can do better in.
///
/// The one use: a Linux Wayland desktop whose portal has no GlobalShortcuts
/// (GNOME before 48, wlroots, Gamescope) while GTK draws through XWayland (the
/// Flatpak pins `GDK_BACKEND=x11`, the Steam Game Mode launcher does too). The
/// portal then answers `portalMissing`, but an X11 key grab (keybinder) still
/// fires whenever an X11 client has focus — every game under XWayland /
/// Gamescope. Before the portal backend existed that grab was all these
/// sessions had; reporting "not supported" there would take it away.
///
/// Pure Dart (no Flutter import): the backends come in as instances /
/// factories, so this is tested with plain fakes.
library;

import 'dart:async';

import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';

class FallbackGlobalHotKeyBackend implements GlobalHotKeyBackend {
  FallbackGlobalHotKeyBackend({
    required GlobalHotKeyBackend primary,
    required GlobalHotKeyBackend Function() createFallback,
    required bool Function(GlobalHotKeyStatus status) shouldFallBack,
    void Function(String message)? log,
  }) : _active = primary,
       _createFallback = createFallback,
       _shouldFallBack = shouldFallBack,
       _log = log ?? ((String _) {}) {
    _activeSub = primary.statusChanges.listen(_forward);
  }

  final GlobalHotKeyBackend Function() _createFallback;
  final bool Function(GlobalHotKeyStatus status) _shouldFallBack;
  final void Function(String message) _log;

  GlobalHotKeyBackend _active;
  StreamSubscription<GlobalHotKeyStatus>? _activeSub;
  bool _fellBack = false;
  bool _disposed = false;
  List<GlobalHotKeyRequest> _requests = const <GlobalHotKeyRequest>[];

  /// Backends already disposed (each is disposed exactly once, whether by the
  /// switch or by [dispose]).
  final Set<GlobalHotKeyBackend> _released = <GlobalHotKeyBackend>{};

  final StreamController<GlobalHotKeyStatus> _statusChanges =
      StreamController<GlobalHotKeyStatus>.broadcast();

  /// Serial chain: a switch (dispose primary → apply on the fallback) must not
  /// interleave with an [apply] / [rebind] that would land on the old backend.
  Future<void> _chain = Future<void>.value();

  Future<void> _serial(Future<void> Function() body) {
    final Future<void> next = _chain.then((_) => _disposed ? null : body());
    // A failed round must not wedge the chain; the caller still sees it.
    _chain = next.catchError((Object _) {});
    return next;
  }

  /// Whether the switch to the fallback happened.
  bool get fellBack => _fellBack;

  @override
  GlobalHotKeyBackendKind get kind => _active.kind;

  @override
  GlobalHotKeyStatus get status => _active.status;

  @override
  Stream<GlobalHotKeyStatus> get statusChanges => _statusChanges.stream;

  void _forward(GlobalHotKeyStatus status) {
    // The state that triggers the switch is not what the user ends up with;
    // the fallback's own status follows right after it.
    if (!_fellBack && _shouldFallBack(status)) return;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  Future<void> _release(GlobalHotKeyBackend backend) async {
    if (!_released.add(backend)) return;
    await backend.dispose();
  }

  /// Runs after every primary round: the decisive status (e.g. "no portal")
  /// is only known once the primary has tried.
  Future<void> _fallBackIfNeeded() async {
    if (_fellBack || _disposed || !_shouldFallBack(_active.status)) return;
    _fellBack = true;
    final GlobalHotKeyBackend primary = _active;
    _log(
      'hotkey: ${primary.kind.name} backend unusable '
      '(${primary.status.problem?.name}) — falling back',
    );
    await _activeSub?.cancel();
    _activeSub = null;
    await _release(primary);
    if (_disposed) return;
    final GlobalHotKeyBackend fallback = _createFallback();
    _active = fallback;
    _activeSub = fallback.statusChanges.listen(_forward);
    if (!_statusChanges.isClosed) _statusChanges.add(fallback.status);
    await fallback.apply(_requests);
  }

  @override
  Future<void> apply(List<GlobalHotKeyRequest> requests) => _serial(() async {
    _requests = List<GlobalHotKeyRequest>.unmodifiable(requests);
    await _active.apply(_requests);
    await _fallBackIfNeeded();
  });

  @override
  Future<void> rebind() => _serial(() async {
    await _active.rebind();
    await _fallBackIfNeeded();
  });

  @override
  Future<bool> configure({String? activationToken}) =>
      _active.configure(activationToken: activationToken);

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _activeSub?.cancel();
    _activeSub = null;
    // Not queued behind the chain: the active backend's own dispose ends what
    // a running round may be waiting on (a portal dialog left open).
    await _release(_active);
    await _chain;
    // A switch already past its dispose step when this started may have
    // installed the fallback meanwhile.
    await _release(_active);
    await _statusChanges.close();
  }
}

/// **Pure**: whether a portal [status] should hand the hotkeys to the X11 key
/// grab. Only when the portal has no GlobalShortcuts at all (nothing the user
/// could fix in the desktop) and GTK draws on an X11 display (XWayland), where
/// keybinder can grab; on a native Wayland GTK display it cannot.
bool portalShouldFallBackToX11Grab(
  GlobalHotKeyStatus status, {
  required bool gtkDrawsOnX11,
}) =>
    gtkDrawsOnX11 &&
    status.kind == GlobalHotKeyBackendKind.portal &&
    status.problem == GlobalHotKeyProblem.portalMissing;

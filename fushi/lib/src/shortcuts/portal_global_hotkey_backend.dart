/// [GlobalHotKeyBackend] over the XDG GlobalShortcuts portal (Linux Wayland).
///
/// Lifetime: one portal session per app run (the app is single-instance, so
/// one per user session). It is created on the first [apply], bound with the
/// whole `globalExternal` set, re-bound on the **same** session only when the
/// set itself changes (ids / descriptions — e.g. the UI language changed), and
/// closed by [dispose] on exit. A changed preferred trigger alone does not
/// re-bind: once the desktop knows a shortcut, the key is the user's choice in
/// the system settings and a new hint would be ignored anyway.
///
/// The user dismissing the desktop's dialog is not retried automatically (that
/// would be a dialog loop); the settings page offers [rebind]. A session the
/// desktop closes is likewise reported and re-created only on [rebind] or the
/// next set change.
library;

import 'dart:async';

import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/global_shortcuts_portal.dart';

class PortalGlobalHotKeyBackend implements GlobalHotKeyBackend {
  PortalGlobalHotKeyBackend({
    required GlobalShortcutsPortal portal,
    required String appId,
    void Function(String message)? log,
    void Function(String context, Object error, StackTrace? stack)? onError,
  }) : _portal = portal,
       _appId = appId,
       _log = log ?? ((String _) {}),
       _onError = onError ?? ((String _, Object _, StackTrace? _) {});

  final GlobalShortcutsPortal _portal;
  final String _appId;
  final void Function(String message) _log;
  final void Function(String context, Object error, StackTrace? stack) _onError;

  final StreamController<GlobalHotKeyStatus> _statusChanges =
      StreamController<GlobalHotKeyStatus>.broadcast();
  GlobalHotKeyStatus _status = const GlobalHotKeyStatus.idle(
    GlobalHotKeyBackendKind.portal,
  );

  /// Serial chain: every public operation runs after the previous one.
  Future<void> _chain = Future<void>.value();

  /// null = not opened yet; 0 = opened, no GlobalShortcuts on this desktop.
  int? _version;
  bool _opened = false;
  String? _session;
  final List<StreamSubscription<Object>> _subscriptions =
      <StreamSubscription<Object>>[];

  /// The current wanted set, by id.
  Map<String, GlobalHotKeyRequest> _requests = <String, GlobalHotKeyRequest>{};

  /// Signature of the set the current session has bound.
  String? _boundSignature;

  /// Signature of the set whose dialog the user dismissed (not re-prompted
  /// until the set changes or the user asks via [rebind]).
  String? _declinedSignature;
  bool _disposed = false;

  @override
  GlobalHotKeyBackendKind get kind => GlobalHotKeyBackendKind.portal;

  @override
  GlobalHotKeyStatus get status => _status;

  @override
  Stream<GlobalHotKeyStatus> get statusChanges => _statusChanges.stream;

  void _setStatus(GlobalHotKeyStatus next) {
    if (next == _status) return;
    _status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }

  Future<void> _serial(Future<void> Function() body) {
    final Future<void> next = _chain.then((_) => _disposed ? null : body());
    _chain = next.catchError((Object e, StackTrace st) {
      _onError('PortalGlobalHotKeyBackend', e, st);
    });
    return _chain;
  }

  static String _signatureOf(Iterable<GlobalHotKeyRequest> requests) {
    final List<String> parts = <String>[
      for (final GlobalHotKeyRequest r in requests)
        '${r.id}\u0001${r.description}',
    ]..sort();
    return parts.join('\u0002');
  }

  @override
  Future<void> apply(List<GlobalHotKeyRequest> requests) => _serial(() async {
    _requests = <String, GlobalHotKeyRequest>{
      for (final GlobalHotKeyRequest r in requests) r.id: r,
    };
    final String signature = _signatureOf(_requests.values);
    if (_session != null && signature == _boundSignature) {
      // Same set: the handlers above were swapped in place, nothing to ask the
      // desktop.
      return;
    }
    if (signature == _declinedSignature) return;
    await _bind(signature);
  });

  @override
  Future<void> rebind() => _serial(() async {
    _declinedSignature = null;
    _boundSignature = null;
    await _bind(_signatureOf(_requests.values));
  });

  @override
  Future<bool> configure({String? activationToken}) async {
    final String? session = _session;
    final int version = _version ?? 0;
    if (session == null || version < 2) return false;
    try {
      await _portal.configureShortcuts(
        session,
        activationToken: activationToken,
      );
      return true;
    } on GlobalShortcutsPortalException catch (e, st) {
      _onError('PortalGlobalHotKeyBackend.configure', e, st);
      return false;
    }
  }

  /// Opens the portal once per run. Returns false when it is missing (status
  /// already says so).
  Future<bool> _ensureOpen() async {
    if (_opened) return (_version ?? 0) > 0;
    _opened = true;
    final int? version = await _portal.open(appId: _appId);
    _version = version ?? 0;
    if (version == null) {
      _setStatus(
        const GlobalHotKeyStatus(
          kind: GlobalHotKeyBackendKind.portal,
          problem: GlobalHotKeyProblem.portalMissing,
        ),
      );
      return false;
    }
    _log('portal: GlobalShortcuts version $version');
    _subscriptions
      ..add(_portal.activated.listen(_onActivated))
      ..add(_portal.shortcutsChanged.listen(_onShortcutsChanged))
      ..add(_portal.sessionClosed.listen(_onSessionClosed));
    return true;
  }

  Future<void> _bind(String signature) async {
    if (!await _ensureOpen()) return;
    final List<PortalShortcut> shortcuts = <PortalShortcut>[
      for (final GlobalHotKeyRequest r in _requests.values)
        PortalShortcut(
          id: r.id,
          description: r.description,
          preferredTrigger: r.chord?.portalTrigger,
        ),
    ];
    try {
      final String session = _session ??= await _portal.createSession();
      final List<PortalBoundShortcut> bound = await _portal.bindShortcuts(
        session,
        shortcuts,
      );
      _boundSignature = signature;
      _declinedSignature = null;
      _log(
        'portal: bound ${bound.map((PortalBoundShortcut b) => '${b.id}=${b.triggerDescription}').join(', ')}',
      );
      _setStatus(
        GlobalHotKeyStatus(
          kind: GlobalHotKeyBackendKind.portal,
          bound: true,
          canConfigure: (_version ?? 0) >= 2,
          triggers: _triggersOf(bound),
        ),
      );
    } on GlobalShortcutsPortalException catch (e, st) {
      switch (e.failure) {
        case PortalFailure.cancelled:
          _declinedSignature = signature;
          _log('portal: shortcut dialog dismissed');
          _setStatus(
            GlobalHotKeyStatus(
              kind: GlobalHotKeyBackendKind.portal,
              problem: GlobalHotKeyProblem.dialogCancelled,
              canConfigure: (_version ?? 0) >= 2,
            ),
          );
        case PortalFailure.notAllowed:
          _onError('PortalGlobalHotKeyBackend.bind', e, st);
          _setStatus(
            GlobalHotKeyStatus(
              kind: GlobalHotKeyBackendKind.portal,
              problem: GlobalHotKeyProblem.portalNeedsAppId,
              detail: e.message,
            ),
          );
        case PortalFailure.failed:
          _onError('PortalGlobalHotKeyBackend.bind', e, st);
          _setStatus(
            GlobalHotKeyStatus(
              kind: GlobalHotKeyBackendKind.portal,
              problem: GlobalHotKeyProblem.portalFailed,
              detail: e.message,
            ),
          );
      }
    }
  }

  static Map<String, String> _triggersOf(List<PortalBoundShortcut> bound) =>
      <String, String>{
        for (final PortalBoundShortcut b in bound) b.id: b.triggerDescription,
      };

  void _onActivated(PortalActivation activation) {
    if (activation.sessionHandle != _session) return;
    final GlobalHotKeyRequest? request = _requests[activation.shortcutId];
    if (request == null) {
      _log('portal: Activated for unknown id ${activation.shortcutId}');
      return;
    }
    _log('portal: Activated ${activation.shortcutId}');
    unawaited(
      request
          .onActivated(
            GlobalHotKeyActivation(activationToken: activation.activationToken),
          )
          .catchError((Object e, StackTrace st) {
            _onError('PortalGlobalHotKeyBackend.activated', e, st);
          }),
    );
  }

  void _onShortcutsChanged(PortalShortcutsChanged change) {
    if (change.sessionHandle != _session) return;
    _setStatus(
      GlobalHotKeyStatus(
        kind: GlobalHotKeyBackendKind.portal,
        bound: true,
        canConfigure: (_version ?? 0) >= 2,
        triggers: _triggersOf(change.shortcuts),
      ),
    );
  }

  void _onSessionClosed(String session) {
    if (session != _session) return;
    _session = null;
    _boundSignature = null;
    _log('portal: session closed by the desktop');
    _setStatus(
      const GlobalHotKeyStatus(
        kind: GlobalHotKeyBackendKind.portal,
        problem: GlobalHotKeyProblem.sessionClosed,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _serial(() async {
      final String? session = _session;
      _session = null;
      if (session != null) await _portal.closeSession(session);
      for (final StreamSubscription<Object> s in _subscriptions) {
        await s.cancel();
      }
      _subscriptions.clear();
      if (_opened) await _portal.close();
    });
    _disposed = true;
    await _statusChanges.close();
  }
}

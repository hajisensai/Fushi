import 'dart:async';

import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// [GlobalHotKeyBackend] over `hotkey_manager`: Windows `RegisterHotKey`,
/// macOS Carbon, Linux X11 keybinder. The app owns the key, so exactly the
/// chord from the shortcut registry is registered; an action without a chord
/// stays off.
class NativeGlobalHotKeyBackend implements GlobalHotKeyBackend {
  NativeGlobalHotKeyBackend();

  /// Registered last round, by request id. Table-driven: unregister /
  /// re-register has one path whatever the number of actions.
  final Map<String, HotKey> _hotKeys = <String, HotKey>{};
  final StreamController<GlobalHotKeyStatus> _statusChanges =
      StreamController<GlobalHotKeyStatus>.broadcast();
  List<GlobalHotKeyRequest> _requests = const <GlobalHotKeyRequest>[];
  Future<void> _chain = Future<void>.value();

  @override
  GlobalHotKeyBackendKind get kind => GlobalHotKeyBackendKind.native;

  @override
  GlobalHotKeyStatus get status =>
      const GlobalHotKeyStatus(kind: GlobalHotKeyBackendKind.native);

  @override
  Stream<GlobalHotKeyStatus> get statusChanges => _statusChanges.stream;

  /// Serialized: [apply] has several awaits between "drop the old table" and
  /// "register the new one", and the controller calls it fire-and-forget on
  /// every registry change (remap + reset + profile switch can come in a
  /// burst). A second round entering an await gap of the first would see an
  /// already cleared table, skip the unregister and register the same chord
  /// twice — one of them could never be unregistered again.
  Future<void> _serial(Future<void> Function() body) {
    final Future<void> next = _chain
        .then((_) => body())
        // A failed round must not wedge the chain (each step catches already).
        .catchError(
          (Object e) => glog('hotkey: registration round FAILED: $e'),
        );
    _chain = next;
    return next;
  }

  @override
  Future<void> apply(List<GlobalHotKeyRequest> requests) {
    _requests = List<GlobalHotKeyRequest>.unmodifiable(requests);
    return _serial(() => _registerNow(_requests));
  }

  @override
  Future<void> rebind() => _serial(() => _registerNow(_requests));

  @override
  Future<bool> configure({String? activationToken}) async => false;

  Future<void> _registerNow(List<GlobalHotKeyRequest> requests) async {
    await _unregisterAll();
    for (final GlobalHotKeyRequest request in requests) {
      await _registerOne(request);
    }
  }

  Future<void> _unregisterAll() async {
    final List<MapEntry<String, HotKey>> previous = _hotKeys.entries.toList(
      growable: false,
    );
    _hotKeys.clear();
    for (final MapEntry<String, HotKey> entry in previous) {
      try {
        await hotKeyManager.unregister(entry.value);
      } catch (e) {
        glog('hotkey: unregister previous ${entry.key} FAILED (non-fatal): $e');
      }
    }
  }

  /// One OS hotkey. A failure only affects this action.
  Future<void> _registerOne(GlobalHotKeyRequest request) async {
    final GlobalHotKeyChord? chord = request.chord;
    if (chord == null) {
      glog(
        'hotkey: no keyboard binding for ${request.id} — not registered '
        '(feature off until a key is assigned)',
      );
      return;
    }
    final HotKey hotKey = HotKey(
      key: PhysicalKeyboardKey(chord.physicalUsage),
      modifiers: <HotKeyModifier>[
        for (final GlobalHotKeyModifier mod in chord.modifiers)
          switch (mod) {
            GlobalHotKeyModifier.ctrl => HotKeyModifier.control,
            GlobalHotKeyModifier.shift => HotKeyModifier.shift,
            GlobalHotKeyModifier.alt => HotKeyModifier.alt,
            GlobalHotKeyModifier.meta => HotKeyModifier.meta,
          },
      ],
      scope: HotKeyScope.system,
    );
    _hotKeys[request.id] = hotKey;
    try {
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) =>
            unawaited(request.onActivated(const GlobalHotKeyActivation())),
      );
      glog('hotkey: registered ${request.id} = ${chord.label} OK');
    } catch (e, st) {
      // The table keeps the entry: the next round's unregister of a HotKey the
      // OS never took is a harmless no-op, so no rollback is needed.
      glog('hotkey: register ${request.id} FAILED: $e');
      // TODO-1086: a failed register (combo taken by another app, init-order
      // race) must reach the user-visible / uploadable error log, not only the
      // temp-file glog — otherwise "the app-outside lookup never fires" has no
      // visible cause.
      ErrorLogService.instance.log(
        'GlobalLookupController.registerHotKey',
        'Failed to register global hotkey ${request.id} = ${chord.label}: $e',
        st,
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _serial(_unregisterAll);
    await _statusChanges.close();
  }
}

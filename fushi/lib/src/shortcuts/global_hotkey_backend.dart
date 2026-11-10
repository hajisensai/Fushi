/// App-outside (OS-level) hotkeys: the contract every platform backend
/// implements, so [GlobalLookupController] registers the `globalExternal`
/// actions through one path whatever the desktop does underneath.
///
/// Two backends exist:
///
///  * [GlobalHotKeyBackendKind.native] — `hotkey_manager`: Windows
///    `RegisterHotKey`, macOS Carbon, Linux X11 keybinder. The app owns the key:
///    it registers exactly the chord the user recorded in settings.
///  * [GlobalHotKeyBackendKind.portal] — the XDG GlobalShortcuts portal on a
///    Linux Wayland desktop (KDE Plasma incl. Steam Deck Desktop Mode, GNOME
///    48+). Wayland gives no client a global key grab, so the **desktop** owns
///    the binding: the app only declares shortcut ids + descriptions (+ a
///    preferred trigger as a hint), the desktop may ask the user to confirm or
///    change the keys, and later changes happen in the system settings. What the
///    key actually is comes back from the portal ([GlobalHotKeyStatus.triggers]).
///
/// Pure Dart (no Flutter import): the portal backend and this contract are
/// tested with `dart test`.
library;

import 'dart:async';

/// Which mechanism registers the app-outside hotkeys in this process.
enum GlobalHotKeyBackendKind {
  /// `hotkey_manager` (Windows / macOS / Linux X11 keybinder).
  native,

  /// XDG GlobalShortcuts portal (Linux Wayland desktops).
  portal,
}

/// Why app-outside hotkeys do not (fully) work right now. Shown in the
/// shortcut settings so a dead hotkey is never silent.
enum GlobalHotKeyProblem {
  /// Wayland desktop whose portal has no GlobalShortcuts backend (GNOME before
  /// 48, most wlroots compositors, gamescope).
  portalMissing,

  /// The portal could not tell which app is asking ("An app id is required"):
  /// a host install whose `app.fushi.reader.desktop` entry is not installed.
  portalNeedsAppId,

  /// The user dismissed the desktop's shortcut dialog; nothing is bound until
  /// they bind again or assign keys in the system settings.
  dialogCancelled,

  /// The portal returned an error / the D-Bus call failed.
  portalFailed,

  /// The desktop ended the session (portal restarted, compositor closed it).
  sessionClosed,
}

/// Snapshot of the backend state, for the settings page.
class GlobalHotKeyStatus {
  const GlobalHotKeyStatus({
    required this.kind,
    this.problem,
    this.triggers = const <String, String>{},
    this.bound = false,
    this.canConfigure = false,
    this.detail,
  });

  /// Initial state before the backend did anything.
  const GlobalHotKeyStatus.idle(GlobalHotKeyBackendKind kind)
    : this(kind: kind);

  final GlobalHotKeyBackendKind kind;

  /// null = working (or not started yet).
  final GlobalHotKeyProblem? problem;

  /// Portal only: shortcut id → the trigger the desktop reports
  /// (`trigger_description`, already human readable). An empty string means
  /// the shortcut is registered but has no key assigned; a missing id means
  /// the desktop did not bind it.
  final Map<String, String> triggers;

  /// Portal only: the desktop accepted the shortcut set (a dialog may have
  /// been shown and confirmed).
  final bool bound;

  /// Portal only: the desktop can open its own shortcut editor for this app
  /// (`ConfigureShortcuts`, interface version 2).
  final bool canConfigure;

  /// Raw error text for diagnostics (never shown as the main message).
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is GlobalHotKeyStatus &&
      other.kind == kind &&
      other.problem == problem &&
      other.bound == bound &&
      other.canConfigure == canConfigure &&
      other.detail == detail &&
      _mapEquals(other.triggers, triggers);

  @override
  int get hashCode => Object.hash(
    kind,
    problem,
    bound,
    canConfigure,
    detail,
    Object.hashAllUnordered(
      triggers.entries.map(
        (MapEntry<String, String> e) => '${e.key}=${e.value}',
      ),
    ),
  );

  @override
  String toString() =>
      'GlobalHotKeyStatus(kind: ${kind.name}, problem: ${problem?.name}, '
      'bound: $bound, canConfigure: $canConfigure, triggers: $triggers)';
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// Modifier of a [GlobalHotKeyChord].
enum GlobalHotKeyModifier { ctrl, alt, shift, meta }

/// A keyboard chord in a platform-neutral form: the USB-HID usage the native
/// backend registers, plus the xkb keysym name the portal's preferred trigger
/// uses. Built from a registry binding by `global_hotkey_chords.dart`.
class GlobalHotKeyChord {
  const GlobalHotKeyChord({
    required this.physicalUsage,
    required this.modifiers,
    required this.label,
    this.keysym,
  });

  /// USB-HID usage (`PhysicalKeyboardKey.usbHidUsage`).
  final int physicalUsage;

  /// xkb keysym name without the `XKB_KEY_` prefix (`d`, `F5`, `Return`);
  /// null when the key has no stable name (then no preferred trigger is sent).
  final String? keysym;

  final Set<GlobalHotKeyModifier> modifiers;

  /// What the settings page shows for this chord (`Ctrl+Alt+D`).
  final String label;

  /// The chord in the XDG shortcuts spec format (`CTRL+ALT+d`): modifiers
  /// `CTRL` / `ALT` / `SHIFT` / `LOGO` joined to the keysym by `+`. null when
  /// the key has no keysym name.
  String? get portalTrigger {
    final String? key = keysym;
    if (key == null || key.isEmpty) return null;
    final List<String> parts = <String>[
      if (modifiers.contains(GlobalHotKeyModifier.ctrl)) 'CTRL',
      if (modifiers.contains(GlobalHotKeyModifier.alt)) 'ALT',
      if (modifiers.contains(GlobalHotKeyModifier.shift)) 'SHIFT',
      if (modifiers.contains(GlobalHotKeyModifier.meta)) 'LOGO',
      key,
    ];
    return parts.join('+');
  }
}

/// Facts the desktop passes along with one activation.
class GlobalHotKeyActivation {
  const GlobalHotKeyActivation({this.activationToken});

  /// Wayland `xdg_activation_v1` token (portal `Activated` option
  /// `activation_token`), letting the app raise its own window in response.
  /// null on the native backend and on portals that do not send one.
  final String? activationToken;
}

/// Runs one `globalExternal` action.
typedef GlobalHotKeyHandler =
    Future<void> Function(GlobalHotKeyActivation activation);

/// One app-outside hotkey the controller wants registered.
class GlobalHotKeyRequest {
  const GlobalHotKeyRequest({
    required this.id,
    required this.description,
    required this.onActivated,
    this.chord,
  });

  /// Stable id: the action's persisted key (`ShortcutAction.key`). The portal
  /// keeps the user's key assignment under it across runs, so it must never be
  /// renamed.
  final String id;

  /// User-readable description, shown by the desktop's shortcut dialog and
  /// system settings.
  final String description;

  /// The chord from the shortcut registry. Native: the key that is registered
  /// (null = this action has no key and stays off). Portal: only the
  /// preferred trigger hint for a shortcut the desktop has not seen yet.
  final GlobalHotKeyChord? chord;

  final GlobalHotKeyHandler onActivated;
}

/// Registers the app-outside hotkeys on one OS mechanism.
abstract interface class GlobalHotKeyBackend {
  GlobalHotKeyBackendKind get kind;

  GlobalHotKeyStatus get status;

  /// Fires whenever [status] changes.
  Stream<GlobalHotKeyStatus> get statusChanges;

  /// Replaces the whole registered set with [requests]. Serialized: calls
  /// made while one is running run after it.
  Future<void> apply(List<GlobalHotKeyRequest> requests);

  /// Portal: bind the current set again after the user cancelled the dialog or
  /// the desktop closed the session. Native: same as re-applying.
  Future<void> rebind();

  /// Portal: ask the desktop to open its shortcut editor for this app.
  /// Returns false when the desktop cannot (native backend, portal version 1);
  /// the settings page then explains where to change the keys instead.
  Future<bool> configure({String? activationToken});

  /// Unregisters everything and releases the OS resources (portal session).
  Future<void> dispose();
}

/// Whether this Linux desktop session is Wayland, judged from the session —
/// not from the GTK backend: the Flatpak pins `GDK_BACKEND=x11` (Fushi draws
/// through XWayland there), yet the desktop is still Wayland and an X11 key
/// grab only sees keys while an X11 window has focus.
///
/// `XDG_SESSION_TYPE` decides when it is set (`wayland` / `x11`); without it a
/// reachable `WAYLAND_DISPLAY` means Wayland.
bool linuxDesktopIsWayland(Map<String, String> environment) {
  final String session = (environment['XDG_SESSION_TYPE'] ?? '')
      .trim()
      .toLowerCase();
  if (session == 'wayland') return true;
  if (session.isNotEmpty) return false;
  return (environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
}

/// Which backend a desktop process uses; null = no app-outside hotkeys
/// (mobile).
GlobalHotKeyBackendKind? globalHotKeyBackendKindFor({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
  required Map<String, String> environment,
}) {
  if (isWindows || isMacOS) return GlobalHotKeyBackendKind.native;
  if (!isLinux) return null;
  return linuxDesktopIsWayland(environment)
      ? GlobalHotKeyBackendKind.portal
      : GlobalHotKeyBackendKind.native;
}

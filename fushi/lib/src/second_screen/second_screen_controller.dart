import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// User setting for the second screen.
enum SecondScreenMode {
  /// Use a second screen once the user approved it (asked once per screen).
  auto,

  /// Use any second screen without asking.
  always,

  /// Never use a second screen.
  off;

  static SecondScreenMode fromPref(Object? value) {
    for (final SecondScreenMode m in SecondScreenMode.values) {
      if (m.name == value) return m;
    }
    return SecondScreenMode.auto;
  }
}

/// Where lookups made on the main screen open while the companion is up.
enum SecondScreenLookupScreen {
  /// The companion's Lookup tab (the default).
  bottom,

  /// The page's normal in-page popup on the main screen; the companion keeps
  /// its panels.
  top;

  static SecondScreenLookupScreen fromPref(Object? value) {
    for (final SecondScreenLookupScreen s in SecondScreenLookupScreen.values) {
      if (s.name == value) return s;
    }
    return SecondScreenLookupScreen.bottom;
  }
}

/// Preference keys (registered in `preference_keys.dart`, device-local).
const String kSecondScreenModePrefKey = 'second_screen_mode';
const String kSecondScreenApprovedPrefKey = 'second_screen_approved_displays';
const String kSecondScreenLookupScreenPrefKey = 'second_screen_lookup_screen';

/// Main-engine side of the companion on the second screen: the single source
/// of truth for "is the second screen in use by the companion". Pages never
/// look at displays themselves; they read [isActive].
///
/// `isActive = display available && (always || (auto && approved)) && no
/// session override to off && the companion panel is actually up` (the game
/// stream takes the second screen while it streams; the companion is
/// inactive then and comes back after).
class SecondScreenController extends ChangeNotifier {
  SecondScreenController({
    required this.readPref,
    required this.writePref,
    required SecondScreenHost? host,
  }) : _host = host;

  /// Preference access, injected so tests need no AppModel.
  final Object? Function(String key) readPref;
  final Future<void> Function(String key, Object? value) writePref;

  /// Null where a second screen is not supported: always inactive.
  final SecondScreenHost? _host;

  bool _started = false;
  bool _disposed = false;
  SecondScreenMode _mode = SecondScreenMode.auto;
  SecondScreenLookupScreen _lookupScreen = SecondScreenLookupScreen.bottom;
  Set<String> _approved = <String>{};

  /// Fingerprints the user said "not now" to in this run (asked again next
  /// launch).
  final Set<String> _declinedThisRun = <String>{};

  /// Quick toggle for this run: null = follow the setting.
  bool? _sessionOverride;

  /// The screen [_sessionOverride] was made for.
  String? _overrideFingerprint;

  SecondScreenMode get mode => _mode;

  /// Where main-screen lookups open while the companion is up (every media
  /// type and the controller lookup mode; the companion bridge mirrors it to
  /// the context registry, the single routing point).
  SecondScreenLookupScreen get lookupScreen => _lookupScreen;

  /// The screen the companion goes on: the first one the platform offers.
  SecondScreenDisplayInfo? get display {
    final List<SecondScreenDisplayInfo>? displays = _host?.displays.value;
    return displays == null || displays.isEmpty ? null : displays.first;
  }

  /// A second screen exists (whatever the setting says).
  bool get displayAvailable => display != null;

  /// The companion is up on the second screen: route lookups and controls
  /// there. False means today's single-screen behaviour.
  bool get isActive =>
      _wantActive &&
      _host?.panel.value?.mode == SecondScreenPanelMode.companion;

  /// The main screen should ask "Use this screen for Fushi?".
  bool get needsApproval {
    final SecondScreenDisplayInfo? screen = display;
    return screen != null &&
        _started &&
        _mode == SecondScreenMode.auto &&
        _sessionOverride == null &&
        !_approved.contains(screen.fingerprint) &&
        !_declinedThisRun.contains(screen.fingerprint);
  }

  bool get _wantActive {
    final SecondScreenDisplayInfo? screen = display;
    if (screen == null) return false;
    final bool? override = _sessionOverride;
    if (override != null) return override;
    return switch (_mode) {
      SecondScreenMode.off => false,
      SecondScreenMode.always => true,
      SecondScreenMode.auto => _approved.contains(screen.fingerprint),
    };
  }

  /// Call once preferences are readable (main AppModel initialised).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _mode = SecondScreenMode.fromPref(readPref(kSecondScreenModePrefKey));
    _lookupScreen = SecondScreenLookupScreen.fromPref(
      readPref(kSecondScreenLookupScreenPrefKey),
    );
    _approved = _decodeApproved(readPref(kSecondScreenApprovedPrefKey));
    final SecondScreenHost? host = _host;
    if (host == null) return;
    host.displays.addListener(_onDisplays);
    host.panel.addListener(_onPanel);
    host.resets.addListener(_onReset);
    try {
      await host.start();
    } catch (error, stack) {
      // No second-screen host on this build / Activity: stay single-screen.
      ErrorLogService.instance.log(
        'SecondScreenController.start',
        error,
        stack,
      );
      return;
    }
    _notify();
    await _apply();
  }

  Future<void> setMode(SecondScreenMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _sessionOverride = null;
    await writePref(kSecondScreenModePrefKey, mode.name);
    await _apply();
  }

  Future<void> setLookupScreen(SecondScreenLookupScreen screen) async {
    if (_lookupScreen == screen) return;
    _lookupScreen = screen;
    _notify();
    await writePref(kSecondScreenLookupScreenPrefKey, screen.name);
  }

  /// Answer to the approval prompt for the current screen.
  Future<void> answerApproval({required bool useScreen}) async {
    final SecondScreenDisplayInfo? screen = display;
    if (screen == null) return;
    final String fingerprint = screen.fingerprint;
    if (useScreen) {
      _approved = <String>{..._approved, fingerprint};
      await writePref(
        kSecondScreenApprovedPrefKey,
        jsonEncode(_approved.toList()),
      );
    } else {
      _declinedThisRun.add(fingerprint);
    }
    await _apply();
  }

  /// Quick toggle for this run only (until the screen changes).
  Future<void> toggleForSession() async {
    final SecondScreenDisplayInfo? screen = display;
    if (screen == null) return;
    _sessionOverride = !_wantActive;
    _overrideFingerprint = screen.fingerprint;
    await _apply();
  }

  void _onDisplays() {
    // The override belongs to the screen it was made for.
    if (_sessionOverride != null &&
        display?.fingerprint != _overrideFingerprint) {
      _sessionOverride = null;
      _overrideFingerprint = null;
    }
    _notify();
    // Also brings the companion back after its panel went away on its own
    // (the next display event asks again, never a loop on panel events).
    unawaited(_apply());
  }

  void _onPanel() => _notify();

  void _onReset() => unawaited(_apply());

  Future<void> _apply() async {
    final SecondScreenHost? host = _host;
    if (host == null || _disposed) return;
    _notify();
    try {
      await host.request(
        SecondScreenPanelMode.companion,
        _wantActive ? display?.id : null,
      );
    } catch (error, stack) {
      // The call did not reach the platform side (Activity being recreated):
      // its reset makes us place again.
      ErrorLogService.instance.log(
        'SecondScreenController.apply',
        error,
        stack,
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Set<String> _decodeApproved(Object? raw) {
    if (raw is! String || raw.isEmpty) return <String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toSet();
    } on FormatException {
      // Corrupt value: treat as nothing approved; the user is asked again.
    }
    return <String>{};
  }

  @override
  void dispose() {
    _disposed = true;
    final SecondScreenHost? host = _host;
    if (host != null && _started) {
      host.displays.removeListener(_onDisplays);
      host.panel.removeListener(_onPanel);
      host.resets.removeListener(_onReset);
    }
    super.dispose();
  }
}

/// App-wide second-screen controller (main engine). Starts itself once the
/// AppModel's preferences are loaded.
final ChangeNotifierProvider<SecondScreenController>
secondScreenControllerProvider = ChangeNotifierProvider<SecondScreenController>(
  (Ref ref) {
    final AppModel appModel = ref.read(appProvider);
    final SecondScreenController controller = SecondScreenController(
      readPref: (String key) => appModel.prefsRepo.getPref(key),
      writePref: (String key, Object? value) =>
          appModel.prefsRepo.setPref(key, value),
      host: SecondScreenHost.forCurrentPlatform(),
    );
    void maybeStart() {
      if (appModel.isInitialised) unawaited(controller.start());
    }

    appModel.addListener(maybeStart);
    ref.onDispose(() => appModel.removeListener(maybeStart));
    maybeStart();
    return controller;
  },
);

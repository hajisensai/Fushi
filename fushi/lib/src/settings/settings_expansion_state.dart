import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device UI preferences, deliberately outside Profile and backup preferences.
class SettingsExpansionState extends ChangeNotifier {
  SettingsExpansionState({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static final SettingsExpansionState instance = SettingsExpansionState();
  static const String keyPrefix = 'settings_section_expanded.';

  final Future<SharedPreferences> Function() _loadPreferences;
  final Map<String, bool> _values = <String, bool>{};
  Future<void>? _loading;
  SharedPreferences? _preferences;

  bool value(String id, {required bool defaultValue}) =>
      _values[id] ?? defaultValue;

  Future<void> load() => _loading ??= _read().catchError((
    Object error,
    StackTrace stack,
  ) {
    // A failed read is not a loaded store. A later explicit visit or toggle can
    // load again, preserving any user choices already made in memory.
    _loading = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _read() async {
    final SharedPreferences preferences = await _loadPreferences();
    for (final String key in preferences.getKeys()) {
      if (!key.startsWith(keyPrefix)) continue;
      final Object? value = preferences.get(key);
      if (value is bool) {
        // A user may already have toggled while the device store was loading.
        _values.putIfAbsent(key.substring(keyPrefix.length), () => value);
      }
    }
    _preferences = preferences;
    notifyListeners();
  }

  Future<void> setExpanded(String id, bool expanded) async {
    _values[id] = expanded;
    notifyListeners();
    await load();
    // Persist the latest intent if several toggles happened during loading.
    final bool saved = await _preferences!.setBool(
      '$keyPrefix$id',
      _values[id]!,
    );
    if (!saved) throw StateError('Could not save settings section state: $id');
  }
}

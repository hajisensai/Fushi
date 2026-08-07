import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// Host-owned service configuration that a paired child may import over the
/// authenticated interconnect channel.
///
/// This is intentionally a small allowlist, not a general preferences backup.
/// Device identity, pairing credentials, local paths, inbound API passwords and
/// media-source secrets must never enter this payload.
class InterconnectServiceConfigSnapshot {
  InterconnectServiceConfigSnapshot._(this.preferences);

  static const int schemaVersion = 1;

  /// Preferences that describe external services shared by the user's devices.
  ///
  /// `yomitan_api_key` is deliberately absent: it protects this device's local
  /// inbound API. Bangumi/Anki credentials and `media_source_secret_*` are also
  /// device-scoped or have external write authority and remain local.
  static const Set<String> sharedPreferenceKeys = <String>{
    'jimaku_api_key',
    'video_scraper_tmdb_api_key',
    'qb_connection_config',
    'manga_online_catalog_base_url',
    'manga_online_catalog_enabled',
  };

  static final Map<String, String> _defaultRawValues = <String, String>{
    'jimaku_api_key': PrefCodec.encode(''),
    'video_scraper_tmdb_api_key': PrefCodec.encode(''),
    'qb_connection_config': PrefCodec.encode(''),
    'manga_online_catalog_base_url': PrefCodec.encode('https://mokuro.moe'),
    'manga_online_catalog_enabled': PrefCodec.encode(true),
  };

  /// Raw [PrefCodec] values, kept raw so the client does not double-encode
  /// strings or JSON. Missing host rows are materialized as semantic defaults,
  /// allowing a cleared/rotated key to clear an older child value.
  final Map<String, String> preferences;

  factory InterconnectServiceConfigSnapshot.fromPreferences(
    Map<String, String> allPreferences,
  ) {
    return InterconnectServiceConfigSnapshot._(
      <String, String>{
        for (final String key in sharedPreferenceKeys)
          key: allPreferences[key] ?? _defaultRawValues[key]!,
      },
    );
  }

  factory InterconnectServiceConfigSnapshot.fromJson(
    Map<String, Object?> json,
  ) {
    final Object? rawPreferences = json['preferences'];
    if (json['schemaVersion'] != schemaVersion || rawPreferences is! Map) {
      throw const FormatException('Unsupported service config snapshot');
    }
    final Map<String, String> accepted = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in rawPreferences.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is! String ||
          value is! String ||
          !sharedPreferenceKeys.contains(key)) {
        continue;
      }
      accepted[key] = value;
    }
    return InterconnectServiceConfigSnapshot._(accepted);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'preferences': preferences,
      };

  /// Applies only changed allowlisted rows. Returns the number of rows changed.
  ///
  /// Unknown/missing fields are ignored; a real host snapshot contains every
  /// allowlisted key (including encoded defaults for cleared values).
  Future<int> applyTo(HibikiDatabase db) async {
    int changed = 0;
    for (final MapEntry<String, String> entry in preferences.entries) {
      if (!sharedPreferenceKeys.contains(entry.key)) continue;
      if (await db.getPref(entry.key) == entry.value) continue;
      await db.setPref(entry.key, entry.value);
      changed++;
    }
    return changed;
  }
}

/// Optional host capability kept separate from [HibikiLibraryHostService]'s
/// large media interface so older/test host implementations remain compatible.
abstract interface class InterconnectServiceConfigHost {
  Future<InterconnectServiceConfigSnapshot> getInterconnectServiceConfig();
}

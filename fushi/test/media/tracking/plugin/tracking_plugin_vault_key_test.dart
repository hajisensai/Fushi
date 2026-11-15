import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_vault_key.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';

/// Tracking keeps its vault data key under its own secure-storage entry: the
/// music key is never read, written or shared.
class _Store implements MusicPluginSecretStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

void main() {
  test('the tracking key lives under its own entry', () async {
    final Directory root = Directory.systemTemp.createTempSync('fushi-tvk-');
    addTearDown(() => root.deleteSync(recursive: true));
    final _Store store = _Store()
      ..data[MusicPluginVaultKey.storageKey] = 'music-key-untouched';
    final MusicPluginVaultKey key = MusicPluginVaultKey(
      vaultRoot: root.path,
      store: store,
      secretName: kTrackingPluginVaultKeyName,
      osManaged: false,
    );
    final List<int>? bytes = await key.call();
    expect(bytes, hasLength(32));
    expect(store.data.keys, <String>{
      MusicPluginVaultKey.storageKey,
      kTrackingPluginVaultKeyName,
    });
    expect(store.data[MusicPluginVaultKey.storageKey], 'music-key-untouched');
    expect(kTrackingPluginVaultKeyName, isNot(MusicPluginVaultKey.storageKey));
  });
}

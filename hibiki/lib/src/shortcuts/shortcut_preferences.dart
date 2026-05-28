import 'package:flutter/material.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

const String _prefKey = 'shortcut_bindings_json';

Future<void> loadShortcutRegistry(
  HibikiShortcutRegistry registry,
  ReaderHibikiSource source,
  TargetPlatform platform,
) async {
  registry.loadDefaults(platform);
  final String? json = source.getPreference<String?>(
    key: _prefKey,
    defaultValue: null,
  );
  if (json != null) {
    registry.loadFromJsonString(json, platform);
  }
}

Future<void> saveShortcutRegistry(
  HibikiShortcutRegistry registry,
  ReaderHibikiSource source,
) async {
  await source.setPreference<String>(
    key: _prefKey,
    value: registry.toJsonString(),
  );
}

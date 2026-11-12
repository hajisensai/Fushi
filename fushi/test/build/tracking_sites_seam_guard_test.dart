import 'dart:io';

import 'package:test/test.dart';

/// The tracking sites besides Bangumi (AniList, MangaBaka, ...) are tracking
/// plugins only (docs/specs/2026-11-10-tracking-plugins.md). The app and the
/// engine ship no built-in code for them: no `media/tracking/sites/` folder
/// and nothing importing one. Bangumi is the one built-in site (the bundled
/// plugin, plus the Dart provider where plugins are not available).
///
/// Run from `fushi/`.
void main() {
  const List<String> siteFolders = <String>[
    '../packages/fushi_engine/lib/media/tracking/sites',
    'lib/src/media/tracking/sites',
  ];
  final RegExp siteImport = RegExp(
    r'''^\s*(?:import|export)\s+['"][^'"]*media/tracking/(?:sites/|tracking_sites\.dart|tracking_site_sections\.dart)''',
    multiLine: true,
  );

  test('no built-in tracking site folder exists', () {
    for (final String folder in siteFolders) {
      expect(
        Directory(folder).existsSync(),
        isFalse,
        reason: '$folder: add the site as a tracking plugin instead',
      );
    }
  });

  test('nothing imports a built-in tracking site', () {
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final String root in <String>[
      'lib',
      'test',
      '../packages/fushi_engine/lib',
      '../packages/fushi_server/lib',
      '../packages/fushi_cli/lib',
    ]) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        scanned++;
        if (siteImport.hasMatch(entity.readAsStringSync())) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }
    }
    expect(scanned, greaterThan(1000), reason: 'the scan found the sources');
    expect(offenders, isEmpty);
  });
}

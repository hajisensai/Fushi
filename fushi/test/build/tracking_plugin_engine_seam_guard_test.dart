import 'dart:io';

import 'package:test/test.dart';

/// The tracking code reaches the shared sandbox engine (`package:fushi_music`)
/// through `tracking_plugin_engine.dart` only, so the engine can move to its
/// own crate without touching the rest (spec
/// `docs/specs/2026-11-10-tracking-plugins.md` §5). Run from `fushi/`.
void main() {
  const String seam =
      'lib/src/media/tracking/plugin/tracking_plugin_engine.dart';
  final RegExp engineImport = RegExp(
    r'''^\s*(?:import|export)\s+['"]package:fushi_music/''',
    multiLine: true,
  );

  test('only tracking_plugin_engine.dart imports package:fushi_music', () {
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity entity in Directory(
      'lib/src/media/tracking',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String path = entity.path.replaceAll(r'\', '/');
      if (path == seam) continue;
      scanned++;
      if (engineImport.hasMatch(entity.readAsStringSync())) {
        offenders.add(path);
      }
    }
    expect(scanned, greaterThan(5), reason: 'the scan found the sources');
    expect(offenders, isEmpty);
    expect(
      engineImport.hasMatch(File(seam).readAsStringSync()),
      isTrue,
      reason: 'the seam file is where the engine is used',
    );
  });
}

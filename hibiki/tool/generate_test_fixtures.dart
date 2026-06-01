import 'dart:io';

import 'test_flow/test_fixture_generator.dart';

Future<void> main(List<String> args) async {
  String outputDir = '../.codex-test/fixtures';
  for (final String arg in args) {
    if (arg.startsWith('--output=')) {
      outputDir = arg.substring('--output='.length);
    } else {
      stderr.writeln('Unknown argument: $arg');
      exitCode = 64;
      return;
    }
  }

  final FixtureGenerationResult result =
      await generateComprehensiveFixtures(outputDir: outputDir);
  stdout
    ..writeln('marker.epub: ${result.markerEpub.path}')
    ..writeln('test-yomitan.zip: ${result.dictionaryZip.path}')
    ..writeln('test-font.ttf: ${result.fontFile.path}');
}

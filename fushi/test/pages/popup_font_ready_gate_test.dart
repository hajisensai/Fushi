import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('popup reveal waits for configured custom fonts', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/pages/popup_font_ready_gate_test.js');
    expect(jsTest.existsSync(), isTrue);
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'font-ready reveal behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  test('popup and host keep the custom-font reveal contract wired', () {
    final String popup = File('assets/popup/popup.js').readAsStringSync();
    expect(popup, contains('document.fonts.ready'));
    expect(popup, contains('document.body.offsetWidth'));
    expect(popup, contains('generation !== window._renderGeneration'));

    final String injection = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();
    expect(
      injection,
      contains('window.__fushiDictionaryFontsConfigured ='),
    );
  });
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}

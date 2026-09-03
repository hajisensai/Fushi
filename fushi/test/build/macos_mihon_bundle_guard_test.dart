import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS debug launcher builds, bundles, and verifies the Mihon bridge',
      () {
    final String script = File('../script/build_and_run.sh').readAsStringSync();

    expect(script, contains('FUSHI_MIHON_ARCHS=host bash'));
    expect(
      script,
      contains(
        r'mihon_bundle="$app/Contents/Resources/mihon_bridge"',
      ),
    );
    expect(script, contains('tool/mihon/verify_desktop_runtime.sh'));
    expect(script, contains('m-extension-server.jar'));
    expect(script, contains(r'$mihon_host_runtime/bin/java'));
  });

  test('macOS Mihon JDK downloads are pinned and checksum verified', () {
    final String script =
        File('../tool/mihon/build_desktop_runtime.sh').readAsStringSync();

    expect(script, contains('corretto_version="21.0.12.8.1"'));
    expect(script, contains('corretto.aws/downloads/resources'));
    expect(script, contains('x64_archive_sha256='));
    expect(script, contains('arm64_archive_sha256='));
    expect(script, contains('shasum -a 256 --check'));
    expect(script, contains('--continue-at -'));
  });
}

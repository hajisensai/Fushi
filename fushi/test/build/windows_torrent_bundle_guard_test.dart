import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows Profile and Release bundles require the torrent runtime', () {
    final String source = File('windows/CMakeLists.txt').readAsStringSync();

    expect(
      source,
      contains(
        r'CMAKE_INSTALL_CONFIG_NAME MATCHES \"^(Profile|Release)$\"',
      ),
    );
    expect(source, contains('fushi_torrent_ffi.dll'));
    expect(source, contains('torrent-rasterbar.dll'));
    expect(source, contains('libssl-3-x64.dll'));
    expect(source, contains('libcrypto-3-x64.dll'));
    expect(source, contains('message(FATAL_ERROR'));
    expect(source, contains('build_windows_dll.ps1'));
  });
}

// Regression test for the JIT crash behind PR #2422's random flutter_tester
// SIGSEGV, plus a canary that tells us when the Dart SDK has fixed it.
//
// Both run test/fixtures/deopt_fill.dart in a separate `dart` process: the raw
// variant takes the whole process down, which must not happen inside the test
// runner.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) {
    fail('FLUTTER_ROOT is not set; cannot locate the SDK dart executable');
  }
  final String exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final File dart = File(
    '$flutterRoot/bin/cache/dart-sdk/bin/$exe'.replaceAll('\\', '/'),
  );
  if (!dart.existsSync()) fail('SDK dart not found at ${dart.path}');
  return dart.path;
}

Future<ProcessResult> _runFixture(String mode) {
  // The package config of the pub workspace (packages/<pkg> -> ../../).
  final String packages = File(
    '../../.dart_tool/package_config.json',
  ).absolute.path;
  return Process.run(_dartExecutable(), <String>[
    '--packages=$packages',
    'test/fixtures/deopt_fill.dart',
    mode,
  ]);
}

void main() {
  test(
    'views made by asTypedListOutOfLine survive deoptimization of the caller',
    () async {
      final ProcessResult result = await _runFixture('outOfLine');
      expect(
        result.exitCode,
        0,
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect((result.stdout as String).trim(), 'ok');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'canary: the SDK still mis-materializes a sunk asTypedList view on deopt',
    () async {
      final ProcessResult result = await _runFixture('raw');
      // Must be the VM's own crash dump at the view store, not any other
      // failure of the fixture (that would make the canary pass vacuously).
      expect(
        result.stderr as String,
        allOf(contains('===== CRASH ====='), contains('_External')),
        reason:
            'The raw asTypedList pattern no longer crashes on this Dart SDK '
            '(${Platform.version}). The VM bug that fushi_ffi_view works around '
            'looks fixed: switch the call sites back to asTypedList, delete '
            'packages/fushi_ffi_view and '
            'fushi/test/build/ffi_typed_list_view_guard_test.dart.\n'
            'stdout: ${result.stdout}',
      );
      expect(result.stdout as String, isNot(contains('ok')));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

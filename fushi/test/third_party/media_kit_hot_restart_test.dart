import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart' show maskComments;

const String _patchPath =
    '../ci/patches/hosted/media_kit-1.2.6/lib/src/player/native/core/initializer.dart';

String? _nativeLibrary() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final File library = File(
    override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll',
  );
  return library.existsSync() ? library.absolute.path : null;
}

Future<ProcessResult> _runProbe(String library, String mode) async {
  // flutter_tester does not implement Isolate.packageConfig. This app is a
  // workspace member, so use the same root config resolved by flutter test.
  final Uri config = File('../.dart_tool/package_config.json').absolute.uri;
  final Map<String, dynamic> packages =
      jsonDecode(await File.fromUri(config).readAsString())
          as Map<String, dynamic>;
  final List<dynamic> entries = packages['packages'] as List<dynamic>;
  final Map<String, dynamic> flutter = entries
      .cast<Map<String, dynamic>>()
      .singleWhere((Map<String, dynamic> entry) => entry['name'] == 'flutter');
  final String flutterRootPath = flutter['rootUri'] as String;
  final Uri flutterRoot = config.resolve(
    flutterRootPath.endsWith('/') ? flutterRootPath : '$flutterRootPath/',
  );
  final String dart = flutterRoot
      .resolve('../../bin/cache/dart-sdk/bin/dart.exe')
      .toFilePath();
  final Process process = await Process.start(dart, <String>[
    '--packages=${config.toFilePath()}',
    File(
      'test/third_party/fixtures/media_kit_isolate_exit_probe.dart',
    ).absolute.path,
    library,
    mode,
  ]);
  final Future<String> output = process.stdout.transform(utf8.decoder).join();
  final Future<String> errors = process.stderr.transform(utf8.decoder).join();
  try {
    final int code = await process.exitCode.timeout(
      const Duration(seconds: 25),
    );
    return ProcessResult(process.pid, code, await output, await errors);
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    throw StateError(
      'libmpv $mode probe timed out\n${await output}\n${await errors}',
    );
  }
}

void main() {
  test('BUG-3003: create/dispose share the Windows debug event backend', () {
    final String code = maskComments(File(_patchPath).readAsStringSync());
    expect(
      code,
      contains('isExecmemRestricted || (Platform.isWindows && kDebugMode)'),
    );
    expect(RegExp(r'if\s*\(!_useIsolate\)').allMatches(code), hasLength(2));
    expect(code, contains('InitializerIsolate().create(callback'));
    expect(code, contains('InitializerIsolate().dispose(mpv, ctx)'));
    final String lock = File('../pubspec.lock').readAsStringSync();
    expect(
      RegExp(
        r'  media_kit:\r?\n(?:(?!\r?\n  \w)[\s\S])*',
      ).firstMatch(lock)?.group(0),
      contains('version: "1.2.6"'),
      reason:
          'The initializer patch must track the resolved media_kit version.',
    );
  });

  final String? library = _nativeLibrary();
  final String? skip = !Platform.isWindows
      ? 'Windows debug libmpv lifecycle regression'
      : library == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;
  for (final String mode in <String>['kill', 'dispose']) {
    test(
      'BUG-3003: native wakeup/quit survives owner $mode',
      () async {
        final ProcessResult result = await _runProbe(library!, mode);
        final String evidence = '${result.stdout}\n${result.stderr}';
        expect(result.exitCode, 0, reason: evidence);
        expect(result.stdout, contains('OWNER EXITED'), reason: evidence);
        expect(result.stdout, contains('WORKERS EXITED'), reason: evidence);
        expect(result.stdout, contains('EVENTS DRAINED'), reason: evidence);
        expect(result.stdout, contains('WAKEUP RETURNED'), reason: evidence);
        expect(result.stdout, contains('QUIT RETURNED'), reason: evidence);
        expect(result.stdout, contains('PASS $mode'), reason: evidence);
        if (mode == 'dispose') {
          expect(result.stdout, contains('DISPOSE RETURNED'), reason: evidence);
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 35)),
    );
  }
}

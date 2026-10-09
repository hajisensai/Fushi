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

Future<({String dart, String kernel})> _compileProbe() async {
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
  final Directory tempRoot = Directory.systemTemp.absolute;
  final Directory output = tempRoot.createTempSync('fushi-libmpv-probe-');
  addTearDown(() {
    if (output.parent.absolute.path != tempRoot.path) {
      throw StateError('Refusing to remove a probe directory outside temp');
    }
    output.deleteSync(recursive: true);
  });
  final String kernel = '${output.path}/probe.dill';
  final ProcessResult result = await _runBoundedProcess(
    dart,
    <String>[
      'compile',
      'kernel',
      '--packages=${config.toFilePath()}',
      '--output=$kernel',
      File(
        'test/third_party/fixtures/media_kit_isolate_exit_probe.dart',
      ).absolute.path,
    ],
    stage: 'compile probe kernel',
    deadline: const Duration(seconds: 90),
  );
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  expect(File(kernel).existsSync(), isTrue);
  return (dart: dart, kernel: kernel);
}

/// Keep compiler startup outside the native deadline, and retain partial output
/// even when a subprocess never closes its pipes. Only this Process's tree is
/// terminated; a teardown also owns it if the enclosing test times out first.
Future<ProcessResult> _runBoundedProcess(
  String executable,
  List<String> arguments, {
  required String stage,
  required Duration deadline,
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  final Process process = await Process.start(executable, arguments);
  final StringBuffer output = StringBuffer();
  final StringBuffer errors = StringBuffer();
  final List<String> problems = <String>[];
  final Completer<void> outputDone = Completer<void>();
  final Completer<void> errorsDone = Completer<void>();
  StreamSubscription<String> capture(
    Stream<List<int>> stream,
    StringBuffer buffer,
    Completer<void> done,
  ) => stream
      .transform(utf8.decoder)
      .listen(
        buffer.write,
        onError: (Object error, StackTrace stack) {
          problems.add('pipe: $error');
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
  final StreamSubscription<String> out = capture(
    process.stdout,
    output,
    outputDone,
  );
  final StreamSubscription<String> err = capture(
    process.stderr,
    errors,
    errorsDone,
  );
  bool exited = false;
  final Future<int> exitCode = process.exitCode.then((int code) {
    exited = true;
    return code;
  });
  Future<void>? stopping;
  Future<void> stop() => stopping ??= () async {
    if (exited) return;
    // dart compile kernel may own a compiler subprocess. The PID comes only
    // from Process.start above; never enumerate or terminate other Dart apps.
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill.exe', <String>[
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 3));
      } on Object catch (error) {
        errors.writeln('tree cleanup: $error');
      }
    }
    if (!exited) process.kill();
    await exitCode.timeout(const Duration(seconds: 2));
  }();
  addTearDown(stop);
  int? code;
  try {
    code = await exitCode.timeout(deadline);
  } on Object catch (error) {
    problems.add('$stage: $error');
  } finally {
    try {
      await stop();
    } on Object catch (error) {
      problems.add('process cleanup: $error');
    }
    try {
      await Future.wait<void>(<Future<void>>[
        outputDone.future,
        errorsDone.future,
      ]).timeout(const Duration(seconds: 2));
    } on Object catch (error) {
      problems.add('output drain: $error');
    }
    try {
      await Future.wait<void>(<Future<void>>[
        out.cancel(),
        err.cancel(),
      ]).timeout(const Duration(seconds: 1));
    } on Object catch (error) {
      problems.add('pipe cleanup: $error');
    }
  }
  if (problems.isNotEmpty) {
    throw StateError(
      '$stage pid=${process.pid} elapsed=${elapsed.elapsed}\n'
      '${problems.join('\n')}\nstdout:\n$output\nstderr:\n$errors',
    );
  }
  return ProcessResult(
    process.pid,
    code!,
    output.toString(),
    errors.toString(),
  );
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
  group(
    'precompiled native libmpv lifecycle',
    () {
      late ({String dart, String kernel}) probe;
      setUpAll(() async {
        // Compile once under a separate 90s deadline. Native tests below retain
        // their 25s execution deadline and 35s enclosing test timeout.
        probe = await _compileProbe();
      });
      for (final String mode in <String>['kill', 'dispose']) {
        test('BUG-3003: native wakeup/quit survives owner $mode', () async {
          final ProcessResult result = await _runBoundedProcess(
            probe.dart,
            <String>[probe.kernel, library!, mode],
            stage: 'libmpv $mode native probe',
            deadline: const Duration(seconds: 25),
          );
          final String evidence = '${result.stdout}\n${result.stderr}';
          expect(result.exitCode, 0, reason: evidence);
          expect(result.stdout, contains('OWNER EXITED'), reason: evidence);
          expect(result.stdout, contains('WORKERS EXITED'), reason: evidence);
          expect(result.stdout, contains('EVENTS DRAINED'), reason: evidence);
          expect(result.stdout, contains('WAKEUP RETURNED'), reason: evidence);
          expect(result.stdout, contains('QUIT RETURNED'), reason: evidence);
          expect(result.stdout, contains('PASS $mode'), reason: evidence);
          if (mode == 'dispose') {
            expect(
              result.stdout,
              contains('DISPOSE RETURNED'),
              reason: evidence,
            );
          }
        }, timeout: const Timeout(Duration(seconds: 35)));
      }
    },
    skip: skip,
  );
}

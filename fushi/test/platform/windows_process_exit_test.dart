import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fushi/src/platform/windows_process_exit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/source_guard.dart' show maskComments;

typedef _OpenMutexWNative =
    IntPtr Function(
      Uint32 dwDesiredAccess,
      Int32 bInheritHandle,
      Pointer<Utf16> lpName,
    );
typedef _OpenMutexWDart =
    int Function(
      int dwDesiredAccess,
      int bInheritHandle,
      Pointer<Utf16> lpName,
    );
typedef _WaitForSingleObjectNative =
    Uint32 Function(IntPtr hHandle, Uint32 dwMilliseconds);
typedef _WaitForSingleObjectDart =
    int Function(int hHandle, int dwMilliseconds);
typedef _ReleaseMutexNative = Int32 Function(IntPtr hMutex);
typedef _ReleaseMutexDart = int Function(int hMutex);
typedef _CloseHandleNative = Int32 Function(IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

const int _synchronizeAccess = 0x00100000;
const int _waitAbandoned = 0x00000080;
const int _waitTimeout = 0x00000102;
const int _errorFileNotFound = 2;

String _dartExecutable() {
  final String resolved = Platform.resolvedExecutable;
  if (p.basename(resolved).toLowerCase() == 'dart.exe' &&
      File(resolved).existsSync()) {
    return resolved;
  }
  Directory dir = File(resolved).parent;
  for (int i = 0; i < 12; i++) {
    if (p.basename(dir.path) == 'cache') {
      final String candidate = p.join(
        dir.path,
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      if (File(candidate).existsSync()) return candidate;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final String candidate = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError('找不到 dart 可执行文件（resolvedExecutable=$resolved）');
}

String _packageConfigPath() {
  final File workspaceConfig = File('../.dart_tool/package_config.json');
  if (workspaceConfig.existsSync()) return workspaceConfig.absolute.path;
  final File localConfig = File('.dart_tool/package_config.json');
  if (localConfig.existsSync()) return localConfig.absolute.path;
  throw StateError('找不到 package_config.json（cwd=${Directory.current.path}）');
}

String _escapeDartString(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

void main() {
  group('exitProcessForPlatform 分派逻辑', () {
    test('isWindows 为 true 且 TerminateProcess 返回 true 时不调 fallbackExit', () {
      final List<int> terminated = <int>[];
      final List<int> fallbacks = <int>[];

      exitProcessForPlatform(
        0,
        isWindows: true,
        terminateWindowsProcess: (int code) {
          terminated.add(code);
          return true;
        },
        fallbackExit: fallbacks.add,
      );

      expect(terminated, <int>[0]);
      expect(fallbacks, isEmpty);
    });

    test('isWindows 为 true 且 TerminateProcess 返回 false 时回退 fallbackExit', () {
      final List<int> terminated = <int>[];
      final List<int> fallbacks = <int>[];

      exitProcessForPlatform(
        7,
        isWindows: true,
        terminateWindowsProcess: (int code) {
          terminated.add(code);
          return false;
        },
        fallbackExit: fallbacks.add,
      );

      expect(terminated, <int>[7]);
      expect(fallbacks, <int>[7]);
    });

    test('isWindows 为 true 且 TerminateProcess 抛异常时回退 fallbackExit', () {
      final List<int> fallbacks = <int>[];

      exitProcessForPlatform(
        9,
        isWindows: true,
        terminateWindowsProcess: (int code) => throw StateError('kernel32 err'),
        fallbackExit: fallbacks.add,
      );

      expect(fallbacks, <int>[9]);
    });

    test('isWindows 为 false 时跳过 TerminateProcess 并直接调 fallbackExit', () {
      final List<int> terminated = <int>[];
      final List<int> fallbacks = <int>[];

      exitProcessForPlatform(
        3,
        isWindows: false,
        terminateWindowsProcess: (int code) {
          terminated.add(code);
          return true;
        },
        fallbackExit: fallbacks.add,
      );

      expect(terminated, isEmpty);
      expect(fallbacks, <int>[3]);
    });

    test('AppExitCoordinator._systemExit 确实接入 exitProcessForPlatform', () {
      final String src = maskComments(
        File('lib/src/platform/app_exit_coordinator.dart').readAsStringSync(),
      );
      final int fnStart = src.indexOf('void _systemExit(int code)');
      expect(fnStart, isNonNegative);
      final int nextClass = src.indexOf('class AppExitCoordinator', fnStart);
      expect(nextClass, greaterThan(fnStart));
      final String fnSlice = src.substring(fnStart, nextClass);
      expect(fnSlice, contains('exitProcessForPlatform('));
    });
  });

  group(
    'Windows 真实子进程 TerminateProcess 验证',
    skip: Platform.isWindows
        ? null
        : 'Windows-only Win32 TerminateProcess test',
    () {
      late Directory tempDir;
      late String dartExe;
      late String packageConfig;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('fushi_win_exit_test_');
        dartExe = _dartExecutable();
        packageConfig = _packageConfigPath();
      });

      tearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows 偶发短暂占用。
        }
      });

      Future<({int exitCode, String stdoutText, String stderrText})>
      runExitCodeProbe(int code) async {
        final File script = File(p.join(tempDir.path, 'probe_$code.dart'));
        script.writeAsStringSync('''
import 'dart:io';
import 'package:fushi/src/platform/windows_process_exit.dart';

void main() {
  terminateCurrentWindowsProcess($code);
  stdout.writeln('UNREACHABLE');
  exit(99);
}
''');
        final Process process = await Process.start(dartExe, <String>[
          '--packages=$packageConfig',
          script.path,
        ]);
        final Future<String> stdoutFuture = process.stdout
            .transform(utf8.decoder)
            .join();
        final Future<String> stderrFuture = process.stderr
            .transform(utf8.decoder)
            .join();
        try {
          final int exitCode = await process.exitCode.timeout(
            const Duration(seconds: 15),
          );
          final String stdoutText = await stdoutFuture.timeout(
            const Duration(seconds: 5),
          );
          final String stderrText = await stderrFuture.timeout(
            const Duration(seconds: 5),
          );
          return (
            exitCode: exitCode,
            stdoutText: stdoutText,
            stderrText: stderrText,
          );
        } finally {
          process.kill(ProcessSignal.sigkill);
        }
      }

      test('terminateCurrentWindowsProcess(0) 立即以 0 退出且不执行后续代码', () async {
        final ({int exitCode, String stdoutText, String stderrText}) res =
            await runExitCodeProbe(0);
        expect(res.exitCode, 0, reason: res.stderrText);
        expect(res.stdoutText, isNot(contains('UNREACHABLE')));
      });

      test('terminateCurrentWindowsProcess(42) 立即以 42 退出且不执行后续代码', () async {
        final ({int exitCode, String stdoutText, String stderrText}) res =
            await runExitCodeProbe(42);
        expect(res.exitCode, 42, reason: res.stderrText);
        expect(res.stdoutText, isNot(contains('UNREACHABLE')));
      });

      test(
        '子进程持有名为单实例模式的命名互斥量时 TerminateProcess 后内核立即释放为 WAIT_ABANDONED 且可彻底销毁',
        () async {
          final String mutexName =
              'Local\\FushiTerminateProcessTest_${pid}_${DateTime.now().microsecondsSinceEpoch}';
          final File script = File(p.join(tempDir.path, 'mutex_probe.dart'));
          script.writeAsStringSync('''
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:fushi/src/platform/windows_process_exit.dart';

typedef _CreateMutexWNative = IntPtr Function(
  Pointer<Void> lpMutexAttributes,
  Int32 bInitialOwner,
  Pointer<Utf16> lpName,
);
typedef _CreateMutexWDart = int Function(
  Pointer<Void> lpMutexAttributes,
  int bInitialOwner,
  Pointer<Utf16> lpName,
);

Future<void> main() async {
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final _CreateMutexWDart createMutexW = kernel32
      .lookupFunction<_CreateMutexWNative, _CreateMutexWDart>('CreateMutexW');
  final Pointer<Utf16> namePtr = '${_escapeDartString(mutexName)}'.toNativeUtf16();
  final int handle = createMutexW(nullptr, 1, namePtr);
  if (handle == 0) {
    stderr.writeln('CreateMutexW failed');
    exit(2);
  }
  stdout.writeln('LOCKED');
  await stdout.flush();
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  terminateCurrentWindowsProcess(0);
  stdout.writeln('UNREACHABLE');
  exit(99);
}
''');

          final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
          final _OpenMutexWDart openMutexW = kernel32
              .lookupFunction<_OpenMutexWNative, _OpenMutexWDart>('OpenMutexW');
          final _WaitForSingleObjectDart waitForSingleObject = kernel32
              .lookupFunction<
                _WaitForSingleObjectNative,
                _WaitForSingleObjectDart
              >('WaitForSingleObject');
          final _ReleaseMutexDart releaseMutex = kernel32
              .lookupFunction<_ReleaseMutexNative, _ReleaseMutexDart>(
                'ReleaseMutex',
              );
          final _CloseHandleDart closeHandle = kernel32
              .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
                'CloseHandle',
              );
          final _GetLastErrorDart getLastError = kernel32
              .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
                'GetLastError',
              );

          final Process process = await Process.start(dartExe, <String>[
            '--packages=$packageConfig',
            script.path,
          ]);
          final Stream<String> stdoutLines = process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter());
          final Future<String> stderrFuture = process.stderr
              .transform(utf8.decoder)
              .join();
          final Pointer<Utf16> namePtr = mutexName.toNativeUtf16();
          int mutexHandle = 0;
          bool acquired = false;
          bool released = false;
          bool closed = false;

          try {
            final Completer<void> lockedCompleter = Completer<void>();
            final List<String> extraLines = <String>[];
            final StreamSubscription<String> sub = stdoutLines.listen((
              String line,
            ) {
              if (line == 'LOCKED' && !lockedCompleter.isCompleted) {
                lockedCompleter.complete();
              } else {
                extraLines.add(line);
              }
            });
            addTearDown(sub.cancel);

            await lockedCompleter.future.timeout(const Duration(seconds: 15));

            mutexHandle = openMutexW(_synchronizeAccess, 0, namePtr);
            expect(mutexHandle, isNot(0), reason: '子进程持有期间 OpenMutexW 必须成功');
            expect(
              waitForSingleObject(mutexHandle, 0),
              _waitTimeout,
              reason: '子进程未退出前互斥量应处于被占用状态（WAIT_TIMEOUT）',
            );

            process.stdin.writeln('GO');
            await process.stdin.flush();

            final int exitCode = await process.exitCode.timeout(
              const Duration(seconds: 15),
            );
            final String stderrText = await stderrFuture.timeout(
              const Duration(seconds: 5),
            );
            expect(exitCode, 0, reason: stderrText);
            expect(extraLines, isNot(contains('UNREACHABLE')));

            final int afterExitWait = waitForSingleObject(mutexHandle, 5000);
            expect(
              afterExitWait,
              _waitAbandoned,
              reason:
                  'TerminateProcess 终止持有线程后，SingleInstanceMutex 必须立即变为 WAIT_ABANDONED',
            );
            acquired = true;

            released = releaseMutex(mutexHandle) != 0;
            expect(released, isTrue);
            expect(closeHandle(mutexHandle), isNot(0));
            closed = true;

            final int reopened = openMutexW(_synchronizeAccess, 0, namePtr);
            final int err = getLastError();
            if (reopened != 0) {
              closeHandle(reopened);
            }
            expect(reopened, 0, reason: '所有句柄关闭后命名互斥量应从对象命名空间销毁');
            expect(err, _errorFileNotFound);
          } finally {
            if (mutexHandle != 0 && !closed) {
              if (acquired && !released) {
                releaseMutex(mutexHandle);
              }
              closeHandle(mutexHandle);
            }
            calloc.free(namePtr);
            process.kill(ProcessSignal.sigkill);
          }
        },
      );
    },
  );
}

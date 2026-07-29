import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Keeps the desktop Mihon sidecar inside the Hibiki process lifetime.
///
/// The normal shutdown path still asks M-Extension-Server to stop and then
/// terminates the exact retained [Process] if necessary. Windows additionally
/// needs an OS-level backstop because Hibiki deliberately uses a process-level
/// fast exit for desktop window closes: an asynchronous Dart cleanup callback
/// cannot be the sole owner of an external JVM in that path.
abstract interface class MihonChildProcessContainment {
  factory MihonChildProcessContainment.platform() {
    if (Platform.isWindows) return _WindowsJobContainment();
    if (Platform.isMacOS) return _MacOsProcessGroupContainment();
    return _NoopContainment();
  }

  /// Starts and attaches the sidecar before returning it to the runtime.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
  });

  /// Adds one exact child PID to this runtime's containment group.
  void attach(int pid);

  Future<bool> hasExited(Process process);

  /// Terminates the retained process or process group within bounded time.
  Future<void> terminate(Process process);

  /// Releases the containment group. On Windows this also terminates children
  /// that ignored graceful shutdown.
  Future<void> close();
}

class _NoopContainment implements MihonChildProcessContainment {
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
  }) =>
      Process.start(
        executable,
        arguments,
        environment: environment,
        mode: ProcessStartMode.normal,
      );

  @override
  void attach(int pid) {}

  @override
  Future<bool> hasExited(Process process) => _hasProcessExited(process);

  @override
  Future<void> terminate(Process process) async {
    if (await hasExited(process)) return;
    process.kill(ProcessSignal.sigterm);
    if (await _waitForProcessExit(
      process,
      const Duration(milliseconds: 700),
    )) {
      return;
    }
    process.kill(ProcessSignal.sigkill);
    await _waitForProcessExit(process, const Duration(milliseconds: 500));
  }

  @override
  Future<void> close() async {}
}

enum MihonPosixSignalResult { delivered, noSuchProcess, permissionDenied }

typedef MihonPosixGroupSignal = MihonPosixSignalResult Function(
  int processGroupId,
  ProcessSignal? signal,
);

/// Testable TERM -> bounded wait -> KILL state machine for a POSIX group.
@visibleForTesting
class MihonPosixProcessGroupController {
  MihonPosixProcessGroupController({
    required MihonPosixGroupSignal signalGroup,
    this.termWait = const Duration(milliseconds: 700),
    this.killWait = const Duration(milliseconds: 500),
    this.pollInterval = const Duration(milliseconds: 25),
  }) : _signalGroup = signalGroup;

  final MihonPosixGroupSignal _signalGroup;
  final Duration termWait;
  final Duration killWait;
  final Duration pollInterval;

  Future<void> terminate(int processGroupId) async {
    if (!await _processGroupExists(processGroupId)) return;
    _deliver(processGroupId, ProcessSignal.sigterm);
    if (await _waitForProcessGroupExit(processGroupId, termWait)) return;
    _deliver(processGroupId, ProcessSignal.sigkill);
    if (!await _waitForProcessGroupExit(processGroupId, killWait)) {
      throw StateError(
        'Mihon process group $processGroupId survived SIGKILL',
      );
    }
  }

  Future<bool> _processGroupExists(int processGroupId) async {
    return switch (_signalGroup(processGroupId, null)) {
      MihonPosixSignalResult.delivered => true,
      MihonPosixSignalResult.noSuchProcess => false,
      MihonPosixSignalResult.permissionDenied => throw StateError(
          'Permission denied probing Mihon process group $processGroupId',
        ),
    };
  }

  void _deliver(int processGroupId, ProcessSignal signal) {
    switch (_signalGroup(processGroupId, signal)) {
      case MihonPosixSignalResult.delivered ||
            MihonPosixSignalResult.noSuchProcess:
        return;
      case MihonPosixSignalResult.permissionDenied:
        throw StateError(
          'Permission denied signalling Mihon process group $processGroupId',
        );
    }
  }

  Future<bool> _waitForProcessGroupExit(
    int processGroupId,
    Duration timeout,
  ) async {
    final Stopwatch elapsed = Stopwatch()..start();
    do {
      if (!await _processGroupExists(processGroupId)) return true;
      if (elapsed.elapsed >= timeout) return false;
      await Future<void>.delayed(pollInterval);
    } while (true);
  }
}

class _MacOsProcessGroupContainment implements MihonChildProcessContainment {
  _MacOsProcessGroupContainment()
      : _controller = MihonPosixProcessGroupController(
          signalGroup: _signalProcessGroup,
        );

  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final _KillDart _kill =
      _libc.lookupFunction<_KillNative, _KillDart>('kill');
  static final _GetProcessGroupDart _getProcessGroup =
      _libc.lookupFunction<_GetProcessGroupNative, _GetProcessGroupDart>(
    'getpgid',
  );
  static final _ErrnoLocationDart _errnoLocation =
      _libc.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
    '__error',
  );

  static const int _eperm = 1;
  static const int _esrch = 3;

  // The detached shell is the session leader (PGID == its PID). It keeps the
  // token in the inherited environment, never argv or disk, and watches both
  // the original parent PID and its stable process start identity. If Hibiki
  // exits or that PID is reused, the supervisor signals its whole group.
  static const String _supervisorScript = r'''
set -eu
parent_pid="$1"
shift
parent_identity="$(ps -o lstart= -p "$parent_pid" 2>/dev/null || true)"
child_pid=""
shutdown_group() {
  trap - EXIT
  trap '' HUP INT TERM
  kill -TERM -- "-$$" 2>/dev/null || true
  remaining=10
  while [ "$remaining" -gt 0 ] && [ -n "$child_pid" ] &&
      kill -0 "$child_pid" 2>/dev/null; do
    sleep 0.1
    remaining=$((remaining - 1))
  done
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL -- "-$$" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown_group EXIT HUP INT TERM
"$@" &
child_pid="$!"
while kill -0 "$child_pid" 2>/dev/null; do
  current_identity="$(ps -o lstart= -p "$parent_pid" 2>/dev/null || true)"
  if [ -z "$parent_identity" ] || [ "$current_identity" != "$parent_identity" ]; then
    shutdown_group
  fi
  sleep 0.2
done
wait "$child_pid"
''';

  final MihonPosixProcessGroupController _controller;
  int? _processGroupId;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
  }) async {
    if (_processGroupId != null) {
      throw StateError('A Mihon process group is already attached');
    }
    final Process process = await Process.start(
      '/bin/sh',
      <String>[
        '-c',
        _supervisorScript,
        'hibiki-mihon-supervisor',
        '$pid',
        executable,
        ...arguments,
      ],
      environment: environment,
      mode: ProcessStartMode.detachedWithStdio,
    );
    // dart:io creates a new detached session. Verify the runtime contract
    // before retaining it: later negative-PGID signals are only safe when this
    // exact leader PID owns the group.
    final int actualProcessGroupId = _getProcessGroup(process.pid);
    if (actualProcessGroupId != process.pid) {
      process.kill(ProcessSignal.sigkill);
      final int error = actualProcessGroupId == -1 ? _errnoLocation().value : 0;
      throw StateError(
        'Detached Mihon leader PID ${process.pid} has PGID '
        '$actualProcessGroupId${error == 0 ? '' : ' (errno $error)'}',
      );
    }
    _processGroupId = process.pid;
    return process;
  }

  @override
  void attach(int pid) {
    if (_processGroupId != pid) {
      throw StateError(
        'macOS Mihon process leader PID $pid does not match '
        'PGID $_processGroupId',
      );
    }
  }

  @override
  Future<bool> hasExited(Process process) async {
    final int? processGroupId = _processGroupId;
    if (processGroupId == null) return true;
    return !_processGroupExists(processGroupId);
  }

  bool _processGroupExists(int processGroupId) {
    return switch (_signalProcessGroup(processGroupId, null)) {
      MihonPosixSignalResult.delivered => true,
      MihonPosixSignalResult.noSuchProcess => false,
      MihonPosixSignalResult.permissionDenied => throw StateError(
          'Permission denied probing Mihon process group $processGroupId',
        ),
    };
  }

  @override
  Future<void> terminate(Process process) async {
    final int? processGroupId = _processGroupId;
    if (processGroupId == null) return;
    await _controller.terminate(processGroupId);
    _processGroupId = null;
  }

  @override
  Future<void> close() async {
    final int? processGroupId = _processGroupId;
    if (processGroupId == null) return;
    await _controller.terminate(processGroupId);
    _processGroupId = null;
  }

  static MihonPosixSignalResult _signalProcessGroup(
    int processGroupId,
    ProcessSignal? signal,
  ) {
    final int result = _kill(
      -processGroupId,
      signal?.signalNumber ?? 0,
    );
    if (result == 0) return MihonPosixSignalResult.delivered;
    final int error = _errnoLocation().value;
    if (error == _esrch) return MihonPosixSignalResult.noSuchProcess;
    if (error == _eperm) return MihonPosixSignalResult.permissionDenied;
    throw OSError('killpg failed for Mihon process group', error);
  }
}

/// A private Windows Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
///
/// The job handle lives in the Hibiki process. Windows closes that handle even
/// when Flutter exits before an async teardown finishes, and the kernel then
/// terminates only the Java processes that this runtime explicitly assigned.
class _WindowsJobContainment implements MihonChildProcessContainment {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static const int _processTerminate = 0x0001;
  static const int _processSetQuota = 0x0100;
  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _jobObjectLimitKillOnJobClose = 0x00002000;

  // Hibiki's Windows target is x64. JOBOBJECT_EXTENDED_LIMIT_INFORMATION is
  // 144 bytes there, with BasicLimitInformation.LimitFlags at byte offset 16.
  static const int _extendedLimitInformationSizeX64 = 144;
  static const int _limitFlagsOffset = 16;

  late final _CreateJobObjectDart _createJobObject =
      _kernel32.lookupFunction<_CreateJobObjectNative, _CreateJobObjectDart>(
          'CreateJobObjectW');
  late final _SetInformationJobObjectDart _setInformationJobObject =
      _kernel32.lookupFunction<_SetInformationJobObjectNative,
          _SetInformationJobObjectDart>('SetInformationJobObject');
  late final _OpenProcessDart _openProcess = _kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
  late final _AssignProcessToJobObjectDart _assignProcessToJobObject =
      _kernel32.lookupFunction<_AssignProcessToJobObjectNative,
          _AssignProcessToJobObjectDart>('AssignProcessToJobObject');
  late final _CloseHandleDart _closeHandle = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  late final _GetLastErrorDart _getLastError = _kernel32
      .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');

  int? _jobHandle;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
  }) async {
    final Process process = await Process.start(
      executable,
      arguments,
      environment: environment,
      mode: ProcessStartMode.normal,
    );
    try {
      attach(process.pid);
      return process;
    } on Object {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  @override
  void attach(int pid) {
    if (sizeOf<IntPtr>() != 8) {
      throw UnsupportedError(
        'Mihon Windows process containment requires the x64 build',
      );
    }
    final int job = _jobHandle ?? _createConfiguredJob();
    final int process =
        _openProcess(_processTerminate | _processSetQuota, 0, pid);
    if (process == 0) {
      throw _WindowsApiException(
        'OpenProcess failed for Mihon child PID $pid',
        _getLastError(),
      );
    }
    try {
      if (_assignProcessToJobObject(job, process) == 0) {
        throw _WindowsApiException(
          'AssignProcessToJobObject failed for Mihon child PID $pid',
          _getLastError(),
        );
      }
    } finally {
      _closeHandle(process);
    }
  }

  int _createConfiguredJob() {
    final int job = _createJobObject(nullptr, nullptr);
    if (job == 0) {
      throw _WindowsApiException(
        'CreateJobObjectW failed for Mihon sidecar',
        _getLastError(),
      );
    }

    final Pointer<Uint8> information =
        calloc<Uint8>(_extendedLimitInformationSizeX64);
    try {
      information.elementAt(_limitFlagsOffset).cast<Uint32>().value =
          _jobObjectLimitKillOnJobClose;
      if (_setInformationJobObject(
            job,
            _jobObjectExtendedLimitInformation,
            information.cast<Void>(),
            _extendedLimitInformationSizeX64,
          ) ==
          0) {
        final int error = _getLastError();
        _closeHandle(job);
        throw _WindowsApiException(
          'SetInformationJobObject failed for Mihon sidecar',
          error,
        );
      }
      _jobHandle = job;
      return job;
    } finally {
      calloc.free(information);
    }
  }

  @override
  Future<bool> hasExited(Process process) => _hasProcessExited(process);

  @override
  Future<void> terminate(Process process) async {
    if (await hasExited(process)) return;
    process.kill(ProcessSignal.sigterm);
    if (await _waitForProcessExit(
      process,
      const Duration(milliseconds: 700),
    )) {
      return;
    }
    process.kill(ProcessSignal.sigkill);
    await _waitForProcessExit(process, const Duration(milliseconds: 500));
  }

  @override
  Future<void> close() async {
    final int? job = _jobHandle;
    _jobHandle = null;
    if (job != null) _closeHandle(job);
  }
}

Future<bool> _hasProcessExited(Process process) async {
  try {
    await process.exitCode.timeout(const Duration(milliseconds: 1));
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<bool> _waitForProcessExit(Process process, Duration timeout) async {
  try {
    await process.exitCode.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

class _WindowsApiException implements Exception {
  const _WindowsApiException(this.message, this.errorCode);

  final String message;
  final int errorCode;

  @override
  String toString() => '$message (Win32 error $errorCode)';
}

typedef _CreateJobObjectNative = IntPtr Function(
  Pointer<Void> jobAttributes,
  Pointer<Utf16> name,
);
typedef _CreateJobObjectDart = int Function(
  Pointer<Void> jobAttributes,
  Pointer<Utf16> name,
);
typedef _SetInformationJobObjectNative = Int32 Function(
  IntPtr job,
  Uint32 informationClass,
  Pointer<Void> information,
  Uint32 informationLength,
);
typedef _SetInformationJobObjectDart = int Function(
  int job,
  int informationClass,
  Pointer<Void> information,
  int informationLength,
);
typedef _OpenProcessNative = IntPtr Function(
  Uint32 desiredAccess,
  Int32 inheritHandle,
  Uint32 processId,
);
typedef _OpenProcessDart = int Function(
  int desiredAccess,
  int inheritHandle,
  int processId,
);
typedef _AssignProcessToJobObjectNative = Int32 Function(
  IntPtr job,
  IntPtr process,
);
typedef _AssignProcessToJobObjectDart = int Function(
  int job,
  int process,
);
typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _KillNative = Int32 Function(Int32 processId, Int32 signal);
typedef _KillDart = int Function(int processId, int signal);
typedef _GetProcessGroupNative = Int32 Function(Int32 processId);
typedef _GetProcessGroupDart = int Function(int processId);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

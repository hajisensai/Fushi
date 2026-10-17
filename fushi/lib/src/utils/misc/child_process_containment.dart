import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Keeps desktop helper processes inside the Fushi process lifetime.
///
/// The normal shutdown path may first ask a helper to stop gracefully. Windows
/// needs an OS-level backstop because Fushi deliberately uses a process-level
/// fast exit for desktop window closes: an asynchronous Dart cleanup callback
/// cannot be the sole owner of an external JVM in that path.
///
/// Attach the direct child before allowing it to spawn descendants; containment
/// cannot retroactively adopt processes that were created before attachment.
abstract interface class ChildProcessContainment {
  factory ChildProcessContainment.platform({
    Duration terminationTimeout = const Duration(seconds: 10),
  }) {
    if (terminationTimeout.isNegative) {
      throw ArgumentError.value(terminationTimeout, 'terminationTimeout');
    }
    if (Platform.isWindows) return _WindowsJobContainment(terminationTimeout);
    return _NoopContainment();
  }

  /// Adds one exact child PID to this runtime's containment group.
  void attach(int pid);

  /// Releases the containment group. On Windows this also terminates any child
  /// that ignored the graceful stop request.
  void close();

  /// On Windows, terminate the assigned process tree and wait until the kernel
  /// reports no active processes before releasing the job. Failure or timeout
  /// throws: callers must not treat it as permission to delete in-use files.
  /// Call this before [close]; close alone does not wait for process exit.
  /// Other platforms retain the existing no-op containment behavior.
  Future<void> terminateAndWait();
}

class _NoopContainment implements ChildProcessContainment {
  @override
  void attach(int pid) {}

  @override
  void close() {}

  @override
  Future<void> terminateAndWait() async {}
}

/// A private Windows Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
///
/// The job handle lives in the Fushi process. Windows closes that handle even
/// when Flutter exits before an async teardown finishes, and the kernel then
/// terminates only the assigned processes and descendants they subsequently start.
class _WindowsJobContainment implements ChildProcessContainment {
  _WindowsJobContainment(this._terminationTimeout);

  final Duration _terminationTimeout;
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static const int _processTerminate = 0x0001;
  static const int _processSetQuota = 0x0100;
  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _jobObjectLimitKillOnJobClose = 0x00002000;
  static const int _jobObjectBasicAccountingInformation = 1;
  static const int _basicAccountingInformationSize = 48;
  static const int _activeProcessesOffset = 40;

  // Fushi's Windows target is x64. JOBOBJECT_EXTENDED_LIMIT_INFORMATION is
  // 144 bytes there, with BasicLimitInformation.LimitFlags at byte offset 16.
  static const int _extendedLimitInformationSizeX64 = 144;
  static const int _limitFlagsOffset = 16;

  late final _CreateJobObjectDart _createJobObject = _kernel32
      .lookupFunction<_CreateJobObjectNative, _CreateJobObjectDart>(
        'CreateJobObjectW',
      );
  late final _SetInformationJobObjectDart _setInformationJobObject = _kernel32
      .lookupFunction<
        _SetInformationJobObjectNative,
        _SetInformationJobObjectDart
      >('SetInformationJobObject');
  late final _OpenProcessDart _openProcess = _kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
  late final _AssignProcessToJobObjectDart _assignProcessToJobObject = _kernel32
      .lookupFunction<
        _AssignProcessToJobObjectNative,
        _AssignProcessToJobObjectDart
      >('AssignProcessToJobObject');
  late final _CloseHandleDart _closeHandle = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  late final _GetLastErrorDart _getLastError = _kernel32
      .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  late final _TerminateJobObjectDart _terminateJobObject = _kernel32
      .lookupFunction<_TerminateJobObjectNative, _TerminateJobObjectDart>(
        'TerminateJobObject',
      );
  late final _QueryInformationJobObjectDart _queryInformationJobObject =
      _kernel32.lookupFunction<
        _QueryInformationJobObjectNative,
        _QueryInformationJobObjectDart
      >('QueryInformationJobObject');

  int? _jobHandle;
  Future<void>? _terminationFuture;

  @override
  void attach(int pid) {
    if (_terminationFuture != null) {
      throw StateError(
        'Cannot attach a process while containment is terminating',
      );
    }
    if (sizeOf<IntPtr>() != 8) {
      throw UnsupportedError(
        'Windows process containment requires a 64-bit build',
      );
    }
    final int job = _jobHandle ?? _createConfiguredJob();
    final int process = _openProcess(
      _processTerminate | _processSetQuota,
      0,
      pid,
    );
    if (process == 0) {
      throw _WindowsApiException(
        'OpenProcess failed for child PID $pid',
        _getLastError(),
      );
    }
    try {
      if (_assignProcessToJobObject(job, process) == 0) {
        throw _WindowsApiException(
          'AssignProcessToJobObject failed for child PID $pid',
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
        'CreateJobObjectW failed for child containment',
        _getLastError(),
      );
    }

    final Pointer<Uint8> information = calloc<Uint8>(
      _extendedLimitInformationSizeX64,
    );
    try {
      (information + _limitFlagsOffset).cast<Uint32>().value =
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
          'SetInformationJobObject failed for child containment',
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
  void close() {
    final int? job = _jobHandle;
    _jobHandle = null;
    if (job != null) _closeHandle(job);
  }

  @override
  Future<void> terminateAndWait() {
    final Future<void>? pending = _terminationFuture;
    if (pending != null) return pending;
    final int? job = _jobHandle;
    if (job == null) return Future<void>.value();
    final Future<void> next = _terminateAndDrain(job);
    _terminationFuture = next;
    return next.whenComplete(() {
      if (identical(_terminationFuture, next)) _terminationFuture = null;
    });
  }

  Future<void> _terminateAndDrain(int job) async {
    if (_terminateJobObject(job, 1) == 0) {
      throw _WindowsApiException('TerminateJobObject failed', _getLastError());
    }
    final Stopwatch elapsed = Stopwatch()..start();
    final Pointer<Uint8> accounting = calloc<Uint8>(
      _basicAccountingInformationSize,
    );
    try {
      while (true) {
        // A concurrent synchronous close cannot establish the stronger drain
        // guarantee. Fail closed rather than querying a potentially reused handle.
        if (_jobHandle != job) {
          throw StateError('Containment was closed before process-tree drain');
        }
        if (_queryInformationJobObject(
              job,
              _jobObjectBasicAccountingInformation,
              accounting.cast<Void>(),
              _basicAccountingInformationSize,
              nullptr,
            ) ==
            0) {
          throw _WindowsApiException(
            'QueryInformationJobObject failed',
            _getLastError(),
          );
        }
        final int active = (accounting + _activeProcessesOffset)
            .cast<Uint32>()
            .value;
        if (active == 0) {
          close();
          return;
        }
        if (elapsed.elapsed >= _terminationTimeout) {
          throw TimeoutException(
            'Child process containment still has $active active processes',
            _terminationTimeout,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      calloc.free(accounting);
    }
  }
}

class _WindowsApiException implements Exception {
  const _WindowsApiException(this.message, this.errorCode);

  final String message;
  final int errorCode;

  @override
  String toString() => '$message (Win32 error $errorCode)';
}

typedef _CreateJobObjectNative =
    IntPtr Function(Pointer<Void> jobAttributes, Pointer<Utf16> name);
typedef _CreateJobObjectDart =
    int Function(Pointer<Void> jobAttributes, Pointer<Utf16> name);
typedef _SetInformationJobObjectNative =
    Int32 Function(
      IntPtr job,
      Uint32 informationClass,
      Pointer<Void> information,
      Uint32 informationLength,
    );
typedef _SetInformationJobObjectDart =
    int Function(
      int job,
      int informationClass,
      Pointer<Void> information,
      int informationLength,
    );
typedef _OpenProcessNative =
    IntPtr Function(
      Uint32 desiredAccess,
      Int32 inheritHandle,
      Uint32 processId,
    );
typedef _OpenProcessDart =
    int Function(int desiredAccess, int inheritHandle, int processId);
typedef _AssignProcessToJobObjectNative =
    Int32 Function(IntPtr job, IntPtr process);
typedef _AssignProcessToJobObjectDart = int Function(int job, int process);
typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

typedef _TerminateJobObjectNative = Int32 Function(IntPtr job, Uint32 exitCode);
typedef _TerminateJobObjectDart = int Function(int job, int exitCode);

typedef _QueryInformationJobObjectNative =
    Int32 Function(
      IntPtr job,
      Uint32 informationClass,
      Pointer<Void> information,
      Uint32 informationLength,
      Pointer<Uint32> returnLength,
    );
typedef _QueryInformationJobObjectDart =
    int Function(
      int job,
      int informationClass,
      Pointer<Void> information,
      int informationLength,
      Pointer<Uint32> returnLength,
    );

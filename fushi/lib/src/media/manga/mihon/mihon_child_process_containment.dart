import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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
    return _NoopContainment();
  }

  /// Adds one exact child PID to this runtime's containment group.
  void attach(int pid);

  /// Releases the containment group. On Windows this also terminates any child
  /// that ignored the graceful stop request.
  void close();
}

class _NoopContainment implements MihonChildProcessContainment {
  @override
  void attach(int pid) {}

  @override
  void close() {}
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
  void close() {
    final int? job = _jobHandle;
    _jobHandle = null;
    if (job != null) _closeHandle(job);
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

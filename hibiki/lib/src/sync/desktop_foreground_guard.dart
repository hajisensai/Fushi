import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Windows foreground checks that [window_manager.isFocused] cannot always
/// express. Native child windows such as WebView can temporarily own focus while
/// the foreground window still belongs to this Hibiki process; in that state
/// calling show/focus asks Windows to flash the taskbar button.
abstract final class DesktopForegroundGuard {
  @visibleForTesting
  static bool? debugForegroundOwnedByCurrentProcess;

  @visibleForTesting
  static bool? debugForegroundOwnedByHibikiAppFamily;

  @visibleForTesting
  static bool? debugHiddenWindowsRunner;

  static bool get isHiddenWindowsRunner {
    final bool? override = debugHiddenWindowsRunner;
    if (override != null) return override;
    if (!Platform.isWindows) return false;
    return Platform.environment.containsKey('HIBIKI_TEST_HIDDEN');
  }

  static bool isForegroundOwnedByCurrentProcess() {
    final bool? override = debugForegroundOwnedByCurrentProcess;
    if (override != null) return override;
    if (!Platform.isWindows) return false;
    try {
      return _WindowsForegroundProbe.instance
          .isForegroundOwnedByCurrentProcess();
    } on Object {
      return false;
    }
  }

  static bool isForegroundOwnedByHibikiAppFamily() {
    final bool? override = debugForegroundOwnedByHibikiAppFamily;
    if (override != null) return override;
    if (!Platform.isWindows) return false;
    try {
      return _WindowsForegroundProbe.instance
          .isForegroundOwnedByHibikiAppFamily();
    } on Object {
      return false;
    }
  }
}

final class _WindowsForegroundProbe {
  _WindowsForegroundProbe._()
      : _getForegroundWindow = DynamicLibrary.open('user32.dll').lookupFunction<
            _GetForegroundWindowNative,
            _GetForegroundWindowDart>('GetForegroundWindow'),
        _getWindowThreadProcessId = DynamicLibrary.open('user32.dll')
            .lookupFunction<_GetWindowThreadProcessIdNative,
                _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId'),
        _getCurrentProcessId = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_GetCurrentProcessIdNative,
                _GetCurrentProcessIdDart>('GetCurrentProcessId'),
        _openProcess = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_OpenProcessNative, _OpenProcessDart>(
                'OpenProcess'),
        _queryFullProcessImageName = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_QueryFullProcessImageNameNative,
                _QueryFullProcessImageNameDart>('QueryFullProcessImageNameW'),
        _closeHandle = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
                'CloseHandle');

  static final _WindowsForegroundProbe instance = _WindowsForegroundProbe._();

  final _GetForegroundWindowDart _getForegroundWindow;
  final _GetWindowThreadProcessIdDart _getWindowThreadProcessId;
  final _GetCurrentProcessIdDart _getCurrentProcessId;
  final _OpenProcessDart _openProcess;
  final _QueryFullProcessImageNameDart _queryFullProcessImageName;
  final _CloseHandleDart _closeHandle;

  static const int _processQueryLimitedInformation = 0x1000;
  static const int _imagePathBufferLength = 32768;

  bool isForegroundOwnedByCurrentProcess() {
    try {
      return _foregroundProcessId() == _getCurrentProcessId();
    } on Object {
      return false;
    }
  }

  bool isForegroundOwnedByHibikiAppFamily() {
    final int? pid = _foregroundProcessId();
    if (pid == null) return false;
    if (pid == _getCurrentProcessId()) return true;
    final String? imagePath = _processImagePath(pid);
    if (imagePath == null) return false;
    return _looksLikeHibikiExecutable(imagePath);
  }

  int? _foregroundProcessId() {
    final int foregroundHwnd = _getForegroundWindow();
    if (foregroundHwnd == 0) return null;
    final Pointer<Uint32> foregroundPid = calloc<Uint32>();
    try {
      _getWindowThreadProcessId(foregroundHwnd, foregroundPid);
      final int pid = foregroundPid.value;
      return pid == 0 ? null : pid;
    } finally {
      calloc.free(foregroundPid);
    }
  }

  String? _processImagePath(int pid) {
    final int handle = _openProcess(
      _processQueryLimitedInformation,
      0,
      pid,
    );
    if (handle == 0) return null;
    final Pointer<Utf16> path = calloc<Uint16>(_imagePathBufferLength).cast();
    final Pointer<Uint32> length = calloc<Uint32>()
      ..value = _imagePathBufferLength;
    try {
      final int ok = _queryFullProcessImageName(handle, 0, path, length);
      if (ok == 0 || length.value == 0) return null;
      return path.toDartString(length: length.value);
    } finally {
      calloc.free(length);
      calloc.free(path);
      _closeHandle(handle);
    }
  }

  static bool _looksLikeHibikiExecutable(String imagePath) {
    final String foregroundExe = _basenameLower(imagePath);
    final String currentExe = _basenameLower(Platform.resolvedExecutable);
    if (foregroundExe == currentExe) return true;
    final String stem = foregroundExe.endsWith('.exe')
        ? foregroundExe.substring(0, foregroundExe.length - 4)
        : foregroundExe;
    return stem == 'hibiki' || stem.startsWith('hibiki-');
  }

  static String _basenameLower(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int slash = normalized.lastIndexOf('/');
    final String basename =
        slash >= 0 ? normalized.substring(slash + 1) : normalized;
    return basename.toLowerCase();
  }
}

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
  IntPtr hWnd,
  Pointer<Uint32> processId,
);
typedef _GetWindowThreadProcessIdDart = int Function(
  int hWnd,
  Pointer<Uint32> processId,
);

typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

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

typedef _QueryFullProcessImageNameNative = Int32 Function(
  IntPtr process,
  Uint32 flags,
  Pointer<Utf16> exeName,
  Pointer<Uint32> size,
);
typedef _QueryFullProcessImageNameDart = int Function(
  int process,
  int flags,
  Pointer<Utf16> exeName,
  Pointer<Uint32> size,
);

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

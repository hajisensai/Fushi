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
                _GetCurrentProcessIdDart>('GetCurrentProcessId');

  static final _WindowsForegroundProbe instance = _WindowsForegroundProbe._();

  final _GetForegroundWindowDart _getForegroundWindow;
  final _GetWindowThreadProcessIdDart _getWindowThreadProcessId;
  final _GetCurrentProcessIdDart _getCurrentProcessId;

  bool isForegroundOwnedByCurrentProcess() {
    try {
      final int foregroundHwnd = _getForegroundWindow();
      if (foregroundHwnd == 0) return false;
      final Pointer<Uint32> foregroundPid = calloc<Uint32>();
      try {
        _getWindowThreadProcessId(foregroundHwnd, foregroundPid);
        return foregroundPid.value == _getCurrentProcessId();
      } finally {
        calloc.free(foregroundPid);
      }
    } on Object {
      return false;
    }
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

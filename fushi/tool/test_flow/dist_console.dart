/// The no-pop-up guarantee of `tool/dist_test.dart` on Windows.
///
/// A console program started by a process that has no console gets a console
/// of its own, and with it a visible window (Windows Terminal or conhost)
/// that takes the focus. dist_test starts dozens of them (flutter.bat, git,
/// powershell, ssh), so it only runs attached to a console its children can
/// share; a windowless one (`CREATE_NO_WINDOW`, what agent shells use) is
/// fine. `GetConsoleWindow` cannot tell the two apart (it is null for both),
/// `GetConsoleProcessList` can: it returns 0 only without a console.
library;

import 'dart:ffi';
import 'dart:io';

/// True off Windows, and on Windows when this process has a console.
bool hasSharedConsole() {
  if (!Platform.isWindows) return true;
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final int Function(Pointer<Uint32>, int) getConsoleProcessList = kernel32
      .lookupFunction<
        Uint32 Function(Pointer<Uint32>, Uint32),
        int Function(Pointer<Uint32>, int)
      >('GetConsoleProcessList');
  final Pointer<Uint32> Function(int, int) localAlloc = kernel32
      .lookupFunction<
        Pointer<Uint32> Function(Uint32, IntPtr),
        Pointer<Uint32> Function(int, int)
      >('LocalAlloc');
  final int Function(Pointer<Uint32>) localFree = kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Uint32>),
        int Function(Pointer<Uint32>)
      >('LocalFree');
  // LPTR (zeroed); the count comes back even when it exceeds the buffer.
  final Pointer<Uint32> buffer = localAlloc(0x40, 16 * sizeOf<Uint32>());
  try {
    return getConsoleProcessList(buffer, 16) > 0;
  } finally {
    localFree(buffer);
  }
}

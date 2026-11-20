// Whether a process of this user is still running, by pid. For sweeping
// files a killed process left behind under its pid (heavy_offload_rival.dart).
//
// A pid the OS has since given to another live process of this user reads
// as alive: the caller's leftovers then wait for a later sweep, they are
// never taken for a live process's by mistake the other way round.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int _processQueryLimitedInformation = 0x1000;
const int _stillActive = 259;

DynamicLibrary? _kernel32Lib;
DynamicLibrary get _kernel32 =>
    _kernel32Lib ??= DynamicLibrary.open('kernel32.dll');

final int Function(int, int, int) _openProcess = _kernel32
    .lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');
final int Function(int, Pointer<Uint32>) _getExitCodeProcess = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetExitCodeProcess');
final int Function(int) _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

/// True while process [pid] runs. A pid that cannot be opened (gone, or
/// another user's) is not one of this user's running processes.
bool pidAlive(int pid) {
  if (pid <= 0) return false;
  if (!Platform.isWindows) {
    return Process.runSync('kill', <String>['-0', '$pid']).exitCode == 0;
  }
  final int handle = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (handle == 0) return false;
  final Pointer<Uint32> code = calloc<Uint32>();
  try {
    if (_getExitCodeProcess(handle, code) == 0) return true;
    return code.value == _stillActive;
  } finally {
    calloc.free(code);
    _closeHandle(handle);
  }
}

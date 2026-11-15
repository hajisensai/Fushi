// 附着（attach）到一个已在运行的 TyranoScript（Electron / NW.js）游戏时，DOM 数据源只能
// 复用游戏自己启动时带的 Chrome 远程调试端口：从目标进程的命令行读 `--remote-debugging-port`。
// 读不到就不启用 DOM 源——Fushi 不会替用户重启游戏去补这个参数。
//
// 命令行走 `NtQueryInformationProcess(ProcessCommandLineInformation)`（Windows 8.1+，
// 只要 PROCESS_QUERY_LIMITED_INFORMATION，跨 WOW64 也按调用方位宽返回），不读 PEB。
// 走裸 FFI 而不是 `package:win32`，理由同 `galgame_play_tracker.dart`（win32 在本仓只是
// 传递依赖）。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fushi/src/mining/galgame_library.dart'
    show parseGameLaunchArguments;
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_launch.dart'
    show parseRemoteDebuggingPort;

/// [pid] 的完整命令行；非 Windows / 进程不存在 / 无权限时返回 null。
String? readProcessCommandLine(int pid) {
  if (!Platform.isWindows || pid <= 0) return null;
  try {
    return _WindowsCommandLineReader.read(pid);
  } on Object {
    return null;
  }
}

/// 从 [pid] 的命令行里读出 Chrome 远程调试端口；读不到返回 null。
///
/// [commandLineReader] 仅供测试替换。
int? readRemoteDebuggingPortForPid(
  int pid, {
  String? Function(int pid) commandLineReader = readProcessCommandLine,
}) {
  final String? commandLine = commandLineReader(pid);
  if (commandLine == null || commandLine.trim().isEmpty) return null;
  return parseRemoteDebuggingPort(parseGameLaunchArguments(commandLine));
}

final class _UnicodeString extends Struct {
  @Uint16()
  external int length;

  @Uint16()
  external int maximumLength;

  external Pointer<Uint16> buffer;
}

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _NtQueryInformationProcessNative =
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>);
typedef _NtQueryInformationProcessDart =
    int Function(int, int, Pointer<Void>, int, Pointer<Uint32>);

abstract final class _WindowsCommandLineReader {
  static const int _processQueryLimitedInformation = 0x1000;
  static const int _processCommandLineInformation = 60;

  /// 命令行上限 32767 个 UTF-16 单元 + UNICODE_STRING 头；超过它的返回值不可信。
  static const int _maximumBufferBytes = 32767 * 2 + 64;

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _ntdll = DynamicLibrary.open('ntdll.dll');
  static final _OpenProcessDart _openProcess = _kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
  static final _CloseHandleDart _closeHandle = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  static final _NtQueryInformationProcessDart _query = _ntdll
      .lookupFunction<
        _NtQueryInformationProcessNative,
        _NtQueryInformationProcessDart
      >('NtQueryInformationProcess');

  static String? read(int pid) {
    final int handle = _openProcess(_processQueryLimitedInformation, 0, pid);
    if (handle == 0) return null;
    final Pointer<Uint32> needed = calloc<Uint32>();
    try {
      // 第一次只取所需长度（STATUS_INFO_LENGTH_MISMATCH），再按长度取。
      _query(handle, _processCommandLineInformation, nullptr, 0, needed);
      final int size = needed.value;
      if (size < sizeOf<_UnicodeString>() || size > _maximumBufferBytes) {
        return null;
      }
      final Pointer<Uint8> buffer = calloc<Uint8>(size);
      try {
        final int status = _query(
          handle,
          _processCommandLineInformation,
          buffer.cast(),
          size,
          needed,
        );
        if (status != 0) return null;
        final _UnicodeString header = buffer.cast<_UnicodeString>().ref;
        final int units = header.length ~/ 2;
        if (units == 0 || header.buffer == nullptr) return null;
        return header.buffer.cast<Utf16>().toDartString(length: units);
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(needed);
      _closeHandle(handle);
    }
  }
}

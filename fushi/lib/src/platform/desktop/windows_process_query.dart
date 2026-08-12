/// Windows 进程 / 注册表查询：**直接调 Win32 API，不生成子进程**。
///
/// ## 为什么存在（真实事故）
///
/// 卡巴斯基 Endpoint Security 的行为检测（PDM）把运行中的 hibiki.exe 判成
/// `PDM:Trojan.Win32.Generic`（威胁级别「高」，对象类型「进程」，直接结束进程）。
/// 没有任何文件特征命中——是**动作链**打分过阈：
///
///   未签名进程 → 联网拉 PE 落盘 → 生成 powershell 子进程枚举全机进程/模块
///   → 生成 reg.exe 读注册表 → 生成分离子进程静默执行刚下载的 PE → 自身退出
///
/// 这条链里「进程生成 powershell/reg 去问系统要信息」这几环是**可以完全消掉**的：
/// 同样的信息用 Win32 API 直接读，既不产生子进程、也不经过 LOLBin。本模块就是那层。
///
/// 换掉的调用（全部曾是 `Process.run`）：
/// - `powershell -Command "Get-CimInstance Win32_Process ..."` ×2（更新器诊断）
/// - `powershell -Command "(Get-Process -Id N).Path"` ×1（端口占用者）
/// - `tasklist /FI "PID eq N"` ×1（端口占用者进程名）
/// - `reg query ...` ×3（安装位置 ×2、系统代理 ×1）
///
/// ## 为什么比 tasklist / Get-CimInstance 更轻
///
/// 那两者取一次信息就把**全机每个进程**的元数据都拉一遍。本模块把「枚举」和
/// 「取完整路径」拆成两步：[enumerateWindowsProcesses] 只读快照里的 PID + image 名
/// （不 `OpenProcess` 任何进程），调用方按名字/PID 过滤完，再对**命中的少数几个**
/// 调 [windowsProcessImagePath]。全机 `OpenProcess` 从此不在正常路径上发生。
///
/// ## 为什么是裸 FFI 而不是 package:win32
///
/// win32 在本仓只是**传递依赖**，直接 import 会触发 `depend_on_referenced_packages`
/// （CI 把 warning 当致命）。仓库既有的 `galgame_play_tracker.dart` /
/// `desktop_foreground_guard.dart` / `selection_capture_ffi.dart` 都是这个范式。
///
/// 非 Windows 平台全部返回空/null，调用方无需自己 gate。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 一个进程的最小身份。[path] 为 null 表示没取到（权限不足 / 进程已退出 /
/// 调用方压根没要求解析路径——见 [enumerateWindowsProcesses] 的惰性契约）。
@immutable
class WindowsProcessEntry {
  const WindowsProcessEntry({
    required this.pid,
    required this.name,
    this.path,
  });

  final int pid;

  /// image 名（`PROCESSENTRY32W.szExeFile`），如 `fushi.exe`。
  final String name;

  /// exe 完整路径，取不到为 null。
  final String? path;

  WindowsProcessEntry withPath(String? resolved) => WindowsProcessEntry(
        pid: pid,
        name: name,
        path: resolved ?? path,
      );

  @override
  String toString() => 'WindowsProcessEntry(pid: $pid, name: $name, '
      'path: ${path ?? '<unresolved>'})';
}

/// 注册表根键。
enum WindowsRegistryRoot {
  currentUser(0x80000001),
  localMachine(0x80000002);

  const WindowsRegistryRoot(this.handle);

  final int handle;
}

// ── 公开 API ─────────────────────────────────────────────────────────────────

/// 枚举全机进程，**只取 PID + image 名**（不 `OpenProcess`，不解析路径）。
///
/// 路径按需单独取（[windowsProcessImagePath]）——这是本模块相对 `tasklist` /
/// `Get-CimInstance` 的核心差别：不为了拿几个进程的路径而访问全机每个进程。
List<WindowsProcessEntry> enumerateWindowsProcesses() {
  if (!Platform.isWindows) return const <WindowsProcessEntry>[];
  return _Win32.instance?.enumerateProcesses() ?? const <WindowsProcessEntry>[];
}

/// 取指定 PID 的 exe 完整路径；取不到返回 null。
String? windowsProcessImagePath(int pid) {
  if (!Platform.isWindows || pid <= 0) return null;
  return _Win32.instance?.processImagePath(pid);
}

/// 取指定 PID 的进程身份（含路径）；进程不存在返回 null。
WindowsProcessEntry? windowsProcessById(int pid) {
  if (!Platform.isWindows || pid <= 0) return null;
  for (final WindowsProcessEntry entry in enumerateWindowsProcesses()) {
    if (entry.pid == pid) {
      return entry.withPath(windowsProcessImagePath(pid));
    }
  }
  return null;
}

/// 按 image 名（大小写不敏感）筛进程，并为命中项解析完整路径。
///
/// 先筛后解析：只对命中的少数进程 `OpenProcess`。
List<WindowsProcessEntry> windowsProcessesByNames(Set<String> imageNames) {
  if (!Platform.isWindows || imageNames.isEmpty) {
    return const <WindowsProcessEntry>[];
  }
  final Set<String> wanted =
      imageNames.map((String name) => name.toLowerCase()).toSet();
  return <WindowsProcessEntry>[
    for (final WindowsProcessEntry entry in enumerateWindowsProcesses())
      if (wanted.contains(entry.name.toLowerCase()))
        entry.withPath(windowsProcessImagePath(entry.pid)),
  ];
}

/// 批量取若干 PID 的身份（含路径）。只枚举一次快照。
Map<int, WindowsProcessEntry> windowsProcessesByIds(Iterable<int> pids) {
  final Set<int> wanted = pids.where((int pid) => pid > 0).toSet();
  if (!Platform.isWindows || wanted.isEmpty) {
    return const <int, WindowsProcessEntry>{};
  }
  return <int, WindowsProcessEntry>{
    for (final WindowsProcessEntry entry in enumerateWindowsProcesses())
      if (wanted.contains(entry.pid))
        entry.pid: entry.withPath(windowsProcessImagePath(entry.pid)),
  };
}

/// 读注册表字符串值（`REG_SZ` / `REG_EXPAND_SZ`）；不存在或类型不符返回 null。
String? readWindowsRegistryString(
  WindowsRegistryRoot root,
  String subKey,
  String valueName,
) {
  if (!Platform.isWindows) return null;
  return _Win32.instance?.readRegistryString(root, subKey, valueName);
}

/// 读注册表 DWORD 值（`REG_DWORD`）；不存在或类型不符返回 null。
int? readWindowsRegistryDword(
  WindowsRegistryRoot root,
  String subKey,
  String valueName,
) {
  if (!Platform.isWindows) return null;
  return _Win32.instance?.readRegistryDword(root, subKey, valueName);
}

// ── Win32 绑定 ───────────────────────────────────────────────────────────────

/// 惰性单例：只在真 Windows 上 `DynamicLibrary.open`，失败则整体退化成 null
/// （调用方拿到空结果，与「查不到」同义，绝不抛到业务层）。
class _Win32 {
  _Win32._()
      : _openProcess =
            _kernel32.lookupFunction<_OpenProcessNative, _OpenProcessDart>(
                'OpenProcess'),
        _queryFullProcessImageName = _kernel32.lookupFunction<
            _QueryFullProcessImageNameNative,
            _QueryFullProcessImageNameDart>('QueryFullProcessImageNameW'),
        _createToolhelp32Snapshot = _kernel32.lookupFunction<
            _CreateToolhelp32SnapshotNative,
            _CreateToolhelp32SnapshotDart>('CreateToolhelp32Snapshot'),
        _process32First =
            _kernel32.lookupFunction<_Process32Native, _Process32Dart>(
                'Process32FirstW'),
        _process32Next = _kernel32
            .lookupFunction<_Process32Native, _Process32Dart>('Process32NextW'),
        _closeHandle =
            _kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
                'CloseHandle'),
        _regOpenKeyEx =
            _advapi32.lookupFunction<_RegOpenKeyExNative, _RegOpenKeyExDart>(
                'RegOpenKeyExW'),
        _regQueryValueEx = _advapi32.lookupFunction<_RegQueryValueExNative,
            _RegQueryValueExDart>('RegQueryValueExW'),
        _regCloseKey =
            _advapi32.lookupFunction<_RegCloseKeyNative, _RegCloseKeyDart>(
                'RegCloseKey');

  static _Win32? _cached;
  static bool _initialised = false;

  static _Win32? get instance {
    if (_initialised) return _cached;
    _initialised = true;
    try {
      _cached = _Win32._();
    } on Object catch (e) {
      debugPrint('[WindowsProcessQuery] Win32 bind failed: $e');
      _cached = null;
    }
    return _cached;
  }

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

  static const int _processQueryLimitedInformation = 0x1000;
  static const int _th32csSnapProcess = 0x00000002;
  static const int _invalidHandleValue = -1;
  static const int _imagePathBufferLength = 32768;
  static const int _errorSuccess = 0;
  static const int _keyRead = 0x20019;
  static const int _regSz = 1;
  static const int _regExpandSz = 2;
  static const int _regDword = 4;

  final _OpenProcessDart _openProcess;
  final _QueryFullProcessImageNameDart _queryFullProcessImageName;
  final _CreateToolhelp32SnapshotDart _createToolhelp32Snapshot;
  final _Process32Dart _process32First;
  final _Process32Dart _process32Next;
  final _CloseHandleDart _closeHandle;
  final _RegOpenKeyExDart _regOpenKeyEx;
  final _RegQueryValueExDart _regQueryValueEx;
  final _RegCloseKeyDart _regCloseKey;

  List<WindowsProcessEntry> enumerateProcesses() {
    final List<WindowsProcessEntry> result = <WindowsProcessEntry>[];
    int snapshot = _invalidHandleValue;
    Pointer<_ProcessEntry32W>? entry;
    try {
      snapshot = _createToolhelp32Snapshot(_th32csSnapProcess, 0);
      if (snapshot == _invalidHandleValue || snapshot == 0) return result;
      entry = calloc<_ProcessEntry32W>();
      entry.ref.dwSize = sizeOf<_ProcessEntry32W>();
      int ok = _process32First(snapshot, entry);
      while (ok != 0) {
        final int pid = entry.ref.th32ProcessID;
        if (pid > 0) {
          result.add(
            WindowsProcessEntry(
              pid: pid,
              name: _exeNameFrom(entry.ref.szExeFile),
            ),
          );
        }
        ok = _process32Next(snapshot, entry);
      }
      return result;
    } on Object {
      return result;
    } finally {
      if (entry != null) calloc.free(entry);
      if (snapshot != _invalidHandleValue && snapshot != 0) {
        _closeHandle(snapshot);
      }
    }
  }

  /// `szExeFile` 是定长 260 的 UTF-16 数组，读到 NUL 为止。
  String _exeNameFrom(Array<Uint16> raw) {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 260; i++) {
      final int unit = raw[i];
      if (unit == 0) break;
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  String? processImagePath(int pid) {
    try {
      final int handle = _openProcess(_processQueryLimitedInformation, 0, pid);
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
    } on Object {
      return null;
    }
  }

  /// 打开子键 → 读值 → 关键。失败一律 null（与「没有这个值」同义）。
  T? _withRegistryValue<T>(
    WindowsRegistryRoot root,
    String subKey,
    String valueName,
    T? Function(int type, Pointer<Uint8> data, int bytes) read,
  ) {
    final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
    final Pointer<Utf16> valuePtr = valueName.toNativeUtf16();
    final Pointer<IntPtr> keyHandle = calloc<IntPtr>();
    try {
      if (_regOpenKeyEx(root.handle, subKeyPtr, 0, _keyRead, keyHandle) !=
          _errorSuccess) {
        return null;
      }
      final int key = keyHandle.value;
      final Pointer<Uint32> type = calloc<Uint32>();
      final Pointer<Uint32> size = calloc<Uint32>();
      try {
        // 第一次调用只问长度（data == nullptr）。
        if (_regQueryValueEx(key, valuePtr, nullptr, type, nullptr, size) !=
            _errorSuccess) {
          return null;
        }
        if (size.value == 0) return null;
        final Pointer<Uint8> data = calloc<Uint8>(size.value);
        try {
          if (_regQueryValueEx(key, valuePtr, nullptr, type, data, size) !=
              _errorSuccess) {
            return null;
          }
          return read(type.value, data, size.value);
        } finally {
          calloc.free(data);
        }
      } finally {
        calloc.free(size);
        calloc.free(type);
        _regCloseKey(key);
      }
    } on Object {
      return null;
    } finally {
      calloc.free(keyHandle);
      calloc.free(valuePtr);
      calloc.free(subKeyPtr);
    }
  }

  String? readRegistryString(
    WindowsRegistryRoot root,
    String subKey,
    String valueName,
  ) =>
      _withRegistryValue<String>(root, subKey, valueName,
          (int type, Pointer<Uint8> data, int bytes) {
        if (type != _regSz && type != _regExpandSz) return null;
        // 字节数 → UTF-16 码元数；注册表字符串可能带也可能不带结尾 NUL。
        final int units = bytes ~/ 2;
        final Pointer<Uint16> units16 = data.cast<Uint16>();
        final StringBuffer buffer = StringBuffer();
        for (int i = 0; i < units; i++) {
          final int unit = units16[i];
          if (unit == 0) break;
          buffer.writeCharCode(unit);
        }
        final String value = buffer.toString();
        return value.isEmpty ? null : value;
      });

  int? readRegistryDword(
    WindowsRegistryRoot root,
    String subKey,
    String valueName,
  ) =>
      _withRegistryValue<int>(root, subKey, valueName,
          (int type, Pointer<Uint8> data, int bytes) {
        if (type != _regDword || bytes < 4) return null;
        return data.cast<Uint32>().value;
      });
}

/// `PROCESSENTRY32W`。`dwSize` 必须等于 `sizeOf<_ProcessEntry32W>()`，字段顺序与
/// 对齐（`th32DefaultHeapID` 是 `ULONG_PTR` → [IntPtr]）不能动。
final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;

  @Uint32()
  external int cntUsage;

  @Uint32()
  external int th32ProcessID;

  @IntPtr()
  external int th32DefaultHeapID;

  @Uint32()
  external int th32ModuleID;

  @Uint32()
  external int cntThreads;

  @Uint32()
  external int th32ParentProcessID;

  @Int32()
  external int pcPriClassBase;

  @Uint32()
  external int dwFlags;

  @Array(260)
  external Array<Uint16> szExeFile;
}

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

typedef _CreateToolhelp32SnapshotNative = IntPtr Function(
  Uint32 flags,
  Uint32 processId,
);
typedef _CreateToolhelp32SnapshotDart = int Function(
  int flags,
  int processId,
);

typedef _Process32Native = Int32 Function(
  IntPtr snapshot,
  Pointer<_ProcessEntry32W> entry,
);
typedef _Process32Dart = int Function(
  int snapshot,
  Pointer<_ProcessEntry32W> entry,
);

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

typedef _RegOpenKeyExNative = Int32 Function(
  IntPtr key,
  Pointer<Utf16> subKey,
  Uint32 options,
  Uint32 desired,
  Pointer<IntPtr> result,
);
typedef _RegOpenKeyExDart = int Function(
  int key,
  Pointer<Utf16> subKey,
  int options,
  int desired,
  Pointer<IntPtr> result,
);

typedef _RegQueryValueExNative = Int32 Function(
  IntPtr key,
  Pointer<Utf16> valueName,
  Pointer<Uint32> reserved,
  Pointer<Uint32> type,
  Pointer<Uint8> data,
  Pointer<Uint32> size,
);
typedef _RegQueryValueExDart = int Function(
  int key,
  Pointer<Utf16> valueName,
  Pointer<Uint32> reserved,
  Pointer<Uint32> type,
  Pointer<Uint8> data,
  Pointer<Uint32> size,
);

typedef _RegCloseKeyNative = Int32 Function(IntPtr key);
typedef _RegCloseKeyDart = int Function(int key);

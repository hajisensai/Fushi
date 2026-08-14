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
  static bool? debugForegroundOwnedByFushiAppFamily;

  @visibleForTesting
  static bool? debugHiddenWindowsRunner;

  static bool get isHiddenWindowsRunner {
    final bool? override = debugHiddenWindowsRunner;
    if (override != null) return override;
    if (!Platform.isWindows) return false;
    return Platform.environment.containsKey('FUSHI_TEST_HIDDEN');
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

  static bool isForegroundOwnedByFushiAppFamily() {
    final bool? override = debugForegroundOwnedByFushiAppFamily;
    if (override != null) return override;
    if (!Platform.isWindows) return false;
    try {
      return _WindowsForegroundProbe.instance
          .isForegroundOwnedByFushiAppFamily();
    } on Object {
      return false;
    }
  }

  /// **主窗自己**是不是前台窗口——注意与上面两个**进程级**判据的区别。
  ///
  /// 桌面版 Fushi 是多顶层窗口进程：主窗之外还有剪贴板查词面板、app 外查词
  /// 覆盖窗、悬浮歌词 / 台词窗。这些辅助窗取得前台时，进程级判据一律为真，
  /// 而主窗其实还压在用户的游戏 / 浏览器底下。凡是「主窗该不该抢键盘焦点」
  /// 这类决策都必须用本判据，用进程级的就会把主界面拽到用户面前
  /// （BUG-1619：拖剪贴板面板顶栏 → 面板夺焦 → 进程级 resumed →
  /// 主窗 requestFocus → 引擎 SetFocus(FlutterView) → 连带激活主窗）。
  ///
  /// 非 Windows 恒 true：那些平台没有这套多顶层窗口结构，判据不该改变它们
  /// 既有的 lifecycle 语义。
  static bool isMainWindowForeground() {
    final bool? override = debugMainWindowForeground;
    if (override != null) return override;
    if (!Platform.isWindows) return true;
    // `flutter test` 跑在 flutter_tester 里，根本没有 runner 主窗：真实探测必然
    // 返回 false，会把**所有**被动焦点修复挡死，整批既有焦点测试瞬间转红（实测）。
    // 这套判据只对「有主窗的桌面 runner」有意义，测试环境一律放行；需要驱动判据的
    // 用例显式设 [debugMainWindowForeground]（上面的 override 先于此生效）。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return true;
    try {
      return _WindowsForegroundProbe.instance.isMainWindowForeground();
    } on Object {
      // 探测失败按「是前台」放行：宁可保留旧的回收行为，也不要把键盘焦点
      // 永久卡死在无人接管的状态。
      return true;
    }
  }

  @visibleForTesting
  static bool? debugMainWindowForeground;
}

/// Flutter runner 主窗的 Win32 窗口类名。
///
/// 必须与 `fushi/windows/runner/win32_window.cpp` 注册的类名逐字符一致——
/// 那是识别「前台窗口是不是主窗」的唯一凭据（辅助窗各有自己的类名）。
/// 守卫测试 `desktop_foreground_guard_main_window_test.dart` 锁死两边一致。
const String kFushiMainWindowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

final class _WindowsForegroundProbe {
  _WindowsForegroundProbe._()
      : _getForegroundWindow = DynamicLibrary.open('user32.dll').lookupFunction<
            _GetForegroundWindowNative,
            _GetForegroundWindowDart>('GetForegroundWindow'),
        _getWindowThreadProcessId = DynamicLibrary.open('user32.dll')
            .lookupFunction<_GetWindowThreadProcessIdNative,
                _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId'),
        _getClassName = DynamicLibrary.open('user32.dll')
            .lookupFunction<_GetClassNameNative, _GetClassNameDart>(
                'GetClassNameW'),
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
  final _GetClassNameDart _getClassName;
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

  bool isForegroundOwnedByFushiAppFamily() {
    final int? pid = _foregroundProcessId();
    if (pid == null) return false;
    if (pid == _getCurrentProcessId()) return true;
    final String? imagePath = _processImagePath(pid);
    if (imagePath == null) return false;
    return _looksLikeFushiExecutable(imagePath);
  }

  /// 前台窗口既属于本进程、类名又是主窗类名 → 主窗就是前台窗口。
  ///
  /// 两个条件缺一不可：只比进程会把辅助窗（面板 / 覆盖窗 / 浮窗）算成主窗；
  /// 只比类名会把另一个 Fushi 进程的主窗算成自己的。
  bool isMainWindowForeground() {
    final int foregroundHwnd = _getForegroundWindow();
    if (foregroundHwnd == 0) return false;
    final Pointer<Uint32> foregroundPid = calloc<Uint32>();
    try {
      _getWindowThreadProcessId(foregroundHwnd, foregroundPid);
      if (foregroundPid.value != _getCurrentProcessId()) return false;
    } finally {
      calloc.free(foregroundPid);
    }
    return _windowClassName(foregroundHwnd) == kFushiMainWindowClassName;
  }

  String? _windowClassName(int hwnd) {
    const int bufferLength = 256;
    final Pointer<Utf16> buffer = calloc<Uint16>(bufferLength).cast<Utf16>();
    try {
      final int written = _getClassName(hwnd, buffer, bufferLength);
      if (written <= 0) return null;
      return buffer.toDartString(length: written);
    } finally {
      calloc.free(buffer);
    }
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

  static bool _looksLikeFushiExecutable(String imagePath) {
    final String foregroundExe = _basenameLower(imagePath);
    final String currentExe = _basenameLower(Platform.resolvedExecutable);
    if (foregroundExe == currentExe) return true;
    final String stem = foregroundExe.endsWith('.exe')
        ? foregroundExe.substring(0, foregroundExe.length - 4)
        : foregroundExe;
    // fushi 是改名后的 exe 词干；hibiki 保留识别仍在运行的旧版/旧便携包。
    return stem == 'fushi' ||
        stem.startsWith('fushi-') ||
        stem == 'hibiki' ||
        stem.startsWith('hibiki-');
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

typedef _GetClassNameNative = Int32 Function(
  IntPtr hWnd,
  Pointer<Utf16> className,
  Int32 maxCount,
);
typedef _GetClassNameDart = int Function(
  int hWnd,
  Pointer<Utf16> className,
  int maxCount,
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

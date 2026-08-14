import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 「在 Anki 中打开」时把 Anki 窗口真正带到前台（Windows）。
///
/// 根因：AnkiConnect 的 `guiBrowse` 只能让 **Anki 自己** 调 `activateWindow()`。
/// 而 Windows 的前台锁定规则里，非前台进程调 `SetForegroundWindow` 会被降级成
/// 「闪任务栏按钮」，于是用户观察到的现象正好分成两半：
///   - Anki 的「浏览」窗口**尚未打开**：`aqt.dialogs.open('Browser')` 走新建窗口
///     路径，新窗口首次显示仍能进前台 → Anki 跳出来，看着是好的；
///   - 「浏览」窗口**已在后台开着**：走复用路径，只是 raise + activate 一个**已
///     存在**的窗口 → 被前台锁定拒绝，只剩任务栏闪烁。
///
/// 有权解开这个锁的只有当时的前台进程，也就是用户刚点下按钮的 Hibiki 自己，所以
/// 修复必须落在这一侧，分两步：
///   1. 发 `guiBrowse` **前**用 [grantForegroundToAnki] 把前台权限**定向**让渡给
///      Anki 进程（`AllowSetForegroundWindow(ankiPid)`；不用 `ASFW_ANY` 放开给
///      任意进程），Anki 自己的 activate 就直接生效，两种情况一并覆盖；
///   2. 发完后用 [raiseAnkiWindow] 兜底：前台仍不属于 Anki 时，按 Z 序取它最顶的
///      可见顶层窗口（Anki 刚 `raise_()` 过「浏览」，Z 序里就是它），必要时先从
///      最小化恢复，再 `SetForegroundWindow`。
///
/// 全程 fail-soft：找不到 Anki 窗口、非 Windows、FFI 加载失败都退回「什么都不做」，
/// 与修复前的行为一致，绝不让制卡链路因此报错。
abstract final class AnkiDesktopForeground {
  /// 单测替身：注入后完全取代真实 Win32 后端（含平台判断）。
  @visibleForTesting
  static AnkiDesktopForegroundBackend? debugBackend;

  /// 兜底重试的间隔。Anki 是 Qt 应用，`guiBrowse` 的 HTTP 响应回来时窗口激活可能
  /// 还差一轮事件循环，所以这里做**正向确认**循环（判据明确：前台归 Anki 即返回），
  /// 而不是盲等一个固定时长。
  @visibleForTesting
  static Duration raiseRetryInterval = const Duration(milliseconds: 120);

  static const int _raiseAttempts = 3;

  static AnkiDesktopForegroundBackend? get _backend {
    final AnkiDesktopForegroundBackend? override = debugBackend;
    if (override != null) return override;
    if (!Platform.isWindows) return null;
    try {
      return _WindowsAnkiForeground.instance;
    } on Object {
      return null;
    }
  }

  /// 把前台权限让渡给本机 Anki 进程，返回它的 pid（找不到/不适用时 null）。
  ///
  /// 返回值交给 [raiseAnkiWindow]，避免在这里存跨调用的可变全局状态。
  static int? grantForegroundToAnki() {
    final AnkiDesktopForegroundBackend? backend = _backend;
    if (backend == null) return null;
    try {
      final int? pid = backend.findAnkiProcessId();
      if (pid == null) return null;
      backend.allowSetForegroundWindow(pid);
      return pid;
    } on Object {
      return null;
    }
  }

  /// 兜底把 [ankiPid] 的顶层窗口拉到前台；前台已经归它时立即返回。
  static Future<void> raiseAnkiWindow(int? ankiPid) async {
    if (ankiPid == null) return;
    final AnkiDesktopForegroundBackend? backend = _backend;
    if (backend == null) return;
    for (int attempt = 0; attempt < _raiseAttempts; attempt++) {
      try {
        if (backend.isForegroundOwnedByProcess(ankiPid)) return;
        if (backend.raiseTopWindowOfProcess(ankiPid) &&
            backend.isForegroundOwnedByProcess(ankiPid)) {
          return;
        }
      } on Object {
        return;
      }
      if (attempt < _raiseAttempts - 1) {
        await Future<void>.delayed(raiseRetryInterval);
      }
    }
  }
}

/// [AnkiDesktopForeground] 依赖的平台原语，抽出来是为了让编排逻辑可单测（真实实现
/// 全是 Win32 调用，测试环境里跑不了）。
abstract interface class AnkiDesktopForegroundBackend {
  /// 本机正在运行的 Anki 桌面端进程 id；没找到返回 null。
  int? findAnkiProcessId();

  /// `AllowSetForegroundWindow`：把本进程的前台权限让渡给 [pid]。
  bool allowSetForegroundWindow(int pid);

  /// 当前前台窗口是否属于 [pid]。
  bool isForegroundOwnedByProcess(int pid);

  /// 按 Z 序取 [pid] 最顶的可见顶层窗口，必要时从最小化恢复，再置前台。
  bool raiseTopWindowOfProcess(int pid);
}

final class _WindowsAnkiForeground implements AnkiDesktopForegroundBackend {
  _WindowsAnkiForeground._()
      : _getTopWindow =
            _user32.lookupFunction<_GetTopWindowNative, _GetTopWindowDart>(
                'GetTopWindow'),
        _getWindow = _user32
            .lookupFunction<_GetWindowNative, _GetWindowDart>('GetWindow'),
        _isWindowVisible = _user32.lookupFunction<_IsWindowVisibleNative,
            _IsWindowVisibleDart>('IsWindowVisible'),
        _getWindowTextLength = _user32.lookupFunction<
            _GetWindowTextLengthNative,
            _GetWindowTextLengthDart>('GetWindowTextLengthW'),
        _getWindowThreadProcessId = _user32.lookupFunction<
            _GetWindowThreadProcessIdNative,
            _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId'),
        _getForegroundWindow = _user32.lookupFunction<
            _GetForegroundWindowNative,
            _GetForegroundWindowDart>('GetForegroundWindow'),
        _setForegroundWindow = _user32.lookupFunction<
            _SetForegroundWindowNative,
            _SetForegroundWindowDart>('SetForegroundWindow'),
        _allowSetForegroundWindow = _user32.lookupFunction<
            _AllowSetForegroundWindowNative,
            _AllowSetForegroundWindowDart>('AllowSetForegroundWindow'),
        _isIconic =
            _user32.lookupFunction<_IsIconicNative, _IsIconicDart>('IsIconic'),
        _showWindow = _user32
            .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow'),
        _openProcess =
            _kernel32.lookupFunction<_OpenProcessNative, _OpenProcessDart>(
                'OpenProcess'),
        _queryFullProcessImageName = _kernel32.lookupFunction<
            _QueryFullProcessImageNameNative,
            _QueryFullProcessImageNameDart>('QueryFullProcessImageNameW'),
        _closeHandle =
            _kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
                'CloseHandle');

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _WindowsAnkiForeground instance = _WindowsAnkiForeground._();

  final _GetTopWindowDart _getTopWindow;
  final _GetWindowDart _getWindow;
  final _IsWindowVisibleDart _isWindowVisible;
  final _GetWindowTextLengthDart _getWindowTextLength;
  final _GetWindowThreadProcessIdDart _getWindowThreadProcessId;
  final _GetForegroundWindowDart _getForegroundWindow;
  final _SetForegroundWindowDart _setForegroundWindow;
  final _AllowSetForegroundWindowDart _allowSetForegroundWindow;
  final _IsIconicDart _isIconic;
  final _ShowWindowDart _showWindow;
  final _OpenProcessDart _openProcess;
  final _QueryFullProcessImageNameDart _queryFullProcessImageName;
  final _CloseHandleDart _closeHandle;

  static const int _gwHwndNext = 2;
  static const int _swRestore = 9;
  static const int _processQueryLimitedInformation = 0x1000;
  static const int _imagePathBufferLength = 32768;

  /// 顶层窗口链的遍历上限；纯粹是防御异常的 Z 序环，正常桌面远达不到。
  static const int _enumerationGuard = 4096;

  @override
  int? findAnkiProcessId() {
    final Map<int, bool> ankiByPid = <int, bool>{};
    int? found;
    _forEachTopLevelWindow((int hwnd, int pid) {
      final bool isAnki = ankiByPid.putIfAbsent(pid, () => _isAnkiProcess(pid));
      if (!isAnki) return true;
      found = pid;
      return false;
    });
    return found;
  }

  @override
  bool allowSetForegroundWindow(int pid) => _allowSetForegroundWindow(pid) != 0;

  @override
  bool isForegroundOwnedByProcess(int pid) {
    final int hwnd = _getForegroundWindow();
    if (hwnd == 0) return false;
    return _windowProcessId(hwnd) == pid;
  }

  @override
  bool raiseTopWindowOfProcess(int pid) {
    int target = 0;
    _forEachTopLevelWindow((int hwnd, int windowPid) {
      if (windowPid != pid) return true;
      target = hwnd;
      return false;
    });
    if (target == 0) return false;
    // 最小化的窗口 IsWindowVisible 仍为真，所以恢复要单独判 IsIconic。
    if (_isIconic(target) != 0) {
      _showWindow(target, _swRestore);
    }
    return _setForegroundWindow(target) != 0;
  }

  /// 按 Z 序（最顶在前）遍历「可见且有标题」的顶层窗口；[visit] 返回 false 即停。
  ///
  /// 用 GetTopWindow + GW_HWNDNEXT 而不是 EnumWindows：等价、天然按 Z 序，且不需要
  /// 为一次性查询建 [NativeCallable] 回调。
  void _forEachTopLevelWindow(bool Function(int hwnd, int pid) visit) {
    int hwnd = _getTopWindow(0);
    int guard = 0;
    while (hwnd != 0 && guard++ < _enumerationGuard) {
      if (_isWindowVisible(hwnd) != 0 && _getWindowTextLength(hwnd) > 0) {
        final int? pid = _windowProcessId(hwnd);
        if (pid != null && !visit(hwnd, pid)) return;
      }
      hwnd = _getWindow(hwnd, _gwHwndNext);
    }
  }

  int? _windowProcessId(int hwnd) {
    final Pointer<Uint32> pid = calloc<Uint32>();
    try {
      _getWindowThreadProcessId(hwnd, pid);
      return pid.value == 0 ? null : pid.value;
    } finally {
      calloc.free(pid);
    }
  }

  bool _isAnkiProcess(int pid) {
    final String? imagePath = _processImagePath(pid);
    if (imagePath == null) return false;
    return _basenameLower(imagePath) == 'anki.exe';
  }

  String? _processImagePath(int pid) {
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
  }

  static String _basenameLower(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int slash = normalized.lastIndexOf('/');
    final String basename =
        slash >= 0 ? normalized.substring(slash + 1) : normalized;
    return basename.toLowerCase();
  }
}

typedef _GetTopWindowNative = IntPtr Function(IntPtr hWnd);
typedef _GetTopWindowDart = int Function(int hWnd);

typedef _GetWindowNative = IntPtr Function(IntPtr hWnd, Uint32 cmd);
typedef _GetWindowDart = int Function(int hWnd, int cmd);

typedef _IsWindowVisibleNative = Int32 Function(IntPtr hWnd);
typedef _IsWindowVisibleDart = int Function(int hWnd);

typedef _GetWindowTextLengthNative = Int32 Function(IntPtr hWnd);
typedef _GetWindowTextLengthDart = int Function(int hWnd);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
  IntPtr hWnd,
  Pointer<Uint32> processId,
);
typedef _GetWindowThreadProcessIdDart = int Function(
  int hWnd,
  Pointer<Uint32> processId,
);

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _SetForegroundWindowNative = Int32 Function(IntPtr hWnd);
typedef _SetForegroundWindowDart = int Function(int hWnd);

typedef _AllowSetForegroundWindowNative = Int32 Function(Uint32 processId);
typedef _AllowSetForegroundWindowDart = int Function(int processId);

typedef _IsIconicNative = Int32 Function(IntPtr hWnd);
typedef _IsIconicDart = int Function(int hWnd);

typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 cmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int cmdShow);

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

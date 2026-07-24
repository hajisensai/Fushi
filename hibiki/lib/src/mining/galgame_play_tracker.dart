/// galgame 游玩计时器（Windows）。见
/// `docs/design/galgame-library-reina-parity.md` §3。
///
/// 旧实现把游玩时长挂在 hook 抓到的**文本行**上（`GalHookActivityAccumulator`），
/// 根本缺陷是「没抓到文本 = 完全不计时」：未适配引擎、纯语音场景、hook 注入失败
/// 全部丢账。这里改成按**前台窗口 + 候选进程组**计时，与文本 hook 彻底解耦。
///
/// 结构上刻意分成三层，避免「只能在真 Windows 上跑的状态机」这种没法测的东西：
///
/// 1. [GalgameProcessProbe]——「怎么拿前台 PID / 怎么枚举进程 / 怎么判活」的抽象；
/// 2. [GalgamePlaySessionMachine]——**平台无关的纯状态机**，只吃显式的时钟毫秒数
///    与 probe 结果，假时钟 + 假 probe 即可完整单测；
/// 3. [GalgamePlayTracker]——只负责按 200ms / 1s 起定时器驱动 2，并在 Windows 上
///    注入 1 的真实实现。非 Windows 平台整体 no-op（galgame 只做 Windows，见根
///    `CLAUDE.md`「Galgame Hook 硬规则」）。
///
/// 会话结束时**不落库**，只回调 [GalgamePlaySessionSink]；写 `galgame_sessions`
/// 由调用方接线，计时器本身不认识数据库。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/mining/galgame_path_match.dart';

/// 计时语义（契约 §1.6）。
enum GalgamePlayTimingMode {
  /// 只累计**前台活跃**秒数（默认）。挂后台挂机不计。
  playtime,

  /// 墙钟：`endMs - startMs`，进程活着就算。
  elapsed,
}

/// 入库门槛（秒）：不足此值的会话直接丢弃，不落库。
const int kMinSessionSeconds = 60;

/// 主进程连续判活失败多少次后重扫游戏目录换主 PID。
const int kMaxConsecutiveFailures = 3;

/// 启动后多久做一次候选进程组全量扫描（毫秒）。
///
/// 3 秒是为了让 Launcher 把本体拉起来：很多 galgame 的 exe 只是个启动器，真正
/// 的游戏进程是它 spawn 出来的另一个 PID，只盯启动器会在几秒后整场丢账。
const int kCandidateScanDelayMs = 3000;

/// 一个进程的最小身份：PID + exe 完整路径（取不到路径时为 null）。
@immutable
class GalgameProcessInfo {
  const GalgameProcessInfo({required this.pid, required this.imagePath});

  final int pid;
  final String? imagePath;
}

/// 一次游玩会话的结算结果。
@immutable
class GalgamePlaySessionResult {
  const GalgamePlaySessionResult({
    required this.gameId,
    required this.startMs,
    required this.endMs,
    required this.durationSeconds,
  });

  /// `galgames.id`。
  final String gameId;

  /// 会话开始（epoch 毫秒）。
  final int startMs;

  /// 会话结束（epoch 毫秒）。
  final int endMs;

  /// 计入时长（秒），语义由 [GalgamePlayTimingMode] 决定。
  final int durationSeconds;

  @override
  String toString() => 'GalgamePlaySessionResult(gameId: $gameId, '
      'startMs: $startMs, endMs: $endMs, durationSeconds: $durationSeconds)';
}

/// 会话结束回调（落库在别处接线）。
typedef GalgamePlaySessionSink = Future<void> Function(
  GalgamePlaySessionResult result,
);

/// 计时器对操作系统的**全部**依赖面。Windows 实现见
/// [GalgameWindowsProcessProbe]，测试注入假实现。
abstract class GalgameProcessProbe {
  /// 当前前台窗口所属 PID；无前台窗口 / 取不到时返回 null。
  int? foregroundProcessId();

  /// 进程是否仍在运行。
  bool isProcessAlive(int pid);

  /// 进程 exe 的完整路径；无权限 / 已退出时返回 null。
  String? processImagePath(int pid);

  /// 枚举当前全部进程（用于候选进程组扫描）。
  List<GalgameProcessInfo> listProcesses();

  /// 解析符号链接后的真实路径；解析不了返回 null（调用方回退到原始路径比较）。
  String? canonicalize(String path);
}

/// 平台无关的游玩计时状态机。
///
/// 不持有任何定时器、不读系统时钟——外部把「现在几点（epoch 毫秒）」和两种 tick
/// 显式喂进来。这样 Launcher 切换、逃逸检测、连续失活切 PID、门槛丢弃、两种计时
/// 模式全部可以在 Linux CI 上用假时钟跑完。
class GalgamePlaySessionMachine {
  GalgamePlaySessionMachine({
    required this.gameId,
    required String gameDirectory,
    required GalgameProcessProbe probe,
    required GalgamePlaySessionSink onSessionEnded,
    this.mode = GalgamePlayTimingMode.playtime,
    this.minSessionSeconds = kMinSessionSeconds,
    this.maxConsecutiveFailures = kMaxConsecutiveFailures,
    this.candidateScanDelayMs = kCandidateScanDelayMs,
  })  : _gameDirectory = gameDirectory,
        _probe = probe,
        _onSessionEnded = onSessionEnded;

  /// `galgames.id`。
  final String gameId;

  /// 计时语义。
  final GalgamePlayTimingMode mode;

  /// 入库门槛（秒）。
  final int minSessionSeconds;

  /// 连续判活失败多少次触发换 PID。
  final int maxConsecutiveFailures;

  /// 候选进程组全量扫描的延迟（毫秒）。
  final int candidateScanDelayMs;

  final String _gameDirectory;
  final GalgameProcessProbe _probe;
  final GalgamePlaySessionSink _onSessionEnded;

  bool _running = false;
  bool _ended = false;
  int _startMs = 0;
  int _endMs = 0;
  int _mainPid = 0;
  int _activeSeconds = 0;
  int _consecutiveFailures = 0;
  bool _candidatesScanned = false;
  bool _foregroundIsGame = false;
  String? _canonicalGameDirectory;
  bool _canonicalGameDirectoryResolved = false;

  final Set<int> _candidatePids = <int>{};

  /// 已确认「不属于本游戏」的前台 PID 负缓存。前台每 200ms 采一次，没有它就会对
  /// explorer.exe 这类常驻前台进程每秒发 5 次路径查询。进程的 exe 路径不会中途
  /// 变化，所以缓存结果恒定；只有 PID 回收可能让缓存过期，故设上限并在超限时整体
  /// 清空（会话级生命周期内足够）。
  final Set<int> _rejectedPids = <int>{};
  static const int _rejectedPidsLimit = 512;

  Future<void>? _sinkFuture;

  /// 会话是否仍在计时。
  bool get isRunning => _running;

  /// 会话是否已经结算过（结算是幂等的）。
  bool get isEnded => _ended;

  /// 当前主进程 PID。
  int get mainPid => _mainPid;

  /// 已累计的前台活跃秒数（[GalgamePlayTimingMode.playtime] 的计量）。
  int get activeSeconds => _activeSeconds;

  /// 最近一次前台采样是否落在候选进程组内。
  bool get foregroundIsGame => _foregroundIsGame;

  /// 当前候选进程组快照。
  Set<int> get candidatePids => Set<int>.unmodifiable(_candidatePids);

  /// 结算回调的 Future（未结算 / 未达门槛时为已完成的空 Future），供测试等待。
  Future<void> get pendingWrite => _sinkFuture ?? Future<void>.value();

  /// 开始一段会话。[mainPid] 是启动时已知的目标进程（通常是 Launcher/exe 本体）。
  void start({required int nowMs, required int mainPid}) {
    if (_running || _ended) return;
    _running = true;
    _startMs = nowMs;
    _endMs = nowMs;
    _mainPid = mainPid;
    _activeSeconds = 0;
    _consecutiveFailures = 0;
    _candidatesScanned = false;
    _foregroundIsGame = false;
    _candidatePids
      ..clear()
      ..add(mainPid);
    _rejectedPids.clear();
  }

  /// 200ms 前台采样：只更新「前台是不是本游戏」这一位共享状态，不累加时间。
  ///
  /// 逃逸检测在这里：前台 PID 不在候选集时，查它的 exe 路径是否在游戏目录下，
  /// 是则补进候选集（游戏中途 spawn 出的新窗口进程、Launcher 换本体都靠这条）。
  void onForegroundSample({required int nowMs, required int? foregroundPid}) {
    if (!_running) return;
    _endMs = nowMs;
    if (foregroundPid == null || foregroundPid <= 0) {
      _foregroundIsGame = false;
      return;
    }
    if (_candidatePids.contains(foregroundPid)) {
      _foregroundIsGame = true;
      return;
    }
    if (_rejectedPids.contains(foregroundPid)) {
      _foregroundIsGame = false;
      return;
    }
    final String? imagePath = _probe.processImagePath(foregroundPid);
    if (imagePath != null && _isUnderGameDirectory(imagePath)) {
      _candidatePids.add(foregroundPid);
      _foregroundIsGame = true;
      return;
    }
    if (_rejectedPids.length >= _rejectedPidsLimit) _rejectedPids.clear();
    _rejectedPids.add(foregroundPid);
    _foregroundIsGame = false;
  }

  /// 1s 累加 tick：候选组延迟扫描 → 按模式累加 → 主进程判活。
  void onSecondTick({required int nowMs}) {
    if (!_running) return;
    _endMs = nowMs;
    if (!_candidatesScanned && nowMs - _startMs >= candidateScanDelayMs) {
      _candidatesScanned = true;
      _rescanCandidates();
    }
    if (mode == GalgamePlayTimingMode.playtime && _foregroundIsGame) {
      _activeSeconds++;
    }
    _tickLiveness(nowMs);
  }

  /// 外部主动结束会话（用户关闭游戏库、App 退出等）。幂等。
  Future<void> stop({required int nowMs}) {
    if (!_running) return pendingWrite;
    _endMs = nowMs;
    _end(nowMs);
    return pendingWrite;
  }

  /// 主进程判活：连续失败 [maxConsecutiveFailures] 次才动作——单次 `OpenProcess`
  /// 失败可能只是瞬时权限/句柄抖动，立刻换 PID 会把正常会话打断。
  void _tickLiveness(int nowMs) {
    if (_probe.isProcessAlive(_mainPid)) {
      _consecutiveFailures = 0;
      return;
    }
    _consecutiveFailures++;
    if (_consecutiveFailures < maxConsecutiveFailures) return;
    final int? next = _findLiveCandidate();
    if (next != null) {
      _mainPid = next;
      _candidatePids.add(next);
      _consecutiveFailures = 0;
      return;
    }
    _end(nowMs);
  }

  /// 找一个仍活着的替补主进程。
  ///
  /// **先重扫再挑**，不走「先在旧候选集里碰运气」的捷径：旧集合里可能有已退出、
  /// PID 又被系统回收给别人的条目，直接判活会把毫不相干的进程认成本游戏。重扫一次
  /// 只发生在主进程连续失活之后，成本可忽略。
  int? _findLiveCandidate() {
    _rescanCandidates();
    for (final int pid in _candidatePids.toList(growable: false)) {
      if (pid == _mainPid) continue;
      if (_probe.isProcessAlive(pid)) return pid;
    }
    return null;
  }

  /// 重建候选进程组 = 游戏目录下的全部在跑进程（+ 仍活着的主 PID）。
  ///
  /// 重建而非累加：只增不减会让已退出的 PID 永远留在集合里，PID 被系统回收后就
  /// 变成误判「前台是游戏」的来源。主 PID 只在**仍活着**时保留——它可能因权限问题
  /// 读不到 exe 路径而扫不进来，但一旦它已经死了就没有任何理由继续留着。
  void _rescanCandidates() {
    final Set<int> scanned = <int>{};
    for (final GalgameProcessInfo info in _probe.listProcesses()) {
      final String? imagePath = info.imagePath;
      if (info.pid <= 0 || imagePath == null) continue;
      if (_isUnderGameDirectory(imagePath)) scanned.add(info.pid);
    }
    if (_probe.isProcessAlive(_mainPid)) scanned.add(_mainPid);
    _candidatePids
      ..clear()
      ..addAll(scanned);
    _rejectedPids.removeAll(scanned);
  }

  /// 原始路径与 `canonicalize` 后的路径任一命中即算在游戏目录下（游戏装在符号
  /// 链接 / junction 后面时，进程报的是解析后的真实路径）。
  bool _isUnderGameDirectory(String path) {
    if (galgamePathIsWithin(path, _gameDirectory)) return true;
    if (!_canonicalGameDirectoryResolved) {
      _canonicalGameDirectoryResolved = true;
      _canonicalGameDirectory = _probe.canonicalize(_gameDirectory);
    }
    final String? canonicalDirectory = _canonicalGameDirectory;
    if (canonicalDirectory == null) return false;
    final String? canonicalPath = _probe.canonicalize(path);
    if (canonicalPath == null) return false;
    return galgamePathIsWithin(canonicalPath, canonicalDirectory);
  }

  /// 结算：按模式算时长，达门槛才回调 sink。幂等（[_ended] 守卫）。
  void _end(int nowMs) {
    if (_ended) return;
    _ended = true;
    _running = false;
    _endMs = nowMs;
    final int durationSeconds = switch (mode) {
      GalgamePlayTimingMode.playtime => _activeSeconds,
      GalgamePlayTimingMode.elapsed => (_endMs - _startMs) ~/ 1000,
    };
    if (durationSeconds < minSessionSeconds) return;
    _sinkFuture = _onSessionEnded(
      GalgamePlaySessionResult(
        gameId: gameId,
        startMs: _startMs,
        endMs: _endMs,
        durationSeconds: durationSeconds,
      ),
    );
  }
}

/// 计时器外壳：起 200ms / 1s 两条定时器驱动 [GalgamePlaySessionMachine]。
///
/// 非 Windows 平台整体 no-op（[start] 直接返回，不建 probe、不建定时器、不回调），
/// 保证三端都能编译并跑测试。
class GalgamePlayTracker {
  GalgamePlayTracker({
    required this.gameId,
    required String gameDirectory,
    required GalgamePlaySessionSink onSessionEnded,
    GalgameProcessProbe? probe,
    GalgamePlayTimingMode mode = GalgamePlayTimingMode.playtime,
    bool? isWindows,
    int Function()? nowMs,
    Duration foregroundInterval = const Duration(milliseconds: 200),
    Duration accrualInterval = const Duration(seconds: 1),
  })  : _gameDirectory = gameDirectory,
        _onSessionEnded = onSessionEnded,
        _probe = probe,
        _mode = mode,
        _isWindows = isWindows ?? Platform.isWindows,
        _nowMs = nowMs ?? _defaultNowMs,
        _foregroundInterval = foregroundInterval,
        _accrualInterval = accrualInterval;

  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// `galgames.id`。
  final String gameId;

  final String _gameDirectory;
  final GalgamePlaySessionSink _onSessionEnded;
  final GalgameProcessProbe? _probe;
  final GalgamePlayTimingMode _mode;
  final bool _isWindows;
  final int Function() _nowMs;
  final Duration _foregroundInterval;
  final Duration _accrualInterval;

  Timer? _foregroundTimer;
  Timer? _accrualTimer;
  GalgamePlaySessionMachine? _machine;

  /// 当前状态机（未启动 / 非 Windows 时为 null）。
  @visibleForTesting
  GalgamePlaySessionMachine? get machine => _machine;

  /// 是否正在计时。
  bool get isRunning => _machine?.isRunning ?? false;

  /// 开始计时。[mainPid] 是启动游戏时拿到的进程 id。
  void start({required int mainPid}) {
    if (!_isWindows || _machine != null) return;
    final GalgameProcessProbe probe = _probe ?? GalgameWindowsProcessProbe();
    final GalgamePlaySessionMachine machine = GalgamePlaySessionMachine(
      gameId: gameId,
      gameDirectory: _gameDirectory,
      probe: probe,
      onSessionEnded: _onSessionEnded,
      mode: _mode,
    );
    machine.start(nowMs: _nowMs(), mainPid: mainPid);
    _machine = machine;
    _foregroundTimer = Timer.periodic(_foregroundInterval, (_) {
      machine.onForegroundSample(
        nowMs: _nowMs(),
        foregroundPid: probe.foregroundProcessId(),
      );
    });
    _accrualTimer = Timer.periodic(_accrualInterval, (_) {
      machine.onSecondTick(nowMs: _nowMs());
      if (!machine.isRunning) unawaited(stop());
    });
  }

  /// 结束计时并等待结算回调完成。非 Windows / 未启动时是空操作。
  Future<void> stop() async {
    _foregroundTimer?.cancel();
    _foregroundTimer = null;
    _accrualTimer?.cancel();
    _accrualTimer = null;
    final GalgamePlaySessionMachine? machine = _machine;
    if (machine == null) return;
    await machine.stop(nowMs: _nowMs());
  }
}

/// Windows 真实 probe：直接 `dart:ffi` 调 user32/kernel32。
///
/// 走裸 FFI 而不是 `package:win32`——win32 在本仓只是**传递依赖**，直接 import 会
/// 触发 `depend_on_referenced_packages`（CI 把 warning 当致命）。仓库既有的
/// `desktop_foreground_guard.dart` / `selection_capture_ffi.dart` 也是这个范式。
class GalgameWindowsProcessProbe implements GalgameProcessProbe {
  GalgameWindowsProcessProbe()
      : _getForegroundWindow = _user32.lookupFunction<
            _GetForegroundWindowNative,
            _GetForegroundWindowDart>('GetForegroundWindow'),
        _getWindowThreadProcessId = _user32.lookupFunction<
            _GetWindowThreadProcessIdNative,
            _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId'),
        _openProcess =
            _kernel32.lookupFunction<_OpenProcessNative, _OpenProcessDart>(
                'OpenProcess'),
        _getExitCodeProcess = _kernel32.lookupFunction<
            _GetExitCodeProcessNative,
            _GetExitCodeProcessDart>('GetExitCodeProcess'),
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
                'CloseHandle');

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static const int _processQueryLimitedInformation = 0x1000;
  static const int _stillActive = 259;
  static const int _th32csSnapProcess = 0x00000002;
  static const int _invalidHandleValue = -1;
  static const int _imagePathBufferLength = 32768;

  final _GetForegroundWindowDart _getForegroundWindow;
  final _GetWindowThreadProcessIdDart _getWindowThreadProcessId;
  final _OpenProcessDart _openProcess;
  final _GetExitCodeProcessDart _getExitCodeProcess;
  final _QueryFullProcessImageNameDart _queryFullProcessImageName;
  final _CreateToolhelp32SnapshotDart _createToolhelp32Snapshot;
  final _Process32Dart _process32First;
  final _Process32Dart _process32Next;
  final _CloseHandleDart _closeHandle;

  @override
  int? foregroundProcessId() {
    try {
      final int hwnd = _getForegroundWindow();
      if (hwnd == 0) return null;
      final Pointer<Uint32> pid = calloc<Uint32>();
      try {
        _getWindowThreadProcessId(hwnd, pid);
        return pid.value == 0 ? null : pid.value;
      } finally {
        calloc.free(pid);
      }
    } on Object {
      return null;
    }
  }

  /// `GetExitCodeProcess` 返回 `STILL_ACTIVE`(259) 即在跑。
  ///
  /// 已知 Win32 边角：进程若真以退出码 259 结束，这里会误判成仍存活。计时器为此
  /// 才有「连续 [kMaxConsecutiveFailures] 次失败 + 重扫目录」这一层，而不是拿单次
  /// 判活当真理。
  @override
  bool isProcessAlive(int pid) {
    if (pid <= 0) return false;
    try {
      final int handle = _openProcess(_processQueryLimitedInformation, 0, pid);
      if (handle == 0) return false;
      final Pointer<Uint32> exitCode = calloc<Uint32>();
      try {
        if (_getExitCodeProcess(handle, exitCode) == 0) return false;
        return exitCode.value == _stillActive;
      } finally {
        calloc.free(exitCode);
        _closeHandle(handle);
      }
    } on Object {
      return false;
    }
  }

  @override
  String? processImagePath(int pid) {
    if (pid <= 0) return null;
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

  @override
  List<GalgameProcessInfo> listProcesses() {
    final List<GalgameProcessInfo> result = <GalgameProcessInfo>[];
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
            GalgameProcessInfo(pid: pid, imagePath: processImagePath(pid)),
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

  @override
  String? canonicalize(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on Object {
      return null;
    }
  }
}

// ── Win32 绑定 ───────────────────────────────────────────────────────────────

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

typedef _GetExitCodeProcessNative = Int32 Function(
  IntPtr process,
  Pointer<Uint32> exitCode,
);
typedef _GetExitCodeProcessDart = int Function(
  int process,
  Pointer<Uint32> exitCode,
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

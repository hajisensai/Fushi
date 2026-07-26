/// 内置 Magpie 窗口超分的**运行时层**（阶段二）。
///
/// 职责：把 `magpie_upscaling.dart` 的纯裁决接到真实的进程 / 窗口 / 文件上，并对
/// galgame 会话暴露两个极窄的钩子 —— [onGameWindowReady] 与 [onSessionEnded]。
///
/// 刻意做成**独立文件 + 独立类**，`gal_hook_session_controller.dart` 侧只加
/// 「一个可空字段 + 一个 setter + 两处调用」，把与并发改动的冲突面压到最小
/// （范式抄该文件既有的 `attachActivityDatabase`）。
///
/// 三条硬约束（都来自阶段一读上游源码的实测结论，违反任何一条都会坏）：
///
/// 1. **绝不给 Hibiki 自己建 autoScale profile**。Magpie 每 50ms 轮询前台窗口，命中任何
///    `autoScale != Disabled` 的 profile 就 `force=true` 重启缩放
///    （`ScalingService.cpp:42-45`、`:250-273`）。守卫在 `magpieProfileTargetAllowed`。
/// 2. **便携标记必须是 0 字节文件**。写 `{}` 会让 scalingModes 为空 → scalingMode 钳到 -1
///    → 缩放报 `InvalidScalingMode`。已由 `magpiePortableConfigContent()` 保证。
/// 3. **绝不动我们没启动的 Magpie**。用户自己开着的实例不写它的配置、不发 QUIT。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/mining/magpie_installer.dart';
import 'package:hibiki/src/mining/magpie_scaling_channel.dart';
import 'package:hibiki/src/mining/magpie_upscaling.dart';

/// 转出确认回调的入参类型：它是本服务对外契约的一部分（[MagpieUpscalingService] 的
/// `confirmDownload` 签名用它），调用方不该为了一个参数类型再去 import 安装器。
export 'package:hibiki/src/mining/magpie_installer.dart'
    show MagpieDownloadPrompt;

/// 偏好键：三态超分开关。**不要改**（改了等于把所有用户的设置清零）。
const String kMagpieUpscalingModePrefKey = 'galgame_magpie_upscaling_mode';

/// 发出 QUIT 之后等 Magpie 自己退出的上限。超时就直接 kill 我们自己起的那个进程。
///
/// 为什么必须有 kill 兜底：`App::InitMessages()` 只对 `WM_MAGPIE_SHOWME` 调了
/// `ChangeWindowMessageFilter`，**QUIT 没放行**。Magpie 若以高完整性运行（它的
/// `IsAlwaysRunAsAdmin` 会自我提权重启），我们的广播会被 UIPI 静默丢掉。
const Duration kMagpieQuitGrace = Duration(seconds: 3);

/// 会话结束后重写配置前的静置：Magpie 退出时会把内存里的配置回存
/// （`AppSettings::SaveAsync`），我们必须等它写完再改，否则改动被覆盖。
const Duration kMagpieConfigSettleDelay = Duration(milliseconds: 400);

/// 预热（bootstrap）等 Magpie 自己生成完整配置的上限。
///
/// `AppSettings::Initialize()` 读到 0 字节配置就走 `configText.empty()` 分支，当场
/// `_SetDefaultScalingModes()` + `SaveAsync()`（`AppSettings.cpp:243-246`）。`SaveAsync`
/// 只是 `resume_background()` 后直接写盘，**没有防抖也没有定时器**（`:287-293`），所以
/// 正常情况几百毫秒内就落盘。8 秒是给冷启动 + 杀软扫描留的余量。
const Duration kMagpieBootstrapTimeout = Duration(seconds: 8);

/// 预热轮询配置文件的间隔。
const Duration kMagpieBootstrapPollInterval = Duration(milliseconds: 150);

/// 超分在本次会话里的实际状态。UI 与诊断读它，**不参与任何控制流判断**。
enum MagpieUpscalingStatus {
  /// 没在跑。
  idle,

  /// 用户关掉了超分。
  disabled,

  /// 想用但用不上（`installedOnly` 且没装 / 非 Windows / 用户拒绝了下载）。
  unavailable,

  /// 正在准备（下载 / 写配置 / 拉起进程）。
  preparing,

  /// 已按自动缩放 profile 拉起 Magpie —— 游戏窗口到前台就该自动全屏超分。
  active,

  /// Magpie 起来了，但**没能配置自动缩放**，用户得自己按 Magpie 热键（默认 Win+Shift+A）。
  hotkeyOnly,

  /// 起不来（下载失败 / 进程拉不起来）。已静默降级，不影响会话。
  failed,
}

/// 一次超分尝试的完整结果（含降级原因），给 UI 与日志用。
@immutable
class MagpieUpscalingReport {
  const MagpieUpscalingReport({
    required this.status,
    this.profileSkipReason,
    this.detail,
    this.scalingActive = false,
  });

  final MagpieUpscalingStatus status;

  /// Magpie 当前**真的**在缩放吗 —— 由 native 侧的 `MagpieScalingChanged` 广播回填，
  /// 是整条链路唯一的事实反馈（其余字段都只是「我们做了什么」，不是「结果如何」）。
  ///
  /// 注意语义：源窗口切到后台**不算**缩放结束（Magpie 仍在跑），native 侧已按
  /// `wParam==0 && lParam!=0` 的判据处理过。
  final bool scalingActive;

  MagpieUpscalingReport copyWith({bool? scalingActive}) =>
      MagpieUpscalingReport(
        status: status,
        profileSkipReason: profileSkipReason,
        detail: detail,
        scalingActive: scalingActive ?? this.scalingActive,
      );

  /// 没能写自动缩放 profile 的原因；写成功或压根没走到这步时为 null。
  final MagpieProfileSkipReason? profileSkipReason;

  /// 人类可读的补充说明（异常文本等），只进日志不进 UI 文案。
  final String? detail;

  @override
  String toString() => 'MagpieUpscalingReport($status, '
      'skip=$profileSkipReason, scaling=$scalingActive, detail=$detail)';
}

/// 我们起的那个 Magpie 进程的最小句柄。
///
/// 抽出这层**只为可测**：真实 `Process` 没法在单测里造，导致「启动之后」的整条收束路径
/// （QUIT → 等退出 → 超时 kill → 复原配置）此前一行都没被覆盖。
abstract class MagpieProcessHandle {
  /// 进程退出码。detached 启动在部分平台上永远不完成 —— 调用方必须自己加超时。
  Future<int> get exitCode;

  /// 强杀。**只允许对我们自己起的进程调用**。
  void kill();
}

/// 真实实现：包一层 `dart:io` 的 [Process]。
class _RealProcessHandle implements MagpieProcessHandle {
  _RealProcessHandle(this._process);

  final Process _process;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill(ProcessSignal.sigkill);
}

/// Win32 边界的可注入抽象：**这一层存在的唯一理由是让上面的编排逻辑能在非 Windows 上单测**。
/// 真实实现是 [MagpieWindowsBridge]，只有它碰 `dart:ffi`。
abstract class MagpieWin32Bridge {
  /// 目标窗口的身份（exe 完整路径 + 窗口类名）；任一拿不到返回 null。
  MagpieWindowIdentity? identityForWindow(int hwnd);

  /// 是否已有 Magpie 实例在跑（查单实例互斥体，比找主窗口可靠 —— `-t` 模式无主窗口）。
  bool isMagpieRunning();

  /// 广播「请求退出」。成功投递返回 true（**不代表对方真的退了**）。
  bool broadcastQuit();
}

/// galgame 会话的窗口超分编排。
///
/// 生命周期与会话一一对应：[onGameWindowReady] 开，[onSessionEnded] 收。两个方法都
/// **绝不抛异常**——超分是锦上添花，任何失败都只降级、不影响 hook 会话本身。
class MagpieUpscalingService extends ChangeNotifier {
  MagpieUpscalingService({
    required MagpieUpscalingMode Function() modeReader,
    Future<bool> Function(MagpieDownloadPrompt prompt)? confirmDownload,
    MagpieWin32Bridge? bridge,
    MagpieInstaller Function()? installerFactory,
    Future<MagpieProcessHandle> Function(
      String executable,
      List<String> arguments,
    )? processLauncher,
    String? hibikiExecutablePath,
    String? configPathOverride,
    bool? isWindowsOverride,
    Duration? bootstrapTimeout,
  })  : _modeReader = modeReader,
        _confirmDownload = confirmDownload,
        _bridge = bridge,
        _installerFactory = installerFactory ?? MagpieInstaller.new,
        _processLauncher = processLauncher ?? _defaultLauncher,
        _hibikiExecutablePath =
            hibikiExecutablePath ?? _safeResolvedExecutable(),
        _configPathOverride = configPathOverride,
        _isWindows = isWindowsOverride ?? Platform.isWindows,
        _bootstrapTimeout = bootstrapTimeout ?? kMagpieBootstrapTimeout;

  final MagpieUpscalingMode Function() _modeReader;
  final Future<bool> Function(MagpieDownloadPrompt prompt)? _confirmDownload;
  final MagpieWin32Bridge? _bridge;
  final MagpieInstaller Function() _installerFactory;
  final Future<MagpieProcessHandle> Function(String, List<String>)
      _processLauncher;
  final String _hibikiExecutablePath;
  final String? _configPathOverride;
  final bool _isWindows;

  /// 预热等待上限；仅测试注入，生产恒为 [kMagpieBootstrapTimeout]。
  final Duration _bootstrapTimeout;

  /// 我们自己起的那个 Magpie。**只有它才允许被 QUIT / kill**。
  MagpieProcessHandle? _ownedProcess;

  /// 本次会话写进配置的身份，收尾时按它把 autoScale 关回去。
  MagpieWindowIdentity? _appliedIdentity;

  /// 用户本次 app 生命周期内已经拒绝过下载 —— 别每开一局游戏就弹一次框。
  bool _downloadDeclined = false;

  /// 同一时刻只允许一条编排在跑（开/收互斥），避免收尾与启动交叉。
  Future<void> _gate = Future<void>.value();

  MagpieUpscalingReport _reportValue =
      const MagpieUpscalingReport(status: MagpieUpscalingStatus.idle);

  /// 当前状态。UI 直接把本服务当 [Listenable] 订阅即可。
  MagpieUpscalingReport get report => _reportValue;

  /// 内部读写口。**所有** `_report = ...` 赋值都走这里，写完立刻 notify ——
  /// 这样以后新增赋值点的人不会忘记通知 UI（「状态变了界面不动」是个太容易犯的错）。
  MagpieUpscalingReport get _report => _reportValue;

  set _report(MagpieUpscalingReport value) {
    if (identical(_reportValue, value)) return;
    _reportValue = value;
    notifyListeners();
  }

  MagpieWin32Bridge get _win32 => _bridge ?? MagpieWindowsBridge.instance;

  static String _safeResolvedExecutable() {
    try {
      return Platform.resolvedExecutable;
    } catch (_) {
      return '';
    }
  }

  static Future<MagpieProcessHandle> _defaultLauncher(
    String executable,
    List<String> arguments,
  ) async =>
      _RealProcessHandle(
        await Process.start(
          executable,
          arguments,
          mode: ProcessStartMode.detached,
        ),
      );

  /// 便携配置文件路径（`<install>/config/config.json`）。
  String get _configPath =>
      _configPathOverride ?? MagpieInstaller.portableConfigPath();

  /// 会话拿到游戏窗口时调用。**幂等**：同一会话重复调（例如迟到重绑）只生效第一次。
  Future<void> onGameWindowReady({required int hwnd}) =>
      _serialize(() => _start(hwnd));

  /// 会话结束时调用。没启动过超分时是空操作。
  Future<void> onSessionEnded() => _serialize(_stop);

  Future<void> _serialize(Future<void> Function() job) {
    final Future<void> run = _gate.then((_) => job());
    _gate = run.catchError((Object _) {});
    return run;
  }

  Future<void> _start(int hwnd) async {
    if (_ownedProcess != null) return; // 已经起过，幂等
    final MagpieUpscalingMode mode = _readMode();
    // 「已装」= 我们自己的产物装好了 **或** 机器上已经跑着一个 Magpie（用户自装的）。
    // 后者也算，否则 `installedOnly` 会在用户明明开着 Magpie 时报 unavailable，而
    // `auto` 会去下一份多余的 10MB。两个探测都是零网络零副作用。
    final bool bundledInstalled = _isWindows && MagpieInstaller.isInstalled();
    final bool externalRunning = _isWindows && _safeIsMagpieRunning();
    final MagpieBackend backend = resolveMagpieBackend(
      mode: mode,
      isWindows: _isWindows,
      installedAvailable: bundledInstalled || externalRunning,
    );

    switch (backend) {
      case MagpieBackend.off:
        _report = const MagpieUpscalingReport(
          status: MagpieUpscalingStatus.disabled,
        );
        return;
      case MagpieBackend.unavailable:
        _report = const MagpieUpscalingReport(
          status: MagpieUpscalingStatus.unavailable,
          detail: 'magpie not installed and download disabled by setting',
        );
        return;
      case MagpieBackend.needsDownload:
        if (!await _ensureDownloaded()) return;
      case MagpieBackend.installed:
        break;
    }

    // 用户自己开着 Magpie：**什么都不做**。它的配置在哪我们不知道（可能是便携、可能在
    // %LOCALAPPDATA%），而且它读配置只在启动时读一次、退出时又会整份回写——此时改配置
    // 一定被覆盖。更要紧的是那是用户的进程，我们没有权限替他关掉重开。
    if (externalRunning) {
      _report = const MagpieUpscalingReport(
        status: MagpieUpscalingStatus.hotkeyOnly,
        profileSkipReason: MagpieProfileSkipReason.externalInstance,
        detail: 'an existing Magpie instance is already running; '
            'left untouched, user can scale with its own hotkey',
      );
      return;
    }

    _report = const MagpieUpscalingReport(
      status: MagpieUpscalingStatus.preparing,
    );

    // 🔴 首次使用的预热：我们装完写的是 0 字节便携标记，里面没有 `scalingModes`，
    // 而没有 scalingModes 就不能写 profile（`scalingMode` 会被钳到 -1 → 缩放报
    // `InvalidScalingMode`）。若不预热，**第一局游戏必然只能按热键**。
    //
    // 预热做的事：静默跑一次 Magpie 让它自己把默认配置（含 7 个 scalingModes）写出来，
    // 再退出。这样第一局就能直接自动缩放，而不是让用户以为「装完没反应」。
    await _ensureConfigMaterialized();

    // 配置必须在**拉起 Magpie 之前**写：Magpie 只在启动时读一次 config.json，全仓没有任何
    // 文件监视（无 ReadDirectoryChanges / FindFirstChangeNotification）。
    final MagpieProfileSkipReason? skip = await _applyAutoScaleProfile(hwnd);

    final String exe = MagpieInstaller.executablePath();
    try {
      _ownedProcess =
          await _processLauncher(exe, <String>[kMagpieSilentLaunchArg]);
    } catch (e) {
      await _restoreProfile();
      _report = MagpieUpscalingReport(
        status: MagpieUpscalingStatus.failed,
        detail: 'failed to launch magpie: $e',
      );
      return;
    }

    _listenScalingEvents();
    _report = MagpieUpscalingReport(
      status: skip == null
          ? MagpieUpscalingStatus.active
          : MagpieUpscalingStatus.hotkeyOnly,
      profileSkipReason: skip,
    );
  }

  /// 订阅 native 侧回传的缩放状态。**只影响 [report] 的展示字段，不参与任何控制流**——
  /// 收不到事件（native 未构建 / UIPI 拦掉 / 非 Windows）时整条链路照常工作。
  void _listenScalingEvents() {
    if (!_isWindows) return;
    try {
      MagpieScalingChannel.setHandler((MagpieScalingEvent event) {
        _report = _report.copyWith(scalingActive: event.scaling);
      });
    } catch (_) {
      // 平台通道不可用（单测环境等）：静默放弃，只是没有状态回填。
    }
  }

  void _unlistenScalingEvents() {
    if (!_isWindows) return;
    try {
      MagpieScalingChannel.clearHandler();
    } catch (_) {}
  }

  /// 互斥体探测。**零网络零副作用**（OpenMutex + CloseHandle），可以随手问。
  /// 桥实现异常一律当作「没在跑」——认不出来时宁可多起一个我们自己的实例，也不要
  /// 误判成「用户开着」而彻底不工作。
  bool _safeIsMagpieRunning() {
    try {
      return _win32.isMagpieRunning();
    } catch (_) {
      return false;
    }
  }

  MagpieUpscalingMode _readMode() {
    try {
      return _modeReader();
    } catch (_) {
      return kMagpieDefaultUpscalingMode;
    }
  }

  /// 交互路径的按需下载。**零网络探测发生在确认框之前**（BUG-1076 的教训）：
  /// `ensureInstalled` 已装时直接返回，未装时立刻弹框、大小探测在后台跑。
  Future<bool> _ensureDownloaded() async {
    final Future<bool> Function(MagpieDownloadPrompt)? confirm =
        _confirmDownload;
    if (confirm == null || _downloadDeclined) {
      _report = const MagpieUpscalingReport(
        status: MagpieUpscalingStatus.unavailable,
        detail: 'no download confirmation handler, or user already declined',
      );
      return false;
    }
    _report = const MagpieUpscalingReport(
      status: MagpieUpscalingStatus.preparing,
    );
    MagpieInstallResult result;
    try {
      result = await _installerFactory().ensureInstalled(confirm: confirm);
    } catch (e) {
      _report = MagpieUpscalingReport(
        status: MagpieUpscalingStatus.failed,
        detail: 'install threw: $e',
      );
      return false;
    }
    switch (result) {
      case MagpieInstallResult.alreadyInstalled:
      case MagpieInstallResult.installed:
        return true;
      case MagpieInstallResult.declined:
        _downloadDeclined = true;
        _report = const MagpieUpscalingReport(
          status: MagpieUpscalingStatus.unavailable,
          detail: 'user declined the download',
        );
        return false;
      case MagpieInstallResult.failed:
      case MagpieInstallResult.unsupportedPlatform:
        _report = MagpieUpscalingReport(
          status: MagpieUpscalingStatus.failed,
          detail: 'install result: ${result.name}',
        );
        return false;
    }
  }

  /// 预热：确保 `config.json` 里已经有 Magpie 自己生成的完整配置（关键是 `scalingModes`）。
  ///
  /// 已经就绪时**零成本直接返回**（只读一次文件），所以第二局起不会再付这份开销。
  ///
  /// 为什么必须由 Magpie 自己生成而不是我们手写：`scalingModes` 是 7 套带效果参数的缩放
  /// 算法配置，手写等于猜上游的私有 schema —— 那正是设计文档 §3.2 明令禁止的事。让它自己
  /// 跑一次是唯一既正确又零 schema 猜测的办法。
  ///
  /// 任何一步失败都静默返回：调用方随后读配置仍会失败，自然降级为热键模式。
  Future<void> _ensureConfigMaterialized() async {
    try {
      if (await _readConfig() != null) return; // 早就好了
      final String exe = MagpieInstaller.executablePath();
      if (!File(exe).existsSync()) return;

      final MagpieProcessHandle warmup =
          await _processLauncher(exe, <String>[kMagpieSilentLaunchArg]);
      try {
        await _waitForConfig();
      } finally {
        // 预热实例必须收干净：它是我们起的，绝不能留一个游离的 Magpie 在跑，
        // 否则下面「真正」那次启动会被单实例互斥体挡掉。
        try {
          _win32.broadcastQuit();
        } catch (_) {}
        await _waitForExit(warmup);
        await Future<void>.delayed(kMagpieConfigSettleDelay);
      }
    } catch (_) {
      // 预热是纯优化：失败只意味着这一局退回热键模式，不影响会话。
    }
  }

  /// 轮询等配置文件变得可用（非空且能解析）。超时就返回，由调用方降级。
  Future<void> _waitForConfig() async {
    final DateTime deadline = DateTime.now().add(_bootstrapTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(kMagpieBootstrapPollInterval);
      Map<String, dynamic>? config;
      try {
        config = await _readConfig();
      } catch (_) {
        config = null; // 可能正读到半写状态，下一轮再试
      }
      final Object? modes = config?['scalingModes'];
      if (modes is List && modes.isNotEmpty) return;
    }
  }

  /// **best-effort** 写自动缩放 profile。返回 null 表示写成功；返回原因表示降级为「只启动
  /// 不配置」。任何异常都被吞成 [MagpieProfileSkipReason.schemaMismatch]。
  Future<MagpieProfileSkipReason?> _applyAutoScaleProfile(int hwnd) async {
    try {
      final MagpieWindowIdentity? identity = _win32.identityForWindow(hwnd);
      if (identity == null || !identity.isComplete) {
        return MagpieProfileSkipReason.missingWindowIdentity;
      }
      final Map<String, dynamic>? config = await _readConfig();
      // 走到这里还读不出配置，说明预热没成功（0 字节标记还在，或 Magpie 起不来）。
      // 这是「第一次用」路径上最常见的降级，单独给个原因让 UI 能说人话。
      if (config == null) return MagpieProfileSkipReason.bootstrapFailed;

      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: config,
        identity: identity,
        profileName: _profileNameFor(identity),
        hibikiExecutablePath: _hibikiExecutablePath,
      );
      if (!result.applied) {
        // alreadySatisfied 说明配置里已经有一条启用了的等价 profile —— 那是成功不是降级，
        // 但它不是我们这轮加的，收尾时也就不该由我们关掉。
        if (result.skipReason == MagpieProfileSkipReason.alreadySatisfied) {
          return null;
        }
        return result.skipReason;
      }
      await _writeConfig(result.config!);
      _appliedIdentity = identity;
      return null;
    } catch (_) {
      return MagpieProfileSkipReason.schemaMismatch;
    }
  }

  /// profile 显示名。带 `Hibiki` 前缀是为了让用户在 Magpie 的 UI 里一眼认出「这条是谁加的」。
  String _profileNameFor(MagpieWindowIdentity identity) {
    final String base = identity.executablePath.split(RegExp(r'[\\/]')).last;
    return 'Hibiki: ${base.isEmpty ? identity.windowClassName : base}';
  }

  Future<Map<String, dynamic>?> _readConfig() async {
    final File file = File(_configPath);
    if (!file.existsSync()) return null;
    final String text = await file.readAsString();
    // 0 字节 = 我们写的便携标记，Magpie 还没跑过第一次 → 没有 scalingModes 可用，
    // 此时写 profile 必然踩 -1 钳位陷阱。交给上层降级为热键模式。
    if (text.trim().isEmpty) return null;
    final Object? decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<void> _writeConfig(Map<String, dynamic> config) async {
    final File file = File(_configPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
      flush: true,
    );
  }

  Future<void> _stop() async {
    _unlistenScalingEvents();
    final MagpieProcessHandle? owned = _ownedProcess;
    _ownedProcess = null;
    if (owned != null) {
      // 先礼后兵：广播 QUIT 让它自己收（能正常清理缩放窗口），超时再 kill。
      try {
        _win32.broadcastQuit();
      } catch (_) {}
      await _waitForExit(owned);
    }
    // 必须在 Magpie 真的退出**之后**再改配置：它退出时会把内存里的设置整份回存
    // （`AppSettings::SaveAsync`），提前改一定被覆盖。
    await Future<void>.delayed(kMagpieConfigSettleDelay);
    await _restoreProfile();
    _report = const MagpieUpscalingReport(status: MagpieUpscalingStatus.idle);
  }

  Future<void> _waitForExit(MagpieProcessHandle process) async {
    try {
      await process.exitCode.timeout(kMagpieQuitGrace);
    } catch (_) {
      // 超时（或拿不到 exitCode：detached 启动在部分平台上就是这样）→ 强杀。
      // 只杀我们自己起的这一个 PID，绝不按进程名扫。
      try {
        process.kill();
      } catch (_) {}
    }
  }

  /// 把本次会话加的 autoScale 关回去。**必须做**：留着的话，用户下次不经 Hibiki 直接双击
  /// 游戏也会被 Magpie 自动拉起缩放 —— 那是我们没被授权做的事。
  Future<void> _restoreProfile() async {
    final MagpieWindowIdentity? identity = _appliedIdentity;
    _appliedIdentity = null;
    if (identity == null) return;
    try {
      final Map<String, dynamic>? config = await _readConfig();
      if (config == null) return;
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleDisabled(
        config: config,
        identity: identity,
      );
      if (result.applied) await _writeConfig(result.config!);
    } catch (_) {
      // 收尾是 best-effort：配置被用户改乱了也不该让会话结束报错。
    }
  }
}

/// Windows 真实实现：裸 `dart:ffi` 调 user32/kernel32。
///
/// 走裸 FFI 而不是 `package:win32` —— win32 在本仓只是**传递依赖**，直接 import 会触发
/// `depend_on_referenced_packages`（CI 把 warning 当致命）。同 `galgame_play_tracker.dart`
/// 与 `desktop_foreground_guard.dart` 的既有范式。
class MagpieWindowsBridge implements MagpieWin32Bridge {
  MagpieWindowsBridge._();

  static final MagpieWindowsBridge instance = MagpieWindowsBridge._();

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static const int _processQueryLimitedInformation = 0x1000;
  static const int _synchronize = 0x00100000;
  static const int _hwndBroadcast = 0xFFFF;
  static const int _maxPath = 32768;

  late final _GetClassNameDart _getClassName = _user32
      .lookupFunction<_GetClassNameNative, _GetClassNameDart>('GetClassNameW');
  late final _GetWindowThreadProcessIdDart _getWindowThreadProcessId =
      _user32.lookupFunction<_GetWindowThreadProcessIdNative,
          _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
  late final _RegisterWindowMessageDart _registerWindowMessage = _user32
      .lookupFunction<_RegisterWindowMessageNative, _RegisterWindowMessageDart>(
          'RegisterWindowMessageW');
  late final _PostMessageDart _postMessage = _user32
      .lookupFunction<_PostMessageNative, _PostMessageDart>('PostMessageW');
  late final _OpenProcessDart _openProcess = _kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
  late final _QueryFullProcessImageNameDart _queryFullProcessImageName =
      _kernel32.lookupFunction<_QueryFullProcessImageNameNative,
          _QueryFullProcessImageNameDart>('QueryFullProcessImageNameW');
  late final _OpenMutexDart _openMutex =
      _kernel32.lookupFunction<_OpenMutexNative, _OpenMutexDart>('OpenMutexW');
  late final _CloseHandleDart _closeHandle = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

  @override
  MagpieWindowIdentity? identityForWindow(int hwnd) {
    if (!Platform.isWindows || hwnd == 0) return null;
    final String? className = _classNameOf(hwnd);
    if (className == null || className.isEmpty) return null;
    final String? path = _executablePathOf(hwnd);
    if (path == null || path.isEmpty) return null;
    return MagpieWindowIdentity(
      executablePath: path,
      windowClassName: className,
    );
  }

  String? _classNameOf(int hwnd) {
    // 类名上限 256 个 WCHAR（RegisterClass 的硬上限），留一位收尾 NUL。
    final Pointer<Uint16> buffer = calloc<Uint16>(257);
    try {
      final int length = _getClassName(hwnd, buffer, 257);
      if (length <= 0) return null;
      return buffer.cast<Utf16>().toDartString(length: length);
    } catch (_) {
      return null;
    } finally {
      calloc.free(buffer);
    }
  }

  /// exe 完整路径。**必须用 `QueryFullProcessImageNameW`** —— Magpie 自己的
  /// `Win32Helper::GetWindowPath` 走的就是它，换个 API（如 `GetModuleFileNameEx`）拿到的
  /// 路径形态可能不同（DOS 设备名 vs 盘符），而 Magpie 的匹配是**裸字符串相等**。
  String? _executablePathOf(int hwnd) {
    final Pointer<Uint32> pidOut = calloc<Uint32>();
    try {
      _getWindowThreadProcessId(hwnd, pidOut);
      final int pid = pidOut.value;
      if (pid == 0) return null;
      final int handle = _openProcess(_processQueryLimitedInformation, 0, pid);
      if (handle == 0) return null;
      final Pointer<Uint16> buffer = calloc<Uint16>(_maxPath);
      final Pointer<Uint32> size = calloc<Uint32>();
      try {
        size.value = _maxPath;
        if (_queryFullProcessImageName(handle, 0, buffer, size) == 0) {
          return null;
        }
        return buffer.cast<Utf16>().toDartString(length: size.value);
      } finally {
        calloc.free(buffer);
        calloc.free(size);
        _closeHandle(handle);
      }
    } catch (_) {
      return null;
    } finally {
      calloc.free(pidOut);
    }
  }

  @override
  bool isMagpieRunning() {
    if (!Platform.isWindows) return false;
    final Pointer<Utf16> name = kMagpieSingleInstanceMutex.toNativeUtf16();
    try {
      final int handle = _openMutex(_synchronize, 0, name);
      if (handle == 0) return false;
      _closeHandle(handle);
      return true;
    } catch (_) {
      return false;
    } finally {
      calloc.free(name);
    }
  }

  @override
  bool broadcastQuit() {
    if (!Platform.isWindows) return false;
    final Pointer<Utf16> name = kMagpieQuitMessage.toNativeUtf16();
    try {
      final int message = _registerWindowMessage(name);
      if (message == 0) return false;
      return _postMessage(_hwndBroadcast, message, 0, 0) != 0;
    } catch (_) {
      return false;
    } finally {
      calloc.free(name);
    }
  }
}

typedef _GetClassNameNative = Int32 Function(
    IntPtr hwnd, Pointer<Uint16> buffer, Int32 maxCount);
typedef _GetClassNameDart = int Function(
    int hwnd, Pointer<Uint16> buffer, int maxCount);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
    IntPtr hwnd, Pointer<Uint32> pid);
typedef _GetWindowThreadProcessIdDart = int Function(
    int hwnd, Pointer<Uint32> pid);

typedef _RegisterWindowMessageNative = Uint32 Function(Pointer<Utf16> name);
typedef _RegisterWindowMessageDart = int Function(Pointer<Utf16> name);

typedef _PostMessageNative = Int32 Function(
    IntPtr hwnd, Uint32 message, IntPtr wParam, IntPtr lParam);
typedef _PostMessageDart = int Function(
    int hwnd, int message, int wParam, int lParam);

typedef _OpenProcessNative = IntPtr Function(
    Uint32 access, Int32 inherit, Uint32 pid);
typedef _OpenProcessDart = int Function(int access, int inherit, int pid);

typedef _QueryFullProcessImageNameNative = Int32 Function(
    IntPtr process, Uint32 flags, Pointer<Uint16> buffer, Pointer<Uint32> size);
typedef _QueryFullProcessImageNameDart = int Function(
    int process, int flags, Pointer<Uint16> buffer, Pointer<Uint32> size);

typedef _OpenMutexNative = IntPtr Function(
    Uint32 access, Int32 inherit, Pointer<Utf16> name);
typedef _OpenMutexDart = int Function(
    int access, int inherit, Pointer<Utf16> name);

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:hibiki/src/platform/desktop/windows_native_pre_exit.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/update_handoff.dart';
import 'package:hibiki/utils.dart'; // ErrorLogService

export 'update_handoff.dart'
    show
        WindowsDetectedInstallLocation,
        WindowsInnoDeleteFileFailure,
        WindowsInstallerDiagnostics,
        WindowsProcessInfo;

enum UpdateChannel { stable, beta, debug }

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    this.sizeBytes,
    this.sha256Digest,
  });

  factory UpdateAsset.fromReleaseAsset(Map<String, dynamic> asset) {
    return UpdateAsset(
      name: asset['name'] as String? ?? '',
      url: asset['browser_download_url'] as String? ?? '',
      sizeBytes: _assetSizeBytes(asset['size']),
      sha256Digest: _assetSha256Digest(asset['digest'] ?? asset['sha256']),
    );
  }

  final String name;
  final String url;
  final int? sizeBytes;
  final String? sha256Digest;

  UpdateAsset copyWith({
    String? name,
    String? url,
    int? sizeBytes,
    String? sha256Digest,
  }) =>
      UpdateAsset(
        name: name ?? this.name,
        url: url ?? this.url,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        sha256Digest: sha256Digest ?? this.sha256Digest,
      );
}

int? _assetSizeBytes(Object? raw) {
  if (raw is int && raw >= 0) return raw;
  if (raw is num && raw >= 0) return raw.toInt();
  if (raw is String) {
    final int? parsed = int.tryParse(raw.trim());
    if (parsed != null && parsed >= 0) return parsed;
  }
  return null;
}

String? _assetSha256Digest(Object? raw) {
  if (raw is! String) return null;
  final String normalized = raw.trim().toLowerCase();
  final String digest = normalized.startsWith('sha256:')
      ? normalized.substring('sha256:'.length)
      : normalized;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ? digest : null;
}

/// 每平台的更新策略：选包（[selectAsset]）+ 安装（[apply]）。
/// 共享的 GitHub 拉取/版本比较/下载浮层仍在 UpdateChecker。
abstract class PlatformUpdater {
  /// 当前平台是否支持「检查更新」（iOS/未实现桌面也为 true，只是 apply=打开发布页）。
  bool get supportsUpdateCheck;

  /// 当前平台是否支持「应用内安装」（决定是否显示自动安装、是否走下载→apply）。
  bool get supportsInAppInstall;

  /// 从 release 的 [assets]（每项含 name / browser_download_url）挑本平台可安装包的
  /// 下载 URL；null = 无适配包（上层回退打开发布页）。
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  });

  /// 应用已下载到 [file] 的更新。仅在 [supportsInAppInstall] 为 true 时被调用。
  Future<void> apply(File file, String version);
}

/// 本期支持「应用内安装」的平台集合（单一真相源；macOS/Linux 在各自阶段加入）。
bool platformSupportsInAppInstall() => Platform.isAndroid || Platform.isWindows;

/// Flutter `--split-per-abi` 产出的 Android ABI 标签（CI 的 `app-<abi>-release.apk`
/// 即据此重命名为 `hibiki-<version>-<abi>.apk`，见 `.github/workflows/release.yml`）。
/// 作为「stable release 资产命名」单一真相源的一部分，供 [synthesizeStableAssetNames]
/// 在没有 GitHub API 资产清单时（TODO-404：纯 GFW 下检查只能拿到 302 跳转里的 tag）
/// 重建候选资产名。
const List<String> kAndroidReleaseAbis = <String>[
  'arm64-v8a',
  'armeabi-v7a',
  'x86_64',
];

/// **纯函数**：按 release 资产命名规则，为某个 stable [version]（已 normalize、不带前导
/// `v`）合成「本应存在于该 release 的可安装资产名」列表。
///
/// 根因背景（TODO-404 / BUG-292）：纯 GFW 且无代理时，更新「检查」打 `api.github.com`
/// 必被镜像 403，唯一可成功的是 `github.com/.../releases/latest` 的 302 网页跳转——但
/// 它只给得到 tag，给不到 GitHub API 的 `assets` 清单。下载阶段又必须知道精确资产名才
/// 能拼出 `releases/download/<tag>/<name>`。命名规则本就是确定的（CI 固定生成），故这里
/// 据 [kAndroidReleaseAbis] + Windows setup 命名把候选资产名重建出来，喂回现有
/// `selectAsset`（Android 仍按设备真实 ABI 自行挑、Windows 直接命中 setup），不在
/// update_checker 里硬编码命名、不绕过既有挑包逻辑。
///
/// 只覆盖「能应用内安装」的平台（Android / Windows，见 [platformSupportsInAppInstall]）；
/// 其余平台 `selectAsset` 本就返 null（走打开发布页），无需合成。仅用于 **stable** 通道
/// （beta/debug 的列表网页经镜像 403，需 TODO-404 方案 B 的 latest.json，本期不做）。
List<String> synthesizeStableAssetNames(String version) {
  final List<String> names = <String>[
    'hibiki-$version-windows-setup.exe',
    for (final String abi in kAndroidReleaseAbis) 'hibiki-$version-$abi.apk',
  ];
  return List<String>.unmodifiable(names);
}

/// 所有平台都至少支持「检查更新 → 打开发布页」。
bool platformSupportsUpdateCheck() => true;

PlatformUpdater updaterForCurrentPlatform() {
  if (Platform.isAndroid) return AndroidUpdater();
  if (Platform.isWindows) return WindowsUpdater();
  return UnsupportedUpdater();
}

/// 从 asset map 安全取出可下载的 (name, url)。
Iterable<UpdateAsset> _downloadable(List<Map<String, dynamic>> assets) sync* {
  for (final Map<String, dynamic> a in assets) {
    final UpdateAsset asset = UpdateAsset.fromReleaseAsset(a);
    if (asset.name.isEmpty || asset.url.isEmpty) continue;
    yield asset;
  }
}

bool _isDebugApkAsset(String name) =>
    name.endsWith('-debug.apk') || name.contains('-debug.');

bool _androidAssetMatchesChannel(String name, UpdateChannel channel) {
  if (!name.endsWith('.apk')) return false;
  return switch (channel) {
    UpdateChannel.debug => _isDebugApkAsset(name),
    UpdateChannel.stable || UpdateChannel.beta => !_isDebugApkAsset(name),
  };
}

bool _isDebugWindowsSetupAsset(String name) =>
    name.endsWith('-windows-setup.exe') && name.contains('-debug.');

bool _windowsAssetMatchesChannel(String name, UpdateChannel channel) {
  if (!name.endsWith('-windows-setup.exe')) return false;
  return switch (channel) {
    UpdateChannel.debug => _isDebugWindowsSetupAsset(name),
    UpdateChannel.stable ||
    UpdateChannel.beta =>
      !_isDebugWindowsSetupAsset(name),
  };
}

class AndroidUpdater extends PlatformUpdater {
  AndroidUpdater({Future<List<String>> Function()? abiProvider})
      : _abiProvider = abiProvider ?? _defaultAbis;

  final Future<List<String>> Function() _abiProvider;

  static Future<List<String>> _defaultAbis() async {
    try {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      return info.supportedAbis;
    } catch (e, s) {
      ErrorLogService.instance.log('PlatformUpdater.getAbi', e, s);
      return <String>[];
    }
  }

  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    final List<String> abis = await _abiProvider();
    final List<String> abiTags =
        abis.map((String a) => a.replaceAll('_', '-')).toList();
    UpdateAsset? fallback;
    for (final UpdateAsset asset in _downloadable(assets)) {
      final String name = asset.name;
      if (!_androidAssetMatchesChannel(name, channel)) continue;
      if (abiTags.any(name.contains)) return asset;
      fallback ??= asset;
    }
    return fallback;
  }

  @override
  Future<void> apply(File file, String version) async {
    await AndroidInstaller.install(file.path);
  }
}

class WindowsUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    for (final UpdateAsset asset in _downloadable(assets)) {
      if (_windowsAssetMatchesChannel(asset.name, channel)) return asset;
    }
    return null;
  }

  @override
  Future<void> apply(File file, String version) async {
    await WindowsInstaller.runAndExit(
      file.path,
      targetVersion: version,
      handoffMarkerFile: WindowsUpdateHandoff.markerFile(file.parent),
    );
  }
}

/// iOS + 本期未实现的 macOS/Linux：可检查但不能自装。
class UnsupportedUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => false;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async =>
      null;

  @override
  Future<void> apply(File file, String version) async {
    throw StateError('UnsupportedUpdater.apply must not be called');
  }
}

// ── 安装器（Task 4 落地 Windows，本 Task 落地 Android）──
/// Android 原生安装：仅 Android 注册的 installApk 通道（FileProvider + ACTION_VIEW，
/// 带 HBK-AUDIT-058 路径校验，见 MainActivity.java）。
class AndroidInstaller {
  static Future<void> install(String apkPath) async {
    await HibikiChannels.update.invokeMethod('installApk', <String, String>{
      'path': apkPath,
    });
  }
}

/// Inno Setup 静默安装参数：
/// - `/VERYSILENT` + `/SP-`：抑制整个向导、跳过初始「准备安装」提示。
/// - `/SUPPRESSMSGBOXES`：配合 `/VERYSILENT` 抑制 Inno 的错误/选择弹窗，避免
///   `DeleteFile failed code 5` 把用户留在 Select action。
/// - `/NOCLOSEAPPLICATIONS` + `/NOFORCECLOSEAPPLICATIONS`：禁止 Inno /
///   RestartManager 自动关闭或强制结束任何残留 Hibiki / libmpv 持有进程。
/// - `/NORESTARTAPPLICATIONS`：不让 RestartManager 自动拉起被它管理的应用。
/// - `/NORESTART`：禁止安装器重启**操作系统**（我们只想重启 app，不重启系统）。
/// - `/DIR=`：应用内更新只写当前运行 `hibiki.exe` 所在目录，不追随注册表或历史路径。
List<String> windowsInstallerArgs(
  String installerPath, {
  String? logPath,
  String? targetInstallDir,
}) =>
    <String>[
      '/VERYSILENT',
      '/SP-',
      '/SUPPRESSMSGBOXES',
      '/NOCLOSEAPPLICATIONS',
      '/NOFORCECLOSEAPPLICATIONS',
      '/NORESTARTAPPLICATIONS',
      '/NORESTART',
      if (targetInstallDir != null && targetInstallDir.trim().isNotEmpty)
        '/DIR=$targetInstallDir',
      '/LOG=${logPath ?? windowsInstallerLogPath(installerPath)}',
    ];

String windowsInstallerLogPath(String installerPath) {
  final int sep = _lastPathSeparatorIndex(installerPath);
  final String dir = sep >= 0 ? installerPath.substring(0, sep) : '';
  final String name =
      sep >= 0 ? installerPath.substring(sep + 1) : installerPath;
  final String stem = name.toLowerCase().endsWith('.exe')
      ? name.substring(0, name.length - 4)
      : name;
  final String logName = '$stem.install.log';
  if (dir.isEmpty) return logName;
  return '$dir${Platform.pathSeparator}$logName';
}

int _lastPathSeparatorIndex(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  return slash > backslash ? slash : backslash;
}

/// Windows 安装器启动/校验失败。被 UpdateChecker 的下载流程 catch → SnackBar 优雅
/// 降级，绝不让损坏下载或启动失败演化成「app 静默消失」式崩溃。
class UpdateInstallerException implements Exception {
  UpdateInstallerException(this.message);

  final String message;

  @override
  String toString() => 'UpdateInstallerException: $message';
}

/// 下载产物是否是真正的 Windows 可执行文件：PE 文件以 DOS「MZ」魔数
/// (0x4D 0x5A) 开头。GFW 下走的 GitHub 代理镜像（ghfast.top / ghproxy）可能用
/// HTTP 200 回一个 HTML 限流/错误页，被原样写进 `hibiki-<v>.exe`；把这种字节喂给
/// `Process.start` 在 Windows 上行为不可控（ERROR_BAD_EXE_FORMAT 等），必须先拦掉。
bool isWindowsExecutableHeader(List<int> header) =>
    header.length >= 2 && header[0] == 0x4D && header[1] == 0x5A;

class WindowsInstallerStartedProcess {
  const WindowsInstallerStartedProcess({required this.pid});

  final int? pid;
}

class WindowsInstallerPostLaunchObservation {
  const WindowsInstallerPostLaunchObservation({
    required this.observedAt,
    required this.installerProcessRunning,
    required this.innoLogExists,
    this.innoLogSizeBytes,
    this.innoLogDeleteFileFailures = const <WindowsInnoDeleteFileFailure>[],
    this.error,
  });

  final DateTime observedAt;
  final bool? installerProcessRunning;
  final bool innoLogExists;
  final int? innoLogSizeBytes;
  final List<WindowsInnoDeleteFileFailure> innoLogDeleteFileFailures;
  final String? error;
}

class WindowsInstaller {
  static Future<WindowsInstallerStartedProcess> _startDetachedInstallerProcess(
    String executable,
    List<String> args,
  ) async {
    final Process process = await Process.start(
      executable,
      args,
      mode: ProcessStartMode.detached,
    );
    return WindowsInstallerStartedProcess(pid: process.pid);
  }

  /// 启动安装器（分离进程）后退出本进程，让安装器替换运行中的 exe 并重启 app。
  ///
  /// 根因修复（Windows 点自动更新崩溃）：
  /// 1. 先校验下载产物确实是 PE 可执行文件，避免把代理 HTML/截断文件喂给
  ///    `Process.start`（曾导致行为不可控）。
  /// 2. 仅当安装器进程**确实启动成功**后才 `exit(0)`；启动失败抛
  ///    [UpdateInstallerException]（上层 catch → SnackBar），绝不让本进程在没有
  ///    接班者的情况下静默消失（用户视角即「崩溃」）。
  static Future<void> runAndExit(
    String installerPath, {
    String? targetVersion,
    File? handoffMarkerFile,
    DateTime Function()? now,
    String? currentExecutablePath,
    Future<WindowsInstallerDiagnostics> Function()? collectDiagnostics,
    Future<WindowsInstallerStartedProcess> Function(
      String executable,
      List<String> args,
    )? startProcess,
    Future<WindowsInstallerPostLaunchObservation> Function(
      int? installerPid,
      String innoLogPath,
    )? observePostLaunch,
    void Function(int code)? exitProcess,
  }) async {
    final DateTime Function() clock = now ?? DateTime.now;
    final String innoLogPath = windowsInstallerLogPath(installerPath);
    final String resolvedExecutablePath =
        currentExecutablePath ?? Platform.resolvedExecutable;
    final Directory currentInstallDir = File(resolvedExecutablePath).parent;
    final WindowsInstallerDiagnostics rawDiagnostics = Platform.isWindows
        ? await (collectDiagnostics ??
            () => collectWindowsInstallerDiagnostics(
                  currentExecutablePath: resolvedExecutablePath,
                  currentProcessId: pid,
                ))()
        : WindowsInstallerDiagnostics(
            currentExecutablePath: resolvedExecutablePath,
            currentInstallDir: currentInstallDir.path,
            targetInstallDir: currentInstallDir.path,
            detectedInstallLocations: <WindowsDetectedInstallLocation>[
              WindowsDetectedInstallLocation(
                source: 'current',
                path: currentInstallDir.path,
              ),
            ],
          );
    final String targetInstallDir =
        rawDiagnostics.targetInstallDir ?? currentInstallDir.path;
    final WindowsInstallerDiagnostics diagnostics = rawDiagnostics.copyWith(
      currentExecutablePath:
          rawDiagnostics.currentExecutablePath ?? resolvedExecutablePath,
      currentInstallDir:
          rawDiagnostics.currentInstallDir ?? currentInstallDir.path,
      targetInstallDir: targetInstallDir,
    );
    if (targetVersion != null && handoffMarkerFile != null) {
      await WindowsUpdateHandoff.writePending(
        markerFile: handoffMarkerFile,
        targetVersion: targetVersion,
        installerPath: installerPath,
        innoLogPath: innoLogPath,
        startedAt: clock(),
        diagnostics: diagnostics,
      );
      ErrorLogService.instance.log(
        'WindowsInstaller.handoff',
        'Prepared Windows update handoff: target=$targetVersion, '
            'installer=$installerPath, targetDir=$targetInstallDir, '
            'log=$innoLogPath',
      );
    }

    final File installer = File(installerPath);
    try {
      if (!installer.existsSync()) {
        throw UpdateInstallerException('installer not found: $installerPath');
      }
      final List<int> header = await _readHeaderBytes(installer);
      if (!isWindowsExecutableHeader(header)) {
        // 下载的不是真正的安装器（多半是代理返回的 HTML/损坏文件）：删掉脏文件，
        // 抛错让上层提示「更新失败」并保留 app 存活，而不是硬启动一个坏 exe。
        try {
          installer.deleteSync();
        } catch (_) {/* best-effort cleanup */}
        throw UpdateInstallerException(
            'downloaded file is not a Windows executable: $installerPath');
      }
      if (Platform.isWindows) {
        await ensureWindowsInstallTargetWritable(Directory(targetInstallDir));
        _throwIfWindowsInstallBlocked(diagnostics, innoLogPath);
      }

      final List<String> args = windowsInstallerArgs(
        installerPath,
        logPath: innoLogPath,
        targetInstallDir: Platform.isWindows ? targetInstallDir : null,
      );
      ErrorLogService.instance.log(
        'WindowsInstaller.launch',
        'Launching Windows installer: $installerPath ${args.join(' ')}',
      );
      final Future<WindowsInstallerStartedProcess> Function(
        String executable,
        List<String> args,
      ) start = startProcess ?? _startDetachedInstallerProcess;
      final WindowsInstallerStartedProcess started = await start(
        installerPath,
        args,
      );
      if (targetVersion != null && handoffMarkerFile != null) {
        await WindowsUpdateHandoff.markLaunchSucceeded(
          markerFile: handoffMarkerFile,
          launchedAt: clock(),
          installerPid: started.pid,
        );
      }
      final WindowsInstallerPostLaunchObservation observation =
          await _observeInstallerPostLaunch(
        installerPid: started.pid,
        innoLogPath: innoLogPath,
        observePostLaunch: observePostLaunch,
      );
      if (targetVersion != null && handoffMarkerFile != null) {
        await WindowsUpdateHandoff.markPostLaunchObserved(
          markerFile: handoffMarkerFile,
          observedAt: observation.observedAt,
          installerProcessRunning: observation.installerProcessRunning,
          innoLogExists: observation.innoLogExists,
          innoLogSizeBytes: observation.innoLogSizeBytes,
          innoLogDeleteFileFailures: observation.innoLogDeleteFileFailures,
          observationError: observation.error,
        );
      }
      ErrorLogService.instance.log(
        'WindowsInstaller.launch',
        'Windows installer launched: target=${targetVersion ?? 'unknown'}, '
            'pid=${started.pid ?? 'unknown'}, log=$innoLogPath, '
            'processRunning=${observation.installerProcessRunning}, '
            'logExists=${observation.innoLogExists}, '
            'logBytes=${observation.innoLogSizeBytes ?? 'unknown'}, '
            'deleteFileFailures='
            '${observation.innoLogDeleteFileFailures.length}',
      );
    } on ProcessException catch (e) {
      final exception =
          UpdateInstallerException('failed to launch installer: ${e.message}');
      await _markLaunchFailed(
        handoffMarkerFile,
        exception,
        clock(),
        StackTrace.current,
      );
      throw exception;
    } catch (e, stack) {
      await _markLaunchFailed(handoffMarkerFile, e, clock(), stack);
      rethrow;
    }

    // 安装器已成功启动（分离进程）。当前实例只让出自己的 hibiki.exe 文件锁；
    // 其他 Hibiki/libmpv 持有进程已经在 preflight 被列出并要求用户手动关闭，
    // 这里绝不委托 Inno/RestartManager 自动关闭或强制结束残留进程。
    await Future<void>.delayed(Duration.zero);
    await WindowsNativePreExit.prepareForExit();
    (exitProcess ?? exit)(0);
  }

  static Future<List<int>> _readHeaderBytes(File file) async {
    final RandomAccessFile raf = await file.open();
    try {
      return await raf.read(2);
    } finally {
      await raf.close();
    }
  }

  static Future<WindowsInstallerPostLaunchObservation>
      _observeInstallerPostLaunch({
    required int? installerPid,
    required String innoLogPath,
    required Future<WindowsInstallerPostLaunchObservation> Function(
      int? installerPid,
      String innoLogPath,
    )? observePostLaunch,
  }) async {
    if (observePostLaunch != null) {
      try {
        return await observePostLaunch(installerPid, innoLogPath);
      } catch (e) {
        return WindowsInstallerPostLaunchObservation(
          observedAt: DateTime.now(),
          installerProcessRunning: null,
          innoLogExists: await File(innoLogPath).exists(),
          innoLogDeleteFileFailures:
              await _readWindowsInnoDeleteFileFailures(innoLogPath),
          error: e.toString(),
        );
      }
    }

    const Duration interval = Duration(milliseconds: 200);
    final DateTime deadline =
        DateTime.now().add(const Duration(milliseconds: 1200));
    bool? installerProcessRunning;
    bool innoLogExists = false;
    int? innoLogSizeBytes;
    List<WindowsInnoDeleteFileFailure> innoLogDeleteFileFailures =
        const <WindowsInnoDeleteFileFailure>[];
    String? error;

    do {
      try {
        if (installerPid != null) {
          installerProcessRunning =
              await _isWindowsProcessRunning(installerPid);
        }
        final File innoLog = File(innoLogPath);
        innoLogExists = await innoLog.exists();
        innoLogSizeBytes = innoLogExists ? await innoLog.length() : null;
        innoLogDeleteFileFailures = innoLogExists
            ? parseWindowsInnoDeleteFileFailures(await innoLog.readAsString())
            : const <WindowsInnoDeleteFileFailure>[];
        if (installerProcessRunning == true || innoLogExists) break;
      } catch (e) {
        error = e.toString();
      }
      if (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(interval);
      }
    } while (DateTime.now().isBefore(deadline));

    return WindowsInstallerPostLaunchObservation(
      observedAt: DateTime.now(),
      installerProcessRunning: installerProcessRunning,
      innoLogExists: innoLogExists,
      innoLogSizeBytes: innoLogSizeBytes,
      innoLogDeleteFileFailures: innoLogDeleteFileFailures,
      error: error,
    );
  }

  static Future<bool?> _isWindowsProcessRunning(int pid) async {
    if (!Platform.isWindows) return null;
    try {
      final ProcessResult result = await Process.run(
        'tasklist',
        <String>['/FI', 'PID eq $pid', '/NH'],
      );
      if (result.exitCode != 0) return null;
      final String output = '${result.stdout}\n${result.stderr}';
      return RegExp('(^|\\s)$pid(\\s|\$)').hasMatch(output);
    } catch (_) {
      return null;
    }
  }

  static void _throwIfWindowsInstallBlocked(
    WindowsInstallerDiagnostics diagnostics,
    String innoLogPath,
  ) {
    final List<WindowsProcessInfo> blockers =
        _blockingWindowsInstallProcesses(diagnostics);
    if (blockers.isEmpty) return;

    final String target = diagnostics.targetInstallDir ?? 'unknown';
    final String holderSummary = blockers
        .map(
          (WindowsProcessInfo process) =>
              'PID ${process.pid}: ${process.path ?? process.name ?? 'unknown'}',
        )
        .join('; ');
    throw UpdateInstallerException(
      'Hibiki cannot install while another Hibiki/libmpv process is using '
      'the target directory. Target: $target. Holders: $holderSummary. '
      'Close the listed process manually, then retry the installer. '
      'Installer log: $innoLogPath',
    );
  }

  static List<WindowsProcessInfo> _blockingWindowsInstallProcesses(
    WindowsInstallerDiagnostics diagnostics,
  ) {
    final String? targetInstallDir = diagnostics.targetInstallDir;
    final Map<int, WindowsProcessInfo> blockers = <int, WindowsProcessInfo>{};
    for (final WindowsProcessInfo process
        in diagnostics.runningHibikiProcesses) {
      if (_processIsInTargetInstallDir(process, targetInstallDir)) {
        blockers[process.pid] = process;
      }
    }
    for (final WindowsProcessInfo process in diagnostics.libmpvModuleHolders) {
      if (_processIsInTargetInstallDir(process, targetInstallDir) ||
          (process.name ?? '').toLowerCase() == 'hibiki.exe') {
        blockers[process.pid] = process;
      }
    }
    return blockers.values.toList(growable: false);
  }

  static bool _processIsInTargetInstallDir(
    WindowsProcessInfo process,
    String? targetInstallDir,
  ) {
    final String? processPath = process.path;
    if (targetInstallDir == null ||
        targetInstallDir.isEmpty ||
        processPath == null ||
        processPath.isEmpty) {
      return false;
    }
    return _windowsPathEquals(File(processPath).parent.path, targetInstallDir);
  }

  static Future<List<WindowsInnoDeleteFileFailure>>
      _readWindowsInnoDeleteFileFailures(String innoLogPath) async {
    final File log = File(innoLogPath);
    if (!await log.exists()) return const <WindowsInnoDeleteFileFailure>[];
    return parseWindowsInnoDeleteFileFailures(await log.readAsString());
  }

  static Future<void> _markLaunchFailed(
    File? handoffMarkerFile,
    Object error,
    DateTime failedAt,
    StackTrace stack,
  ) async {
    ErrorLogService.instance.log('WindowsInstaller.launchFailed', error, stack);
    if (handoffMarkerFile == null) return;
    try {
      await WindowsUpdateHandoff.markLaunchFailed(
        markerFile: handoffMarkerFile,
        error: error.toString(),
        failedAt: failedAt,
      );
    } catch (e, s) {
      ErrorLogService.instance.log(
        'WindowsInstaller.markLaunchFailed',
        e,
        s,
      );
    }
  }
}

Future<WindowsInstallerDiagnostics> collectWindowsInstallerDiagnostics({
  required String currentExecutablePath,
  int? currentProcessId,
}) async {
  final String currentInstallDir = File(currentExecutablePath).parent.path;
  final String targetInstallDir = currentInstallDir;
  final List<WindowsDetectedInstallLocation> detectedInstallLocations =
      <WindowsDetectedInstallLocation>[
    WindowsDetectedInstallLocation(
      source: 'current',
      path: currentInstallDir,
    ),
    ...await queryWindowsRegisteredInstallLocations(),
    ...detectWindowsHistoricalInstallLocations(),
  ];
  final List<WindowsProcessInfo> runningHibikiProcesses =
      (await queryWindowsHibikiProcesses())
          .where((WindowsProcessInfo process) =>
              currentProcessId == null || process.pid != currentProcessId)
          .toList(growable: false);
  final List<WindowsProcessInfo> libmpvModuleHolders =
      (await queryWindowsLibmpvModuleHolders())
          .where((WindowsProcessInfo process) =>
              currentProcessId == null || process.pid != currentProcessId)
          .toList(growable: false);

  return WindowsInstallerDiagnostics(
    currentExecutablePath: currentExecutablePath,
    currentInstallDir: currentInstallDir,
    targetInstallDir: targetInstallDir,
    detectedInstallLocations: detectedInstallLocations,
    runningHibikiProcesses: runningHibikiProcesses,
    libmpvModuleHolders: libmpvModuleHolders,
    pathMismatchWarning: windowsInstallPathMismatchWarning(
      targetInstallDir: targetInstallDir,
      locations: detectedInstallLocations,
    ),
  );
}

Future<List<WindowsDetectedInstallLocation>>
    queryWindowsRegisteredInstallLocations() async {
  if (!Platform.isWindows) return const <WindowsDetectedInstallLocation>[];
  const String appId = r'{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}_is1';
  const List<String> keys = <String>[
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + appId,
    r'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + appId,
  ];
  final List<WindowsDetectedInstallLocation> result =
      <WindowsDetectedInstallLocation>[];
  for (final String key in keys) {
    try {
      final ProcessResult query = await Process.run(
        'reg',
        <String>['query', key],
      );
      if (query.exitCode != 0) continue;
      result.addAll(
        parseWindowsRegistryInstallLocations(
          query.stdout is String ? query.stdout as String : '',
        ),
      );
    } catch (_) {
      // Registry diagnostics are best-effort; absence should not block update.
    }
  }
  return _dedupeInstallLocations(result);
}

List<WindowsDetectedInstallLocation> parseWindowsRegistryInstallLocations(
  String output,
) {
  final List<WindowsDetectedInstallLocation> result =
      <WindowsDetectedInstallLocation>[];
  final String? installLocation =
      _registryValueAfterType(output, 'InstallLocation') ??
          _registryValueAfterType(output, 'Inno Setup: App Path');
  if (installLocation != null && installLocation.isNotEmpty) {
    result.add(
      WindowsDetectedInstallLocation(
        source: 'registered',
        path: installLocation,
      ),
    );
  }

  final String? displayIcon = _registryValueAfterType(output, 'DisplayIcon');
  if (displayIcon != null && displayIcon.isNotEmpty) {
    final String path = _stripDisplayIconSuffix(displayIcon);
    if (path.toLowerCase().endsWith(r'\hibiki.exe') ||
        path.toLowerCase().endsWith('/hibiki.exe')) {
      result.add(
        WindowsDetectedInstallLocation(
          source: 'registered',
          path: File(path).parent.path,
        ),
      );
    }
  }
  return _dedupeInstallLocations(result);
}

List<WindowsDetectedInstallLocation> detectWindowsHistoricalInstallLocations() {
  if (!Platform.isWindows) return const <WindowsDetectedInstallLocation>[];
  final List<String> candidates = <String>[
    r'D:\Program\Hibiki',
    r'D:\APP\Hibiki',
    if ((Platform.environment['LOCALAPPDATA'] ?? '').isNotEmpty)
      '${Platform.environment['LOCALAPPDATA']}\\Hibiki',
  ];
  return _dedupeInstallLocations(
    <WindowsDetectedInstallLocation>[
      for (final String path in candidates)
        if (Directory(path).existsSync())
          WindowsDetectedInstallLocation(source: 'historical', path: path),
    ],
  );
}

String? windowsInstallPathMismatchWarning({
  required String targetInstallDir,
  required List<WindowsDetectedInstallLocation> locations,
}) {
  final List<WindowsDetectedInstallLocation> mismatches = locations
      .where((WindowsDetectedInstallLocation location) =>
          location.path.isNotEmpty &&
          !_windowsPathEquals(location.path, targetInstallDir))
      .toList(growable: false);
  if (mismatches.isEmpty) return null;
  final String details = mismatches
      .map((WindowsDetectedInstallLocation location) =>
          '${location.source}: ${location.path}')
      .join('; ');
  return 'Install locations differ from the running Hibiki directory '
      '$targetInstallDir. This update will install only to the running '
      'directory. Other locations are left untouched; remove old shortcuts or '
      'old install folders manually if they are no longer needed. Detected: '
      '$details';
}

Future<List<WindowsProcessInfo>> queryWindowsHibikiProcesses() async {
  if (!Platform.isWindows) return const <WindowsProcessInfo>[];
  const String command =
      "Get-CimInstance Win32_Process -Filter \"Name = 'hibiki.exe'\" | "
      'Select-Object ProcessId,Name,ExecutablePath | ConvertTo-Json -Compress';
  try {
    final ProcessResult result = await Process.run(
      'powershell',
      <String>['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
    );
    if (result.exitCode != 0) return const <WindowsProcessInfo>[];
    return parseWindowsProcessJson(
      result.stdout is String ? result.stdout as String : '',
    );
  } catch (_) {
    return const <WindowsProcessInfo>[];
  }
}

Future<List<WindowsProcessInfo>> queryWindowsLibmpvModuleHolders() async {
  if (!Platform.isWindows) return const <WindowsProcessInfo>[];
  try {
    final ProcessResult result = await Process.run(
      'tasklist',
      <String>['/M', 'libmpv-2.dll', '/FO', 'CSV', '/NH'],
    );
    if (result.exitCode != 0) return const <WindowsProcessInfo>[];
    final List<WindowsProcessInfo> holders = parseWindowsTasklistModuleHolders(
      result.stdout is String ? result.stdout as String : '',
    );
    final Map<int, WindowsProcessInfo> hydrated =
        await queryWindowsProcessInfoForPids(
      holders.map((WindowsProcessInfo process) => process.pid),
    );
    return holders.map((WindowsProcessInfo process) {
      final WindowsProcessInfo? info = hydrated[process.pid];
      return process.copyWith(
        name: info?.name,
        path: info?.path,
      );
    }).toList(growable: false);
  } catch (_) {
    return const <WindowsProcessInfo>[];
  }
}

Future<Map<int, WindowsProcessInfo>> queryWindowsProcessInfoForPids(
  Iterable<int> pids,
) async {
  final List<int> uniquePids = pids.toSet().where((int pid) => pid > 0).toList()
    ..sort();
  if (!Platform.isWindows || uniquePids.isEmpty) {
    return const <int, WindowsProcessInfo>{};
  }
  final String filter =
      uniquePids.map((int pid) => 'ProcessId = $pid').join(' OR ');
  final String command = 'Get-CimInstance Win32_Process -Filter "$filter" | '
      'Select-Object ProcessId,Name,ExecutablePath | ConvertTo-Json -Compress';
  try {
    final ProcessResult result = await Process.run(
      'powershell',
      <String>['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
    );
    if (result.exitCode != 0) return const <int, WindowsProcessInfo>{};
    final List<WindowsProcessInfo> processes = parseWindowsProcessJson(
      result.stdout is String ? result.stdout as String : '',
    );
    return <int, WindowsProcessInfo>{
      for (final WindowsProcessInfo process in processes) process.pid: process,
    };
  } catch (_) {
    return const <int, WindowsProcessInfo>{};
  }
}

List<WindowsProcessInfo> parseWindowsProcessJson(String output) {
  if (output.trim().isEmpty) return const <WindowsProcessInfo>[];
  try {
    final Object? decoded = jsonDecode(output);
    final List<dynamic> rows = decoded is List
        ? decoded
        : decoded is Map<String, dynamic>
            ? <dynamic>[decoded]
            : const <dynamic>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> row) {
          return WindowsProcessInfo(
            pid: _objectToInt(row['ProcessId']) ?? 0,
            name: row['Name'] as String?,
            path: row['ExecutablePath'] as String?,
          );
        })
        .where((WindowsProcessInfo process) => process.pid > 0)
        .toList(growable: false);
  } catch (_) {
    return const <WindowsProcessInfo>[];
  }
}

List<WindowsProcessInfo> parseWindowsTasklistModuleHolders(String output) {
  final List<WindowsProcessInfo> holders = <WindowsProcessInfo>[];
  for (final String rawLine in const LineSplitter().convert(output)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('INFO:')) continue;
    final List<String> fields = _parseCsvLine(line);
    if (fields.length < 2) continue;
    final int? parsedPid = int.tryParse(fields[1].replaceAll(',', '').trim());
    if (parsedPid == null) continue;
    holders.add(
      WindowsProcessInfo(
        pid: parsedPid,
        name: fields[0].trim(),
      ),
    );
  }
  return holders;
}

List<WindowsInnoDeleteFileFailure> parseWindowsInnoDeleteFileFailures(
  String output,
) {
  final List<String> lines = const LineSplitter().convert(output);
  final List<WindowsInnoDeleteFileFailure> failures =
      <WindowsInnoDeleteFileFailure>[];
  String? previousPath;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final String? pathOnLine = _extractWindowsPath(line);
    if (pathOnLine != null) previousPath = pathOnLine;

    final RegExpMatch? codeMatch = RegExp(
      r'DeleteFile failed[^0-9]*code\s+([0-9]+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (codeMatch == null) continue;

    final int? code = int.tryParse(codeMatch.group(1)!);
    if (code == null) continue;
    final String? nextPath =
        i + 1 < lines.length ? _extractWindowsPath(lines[i + 1]) : null;
    final String path = pathOnLine ?? previousPath ?? nextPath ?? '';
    failures.add(
      WindowsInnoDeleteFileFailure(
        path: path,
        code: code,
        message: line.trim(),
      ),
    );
  }
  return failures
      .where((WindowsInnoDeleteFileFailure failure) => failure.path.isNotEmpty)
      .toList(growable: false);
}

List<WindowsDetectedInstallLocation> _dedupeInstallLocations(
  Iterable<WindowsDetectedInstallLocation> locations,
) {
  final Set<String> seen = <String>{};
  final List<WindowsDetectedInstallLocation> result =
      <WindowsDetectedInstallLocation>[];
  for (final WindowsDetectedInstallLocation location in locations) {
    if (location.path.trim().isEmpty) continue;
    final String key = _normalizeWindowsPath(location.path);
    if (!seen.add(key)) continue;
    result.add(location);
  }
  return result;
}

String? _registryValueAfterType(String output, String valueName) {
  for (final String rawLine in const LineSplitter().convert(output)) {
    final String line = rawLine.trim();
    if (!line.startsWith(valueName)) continue;
    final RegExpMatch? match =
        RegExp(r'^' + RegExp.escape(valueName) + r'\s+REG_\w+\s+(.+)$')
            .firstMatch(line);
    if (match != null) return match.group(1)!.trim();
  }
  return null;
}

String _stripDisplayIconSuffix(String value) {
  String path = value.trim();
  if (path.startsWith('"')) {
    final int closing = path.indexOf('"', 1);
    if (closing > 0) path = path.substring(1, closing);
  }
  return path.replaceFirst(RegExp(r',\d+$'), '').trim();
}

List<String> _parseCsvLine(String line) {
  final List<String> fields = <String>[];
  final StringBuffer current = StringBuffer();
  bool inQuotes = false;
  for (int i = 0; i < line.length; i++) {
    final String char = line[i];
    if (char == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        current.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (char == ',' && !inQuotes) {
      fields.add(current.toString());
      current.clear();
      continue;
    }
    current.write(char);
  }
  fields.add(current.toString());
  return fields;
}

String? _extractWindowsPath(String line) {
  final RegExpMatch? match = RegExp(r'[A-Za-z]:\\[^"\r\n]+').firstMatch(line);
  if (match == null) return null;
  return match.group(0)!.replaceFirst(RegExp(r'[\s.;,]+$'), '').trim();
}

bool _windowsPathEquals(String a, String b) {
  return _normalizeWindowsPath(a) == _normalizeWindowsPath(b);
}

String _normalizeWindowsPath(String path) {
  return path
      .trim()
      .replaceAll('/', r'\')
      .replaceFirst(RegExp(r'\\+$'), '')
      .toLowerCase();
}

int? _objectToInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Future<void> ensureWindowsInstallTargetWritable(Directory installDir) async {
  final File probe = File(
    '${installDir.path}${Platform.pathSeparator}.hibiki-update-write-test',
  );
  try {
    await installDir.create(recursive: true);
    await probe.writeAsString('hibiki updater preflight', flush: true);
  } catch (e) {
    throw UpdateInstallerException(
      'Cannot write to installation directory: ${installDir.path}. '
      'Close Hibiki and run the installer as administrator, or reinstall '
      'Hibiki to a user-writable folder. Details: $e',
    );
  } finally {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // Best-effort cleanup; a failed cleanup should not hide the real result.
    }
  }
}

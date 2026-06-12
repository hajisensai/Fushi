import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart'; // ErrorLogService

enum UpdateChannel { stable, beta, debug }

/// 每平台的更新策略：选包（[selectAsset]）+ 安装（[apply]）。
/// 共享的 GitHub 拉取/版本比较/下载浮层仍在 UpdateChecker。
abstract class PlatformUpdater {
  /// 当前平台是否支持「检查更新」（iOS/未实现桌面也为 true，只是 apply=打开发布页）。
  bool get supportsUpdateCheck;

  /// 当前平台是否支持「应用内安装」（决定是否显示自动安装、是否走下载→apply）。
  bool get supportsInAppInstall;

  /// 从 release 的 [assets]（每项含 name / browser_download_url）挑本平台可安装包的
  /// 下载 URL；null = 无适配包（上层回退打开发布页）。
  Future<String?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  });

  /// 应用已下载到 [file] 的更新。仅在 [supportsInAppInstall] 为 true 时被调用。
  Future<void> apply(File file, String version);
}

/// 本期支持「应用内安装」的平台集合（单一真相源；macOS/Linux 在各自阶段加入）。
bool platformSupportsInAppInstall() => Platform.isAndroid || Platform.isWindows;

/// 所有平台都至少支持「检查更新 → 打开发布页」。
bool platformSupportsUpdateCheck() => true;

PlatformUpdater updaterForCurrentPlatform() {
  if (Platform.isAndroid) return AndroidUpdater();
  if (Platform.isWindows) return WindowsUpdater();
  return UnsupportedUpdater();
}

/// 从 asset map 安全取出可下载的 (name, url)。
Iterable<(String, String)> _downloadable(
    List<Map<String, dynamic>> assets) sync* {
  for (final Map<String, dynamic> a in assets) {
    final String name = a['name'] as String? ?? '';
    final String? url = a['browser_download_url'] as String?;
    if (name.isEmpty || url == null) continue;
    yield (name, url);
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
  Future<String?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    final List<String> abis = await _abiProvider();
    final List<String> abiTags =
        abis.map((String a) => a.replaceAll('_', '-')).toList();
    String? fallback;
    for (final (String name, String url) in _downloadable(assets)) {
      if (!_androidAssetMatchesChannel(name, channel)) continue;
      if (abiTags.any(name.contains)) return url;
      fallback ??= url;
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
  Future<String?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    for (final (String name, String url) in _downloadable(assets)) {
      if (_windowsAssetMatchesChannel(name, channel)) return url;
    }
    return null;
  }

  @override
  Future<void> apply(File file, String version) async {
    await WindowsInstaller.runAndExit(file.path);
  }
}

/// iOS + 本期未实现的 macOS/Linux：可检查但不能自装。
class UnsupportedUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => false;

  @override
  Future<String?> selectAsset(
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

/// Inno Setup 静默安装参数：抑制向导、跳过初始提示；安装器脚本负责关旧实例 + 重启。
List<String> windowsInstallerArgs(String installerPath) =>
    <String>['/VERYSILENT', '/SP-'];

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

class WindowsInstaller {
  /// 启动安装器（分离进程）后退出本进程，让安装器替换运行中的 exe 并重启 app。
  ///
  /// 根因修复（Windows 点自动更新崩溃）：
  /// 1. 先校验下载产物确实是 PE 可执行文件，避免把代理 HTML/截断文件喂给
  ///    `Process.start`（曾导致行为不可控）。
  /// 2. 仅当安装器进程**确实启动成功**后才 `exit(0)`；启动失败抛
  ///    [UpdateInstallerException]（上层 catch → SnackBar），绝不让本进程在没有
  ///    接班者的情况下静默消失（用户视角即「崩溃」）。
  static Future<void> runAndExit(String installerPath) async {
    final File installer = File(installerPath);
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

    try {
      await Process.start(
        installerPath,
        windowsInstallerArgs(installerPath),
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (e) {
      throw UpdateInstallerException(
          'failed to launch installer: ${e.message}');
    }

    // 安装器已成功启动（分离进程）。把当前进程让出文件锁：让出事件循环一拍，
    // 随后退出，安装器（AppMutex + CloseApplications）即可替换 hibiki.exe 并重启。
    await Future<void>.delayed(Duration.zero);
    exit(0);
  }

  static Future<List<int>> _readHeaderBytes(File file) async {
    final RandomAccessFile raf = await file.open();
    try {
      return await raf.read(2);
    } finally {
      await raf.close();
    }
  }
}

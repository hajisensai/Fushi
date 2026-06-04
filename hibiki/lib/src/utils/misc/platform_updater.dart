import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart'; // ErrorLogService

/// 每平台的更新策略：选包（[selectAsset]）+ 安装（[apply]）。
/// 共享的 GitHub 拉取/版本比较/下载浮层仍在 UpdateChecker。
abstract class PlatformUpdater {
  /// 当前平台是否支持「检查更新」（iOS/未实现桌面也为 true，只是 apply=打开发布页）。
  bool get supportsUpdateCheck;

  /// 当前平台是否支持「应用内安装」（决定是否显示自动安装、是否走下载→apply）。
  bool get supportsInAppInstall;

  /// 从 release 的 [assets]（每项含 name / browser_download_url）挑本平台可安装包的
  /// 下载 URL；null = 无适配包（上层回退打开发布页）。
  Future<String?> selectAsset(List<Map<String, dynamic>> assets);

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
  Future<String?> selectAsset(List<Map<String, dynamic>> assets) async {
    final List<String> abis = await _abiProvider();
    final List<String> abiTags =
        abis.map((String a) => a.replaceAll('_', '-')).toList();
    String? fallback;
    for (final (String name, String url) in _downloadable(assets)) {
      if (!name.endsWith('.apk')) continue;
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
  Future<String?> selectAsset(List<Map<String, dynamic>> assets) async {
    for (final (String name, String url) in _downloadable(assets)) {
      if (name.endsWith('-windows-setup.exe')) return url;
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
  Future<String?> selectAsset(List<Map<String, dynamic>> assets) async => null;

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

class WindowsInstaller {
  /// 启动安装器（分离进程）后退出本进程，让安装器替换运行中的 exe 并重启 app。
  static Future<void> runAndExit(String installerPath) async {
    await Process.start(
      installerPath,
      windowsInstallerArgs(installerPath),
      mode: ProcessStartMode.detached,
    );
    // 给安装器拿到文件锁的瞬间；随后退出本进程，让其替换 hibiki.exe。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}

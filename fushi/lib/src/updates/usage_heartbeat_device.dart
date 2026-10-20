// 安装统计心跳的设备维度（服务端 services/leaderboard/src/installs.js、迁移 0017）：
// CPU 架构、系统大版本、安装来源。三项都是粗粒度枚举——只报大版本（不报 build 号）、
// 只报来源类别（不报安装器包名），不比平台本身多出可识别个人的信息。
//
// 归类规则都写成纯函数，平台读数只在 [collectUsageHeartbeatDevice] 一处；任何一项读失败都
// 只让那一项为 null（服务端保留上次的值），不影响心跳本身。

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

/// 心跳里的设备维度；字段为 null = 这次没拿到（不上报）。
@immutable
class UsageHeartbeatDevice {
  const UsageHeartbeatDevice({this.arch, this.osVersion, this.source});

  static const UsageHeartbeatDevice unknown = UsageHeartbeatDevice();

  /// 宿主 CPU 架构：`x64` / `arm64` / `x86` / `arm` / 其它小写记号。
  final String? arch;

  /// 系统大版本记号：Android API 级别、Windows `10` / `11`、macOS 主版本、Linux `<发行版>-<版本>`。
  final String? osVersion;

  /// 安装来源类别，见 [classifyAndroidInstallSource] / [classifyWindowsInstallSource]。
  final String? source;
}

final RegExp _token = RegExp(r'^[a-z0-9_]{1,16}$');

/// **纯函数**：平台报的架构名 → 心跳记号。Android ABI（`arm64-v8a`）、Windows 环境变量
/// （`AMD64` / `ARM64`）、uname（`x86_64` / `aarch64`）三种写法归一；认不出但形状合法的原样小写。
String? normalizeHeartbeatArch(String? raw) {
  if (raw == null) return null;
  final String v = raw.trim().toLowerCase();
  switch (v) {
    case 'arm64-v8a' || 'arm64' || 'aarch64':
      return 'arm64';
    case 'armeabi-v7a' || 'armeabi' || 'arm' || 'armv7l':
      return 'arm';
    case 'x86_64' || 'amd64' || 'x64':
      return 'x64';
    case 'x86' || 'ia32' || 'i386' || 'i686':
      return 'x86';
  }
  final String token = v.replaceAll('-', '_');
  return _token.hasMatch(token) ? token : null;
}

/// **纯函数**：Windows 的宿主架构。x64 进程跑在 ARM64 Windows 的模拟层里时
/// `PROCESSOR_ARCHITECTURE` 报 `AMD64`，但 `PROCESSOR_IDENTIFIER` 仍是 `ARMv8 …`，以后者为准；
/// 32 位进程看 `PROCESSOR_ARCHITEW6432`。
String? windowsHostArch(Map<String, String> env) {
  final String identifier = env['PROCESSOR_IDENTIFIER'] ?? '';
  if (identifier.toUpperCase().startsWith('ARM')) return 'arm64';
  return normalizeHeartbeatArch(
    env['PROCESSOR_ARCHITEW6432'] ?? env['PROCESSOR_ARCHITECTURE'],
  );
}

/// **纯函数**：`dart:ffi` 的 [Abi] → 心跳记号（Linux / 兜底用，报的是进程架构）。
String? abiHeartbeatArch(Abi abi) {
  final String name = abi.toString(); // 形如 linux_x64 / windows_arm64
  final int i = name.indexOf('_');
  return i < 0 ? null : normalizeHeartbeatArch(name.substring(i + 1));
}

/// **纯函数**：Windows 内部版本号 → 大版本（22000 起是 Windows 11）。
String windowsMajorVersion(int buildNumber) =>
    buildNumber >= 22000 ? '11' : '10';

final RegExp _linuxPart = RegExp(r'[^a-z0-9._]');

/// **纯函数**：os-release 的 `ID` + `VERSION_ID` → `ubuntu-24.04`；滚动发行版没有版本号就只报 id。
String? linuxOsVersion(String? id, String? versionId) {
  final String name = (id ?? '').toLowerCase().replaceAll(_linuxPart, '');
  if (name.isEmpty) return null;
  final String ver = (versionId ?? '').toLowerCase().replaceAll(_linuxPart, '');
  final String token = ver.isEmpty ? name : '$name-$ver';
  return token.length <= 32 ? token : token.substring(0, 32);
}

const Set<String> _fdroidClients = <String>{
  'org.fdroid.fdroid',
  'org.fdroid.basic',
  'com.looker.droidify',
  'com.machiav3lli.fdroid',
  'eu.bubu1.fdroidclassic',
};

/// **纯函数**：Android 发起安装的包名（`InstallSourceInfo.initiatingPackageName`，旧系统退回
/// `getInstallerPackageName`）→ 来源类别。只上报类别，不上报包名本身：
/// `play` / `fdroid`（F-Droid 系客户端）/ `obtainium` / `self_update`（本 App 的应用内更新）/
/// `adb`（没有发起方：adb / 开发安装）/ `manual`（其它：文件管理器、浏览器、系统安装器）。
String classifyAndroidInstallSource(String? installer, String ownPackage) {
  if (installer == null || installer.isEmpty) return 'adb';
  if (installer == 'com.android.vending') return 'play';
  if (_fdroidClients.contains(installer)) return 'fdroid';
  if (installer.startsWith('dev.imranr.obtainium')) return 'obtainium';
  if (installer == ownPackage) return 'self_update';
  return 'manual';
}

/// **纯函数**：Windows 只发 Inno Setup 安装包，它在 exe 旁边放 `unins000.exe`；没有就是拷出来的
/// 便携目录 / 开发构建。
String classifyWindowsInstallSource({required bool hasUninstaller}) =>
    hasUninstaller ? 'installer' : 'portable';

Future<UsageHeartbeatDevice>? _cached;

/// 读本机的设备维度（全进程缓存一份：这几项运行期间不会变）。
Future<UsageHeartbeatDevice> collectUsageHeartbeatDevice() =>
    _cached ??= _collect();

Future<UsageHeartbeatDevice> _collect() async {
  Future<T?> read<T>(String what, Future<T?> Function() f) async {
    try {
      return await f();
    } catch (error) {
      debugPrint('UsageHeartbeat: $what unavailable. $error');
      return null;
    }
  }

  final DeviceInfoPlugin plugin = DeviceInfoPlugin();
  if (Platform.isAndroid) {
    final AndroidDeviceInfo? a = await read(
      'androidInfo',
      () => plugin.androidInfo,
    );
    final PackageInfo? pkg = await read(
      'packageInfo',
      PackageInfo.fromPlatform,
    );
    return UsageHeartbeatDevice(
      arch: normalizeHeartbeatArch(
        a == null || a.supportedAbis.isEmpty ? null : a.supportedAbis.first,
      ),
      osVersion: a == null ? null : '${a.version.sdkInt}',
      source: pkg == null
          ? null
          : classifyAndroidInstallSource(pkg.installerStore, pkg.packageName),
    );
  }
  if (Platform.isWindows) {
    final WindowsDeviceInfo? w = await read(
      'windowsInfo',
      () => plugin.windowsInfo,
    );
    final bool? hasUninstaller = await read(
      'uninstaller',
      () => File(
        p.join(p.dirname(Platform.resolvedExecutable), 'unins000.exe'),
      ).exists(),
    );
    return UsageHeartbeatDevice(
      arch:
          windowsHostArch(Platform.environment) ??
          abiHeartbeatArch(Abi.current()),
      osVersion: w == null ? null : windowsMajorVersion(w.buildNumber),
      source: hasUninstaller == null
          ? null
          : classifyWindowsInstallSource(hasUninstaller: hasUninstaller),
    );
  }
  if (Platform.isMacOS) {
    final MacOsDeviceInfo? m = await read('macOsInfo', () => plugin.macOsInfo);
    return UsageHeartbeatDevice(
      arch: normalizeHeartbeatArch(m?.arch) ?? abiHeartbeatArch(Abi.current()),
      osVersion: m == null ? null : '${m.majorVersion}',
      source: 'direct',
    );
  }
  if (Platform.isLinux) {
    final LinuxDeviceInfo? l = await read('linuxInfo', () => plugin.linuxInfo);
    return UsageHeartbeatDevice(
      arch: abiHeartbeatArch(Abi.current()),
      osVersion: l == null ? null : linuxOsVersion(l.id, l.versionId),
      // Linux 版只能从源码构建（CI 不出 Linux App 包）。
      source: 'source',
    );
  }
  return UsageHeartbeatDevice.unknown;
}

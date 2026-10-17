// 安装统计的安装身份：从系统机器标识派生 installId 与签名钥匙（算法在
// fushi_engine/lib/leaderboard/install_identity.dart，服务端 services/leaderboard/src/installs.js）。
//
// 机器标识来源（只在本机做种子，原值**绝不上传、不落盘**）：
//   - Windows：HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid（装系统时生成，重装 app 不变）；
//   - macOS：IOPlatformUUID（device_info_plus 的 systemGUID，IOKit 读取，沙盒内可用）；
//   - Linux：/etc/machine-id，回退 /var/lib/dbus/machine-id；
//   - Android：Settings.Secure.ANDROID_ID（Android 8+ 按签名密钥 + 设备 + 用户稳定，重装不变），
//     经既有 update 通道的 `installMachineId` 方法取（MainActivity.java）；
//   - iOS：不发心跳、反馈也不带安装 id（usage_heartbeat.dart 的平台门），这里不处理。
// 取不到或取到的是已知共用值（isUsableInstallMachineId）时回退到本机随机种子——就是原来的
// `usage_stats_install_id`（随机 UUID v4，设备本地），行为与旧版一致：重装即变。
//
// 工作量证明 nonce 只依赖 installId，第一次在后台 isolate 算出来后存进
// `usage_stats_install_pow`（`<installId>:<nonce>`，设备本地），之后直接复用；installId 变了
// （换机器标识来源 / 回退种子）自动重算。
//
// 全进程一份缓存：心跳与反馈共用同一个解析结果，钥匙推导（一次 P-256 标量乘）与 PoW 只做一次。

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_engine/leaderboard/install_identity.dart';
import 'package:fushi_engine/platform/desktop/windows_process_query.dart';

/// 读系统机器标识；取不到返回 null。
typedef InstallMachineIdReader = Future<String?> Function();

/// 解出工作量证明 nonce（生产走后台 isolate）。
typedef InstallPowSolver = Future<String> Function(String installId);

/// Linux 机器标识文件，按优先级。
const List<String> kLinuxMachineIdPaths = <String>[
  '/etc/machine-id',
  '/var/lib/dbus/machine-id',
];

/// **纯函数**：Linux 机器标识——按 [kLinuxMachineIdPaths] 顺序取第一个可用的值。
/// [read] 读文件内容，读不到返回 null。
String? pickLinuxMachineId(String? Function(String path) read) {
  for (final String path in kLinuxMachineIdPaths) {
    final String? v = read(path)?.trim();
    if (v != null && isUsableInstallMachineId(v)) return v;
  }
  return null;
}

String? _readFileOrNull(String path) {
  try {
    final File f = File(path);
    return f.existsSync() ? f.readAsStringSync() : null;
  } on Object {
    return null;
  }
}

/// 生产读取器：按当前平台取机器标识。任何失败都返回 null（回退随机种子），不抛。
Future<String?> readPlatformInstallMachineId() async {
  try {
    if (Platform.isWindows) {
      return readWindowsRegistryString(
        WindowsRegistryRoot.localMachine,
        r'SOFTWARE\Microsoft\Cryptography',
        'MachineGuid',
      );
    }
    if (Platform.isLinux) {
      return pickLinuxMachineId(_readFileOrNull);
    }
    if (Platform.isMacOS) {
      return (await DeviceInfoPlugin().macOsInfo).systemGUID;
    }
    if (Platform.isAndroid) {
      return await FushiChannels.update.invokeMethod<String>(
        'installMachineId',
      );
    }
  } on Object catch (e) {
    debugPrint('InstallAttestation: machine id unavailable. $e');
  }
  return null;
}

/// **纯函数（除持久化外）**：解析本机的安装证明。机器标识可用就从它派生，否则用
/// [PreferencesRepository.ensureUsageStatsInstallId] 的随机种子；PoW nonce 有缓存且属于
/// 当前 installId 就复用，否则用 [solvePow] 算一次并存起来。
Future<InstallAttestation> resolveInstallAttestation(
  PreferencesRepository prefs, {
  required InstallMachineIdReader readMachineId,
  required InstallPowSolver solvePow,
}) async {
  final String? machineId = await readMachineId();
  final InstallIdentity identity =
      machineId != null && isUsableInstallMachineId(machineId)
      ? InstallIdentity.fromMachineId(machineId)
      : InstallIdentity.fromLocalRandom(
          await prefs.ensureUsageStatsInstallId(),
        );
  final String? cached = prefs.usageStatsInstallPowFor(identity.installId);
  if (cached != null && installPowValid(identity.installId, cached)) {
    return InstallAttestation(identity, cached);
  }
  final String nonce = await solvePow(identity.installId);
  await prefs.setUsageStatsInstallPow(identity.installId, nonce);
  return InstallAttestation(identity, nonce);
}

Future<InstallAttestation>? _cached;

/// 生产入口：全进程缓存一份（失败不缓存，下次再试）。
Future<InstallAttestation> usageStatsInstallAttestation(
  PreferencesRepository prefs,
) {
  final Future<InstallAttestation>? cached = _cached;
  if (cached != null) return cached;
  final Future<InstallAttestation> run = resolveInstallAttestation(
    prefs,
    readMachineId: readPlatformInstallMachineId,
    solvePow: solveInstallPowInBackground,
  );
  _cached = run;
  run.then<void>((_) {}, onError: (Object _) => _cached = null);
  return run;
}

@visibleForTesting
void resetUsageStatsInstallAttestationCache() => _cached = null;

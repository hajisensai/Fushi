/// 复习同步 v2 里本机怎么自报身份（native/fushi_fsrs/src/store/sync2/devices.rs）：默认名称取设备型号 / 主机名
/// （iOS 机型名、Android 厂商 + 型号、Windows 主机名、macOS 机型），App 版本取 `major.minor`，平台给图标用。
/// 每轮同步前交给内核（[srsPublishDeviceInfo]），内核没变不进写锁，随下一次写 head 发布；用户在同步页改的昵称
/// 只替换名称部分（内核单独存，型号照旧更新）。
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/interconnect_device_name.dart'
    show isMeaninglessDeviceName;
import 'package:package_info_plus/package_info_plus.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 本机自报的设备信息。
typedef SrsLocalDeviceInfo = ({String model, String app, String platform});

/// `3.3.1+2200` → `3.3`（只显示 major.minor；认不出就原样去掉 `+build`）。
String srsAppVersionLabel(String version) {
  final String core = version.split('+').first.trim();
  final List<String> parts = core.split('.');
  if (parts.length >= 2 &&
      int.tryParse(parts[0]) != null &&
      int.tryParse(parts[1]) != null) {
    return '${parts[0]}.${parts[1]}';
  }
  return core;
}

/// iPhone 的机型标识（`utsname.machine`，如 `iPhone18,3`）→ 市场名。
const Map<String, String> _kIphoneNames = <String, String>{
  'iPhone12,1': 'iPhone 11',
  'iPhone12,3': 'iPhone 11 Pro',
  'iPhone12,5': 'iPhone 11 Pro Max',
  'iPhone12,8': 'iPhone SE',
  'iPhone13,1': 'iPhone 12 mini',
  'iPhone13,2': 'iPhone 12',
  'iPhone13,3': 'iPhone 12 Pro',
  'iPhone13,4': 'iPhone 12 Pro Max',
  'iPhone14,2': 'iPhone 13 Pro',
  'iPhone14,3': 'iPhone 13 Pro Max',
  'iPhone14,4': 'iPhone 13 mini',
  'iPhone14,5': 'iPhone 13',
  'iPhone14,6': 'iPhone SE',
  'iPhone14,7': 'iPhone 14',
  'iPhone14,8': 'iPhone 14 Plus',
  'iPhone15,2': 'iPhone 14 Pro',
  'iPhone15,3': 'iPhone 14 Pro Max',
  'iPhone15,4': 'iPhone 15',
  'iPhone15,5': 'iPhone 15 Plus',
  'iPhone16,1': 'iPhone 15 Pro',
  'iPhone16,2': 'iPhone 15 Pro Max',
  'iPhone17,1': 'iPhone 16 Pro',
  'iPhone17,2': 'iPhone 16 Pro Max',
  'iPhone17,3': 'iPhone 16',
  'iPhone17,4': 'iPhone 16 Plus',
  'iPhone17,5': 'iPhone 16e',
  'iPhone18,1': 'iPhone 17 Pro',
  'iPhone18,2': 'iPhone 17 Pro Max',
  'iPhone18,3': 'iPhone 17',
  'iPhone18,4': 'iPhone Air',
};

/// Mac 的机型标识（`hw.model`，如 `MacBookPro18,3` / `Mac15,12`）→ 人读名。老式标识按家族名认；Apple
/// Silicon 起统一成 `MacNN,N`，只收常见的几款，认不出给 `Mac`。
const Map<String, String> _kMacNames = <String, String>{
  'Mac13,1': 'Mac Studio',
  'Mac13,2': 'Mac Studio',
  'Mac14,2': 'MacBook Air',
  'Mac14,3': 'Mac mini',
  'Mac14,5': 'MacBook Pro',
  'Mac14,6': 'MacBook Pro',
  'Mac14,7': 'MacBook Pro',
  'Mac14,9': 'MacBook Pro',
  'Mac14,10': 'MacBook Pro',
  'Mac14,12': 'Mac mini',
  'Mac14,13': 'Mac Studio',
  'Mac14,14': 'Mac Studio',
  'Mac14,15': 'MacBook Air',
  'Mac15,3': 'MacBook Pro',
  'Mac15,4': 'iMac',
  'Mac15,5': 'iMac',
  'Mac15,6': 'MacBook Pro',
  'Mac15,7': 'MacBook Pro',
  'Mac15,8': 'MacBook Pro',
  'Mac15,9': 'MacBook Pro',
  'Mac15,10': 'MacBook Pro',
  'Mac15,11': 'MacBook Pro',
  'Mac15,12': 'MacBook Air',
  'Mac15,13': 'MacBook Air',
  'Mac16,1': 'MacBook Pro',
  'Mac16,2': 'iMac',
  'Mac16,3': 'iMac',
  'Mac16,5': 'MacBook Pro',
  'Mac16,6': 'MacBook Pro',
  'Mac16,7': 'MacBook Pro',
  'Mac16,8': 'MacBook Pro',
  'Mac16,10': 'Mac mini',
  'Mac16,11': 'Mac mini',
  'Mac16,12': 'MacBook Air',
  'Mac16,13': 'MacBook Air',
};

/// iOS 机型标识 → 市场名（认不出：iPad 给 `iPad`，其余给 [fallback]）。
String srsAppleMobileModelName(String machine, {required String fallback}) {
  final String? known = _kIphoneNames[machine];
  if (known != null) return known;
  if (machine.startsWith('iPad')) return 'iPad';
  if (machine.startsWith('iPhone')) return 'iPhone';
  return fallback;
}

/// macOS 机型标识 → 人读名。
String srsMacModelName(String model) {
  final String? known = _kMacNames[model];
  if (known != null) return known;
  const List<(String, String)> families = <(String, String)>[
    ('MacBookPro', 'MacBook Pro'),
    ('MacBookAir', 'MacBook Air'),
    ('MacBook', 'MacBook'),
    ('Macmini', 'Mac mini'),
    ('MacPro', 'Mac Pro'),
    ('iMac', 'iMac'),
  ];
  for (final (String prefix, String name) in families) {
    if (model.startsWith(prefix)) return name;
  }
  return 'Mac';
}

/// Android：厂商 + 型号（型号已带厂商名的不重复，如 `Pixel 8` 前补 `Google`、`OnePlus PJD110` 不补）。
String srsAndroidModelName(String? manufacturer, String? model) {
  final String m = (model ?? '').trim();
  final String raw = (manufacturer ?? '').trim();
  if (raw.isEmpty) return m;
  final String vendor = raw[0].toUpperCase() + raw.substring(1);
  if (m.isEmpty) return vendor;
  if (m.toLowerCase().startsWith(raw.toLowerCase())) return m;
  return '$vendor $m';
}

/// 平台码（内核原样存、界面按它选图标）：`ios` / `android` / `windows` / `macos` / `linux`。
String srsPlatformCode() {
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  return Platform.operatingSystem;
}

Future<String> _resolveModel() async {
  final DeviceInfoPlugin plugin = DeviceInfoPlugin();
  if (Platform.isIOS) {
    final IosDeviceInfo i = await plugin.iosInfo;
    return srsAppleMobileModelName(i.utsname.machine, fallback: i.model);
  }
  if (Platform.isAndroid) {
    final AndroidDeviceInfo a = await plugin.androidInfo;
    return srsAndroidModelName(a.manufacturer, a.model);
  }
  if (Platform.isMacOS) {
    return srsMacModelName((await plugin.macOsInfo).model);
  }
  if (Platform.isWindows) {
    final String name = (await plugin.windowsInfo).computerName;
    if (!isMeaninglessDeviceName(name)) return name;
  }
  final String host = Platform.localHostname;
  return isMeaninglessDeviceName(host) ? '' : host;
}

Future<SrsLocalDeviceInfo>? _localInfo;

/// 本机的型号 / 版本 / 平台（进程内只取一次；取不到的项为空串，内核照样能写 head）。
Future<SrsLocalDeviceInfo> srsResolveLocalDeviceInfo() =>
    _localInfo ??= () async {
      String model = '';
      String app = '';
      try {
        model = await _resolveModel();
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsDeviceIdentity.model', e, stack);
      }
      try {
        app = srsAppVersionLabel((await PackageInfo.fromPlatform()).version);
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsDeviceIdentity.app', e, stack);
      }
      return (model: model, app: app, platform: srsPlatformCode());
    }();

/// 每个复习库在本进程里交过一次就不再交（型号 / 版本在进程内不变；内核没变也不进写锁，这里只省一次 FFI）。
final Expando<bool> _published = Expando<bool>('srsDeviceInfoPublished');

/// 把本机型号 / 版本 / 平台交给内核（下一次写 head 发布）。失败只记日志，不挡同步。
Future<void> srsPublishDeviceInfo(SrsDbStore store) async {
  if (_published[store] == true) return;
  try {
    final SrsLocalDeviceInfo info = await srsResolveLocalDeviceInfo();
    await store.sync2DeviceInfo(
      model: info.model,
      app: info.app,
      platform: info.platform,
    );
    _published[store] = true;
  } catch (e, stack) {
    ErrorLogService.instance.log('SrsDeviceIdentity.publish', e, stack);
  }
}

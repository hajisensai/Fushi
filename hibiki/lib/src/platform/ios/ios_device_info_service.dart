import 'package:device_info_plus/device_info_plus.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

class IosDeviceInfoService implements PlatformDeviceInfoService {
  IosDeviceInfo? _cachedInfo;

  Future<IosDeviceInfo> _getInfo() async =>
      _cachedInfo ??= await DeviceInfoPlugin().iosInfo;

  @override
  Future<int?> get sdkVersion async => null;

  @override
  Future<String?> get deviceModel async => (await _getInfo()).model;

  @override
  Future<String?> get osVersion async =>
      'iOS ${(await _getInfo()).systemVersion}';
}

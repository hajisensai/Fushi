import 'package:device_info_plus/device_info_plus.dart';
import 'package:fushi_platform/fushi_platform.dart';

class IosDeviceInfoService implements PlatformDeviceInfoService {
  IosDeviceInfo? _cachedInfo;

  Future<IosDeviceInfo> _getInfo() async =>
      _cachedInfo ??= await DeviceInfoPlugin().iosInfo;

  @override
  Future<int?> get sdkVersion async => null;

  @override
  Future<String?> get deviceModel async => (await _getInfo()).model;

  @override
  Future<String?> get manufacturer async => null;
}

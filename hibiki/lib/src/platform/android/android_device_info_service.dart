import 'package:device_info_plus/device_info_plus.dart';
import 'package:fushi_platform/fushi_platform.dart';

class AndroidDeviceInfoService implements PlatformDeviceInfoService {
  AndroidDeviceInfo? _cachedInfo;

  Future<AndroidDeviceInfo> _getInfo() async =>
      _cachedInfo ??= await DeviceInfoPlugin().androidInfo;

  @override
  Future<int?> get sdkVersion async => (await _getInfo()).version.sdkInt;

  @override
  Future<String?> get deviceModel async => (await _getInfo()).model;

  @override
  Future<String?> get manufacturer async => (await _getInfo()).manufacturer;
}

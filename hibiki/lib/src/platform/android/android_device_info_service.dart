import 'package:device_info_plus/device_info_plus.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

class AndroidDeviceInfoService implements PlatformDeviceInfoService {
  AndroidDeviceInfo? _cachedInfo;

  Future<AndroidDeviceInfo> _getInfo() async =>
      _cachedInfo ??= await DeviceInfoPlugin().androidInfo;

  @override
  Future<int?> get sdkVersion async => (await _getInfo()).version.sdkInt;

  @override
  Future<String?> get deviceModel async => (await _getInfo()).model;

  @override
  Future<String?> get osVersion async {
    final info = await _getInfo();
    return 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
  }
}

abstract class PlatformDeviceInfoService {
  Future<int?> get sdkVersion;
  Future<String?> get deviceModel;
  Future<String?> get osVersion;
}

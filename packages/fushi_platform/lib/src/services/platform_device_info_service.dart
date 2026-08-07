abstract class PlatformDeviceInfoService {
  Future<int?> get sdkVersion;
  Future<String?> get deviceModel;

  /// Device manufacturer (Android `Build.MANUFACTURER`, e.g. `OPPO` /
  /// `realme` / `OnePlus`; casing is vendor-defined). `null` on platforms
  /// without a meaningful vendor split (iOS / desktop). Used to tailor
  /// OEM-specific permission guidance (TODO-1227).
  Future<String?> get manufacturer;
}

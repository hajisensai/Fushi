import 'dart:io';

import 'package:hibiki_platform/hibiki_platform.dart';

class DesktopDeviceInfoService implements PlatformDeviceInfoService {
  @override
  Future<int?> get sdkVersion async => null;

  @override
  Future<String?> get deviceModel async => Platform.localHostname;

  @override
  Future<String?> get osVersion async => Platform.operatingSystemVersion;
}

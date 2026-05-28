import 'package:hibiki_platform/hibiki_platform.dart';

class DesktopPermissionService implements PlatformPermissionService {
  @override
  Future<bool> requestExternalStoragePermission() async => true;

  @override
  Future<bool> hasExternalStoragePermission() async => true;

  @override
  Future<bool> hasCameraPermission() async => true;

  @override
  Future<bool> requestCameraPermission() async => true;

  @override
  Future<bool> canDrawOverlays() async => false;

  @override
  Future<void> requestOverlayPermission() async {}
}

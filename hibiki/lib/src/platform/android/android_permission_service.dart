import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:permission_handler/permission_handler.dart';

class AndroidPermissionService implements PlatformPermissionService {
  @override
  Future<bool> hasExternalStoragePermission() =>
      Permission.manageExternalStorage.isGranted;

  @override
  Future<bool> requestExternalStoragePermission() async {
    final status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
      final basic = await Permission.storage.request();
      return basic.isGranted;
    }
    return true;
  }

  @override
  Future<bool> hasCameraPermission() => Permission.camera.isGranted;

  @override
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  @override
  Future<bool> canDrawOverlays() => Permission.systemAlertWindow.isGranted;

  @override
  Future<void> requestOverlayPermission() =>
      Permission.systemAlertWindow.request();
}

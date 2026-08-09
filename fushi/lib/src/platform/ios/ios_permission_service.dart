import 'package:fushi_platform/fushi_platform.dart';
import 'package:permission_handler/permission_handler.dart';

class IosPermissionService implements PlatformPermissionService {
  @override
  Future<bool> hasExternalStoragePermission() async => true;

  @override
  Future<bool> requestExternalStoragePermission() async => true;

  @override
  Future<bool> hasCameraPermission() => Permission.camera.isGranted;

  @override
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }
}

abstract class PlatformPermissionService {
  Future<bool> hasExternalStoragePermission();
  Future<bool> requestExternalStoragePermission();
  Future<bool> hasCameraPermission();
  Future<bool> requestCameraPermission();
}

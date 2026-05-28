abstract class PlatformPermissionService {
  Future<bool> hasExternalStoragePermission();
  Future<bool> requestExternalStoragePermission();
  Future<bool> hasCameraPermission();
  Future<bool> requestCameraPermission();
  Future<bool> canDrawOverlays();
  Future<void> requestOverlayPermission();
}

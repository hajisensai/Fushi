import 'package:fushi_platform/fushi_platform.dart';
import 'package:permission_handler/permission_handler.dart';

class AndroidPermissionService implements PlatformPermissionService {
  /// SDK 版本从 [_deviceInfo] 取，让版本依赖在构造处显式可见
  /// （与 `AndroidClipboardService` 同一套路，不引入新依赖）。
  AndroidPermissionService(this._deviceInfo);

  final PlatformDeviceInfoService _deviceInfo;

  /// `MANAGE_EXTERNAL_STORAGE`（「所有文件访问权限」）是 Android 11 / API 30
  /// 才引入的。在 API < 30 上 permission_handler 对它**恒返回 `restricted`**
  /// （`permission_handler_android` 的 `PermissionManager.java`：
  /// `checkPermissionStatus` 与 `requestPermissions` 两处都有
  /// `SDK_INT < VERSION_CODES.R -> PERMISSION_STATUS_RESTRICTED`），
  /// 而 `isGranted` 只在 `granted` 时为真，于是旧系统上该谓词恒假。
  ///
  /// 旧系统（API 24~29）上真正管辖外部存储读写的是 `READ/WRITE_EXTERNAL_STORAGE`，
  /// 也就是 `Permission.storage`。查询侧和申请侧必须按 SDK 版本选**同一个**权限，
  /// 否则「问的」和「要的」不是同一件事——那正是 BUG-1213 的根因形状。
  static const int _manageExternalStorageMinSdk = 30;

  /// 当前系统版本下真正管辖「全盘真实路径访问」的那一个权限。
  ///
  /// 查询侧与申请侧共用这一个解析函数——两侧对同一件事只能有同一个答案。
  /// `sdkVersion` 拿不到时（`null`）按新系统处理：在旧系统上多问一次
  /// `MANAGE_EXTERNAL_STORAGE` 只会拿到 `restricted`（无害），而在新系统上
  /// 漏掉它会真的读不到盘。
  Future<Permission> _externalStoragePermission() async {
    final int? sdk = await _deviceInfo.sdkVersion;
    if (sdk != null && sdk < _manageExternalStorageMinSdk) {
      return Permission.storage;
    }
    return Permission.manageExternalStorage;
  }

  @override
  Future<bool> hasExternalStoragePermission() async =>
      (await _externalStoragePermission()).isGranted;

  @override
  Future<bool> requestExternalStoragePermission() async {
    final Permission permission = await _externalStoragePermission();
    final PermissionStatus status = await permission.request();
    if (status.isGranted) return true;
    if (permission != Permission.storage) {
      // API >= 30：用户拒绝「所有文件访问」后仍申请基础存储权限（保留既有行为）。
      await Permission.storage.request();
    }
    // 结论必须与查询侧同源，否则两侧会对同一件事给出不同答案。
    return hasExternalStoragePermission();
  }

  @override
  Future<bool> hasCameraPermission() => Permission.camera.isGranted;

  @override
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }
}

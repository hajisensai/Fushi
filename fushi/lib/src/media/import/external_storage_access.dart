/// 真实路径选择器（`real_path_directory_picker.dart`）在安卓上要的存储权限能力。
///
/// 由 `AppModel` 实现、调用方注入：选择器只需要「申请全文件访问」与「查是否已授权」
/// 两件事，不必 import `app_model.dart`（那会把选择器和它的全部调用方拖进 lib/ 的
/// import 大环，见 `test/build/import_cycle_guard_test.dart`）。
library;

abstract interface class ExternalStorageAccess {
  /// 安卓：确保 MANAGE_EXTERNAL_STORAGE（全文件访问）已申请；其它平台无事可做。
  Future<void> requestExternalStoragePermissions();

  /// 当前是否已有全文件访问权限。
  Future<bool> hasExternalStoragePermission();
}

## BUG-1205 · 安卓选文件夹时顺带弹相机权限申请
- **报告**：2026-07-28（用户：PR#526 审查线索）
- **真实性**：⚠️ 部分属实（代码属实，安卓可见症状未复现）
  - **代码属实**：`hibiki/lib/src/models/app_model.dart:3951-3966`（修复前）的
    `requestExternalStoragePermissions()` 早退门是
    `hasExternalStoragePermission() && hasCameraPermission()`，函数体里还先调
    `requestCameraPermission()` 再调 `requestExternalStoragePermission()`。它的全部
    3 个调用点都在 `hibiki/lib/src/media/import/real_path_directory_picker.dart:37,86,153`
    （选扫描根 / 选文件 / 改下载目录），没有一个需要相机。
  - **相机零消费方**：全仓 `hasCameraPermission` / `requestCameraPermission` 的调用点
    只有这一处（其余全是接口定义与各平台实现）。唯一真正用相机的
    `hibiki/lib/src/creator/enhancements/camera_enhancement.dart:46` 走
    `ImagePicker(ImageSource.camera)` 的系统拍照 intent，从不调这两个方法。
  - **未复现的部分**：`hibiki/android/app/src/main/AndroidManifest.xml` 未声明
    `android.permission.CAMERA`，合并后的 release manifest 里也没有（核过
    `build/app/intermediates/merged_manifest/release/.../AndroidManifest.xml`，且无任何插件
    贡献该权限）。permission_handler_android 10.2.1 对未在 manifest 声明的权限直接判
    denied、**不调 `ActivityCompat.requestPermissions`**
    （`PermissionUtils.java:106-108` + `PermissionManager.java:239-256`），所以当前安卓
    包上**弹不出相机权限框**，`Permission.camera.isGranted` 恒 false。
  - **恒 false 带来的真实副作用**：早退门里的 `&& hasCameraPermission()` 在安卓上恒不
    成立 → 存储已授权时也永远走不进早退分支，每次选文件夹都要重跑一遍申请流程
    （首次安装期还会重复弹 `storage_permissions` toast）。
  - iOS 侧 `hasExternalStoragePermission()` 恒 true、`hasCameraPermission()` 是真状态，
    一旦哪天有非安卓调用点接进来就会弹真·相机框；这条隐患随本次修复一并消除。
- **[x] ① 已修复** — `hibiki/lib/src/models/app_model.dart:3968-3997`：按调用点实际需要
  拆权限——该函数只申请存储权限，早退门只看存储；相机归真正需要相机的入口自己负责
  （`camera_enhancement.dart` 走系统拍照 intent，manifest 未声明 CAMERA，本就不需要运行时
  权限）。`PlatformPermissionService` 的 `hasCameraPermission` / `requestCameraPermission`
  能力方法保留未删（属权限层抽象，删除是更大范围的改动，另议）。commit: 5958414f7
- **[x] ② 已加自动化测试** — `hibiki/test/models/app_model_storage_permission_test.dart`
  （3 条行为测试，非源码扫描）：用记录型 `PlatformPermissionService` 记下**真实生产代码**
  对权限层的每一次调用，断言 ①存储未授权时调用序列恰为 `has:storage → request:storage`、
  ②存储已授权时恰为 `has:storage`（早退，相机未授权也不影响）、③走真实用户入口
  `pickRealDirectoryPath()`（安卓分支 + mock SAF channel）全程零相机调用。
  变异实测：把修复退回旧实现后 3 条全部转红。
- **[ ] ③ 真机复测（未做，必须补）** — 单测只能证明「代码不再向权限层请求相机」，
  证明不了用户在真机上看到什么。需在安卓真机/模拟器走「设置 → 添加本地扫描根」与
  「修改下载目录」，确认只出现存储/全文件访问授权、不出现相机弹框，且授权后扫描能出内容。
- **备注**：
  - 修复期间发现**另一个独立缺陷（未在本 PR 修）**：`AndroidPermissionService`
    `hibiki/lib/src/platform/android/android_permission_service.dart:6-7` 的
    `hasExternalStoragePermission()` 只看 `Permission.manageExternalStorage.isGranted`，
    而 `MANAGE_EXTERNAL_STORAGE` 是 Android 11(API 30) 才引入的，permission_handler 在
    API < 30 上恒返回 RESTRICTED（`PermissionUtils.java:245-250`、
    `PermissionManager.java:347-352`）→ **Android 7~10（API 24-29）上该方法恒 false**，
    `pickRealDirectoryPath()` 因此恒走 `folder_picker_permission_required` 分支并返回
    null，用户加不了扫描根。申请侧 `requestExternalStoragePermission()` 已有
    `Permission.storage` 回退、是好的，缺的是查询侧的 SDK 分级。修它需要真机验证
    Android 7~10 路径，故单独立项。

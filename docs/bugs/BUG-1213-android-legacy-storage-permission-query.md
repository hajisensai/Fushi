## BUG-1213 · Android 7~10 上查询侧恒判未授权，用户根本加不了本地扫描根

- **报告**：2026-07-28（用户：）
- **真实性**：✅ 真 bug（恒定复现，非偶发）。根因 `hibiki/lib/src/platform/android/android_permission_service.dart:6-7`（修复前）——
  查询侧 `hasExternalStoragePermission()` 只看 `Permission.manageExternalStorage.isGranted`。
  `MANAGE_EXTERNAL_STORAGE`（「所有文件访问权限」）是 Android 11 / API 30 才引入的；
  本仓锁定的 `permission_handler_android` 10.2.1 在 `PermissionManager.java:381-382`
  （`checkPermissionStatus`）与 `:255-256`（`requestPermissions`）都有
  `Build.VERSION.SDK_INT < Build.VERSION_CODES.R → PERMISSION_STATUS_RESTRICTED`，
  而 `isGranted` 只在 `granted` 时为真，所以在 API 24~29 上该谓词**恒假**。
  于是 `hibiki/lib/src/media/import/real_path_directory_picker.dart:46-56`
  的 `pickRealDirectoryPath()` 恒走「需要授权」分支 `return null` —— 用户在
  Android 7~10 上**根本加不了本地扫描根**。
  申请侧 `requestExternalStoragePermission()` 早就有 `Permission.storage` 回退，
  查询侧却没有对应的 SDK 分级 —— **两侧不对称**就是本 bug 的根因形状。

- **[x] ① 已修复** — `hibiki/lib/src/platform/android/android_permission_service.dart`：
  抽出唯一的 `_externalStoragePermission()` 解析函数（API < 30 → `Permission.storage`；
  API >= 30 或版本未知 → `Permission.manageExternalStorage`），**查询侧和申请侧共用同一个
  解析结果**，两侧对同一件事只能给出同一个答案。SDK 版本走仓内既有的
  `PlatformDeviceInfoService.sdkVersion`（`AndroidDeviceInfoService` → `device_info_plus`），
  由 `hibiki/lib/src/platform/platform_services.dart:70` 构造注入，**未引入新依赖**
  （与 `AndroidClipboardService(deviceInfo)` 同一套路）。
  API >= 30 上「manage 被拒后再申请基础 storage」的既有行为保留不变。
  提交：见本分支。

- **[x] ② 已加自动化测试** — `hibiki/test/platform/android_permission_service_test.dart`（36 条）：
  被测对象是真实的 `AndroidPermissionService`；测试替换 `PermissionHandlerPlatform.instance`
  为一个**忠实复刻 permission_handler_android 原生语义**的假平台
  （`manageExternalStorage` 在 `sdkInt < 30` 时返回 `restricted`），不是抄一份谓词副本。
  覆盖：① API 24/26/28/29 已授予 `storage` → 查询侧必须返回已授权（这正是修复前恒假的那条路径）；
  ② API 30/33/35 已授予 `manageExternalStorage` → 行为不变，且 API 30 上只有基础 `storage` 不算全文件访问；
  ③ SDK × 已授权集合的整张矩阵上，申请侧返回值与查询侧一致（锁死两侧同源）。
  **变异实测**：把 `_externalStoragePermission()` 退回恒返回 `manageExternalStorage`，
  6 条断言转红（API 24/26/28/29 各一条、API 29 分区存储一条、申请侧 API 24~29 一条）；
  变异确实落到了文件上（`diff` 显示分流的 4 行被删除），恢复后再跑
  `FLUTTER TEST VERDICT: PASSED - 36 tests ran`。

- **[ ] ③ 真机验证（未做）** — 本机 `adb devices` 无 Android 7~10 设备/模拟器，
  **未在真机上复测原始失败路径**。Android 11+ 设备测不出这条（那条路径本来就走
  `manageExternalStorage`）。需要 API 24~29 真机/模拟器上验证：设置 → 添加扫描根 →
  授予存储权限 → 目录选择器返回真实路径而不是 null。

- **备注**：
  - **API 29（Android 10）是分区存储中间态**：`MANAGE_EXTERNAL_STORAGE` 在 29 上
    **根本不存在、不可能被授予**，所以 29 归入 `< 30` 分支、以 `Permission.storage`
    （即 `READ_EXTERNAL_STORAGE`，已在 `AndroidManifest.xml:4` 声明）为准，是**唯一可能正确**的答案。
  - **遗留不确定项（本次未动，属发布面改动）**：`hibiki/android/app/src/main/AndroidManifest.xml`
    的 `<application>` 未声明 `android:requestLegacyExternalStorage="true"`，而
    `targetSdk 35`。在 API 29 上这意味着 app 处于分区存储模式，授予
    `READ_EXTERNAL_STORAGE` 后**通过 `dart:io` 直接读任意真实路径仍可能被系统限制**。
    本次修复解决的是「权限查询恒假导致连目录都选不了」，29 上后续的真实路径读盘是否通畅
    需真机确认；若确实被挡，再单独评估是否加该 manifest 标志（发布面改动，需先报批）。

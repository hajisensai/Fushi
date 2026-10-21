## BUG-3601 · Android 换应用图标（自定义图标）闪退
- **报告**：2026-10-19（应用内反馈 hr-1EecRWm，Android 9 / vivo V1901A，2.10.0-debug.19650：「换应用图标会闪退」，附件只有应用日志）
- **真实性**：⚠️ **闪退本身未在设备上复现；链路上的缺陷是真的**。附带日志只有 Dart 错误日志 + 本次冷启动后的 debug 日志，没有原生栈，也没有任何图标相关的 Dart 异常（`PlatformException` 会被 `UncaughtZone` 记下，日志里没有）——说明进程是在原生侧 / 内存层面直接没了，而不是走到了 Dart 能接住的错误。Android 上可选预设只有 `default` 一档（`IconSwitchHelper.java:22-28`），点它是空操作（`miscellaneous_settings_page.dart:115` 已是当前图标直接 return），所以用户能触发的「换图标」只有「自定义」：选图 → 裁剪 → 原生建桌面快捷方式。这条链路**全程按原图分辨率**走：
  - 裁剪框源图 `FileImage` 全分辨率解码（`crop_image_dialog_page.dart:42`），13MP 相机图 ≈ 52MB RGBA + GPU 纹理；
  - 裁剪输出 `croppedBitmap()` 不设 `maxSize`（`crop_image_dialog_page.dart:182`），再整张 PNG 编码、读回成字节、经 MethodChannel 复制给 Java；
  - Java `createCustomShortcut` 再 `BitmapFactory.decodeByteArray` 全分辨率解码一次（`IconSwitchHelper.java:125`），而最终只要 512px。
  一次「换图标」在 4GB 内存、已经常驻阅读器 / WebView 的手机上瞬时叠出数百 MB 峰值；`OutOfMemoryError` 是 `Error` 不是 `RuntimeException`，Flutter MethodChannel 只接 `RuntimeException`，原生侧 OOM / 被系统按内存杀掉都直接表现为闪退且不留 Dart 日志，与本反馈的日志形态一致。
  - 另一处真缺陷：`IconSwitchHelper.java:134-135` 无条件 `original.recycle()`。`Bitmap.createBitmap` / `createScaledBitmap` 在无需变换时（裁出来本就是正方形、且恰好 512px）直接返回入参本身，此时 `scaled == original`，交给启动器的那张图在 `requestPinShortcut` 之前就被回收了（`Can't parcel a recycled bitmap`）。
- **[x] ① 已修复** — 沿链路给所有环节封顶，而不是吞异常：
  - `fushi/lib/src/utils/misc/app_icon_preferences.dart` 新增 `appIconSourceMaxPixels = 1024`（Android 快捷方式 512px、Windows 窗口图标 256px 的余量）；
  - `fushi/lib/src/pages/implementations/crop_image_dialog_page.dart`：`CropImageDialogPage` / `showCropImageDialog` 新增可选 `maxDimension`，源图经 `cropSourceImageProvider` 按长边等比 `ResizeImage`（不放大），裁剪输出 `croppedBitmap(maxSize: ...)` 同一上限；不传时行为不变（封面等其它调用点不受影响）；
  - `fushi/lib/src/pages/implementations/miscellaneous_settings_page.dart`：应用图标裁剪传 `maxDimension: appIconSourceMaxPixels`；
  - `fushi/android/app/src/main/java/app/fushi/reader/IconSwitchHelper.java`：`createCustomShortcut` 先 `inJustDecodeBounds` 读尺寸，再按 `iconDecodeSampleSize`（短边不小于 512 的最大 2 的幂）降采样解码；只回收与 `scaled` 不是同一对象的中间图。
- **[x] ② 已加自动化测试** — `fushi/test/utils/app_icon_custom_pipeline_bounds_test.dart`：`cropSourceImageProvider` 的行为（无上限=原图、有上限=fit 且不放大）、`CropController.getCroppedBitmap(maxSize:)` 对 3000×2000 真图输出封顶、对话框 / 设置页接线、Java 侧降采样解码与回收别名的源码守卫（Java 侧 CI 不跑 Android 单测，只能源码扫描）。
- **备注**：**待真机复测**（本批不用真机）：在低内存 Android（Android 9 / 4GB 级）上选一张相机原图做自定义图标，确认不再闪退、桌面快捷方式图标正常。另：若用户实际走的是「打开系统相册选图时 Fushi 在后台被系统按内存杀掉」，本修复降低了前后两段的峰值，但选图器期间被杀不归本仓控制。

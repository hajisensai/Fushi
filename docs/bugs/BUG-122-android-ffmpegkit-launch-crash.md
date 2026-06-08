## BUG-122 · Android 16 启动闪退：ffmpeg_kit 原生库不兼容 API 36
- **报告**：2026-06-08（用户：手机打开就闪退）
- **真实性**：✅ 真 bug。真机 logcat 铁证（OnePlus CPH2747 / Android 16 / API 36 / arm64-v8a / 页大小 4096）：
  ```
  java.lang.Error: FFmpegKit failed to start ... api level: 36
    at com.antonkarpenko.ffmpegkit.AbiDetect.<clinit>
    at com.antonkarpenko.ffmpegkit.FFmpegKitConfig.<clinit>
    at d2.g.onAttachedToActivity            ← ffmpeg_kit Flutter 插件
    at app.hibiki.reader.MainActivity.onCreate
  Caused by: java.lang.UnsatisfiedLinkError: Bad JNI version returned from JNI_OnLoad in
    ".../lib/arm64-v8a/libffmpegkit_abidetect.so": 0
  ```
  - 根因 `hibiki/pubspec.yaml`（旧 `ffmpeg_kit_flutter_new_min: ^3.1.0`）+ `hibiki/lib/src/media/video/ffmpeg_backend.dart`（旧 `KitFfmpegBackend`，旧 import line 5-6）。
  - 机理：第三方 `ffmpeg_kit_flutter_new`（antonkarpenko fork）预编译 `libffmpegkit_abidetect.so` 在 Android 16/API 36 上 `JNI_OnLoad` 返回非法版本 0；且该插件在 `onAttachedToActivity`（Activity 创建期，**早于任何 Dart**）就 `System.loadLibrary` 强制加载 → 进程在 `MainActivity.onCreate` 直接死。崩溃在 Dart 之外，`runZonedGuarded`/initError 屏全程拦不住 = 无声闪退。**debug 包亦崩 → 与 ProGuard 无关**（网传 ProGuard keep 规则不适用），是预编译库的原生不兼容。引入于 `4c05c9c33 feat(video): bundle ffmpeg on mobile`，从未真机验证。
- **[x] ① 已修复** — 移除 `ffmpeg_kit_flutter_new_min` 依赖 + 删 `KitFfmpegBackend`；移动端改自编 libffmpeg + FFI（`FfiFfmpegBackend`，与桌面同一份 ffmpeg 源）。两后端共用顶层 `runFfmpegProcess`。Phase 1（本提交）先止崩：FFI 原生库未捆绑前 `FfiFfmpegBackend.run` 抛 `ProcessException` → 各调用方既有 catch 降级（= 引入捆绑 ffmpeg 前状态），**app 不再闪退**。真机验证：卸旧装新 debug APK，启动后 `pidof` 存活、crash buffer 无 FFmpegKit。提交 `7b2d74d9b`。Phase 2/3（NDK/Mac 出库 + FFI 实体）恢复移动端 ffmpeg 功能，见 `docs/superpowers/plans/2026-06-08-android-self-built-ffmpeg.md`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/ffmpeg_backend_selection_test.dart` 源码守卫：①不再依赖 ffmpeg_kit/FFmpegKit/KitFfmpegBackend ②移动端路由 `FfiFfmpegBackend` ③桌面仍 CLI ④两后端共用 `runFfmpegProcess`（SIGKILL 调用仅一处）⑤pubspec 无 ffmpeg_kit。实际原生执行需真机验证。
- **备注**：
  - Phase 1（`7b2d74d9b`）先止崩：删第三方预编译包、移动端临时降级。
  - **Phase 2（自编 ffmpeg-kit 恢复功能）**：方向最终定为「重编 ffmpeg-kit 源码」（用户拍板，比从零 FFI 风险低）。从 `arthenica/ffmpeg-kit` 源码用 NDK r25c 重编**最小变体**（默认不加 `--full`，无外部 GPL 库 = 已「删 full」），在远程 Mac 自建工具链（JDK17+SDK33+NDK r25+cmake3.22.1+自编 pkg-config）。产物 AAR vendored 到 `third_party/ffmpeg_kit_flutter/`（配 arthenica 6.0.3 flutter wrapper，android 用 flatDir 本地 AAR + 补 `smart-exception-java`；并删 wrapper 里 Flutter 3.44 已移除的 v1 embedding `Registrar`）。移动端后端恢复 `KitFfmpegBackend`（`package:ffmpeg_kit_flutter`）。
  - **真机验证（OnePlus CPH2747/Android 16，arm64）**：①启动不再崩、自编 `libffmpegkit_abidetect.so` 正常 `JNI_OnLoad`；②集成测试 `integration_test/ffmpeg_selfbuilt_smoke_test.dart` 在设备上 `ffmpeg -version` / `ffprobe -version` 均 rc=0（日志 `Loaded ffmpeg-kit-flutter-android-min-arm64-v8a-6.0.3`）→ ffmpeg **真能执行**。全量 3123 测试绿。
  - **仍待**：armeabi-v7a（Mac 编译中，覆盖 32 位真机）；x86/x86_64（需 nasm，仅模拟器）；iOS xcframework（Mac 编译中，用户选了 iOS 也带 ffmpeg）。当前 vendored AAR 仅 arm64-v8a → 发布前须补全 ABI，否则非 arm64 设备会同样在 `FFmpegKitConfig.<clinit>` 启动崩。

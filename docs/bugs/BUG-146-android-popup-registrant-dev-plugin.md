## BUG-146 · Android release 构建把 integration_test 注册进 popup 引擎
- **报告**：2026-06-09（用户：安装到 192.168.1.50:5555 时触发）
- **真实性**：✅ 真 bug。`手机编译安装ARM.bat:105` 直接在 `flutter pub get` 后 release 构建，没有清理 `hibiki/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` 中可能由 Flutter test tooling 留下的 `integration_test` dev 插件引用；同时 `hibiki/android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt:53` 让 popup 独立引擎依赖自动生成注册器，而不是已经存在的最小 `FloatingDictPluginRegistrant`。
- **[x] ① 已修复** — popup 独立引擎改用 `FloatingDictPluginRegistrant.registerWith(engine)`；手机 release 安装脚本在构建前删除包含 `integration_test` 的陈旧 Android 生成注册器，迫使 Flutter release 构建重新生成可编译版本。（提交：`a2edde24a`）
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart` 守卫 popup 引擎不再引用 `GeneratedPluginRegistrant`，并守卫手机安装脚本会清理 dev-only 注册器。
- **备注**：验证命令：`flutter test test\pages\popup_dict_flutter_activity_static_test.dart`。

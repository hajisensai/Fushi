[根目录](../../CLAUDE.md) > [packages](../) > **fushi_launch_presence**

# fushi_launch_presence

## 模块职责

告诉 Dart「这次跑 `main()` 的引擎有没有界面」（BUG-4072）。会话标记（`fushi/lib/src/diagnostics/previous_exit_log.dart`）据此把无界面会话记成 `headless`，不算前台闪退。

## 为什么是独立插件包

Android 上要对**每个** FlutterEngine 注册通道：audio_service 在 `AudioService.onCreate` 里无 Activity 新建的引擎不经过 `MainActivity.configureFlutterEngine`，只走 GeneratedPluginRegistrant。只有 pub 插件能进 GeneratedPluginRegistrant，所以单独成包。iOS 只有一个隐式引擎，通道在 `fushi/ios/Runner/AppDelegate.swift`（`FushiLaunchPresence`）里答。

## 契约

- 通道 `app.fushi.reader/launch_presence`，方法 `query` → `{hasUi: bool, detail: String}`。
- 契约守卫：`fushi/test/diagnostics/launch_presence_channel_contract_test.dart`（对账 Dart 常量、Java 插件、AppDelegate 三处字面量）。

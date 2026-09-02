## BUG-2066 · macOS 更改数据位置失败：data_root_access 通道未注册
- **报告**：2026-09-02（GitHub #1159；macOS `Version 2.2.1.12447 (12447)` 更改数据位置时报 `MissingPluginException`）
- **真实性**：✅ 真 bug。`fushi/macos/Runner/MainFlutterWindow.swift:26-27` 已把窗口顶层 controller 换成 `MacOSWindowUtilsViewController`，真正的 Flutter controller 位于其 `flutterViewController`；但 `fushi/macos/Runner/AppDelegate.swift:10` 仍把顶层 `contentViewController` 直接转成 `FlutterViewController`。该转换恒失败，包住 `app.fushi/data_root_access` 与 `app.fushi.reader/foreground_selection` 的注册块被静默跳过；Dart 在 `macos_data_root_access.dart:22` 调 `createBookmark` 时因此收到 `MissingPluginException`。
- **[x] ① 已修复** —（本提交）`AppDelegate.applicationDidFinishLaunching` 改从 `MacOSWindowUtilsViewController.flutterViewController` 取得真实 engine messenger，再注册数据根与前台选中文本两个手写 MethodChannel；包装器缺失时写原生日志，不再静默跳过。
- **[x] ② 已加自动化测试** — `fushi/test/storage/macos_data_root_bookmark_guard_test.dart` 新增源码守卫：掩掉注释后钉住主窗包装结构，并分别验证两个通道的内部 engine messenger、`setMethodCallHandler` 与正确委托目标，禁止恢复顶层 `FlutterViewController` 强转。相关守卫 16 项通过，`flutter build macos --debug --no-pub` 成功。
- **备注**：异常发生在 `DataRootMigrator.migrate` 之前，未关闭数据库、未移动文件、未写 `data_root`，本次失败不会留下半迁移数据。

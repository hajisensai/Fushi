[根目录](../../CLAUDE.md) > [packages](../) > **flutter_inappwebview_windows**

# flutter_inappwebview_windows (fork)

## 模块职责

`flutter_inappwebview` 的 Windows 平台实现 fork（v0.6.0），通过 `dependency_overrides` 在主应用中替代官方版本。使用 WebView2 (Edge) 引擎渲染 WebView。

## 入口与启动

- Flutter plugin，仅 Windows 平台。
- `pluginClass: FlutterInappwebviewWindowsPluginCApi`（C++ 原生）。
- `dartPluginClass: WindowsInAppWebViewPlatform`。

## 对外接口

- 实现 `flutter_inappwebview_platform_interface` 接口。

## 关键依赖与配置

- `flutter_inappwebview_platform_interface: ^1.3.0`。

## 测试与质量

- `test/flutter_inappwebview_windows_test.dart` -- 基础测试。

## 相关文件清单

- `pubspec.yaml` -- 包配置
- `windows/` -- C++ 原生代码

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。

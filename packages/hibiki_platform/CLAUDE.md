[根目录](../../CLAUDE.md) > [packages](../) > **hibiki_platform**

# hibiki_platform

## 模块职责

平台服务抽象模块：定义 TTS 引擎、平台集成和存储路径的跨平台抽象接口。纯 Flutter 依赖，无原生代码。

## 入口与启动

- 库入口：`lib/hibiki_platform.dart`
- 无独立启动流程，由主应用注入具体实现。

## 对外接口

- `TtsEngine` (`lib/src/tts_engine.dart`) -- TTS 文字转语音抽象。
- `PlatformIntegration` (`lib/src/platform_integration.dart`) -- 平台集成抽象。
- `StoragePaths` (`lib/src/storage_paths.dart`) -- 存储路径抽象。

## 关键依赖与配置

- 仅依赖 `flutter` SDK，零第三方依赖。
- 设计为纯抽象层，具体实现在主应用或平台 plugin 中。

## 测试与质量

- 无独立测试。纯抽象接口，通过主应用集成测试验证。

## 相关文件清单

- `lib/hibiki_platform.dart` -- 库入口
- `lib/src/tts_engine.dart` -- TTS 抽象
- `lib/src/platform_integration.dart` -- 平台集成抽象
- `lib/src/storage_paths.dart` -- 存储路径抽象

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。

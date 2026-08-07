[根目录](../../CLAUDE.md) > [packages](../) > **hibiki_anki**

# hibiki_anki

## 模块职责

Anki 集成模块：定义 Anki 服务抽象接口，提供 AnkiDroid（Android 原生 Content Provider）和 AnkiConnect（桌面 HTTP API）两种实现，支持卡片创建、牌组/模型查询、重复检测。

## 入口与启动

- 库入口：`lib/hibiki_anki.dart`
- 服务抽象：`lib/src/anki_service.dart` -- `AnkiService` 抽象类。
- 无独立启动流程，由主应用 `AppModel` 根据平台选择具体实现。

## 对外接口

- `AnkiService` -- 抽象接口：`isAvailable()` / `getDeckNames()` / `getModelNames()` / `getModelFields()` / `addNote()` / `isDuplicate()`。
- `AnkiRepository` (`ankidroid/`) -- AnkiDroid Content Provider 实现（Android 专用）。
- `AnkiConnectRepository` + `AnkiConnectService` (`ankiconnect/`) -- AnkiConnect HTTP 实现（桌面/远程）。
- `BaseAnkiRepository` -- 共享基类。
- `AnkiModels` -- Anki 数据模型。
- `LapisPreset` -- 预设卡片模板。

## 关键依赖与配置

- `shared_preferences: ^2.2.2` -- 持久化 AnkiConnect 地址等设置。
- `http: ^1.1.0` -- AnkiConnect HTTP 通信。
- 无 hibiki_core 依赖（独立模块）。

## 数据模型

- `AnkiModels` -- 牌组/模型/字段元数据。
- `LapisPreset` -- 预设导出模板配置。
- AnkiMapping（定义在 `hibiki_core/tables.dart`）-- Anki 导出映射配置。

## 测试与质量

- 主应用测试：`hibiki/test/anki/anki_models_test.dart`
- 本包无独立 test 目录。

## 相关文件清单

- `lib/hibiki_anki.dart` -- 库入口
- `lib/src/anki_service.dart` -- 服务抽象
- `lib/src/anki_models.dart` -- 数据模型
- `lib/src/base_anki_repository.dart` -- 共享基类
- `lib/src/lapis_preset.dart` -- 预设模板
- `lib/src/ankidroid/anki_repository.dart` -- AnkiDroid 实现
- `lib/src/ankiconnect/ankiconnect_repository.dart` -- AnkiConnect 实现
- `lib/src/ankiconnect/ankiconnect_service.dart` -- AnkiConnect HTTP 服务

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。

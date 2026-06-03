# Hibiki Agent Rules

本文件是 Claude/Codex 进入 Hibiki 仓库后长期执行规则的**唯一真相源**，不是项目宣传页。
只保留会影响分析、修改、验证、审查、提交的规则；详细操作流程拆到 `docs/agent/`，项目介绍/构建上手见 [README.md](README.md)。
`AGENTS.md` 只是指向本文件的薄指针。

## 基本规则

- 始终用中文回复。
- code review spawn subagent 时，必须显式指定 `model: "opus"`，确保审查走 Opus 模型。
- 开始分析、修改、测试、提交或 PR 前，先读最近层级的 `AGENTS.md` / `CLAUDE.md`；子目录里有更近的就按更近层级执行。
- 根因修复：遇到功能异常、测试失败、运行时报错或用户要求修复，先复现或沿真实代码路径定位，再修数据结构、状态同步、生命周期、平台边界或依赖契约。不允许用延迟、重试、吞异常、硬编码、特例分支掩盖症状；只有外部系统或平台限制不可控时才允许临时兼容层，并说明影响范围和清理条件。
- 函数和新增 Dart helper 要有明确类型签名。
- 不从零重写现有功能；在当前实现上删减、合并、修正。
- 发现问题直接说，不要为了顺滑把风险说轻。
- 用户报 bug：按 [docs/BUGS.md](docs/BUGS.md)（文件头有完整流程）——先沿真实代码路径**验真伪**；真 bug 追加 `BUG-NNN`（记根因 `file:line`），再 **① 根因修复**、**② 在最强可落地层加自动化测试**（widget 行为 / CSS 生成器 / 源码扫描守卫），两步各勾一个勾选框并记提交哈希/测试文件；非真 bug/无法复现也记一条标「未复现」。与本地不入库的 `docs/REGRESSION_BUGS.md` 区分。

## 仓库地图

- 仓库根：`D:\APP\vs_claude_code\hibiki`（Melos workspace，名 `hibiki_workspace`）。Flutter app：`hibiki/`；Android 工程：`hibiki/android/`。
- 阅读器页面：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（`ReaderHibikiPage`，~5300 行：WebView 拦截 + JS 分页 + 有声书同步）。
- 书架页面：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`。
- reader source：`hibiki/lib/src/media/sources/reader_hibiki_source.dart`（`ReaderHibikiSource`）。
- 阅读器 JS/CSS：`hibiki/lib/src/reader/`（`reader_pagination_scripts.dart` 等）；JS 桥接全局是 `window.hoshiReader`（历史命名，是真实符号，勿改）。
- 全局状态：`hibiki/lib/src/models/app_model.dart`（`AppModel`，~2900 行，初始化流程 + 子系统委托核心，改前先理解）。
- Drift 数据库：`packages/hibiki_core/lib/src/database/database.dart` 和 `tables.dart`（schema v14，21 张表，WAL）。
- 词典 FFI：`packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart`。
- 有声书：`packages/hibiki_audio/` + `hibiki/lib/src/media/audiobook/`（导入入口 `book_import_dialog.dart` / `audiobook_import_dialog.dart`）。
- i18n 同步脚本：`hibiki/tool/i18n_sync.dart`。
- 审查报告：`docs/reviews/YYYY-MM-DD-project-review.md`；已复现回归：`docs/REGRESSION_BUGS.md`（本地，不入库）；测试证据：`.codex-test/`（不入库）。

## 当前技术事实

- Flutter `3.44.0` / Dart `3.12.0`（stable），Dart SDK 约束 `>=3.5.0 <4.0.0`；最低 Android API 24，`compileSdk 36` / `targetSdk 35`。
- 状态管理 Riverpod；音频 just_audio（桌面经 just_audio_media_kit）；录音 record 6.x。
- 主存储是 Drift SQLite（`HibikiDatabase`，schema v14），偏好落 Drift `preferences` 表 + `profile_settings` 每 Profile 快照。**已无 Isar/Hive 依赖**；旧注释里的 Isar/Hive 不代表当前事实，先查代码再判断。
- EPUB 阅读器走 reader_hibiki 实现（见仓库地图）。`reader_ttu` key、`setTtu*` 方法、`ttuBookId` 列、`ttu_*` i18n 只是旧数据兼容残留，不代表还有 TTU 阅读器；没有迁移方案别随手改这些持久化 key。
- 旧 TTU 迁移代码已移除（develop `90c37b472`：`TtuMigrationServer` / `TtuIdbReader` / `assets/ttu-ebook-reader` 均已删除）；只剩上述命名残留作旧数据兼容。阅读器渲染/交互问题按 reader_hibiki 路径修，不要去上游 ttu fork 仓库改。
- 词典导入/查询核心走 `hoshidicts` C++ FFI；格式 UI 或旧 Dart format 类不一定是真实导入路径。
- 国际化用 Slang，源文件 `hibiki/lib/i18n/*.i18n.json`（17 种语言），生成文件 `strings.g.dart`。
- 5 平台均出包（Android/iOS/macOS/Windows/Linux）：Android 走 Material Design 3，iOS 走 Cupertino，桌面端复用 Material 架构并依赖 fork 的 `flutter_inappwebview_windows` 渲染 EPUB。

## i18n 纪律

- 新增/删除 i18n key **禁止手动逐文件编辑**，必须用 `hibiki/tool/i18n_sync.dart`（Slang 要求 17 个文件 key 完整，缺 key 报错）：`--add <key> <en> <zh>` / `--remove <key>` / 无参补全缺失 / `--dry-run` 预览。
- 改完 key 跑 `dart run slang` 重新生成 `strings.g.dart`，再 `dart format` 生成文件；不要手改生成文件。

## 验证

- 文档改动：至少 `git diff --cached --check`，不必跑 Flutter 测试。
- Dart/Flutter 改动（在 `hibiki/` 下）：`dart format .` + `flutter test`（用项目的 Flutter 3.44.0 工具链；本机 flutter 不在 PATH 就把完整路径写进 `CLAUDE.local.md`）。
- Android 资源/manifest/Gradle/权限/通知/前台服务/打包改动：再加 `gradlew :app:assembleRelease`（在 `hibiki/android/`；Windows 用 `.\gradlew.bat`）。
- 阅读器/导入/播放/布局问题，声明「修好了」前必须用真实模拟器或用户指定设备复测原始失败路径并留证据（见 [docs/agent/integration-testing.md](docs/agent/integration-testing.md)）。

## 提交

- 完成代码/文档/测试/审查改动后默认提交本轮。
- 提交前 `git status --short`，**只 stage 本轮相关文件**（禁止 `git add -A`——本工作区可能有并发 agent 的无关改动）；再 `git diff --cached --check`。
- 提交信息简洁说明真实改动（如 `docs: rewrite agent rules` / `fix(reader): preserve restore position`）。
- 提交后再 `git status --short`，回复中给出提交哈希和仍存在的无关未提交改动。

## 详细操作流程（docs/agent/）

| 要做的事 | 看这里 |
|---|---|
| 跑集成测试 / 设备验证 / ADB 降级 / AnkiDroid / DB 查询 / 测试素材 | [docs/agent/integration-testing.md](docs/agent/integration-testing.md) |
| 构建 5 平台 / melos / 依赖补丁机制 | [docs/agent/build.md](docs/agent/build.md) |
| 持续审查模式 / 报告格式 / 回归记录 | [docs/agent/review-process.md](docs/agent/review-process.md) |
| 阅读器调试（WebView / 恢复 / 分页 / 有声书遮挡 / 平台特例） | [docs/agent/reader-debugging.md](docs/agent/reader-debugging.md) |

## 模块索引

| 模块 | 语言 | 职责 | 模块文档 |
|---|---|---|---|
| `hibiki/` | Dart | Flutter 主应用：UI/阅读器/导入/设置 | [hibiki/CLAUDE.md](hibiki/CLAUDE.md) |
| `packages/hibiki_core/` | Dart | DB schema（21 表）/偏好/语言配置 | [CLAUDE.md](packages/hibiki_core/CLAUDE.md) |
| `packages/hibiki_dictionary/` | Dart+C++ | 词典引擎/FFI/多格式导入 | [CLAUDE.md](packages/hibiki_dictionary/CLAUDE.md) |
| `packages/hibiki_anki/` | Dart | Anki 集成（AnkiDroid + AnkiConnect） | [CLAUDE.md](packages/hibiki_anki/CLAUDE.md) |
| `packages/hibiki_audio/` | Dart | 字幕解析/有声书播放/音频匹配 | [CLAUDE.md](packages/hibiki_audio/CLAUDE.md) |
| `packages/hibiki_platform/` | Dart | TTS/平台集成/存储路径抽象 | [CLAUDE.md](packages/hibiki_platform/CLAUDE.md) |
| `packages/flutter_inappwebview_windows/` | Dart+C++ | inappwebview Windows fork | [CLAUDE.md](packages/flutter_inappwebview_windows/CLAUDE.md) |
| `packages/gamepads_android_stub/` | Dart | `gamepads_android` 的 no-op stub override | — |
| `third_party/` | — | vendored 补丁包：carousel_slider / fading_edge_scrollview / flutter_inappwebview_android / network_to_file_image | — |

> 完整架构、技术栈、构建命令、致谢见 [README.md](README.md)。`file_picker` 用 pub.dev 版（**不是** fork）。依赖补丁机制（vendored vs apply-patches）见 [docs/agent/build.md](docs/agent/build.md)。

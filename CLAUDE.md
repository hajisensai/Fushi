# Hibiki Agent Rules

本文件是 Claude/Codex 进入 Hibiki 仓库后的长期执行规则，不是项目宣传页。只保留会影响分析、修改、验证、审查和提交的内容；项目介绍放 README，细节设计放 docs。

## 基本规则

- 始终用中文回复。
- 开始分析、修改、测试、提交或 PR 前，先读取最近层级的 `AGENTS.md`；如果子目录里还有更近的 `AGENTS.md`，按更近层级执行。
- 遇到功能异常、测试失败、运行时报错或用户要求修复时，必须做根因修复：先复现或沿真实代码路径定位，再修数据结构、状态同步、生命周期、平台边界或依赖契约。
- 不允许用延迟、重试、吞异常、硬编码、特例分支来掩盖症状。只有外部系统或平台限制不可控时，才允许临时兼容层，并说明影响范围和清理条件。
- 函数和新增 Dart helper 要有明确类型签名。
- 不从零重写现有功能；在当前实现上删减、合并、修正。
- 发现问题要直接说，不要为了顺滑而把风险说轻。

## 仓库地图

- 仓库根：`D:\APP\vs_claude_code\hibiki`
- Flutter app：`hibiki/`
- Android 工程：`hibiki/android/`
- 当前阅读器入口：`hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- 当前书架入口：`hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`
- 当前 reader source：`hibiki/lib/src/media/sources/reader_hoshi_source.dart`
- Drift 数据库：`hibiki/lib/src/database/database.dart` 和 `hibiki/lib/src/database/tables.dart`
- 审查报告：`docs/reviews/YYYY-MM-DD-project-review.md`
- 已复现回归：`docs/REGRESSION_BUGS.md`
- 测试证据：`.codex-test/`

## 当前技术事实

- Flutter `3.41.6` / Dart `3.11.4`，最低 Android API 24。
- 主存储是 Drift SQLite：`HibikiDatabase`，偏好也落在 Drift `preferences` 表。旧注释里出现的 `Isar` / `Hive` 不一定代表当前事实，先查代码再判断。
- EPUB 阅读器当前走 Hoshi 实现：`ReaderHoshiPage` / `ReaderHoshiSource`。`ReaderHoshiSource.uniqueKey`、`reader_ttu/hoshi://book/...` 和部分 `setTtu*` 方法名只是旧数据兼容边界，不代表当前还有 TTU 阅读器；不要在没有迁移方案时随手改持久化 key。
- 词典导入和查询核心走 `hoshidicts` C++ FFI；格式 UI 或旧 Dart format 类不一定代表真实导入路径。
- 国际化使用 Slang，源文件在 `hibiki/lib/i18n/*.i18n.json`，生成文件是 `strings.g.dart`。
- 有声书/字幕相关核心路径在 `hibiki/lib/src/media/audiobook/`，当前导入入口包括 `book_import_dialog.dart` 和 `audiobook_import_dialog.dart`。
- 旧 TTU 只保留迁移用途：`TtuMigrationServer` / `TtuIdbReader` / `assets/ttu-ebook-reader` 用来读取历史 IndexedDB 数据。当前阅读器问题不要去 `D:\ttu-fork` 修。

## 审查规则

- 用户要求审查项目、继续审查、风险审计或类似任务时，默认进入持续审查模式；不要只在聊天里输出一次性总结。
- 审查报告写入 `docs/reviews/YYYY-MM-DD-project-review.md`。如果目录不存在，先创建 `docs/reviews/`。
- 每轮审查追加到同一个报告文件，不覆盖历史内容。每轮至少包含：
  - `Scope`: 本轮检查的文件、路径、提交范围或用户路径。
  - `Findings`: 按 `HBK-AUDIT-XXX` 编号列出问题；每个问题必须包含 `severity`、`status`、文件/行号、根因、影响、修复建议和验证方式。
  - `Next Scope`: 下一轮继续审查的范围。
- 审查顺序默认按风险走：数据库/迁移 -> 启动初始化 -> 阅读器状态 -> 字典导入/native FFI -> 音频 cue -> WebView/缓存 -> UI 假状态。
- 审查阶段只写报告和修复建议，不改业务代码；除非用户明确要求“开始修”“逐条修”或等价指令。
- 如果审查或手工验证发现已复现回归，必须同步更新 `docs/REGRESSION_BUGS.md`，并把截图、UI XML、logcat 或 bounds 证据放到 `.codex-test/` 后在报告中引用。
- 报告结论必须区分“代码路径审查发现的风险”“已经复现的 bug”“已验证通过的修复”。没有跑过验证时，不要写成已通过。

## 验证规则

- 文档规则改动：至少运行 `git diff --cached --check`，不需要跑 Flutter 测试。
- Dart/Flutter 改动：在 `hibiki/` 下运行：
  ```powershell
  D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
  D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test
  ```
- Android 资源、manifest、Gradle、权限、通知、前台服务或打包行为改动：还要运行：
  ```powershell
  cd hibiki\android
  .\gradlew.bat :app:assembleRelease
  ```
- 修改当前阅读器 WebView、JS、CSS、资源拦截或分页逻辑时，只在 Hibiki 侧验证 Hoshi 阅读器路径。修改旧 TTU 迁移代码或迁移资产时，验证“历史 IndexedDB -> 当前 Hoshi 存储/书架”的迁移路径。
- 声明“修好了”之前，必须验证原始失败路径；阅读器/导入/播放/布局问题必须用真实模拟器或用户指定设备复测，并留下证据路径。

## 提交规则

- 每次完成代码、文档、测试或审查报告修改后，默认提交本轮改动。
- 提交前检查 `git status --short`，只 stage 本轮相关文件；工作区已有的无关改动不得纳入提交。
- 提交前运行 `git diff --cached --check`。
- 提交信息要简洁说明真实改动，例如 `docs: rewrite claude agent rules` 或 `fix(reader): preserve restore position`。
- 提交后再次检查 `git status --short`，并在回复中说明提交哈希和仍然存在的无关未提交改动。

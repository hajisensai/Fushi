# Hibiki Agent Rules

本文件是 Claude/Codex 进入 Hibiki 仓库后长期执行规则的**唯一真相源**，不是项目宣传页。
只保留会影响分析、修改、验证、审查、提交的规则；详细操作流程拆到 `docs/agent/`，项目介绍/构建上手见 [README.md](README.md)。
`AGENTS.md` 只是指向本文件的薄指针。

## 基本规则

- 始终用中文回复。
- 开始分析、修改、测试、提交或 PR 前，先读最近层级的 `AGENTS.md` / `CLAUDE.md`；子目录里有更近的就按更近层级执行。
- 修改代码、文档、配置或测试时必须使用独立 Git worktree，不得直接在原工作区编辑；在 worktree 中完成修改、验证和提交。非大型修改（单一目标、短周期）完成后，默认将工作分支合并回原目标分支；大型、长周期或需分阶段审查的修改保留独立分支/worktree，待审查确认后再合并。合并不得覆盖原工作区已有的未提交改动。
- 新建 worktree 后（无论 `EnterWorktree`、手动 `git worktree add` 还是其它工具创建），第一件事在该 worktree 里跑 `pwsh -File tool/setup_worktree.ps1`（Windows 用 `powershell -ExecutionPolicy Bypass -File tool/setup_worktree.ps1`）：它从主 checkout 把本地真值密钥（`google_oauth_secret.dart` / `log_upload_secret.dart` 等**所有 skip-worktree 文件**，清单动态读取无需硬编码）搬进来并在本 worktree 续上 `skip-worktree`（真值不显示 dirty、绝不会误提交），再调 `tool/bootstrap.ps1`（pub get + 打补丁）。**别再手动 cp 密钥桩或逐个配置**。只跑 `flutter analyze` / `flutter test` 时入库的占位/空值已够编译；真值仅在 worktree 里真机验证 Google Drive 登录 / 日志上传时才需要。只搬密钥不跑 bootstrap 用 `-SkipBootstrap`。
- 多 agent 并发时必须先登记本机 ownership：
  - 在主 checkout 的 `.worktrees/coordination/claims/` 复制 `_template.json` 新建自己的 claim；若当前位于 `.worktrees/<task>` worktree，则使用同级的 `../coordination/claims/`。
  - claim 写清任务、agent、分支、worktree、base SHA、预计修改文件和高冲突文件；普通任务 agent 只编辑自己的 claim，不在 tracked 文件里记录协调状态。
  - 普通任务 agent 不主动 rebase/merge `develop`；integration owner 统一读取 claims、决定合并顺序、更新 `develop`、跑 broad verification，并将完成/阻塞的 claim 移到 `done/` / `blocked/`。
- 多使用子代理：遇到 2 个以上可独立推进的分析、审查、文件定位、测试诊断或实现子任务时，优先派发子代理并行处理；主代理负责整合结论、控制范围、复核关键证据和最终提交。不要把需要共享同一脏文件或强顺序依赖的步骤硬拆给多个子代理。
- 根因修复：遇到功能异常、测试失败、运行时报错或用户要求修复，先复现或沿真实代码路径定位，再修数据结构、状态同步、生命周期、平台边界或依赖契约。不允许用延迟、重试、吞异常、硬编码、特例分支掩盖症状；只有外部系统或平台限制不可控时才允许临时兼容层，并说明影响范围和清理条件。
- 函数和新增 Dart helper 要有明确类型签名。
- 不从零重写现有功能；在当前实现上删减、合并、修正。
- 发现问题直接说，不要为了顺滑把风险说轻。
- 用户报 bug：按 [docs/BUGS.md](docs/BUGS.md)（文件头有完整流程）——先沿真实代码路径**验真伪**。**一 bug 一文件**：真 bug 用 `dart run tool/bug.dart new <slug> [标题...]` 新建独立文件 `docs/bugs/BUG-NNN[-slug].md`（自动取下一个空号、生成骨架、重建索引；**禁止手动往 `docs/BUGS.md` 加正文**——它只是头部约定 + 自动索引表），在该文件里记根因 `file:line`，再 **① 根因修复**、**② 在最强可落地层加自动化测试**（widget 行为 / CSS 生成器 / 源码扫描守卫），两步各把 `[ ]` 勾成 `[x]` 并记提交哈希/测试文件，改完跑 `dart run tool/bug.dart reindex` 重建索引；非真 bug/无法复现也建一条标「未复现」。这套 per-file 结构消除并发 agent 撞号 + 顶部插入的 git 冲突（守卫 `hibiki/test/tools/bugs_per_file_guard_test.dart`）。与本地不入库的 `docs/REGRESSION_BUGS.md` 区分。

## 仓库地图

- 仓库根：`D:\APP\vs_claude_code\hibiki`（Melos workspace，名 `hibiki_workspace`）。Flutter app：`hibiki/`；Android 工程：`hibiki/android/`。
- 阅读器页面：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（`ReaderHibikiPage`，~7300 行：WebView 拦截 + JS 分页 + 有声书同步）。
- 书架页面：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`。
- reader source：`hibiki/lib/src/media/sources/reader_hibiki_source.dart`（`ReaderHibikiSource`）。
- 阅读器 JS/CSS：`hibiki/lib/src/reader/`（`reader_pagination_scripts.dart` 等）；JS 桥接全局是 `window.hoshiReader`（历史命名，是真实符号，勿改）。
- 全局状态：`hibiki/lib/src/models/app_model.dart`（`AppModel`，~3600 行，初始化流程 + 子系统委托核心，改前先理解）。
- Drift 数据库：`packages/hibiki_core/lib/src/database/database.dart` 和 `tables.dart`（schema v24，28 张表，WAL）。
- 词典 FFI：`packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart`。
- 有声书：`packages/hibiki_audio/` + `hibiki/lib/src/media/audiobook/`（导入入口 `book_import_dialog.dart` / `audiobook_import_dialog.dart`）。
- i18n 同步脚本：`hibiki/tool/i18n_sync.dart`。
- 审查报告：`docs/reviews/YYYY-MM-DD-project-review.md`；已复现回归：`docs/REGRESSION_BUGS.md`（本地，不入库）；测试证据：`.codex-test/`（不入库）。

## 当前技术事实

- Flutter `3.44.0` / Dart `3.12.0`（stable），Dart SDK 约束 `>=3.5.0 <4.0.0`；最低 Android API 24，`compileSdk 36` / `targetSdk 35`。
- 状态管理 Riverpod；音频 just_audio（桌面经 just_audio_media_kit）；录音 record 6.x。
- 主存储是 Drift SQLite（`HibikiDatabase`，schema v24），偏好落 Drift `preferences` 表 + `profile_settings` 每 Profile 快照。**已无 Isar/Hive 依赖**；旧注释里的 Isar/Hive 不代表当前事实，先查代码再判断。
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
- 集成测试操作真 app **一律焦点驱动（`FocusDriver` / `tester.sendKeyEvent`，禁止 `tester.tap` 或坐标点击）**：`Tab` 遍历→检测控件类型→Switch/按钮确认用 `Enter`（**不要用空格**——App 已把裸空格中和为 `DoNothingIntent`，焦点确认统一走 Enter / 手柄 A，见 `hibiki/lib/src/shortcuts/global_navigation.dart`）、Slider/Stepper/Segmented 用方向键→断言真写穿 DB/真生效→还原。同一份测试三端可跑（模拟器 `-d emulator-<port>` / Windows 离屏 `tool/run_windows_itest.ps1` / Mac 跨机 `tool/run_mac_itest.ps1`），完整流程见 [docs/agent/integration-testing.md](docs/agent/integration-testing.md) 的「焦点驱动操作」。

## 提交

- 完成代码/文档/测试/审查改动后默认提交本轮。
- push 前按 [docs/agent/build.md](docs/agent/build.md) 的版本号规则判断是否 bump `hibiki/pubspec.yaml`：**`+build` 每次发布单调 +1**（可读发布序号，与语义版本无关，多数发布只 +build）；**语义版本 `X.Y.Z` 按里程碑升**——一批功能/大改升 minor 重置 patch、一批修复升 patch，不是每个 commit 都升；Android `versionCode` 由 CI `git rev-list --count HEAD` 自动，不靠 `+build`。
- 发布通道硬规则：默认 `main` / `develop` push 只能进入 debug / prerelease / non-Latest 通道；测试版和正式版只能通过手动 `workflow_dispatch` 或手动发布 GitHub Release 触发；push 不得创建或更新 Latest/正式 release。
- Android / Windows debug/beta 发布必须按 [docs/agent/build.md](docs/agent/build.md) 使用跨 workflow 统一 release 序列；同一 commit/语义版本不得用各自 workflow run number 拆成两个同版本预发布入口，发布 workflow 会先跑 `tool/check_release_policy.ps1` 守卫。
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
| `packages/hibiki_core/` | Dart | DB schema（28 表）/偏好/语言配置 | [CLAUDE.md](packages/hibiki_core/CLAUDE.md) |
| `packages/hibiki_dictionary/` | Dart+C++ | 词典引擎/FFI/多格式导入 | [CLAUDE.md](packages/hibiki_dictionary/CLAUDE.md) |
| `packages/hibiki_anki/` | Dart | Anki 集成（AnkiDroid + AnkiConnect） | [CLAUDE.md](packages/hibiki_anki/CLAUDE.md) |
| `packages/hibiki_audio/` | Dart | 字幕解析/有声书播放/音频匹配 | [CLAUDE.md](packages/hibiki_audio/CLAUDE.md) |
| `packages/hibiki_platform/` | Dart | TTS/平台集成/存储路径抽象 | [CLAUDE.md](packages/hibiki_platform/CLAUDE.md) |
| `packages/flutter_inappwebview_windows/` | Dart+C++ | inappwebview Windows fork | [CLAUDE.md](packages/flutter_inappwebview_windows/CLAUDE.md) |
| `packages/gamepads_android_stub/` | Dart | `gamepads_android` 的 no-op stub override | — |
| `third_party/` | — | vendored 补丁包：carousel_slider / fading_edge_scrollview / flutter_inappwebview_android / network_to_file_image | — |

> 完整架构、技术栈、构建命令、致谢见 [README.md](README.md)。`file_picker` 用 pub.dev 版（**不是** fork）。依赖补丁机制（vendored vs apply-patches）见 [docs/agent/build.md](docs/agent/build.md)。

## 始终用中文回复

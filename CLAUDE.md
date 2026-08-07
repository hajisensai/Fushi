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
- 多使用子代理：遇到 2 个以上可独立推进的分析、审查、文件定位、测试诊断或实现子任务时，优先派发子代理并行处理；主代理负责整合结论、控制范围、复核关键证据和最终提交。不要把需要共享同一脏文件或强顺序依赖的步骤硬拆给多个子代理。子代理后台派发、主代理不空等，绝不让两个代理重复做同一子任务；难度分级、标准并行时间线和空等禁止清单见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md)。
- 根因修复：遇到功能异常、测试失败、运行时报错或用户要求修复，先复现或沿真实代码路径定位，再修数据结构、状态同步、生命周期、平台边界或依赖契约。不允许用延迟、重试、吞异常、硬编码、特例分支掩盖症状；只有外部系统或平台限制不可控时才允许临时兼容层，并说明影响范围和清理条件。
- 函数和新增 Dart helper 要有明确类型签名。
- 不从零重写现有功能；在当前实现上删减、合并、修正。
- 发现问题直接说，不要为了顺滑把风险说轻。
- 用户报 bug：按 [docs/BUGS.md](docs/BUGS.md)（文件头有完整流程）——先沿真实代码路径**验真伪**。**一 bug 一文件**：真 bug 用 `dart run tool/bug.dart new <slug> [标题...]` 新建独立文件 `docs/bugs/BUG-NNN[-slug].md`（自动取下一个空号、生成骨架、重建索引；**禁止手动往 `docs/BUGS.md` 加正文**——它只是头部约定 + 自动索引表），在该文件里记根因 `file:line`，再 **① 根因修复**、**② 在最强可落地层加自动化测试**（widget 行为 / CSS 生成器 / 源码扫描守卫），两步各把 `[ ]` 勾成 `[x]` 并记提交哈希/测试文件，改完跑 `dart run tool/bug.dart reindex` 重建索引；**撞号别手改**——跑 `dart run tool/bug.dart renumber <old> <new>`（文件名/正文 H2/代码引用/测试名四处一起改 + reindex + 自校验零残留；只改文件名不改正文 H2 会让守卫测试 CI 红）。取号扫「全部本地+远端分支的 commit 树 **+ 本机每个 git 工作区磁盘上还没提交的 `docs/bugs/*.md`**」（后者是并发撞号的大头：`new` 写文件到 commit 之间隔着几十分钟到几小时，BUG-1429），但那不是分布式锁，开 PR 前和每次 rebase 后仍要重跑 `check`——`check` 现在会跨分支/工作区复核并报出「我新引入的号还被谁占着、在哪个 ref/工作区」，想当硬门用 `check --strict`（默认只让本地不变式决定退出码）；非真 bug/无法复现也建一条标「未复现」。这套 per-file 结构消除并发 agent 撞号 + 顶部插入的 git 冲突（守卫 `hibiki/test/tools/bugs_per_file_guard_test.dart`）。与本地不入库的 `docs/REGRESSION_BUGS.md` 区分。

## 仓库地图

- 仓库根：`D:\APP\vs_claude_code\hibiki`（Melos workspace，名 `fushi_workspace`）。Flutter app：`hibiki/`；Android 工程：`hibiki/android/`。
- 阅读器页面：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（`ReaderHibikiPage`，3242 行主体 + `reader_hibiki/` 下 8 个域 part 共 9583 行：WebView 拦截 + JS 分页 + 有声书同步）。
- 视频页面：`hibiki/lib/src/pages/implementations/video_hibiki_page.dart`（6358 行主体 + `video_hibiki/` 下 18 个 part 共 6966 行）；视频首页 `home_video_page.dart`（3080 行）。
- 书架页面：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`；首页 dashboard：`pages/implementations/home_dashboard_page.dart`。
- reader source：`hibiki/lib/src/media/sources/reader_hibiki_source.dart`（`ReaderHibikiSource`）。
- 阅读器 JS/CSS：`hibiki/lib/src/reader/`（17 个 JS/CSS 注入封装，`reader_pagination_scripts.dart` 等）；JS 桥接全局是 `window.hoshiReader`（历史命名，是真实符号，勿改）。
- 全局状态：`hibiki/lib/src/models/app_model.dart`（`AppModel`，~5150 行，初始化流程 + 子系统委托核心，改前先理解）。
- Drift 数据库：`packages/fushi_core/lib/src/database/database.dart` 和 `tables.dart`（schema v62，53 张表，WAL）。
- 词典：Dart 封装 `packages/fushi_dictionary/lib/src/engine/fushidicts.dart` + FFI 绑定 `lib/src/ffi/fushidicts_ffi_bindings.dart`；C++ 引擎源码全在 `native/hoshidicts/`（包内已无 C++），`hoshidicts_external/` 是 vendored 第三方，上游同步基线见 `native/hoshidicts/UPSTREAM.md`。
- 有声书：`packages/fushi_audio/` + `hibiki/lib/src/media/audiobook/`（导入入口 `book_import_dialog.dart` / `audiobook_import_dialog.dart`）。
- 互联/同步：`hibiki/lib/src/sync/`（`interconnect_*.dart`、`aggregate_sync_service.dart`、`backup_*`）。
- galgame 制卡：Flutter 侧 `hibiki/lib/src/lookup/`（overlay 浮窗）+ `hibiki/lib/src/mining/galgame_*`；C++ hook（injector + hook DLL + vendored LunaHook）在本仓 `native/galgame_hook/`。`tools/build_distribution.ps1` 单独构建两架构 helper zip；zip 随 Windows 主包进入 `galgame_helper/` 供离线首装，同时由根 `.github/workflows/voice-hook-helper.yml` 发布供旧包/后台更新。helper **不链接进 `Hibiki.exe`**，运行时仍是隔离子进程/DLL。
- 浏览器扩展：`tools/browser-extension/`（注意是根级 `tools/`，与 `tool/` 不同目录）。
- 工具脚本归属：根 `tool/` = `setup_worktree.ps1` / `bootstrap.ps1` / `bug.dart` / `check_release_policy.ps1` / `run_mac_itest.ps1`；`hibiki/tool/` = `i18n_sync.dart` / `run_windows_itest.ps1` / `comprehensive_test_runner.dart`。
- 审查报告：`docs/reviews/YYYY-MM-DD-project-review.md`；已复现回归：`docs/REGRESSION_BUGS.md`（本地，不入库）；测试证据：`.codex-test/`（不入库）。

## 当前技术事实

- Flutter 版本分两处：本地钉 `.fvmrc` = `3.41.6`（pubspec `flutter: "^3.41.6"`），CI workflows 用 `3.44.0`；Dart SDK 约束 `>=3.5.0 <4.0.0`。最低 Android API 24，`compileSdk 36` / `targetSdk 35`。
- 状态管理 Riverpod；音频 just_audio（桌面经 just_audio_media_kit）；录音 record 6.0.0；视频播放走 **media_kit**（third_party vendored 全套）+ youtube_explode_dart。
- torrent 走内部包 `packages/fushi_torrent`（libtorrent 2.x C ABI FFI，native 在 `native/hibiki_torrent/`；Windows 预编译 DLL 随包，缺失时回退外接 qBittorrent）。
- 主存储是 Drift SQLite（`HibikiDatabase`，schema v62），偏好落 Drift `preferences` 表 + `profile_settings` 每 Profile 快照。**已无 Isar/Hive 依赖**；旧注释里的 Isar/Hive 不代表当前事实，先查代码再判断。
- EPUB 阅读器走 reader_hibiki 实现（见仓库地图）。`reader_ttu` key、`setTtu*` 方法、`ttu_*` i18n 只是旧数据兼容残留，不代表还有 TTU 阅读器；没有迁移方案别随手改这些持久化 key。（旧文档提过的 `ttuBookId` 列在当前 schema 已不存在，只活在迁移阶梯里。）
- 旧 TTU 迁移代码已移除（develop `90c37b472`：`TtuMigrationServer` / `TtuIdbReader` / `assets/ttu-ebook-reader` 均已删除）；只剩上述命名残留作旧数据兼容。阅读器渲染/交互问题按 reader_hibiki 路径修，不要去上游 ttu fork 仓库改。
- 词典导入/查询核心走 `hoshidicts` C++ FFI；格式 UI 或旧 Dart format 类不一定是真实导入路径。
- 国际化用 Slang，源文件 `hibiki/lib/i18n/*.i18n.json`（17 种语言），生成文件 `strings.g.dart`。
- 5 平台均出包（Android/iOS/macOS/Windows/Linux）：`auto` 下五个平台统一走 Material Design 3；Cupertino / macOS renderer 仅保留为隐藏内部能力。桌面端依赖 fork 的 `flutter_inappwebview_windows` 渲染 EPUB。

## 命名术语表（2026-07 定案，新代码遵守）

同概念一词。存量持久化名（DB 列/偏好键/磁盘目录/wire key）**冻结不追改**，但新代码/新 UI 不再产生淘汰词；详见 `docs/` 下命名统一审计与守卫测试。

| 概念 | 唯一词 | 淘汰词（新代码禁用） |
|---|---|---|
| 媒体配图 | `cover` / 封面 | poster、thumbnail（书岛旧持久化名冻结） |
| 库页（书/视频/游戏页面统称） | library page / 中文按域「书架/媒体库」 | shelf 用作页面名；中文「书库」 |
| 条目排序/归属映射层 | `shelf`（`ShelfEntries` 域） | — |
| 扫描根 | `source library`（`media/source_library/`） | 裸 source |
| 最近打开流 | `history`（仅此一义） | history 用作书架页面名 |
| 首页面板 | `dashboard` | — |
| 续播三层 | 选条目 `continue*` / 定起点 `resolve*ResumePoint` / 落地执行 `restoreTo*` | 三层动词混用 |
| torrent 恢复数据 | `fastResume*`（对齐 qBittorrent） | 裸 resume |
| 互联对端 | 已配对对端 `peer` / 提供库角色 `host` / 对端数据 DTO `Remote*` / 未配对发现 `device`；子系统名 `Interconnect*` | 混用；`HibikiClient*` 作类名前缀 |
| 备份操作 | 顶层 `createBackup`/`restoreBackup`；内部子步骤 `reapply*`；export/import 只留给单资产 | 内部子步骤叫 restore* |
| 时刻列 | `<名>At`（int 毫秒，无 Ms 后缀） | `Ms` 后缀用于时刻（仅时长/偏移可用） |
| 墓碑删除时刻 | `deletedAt` | removedAt |
| 媒体种类值域 | 各域独立枚举（`MediaKind`/`ActivityMediaKind`/`StatSourceKind`/`ProfileMediaKind`/`SyncTombstoneKind`/`SourceLibraryKind`/`SentenceSourceKind`），跨域换算走 `media_kind_mappings.dart`，禁 UI 层裸字符串比较/bool 降维 | — |
| 搜索匹配 | `matchesMediaSearch`/`filterByMediaSearch`（统一归一化） | 裸 `toLowerCase().contains` 做用户可见搜索 |
| 重复条目**处置策略** | 单参 `DuplicatePolicy` 三态：交互式单条 `.ask(cb)` / 批量后台 `.skip()` / 程序化留副本 `.suffix()`。三种差异**有意**（交互预算不同），不要再往一起合，但必须显式声明 | `bool skipIfExists` + `DuplicateTitleCallback?` 两参编码三态；`onDuplicateTitle` 作参数名 |
| 重复**判据**（这东西是否已在库） | `isDuplicate*` / `filterOutDuplicate*` | `isVideoPathReferenced`、`filterDroppedGameExes` |
| 用户对重复的选择 | `DuplicateChoice{suffix, cancel}`（与策略词同形） | `DuplicateTitleResolution{addSuffix, cancel}` |
| i18n key | `<域>_<子域名词>_<动作/状态>`（动词在尾）+ 英文 sentence case；改名必须 `i18n_sync --rename` | 手改 json；新增 `games_`/`ttu_` 前缀 key |

## Galgame Hook 硬规则

- Galgame 文本/语音 Hook、LunaHook、helper、adapter、引擎适配和制卡 E2E 默认**只做 Windows 端**。允许范围是 Windows Hibiki、Windows x86/x64 注入器/helper/hook，以及 Windows 链路必需的共享代码和平台无关测试；禁止修改、构建、运行、打包、发布或宣称支持 Android、iOS、macOS、Linux 的 galgame 实现。只有用户明确变更平台范围时才能越过此边界，通用的多平台构建或集成测试说明不得自动扩大 galgame 任务范围。
- 任何 galgame 文本/语音 Hook、LunaHook、helper、adapter、引擎适配或支持声明，开工前必须完整阅读 [docs/agent/galgame-hooking.md](docs/agent/galgame-hooking.md)；一引擎一任务、一独立 worktree。native 与消费端现在同仓，IPC 契约变更必须在同一个 PR 内同步两侧。
- 写代码前必须在用户原始安装与启动路径建立身份/时序台账：启动器与真实游戏 PID/父子关系、架构、exe/module/helper/DLL 实际路径与 SHA-256、注入/附着策略，以及进程出现、模块加载、首次资源访问和首次音频的时间。imports、模块名、DLL 已加载或 Hook installed 只算候选证据。
- 能力阶段必须分开记录：`process_found → helper_ready → ipc_ready → text_ready → resource/pcm_ready → paired → e2e_verified`；不得用前一阶段推断后一阶段，也不得把 ready、捕获、纯人声分类、哈希一致和端到端混成一个“成功”。
- 每轮只修原始路径上第一个未通过边界。引擎/保护壳/加载时序特例必须收进 profile/adapter；共享中间件不得仅凭 DLL 名启用，且须有跨引擎负向测试。
- Loopback 只是显式降级，不能证明引擎 Hook、逐句配对或纯人声已验证；任何必需测试、双架构构建、replay 或真机门被跳过/阻塞，只能标 `implemented_unverified`，不得宣称“已支持/已修好”。
- 支持升级必须回到原始启动路径完成“当前文本 → 对应语音 → 当前画面 → 真卡写入”E2E；宣称原始逐句资源时还须记录与源 entry 的字节哈希一致性，并只通过 `native/galgame_hook/engine-support.yaml` 真相源更新支持状态。

## i18n 纪律

- 新增/删除 i18n key **禁止手动逐文件编辑**，必须用 `hibiki/tool/i18n_sync.dart`（Slang 要求 17 个文件 key 完整，缺 key 报错）：`--add <key> <en> <zh>` / `--remove <key>` / 无参补全缺失 / `--dry-run` 预览。
- 改完 key 跑 `dart run slang` 重新生成 `strings.g.dart`，再 `dart format` 生成文件；不要手改生成文件。

## 验证

- 文档改动：至少 `git diff --cached --check`，不必跑 Flutter 测试。
- Dart/Flutter 改动（在 `hibiki/` 下）：`dart format` 改动文件 + push 前全量 `flutter analyze`（含 test 目录，CI 把 warning 当致命）+ **按爆炸半径分级的测试**——分支上跑改动覆盖 + 相邻功能的定向 `flutter test <目标> --no-pub`，全量套件由 PR CI 兜底（真单测门是 Build Release APK 的 Run unit tests）；**合入 `develop` 前仍必须本地全量测试，且必须走 `dart run tool/flutter_test_failures.dart --no-pub`**——它是唯一会把「一个测试都没跑成」判为失败的入口（native asset 下载失败、编译失败、tag 过滤把测试全滤掉都算失败），并在 stdout 末行打 `FLUTTER TEST VERDICT: PASSED - N tests ran` / `FAILED - <原因>`。**判绿只认这行 + 退出码**：裸 `flutter test ... | tail -N` 的退出码是 `tail` 的、恒为 0，构建失败时零测试执行会被伪装成通过（BUG-1157）。分级判据见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md)。**测试红了不等于代码坏了**：本机 5~10 个 agent 并发，实测有三类并发伪红（互抢 `sqlite3.dll` / 宿主 IPC 崩溃致 suite 装载失败 / 结果文件被抢致零输出），**遇红先分型再动手**，且**不许拿「可能是伪红」当借口跳过真红**、**零测试执行的红也不算红**——症状、定性办法和三条判别纪律见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md) 的「并发伪红判别」。（工具链钉定：本地 `.fvmrc` 3.41.6，CI 3.44.0；本机 flutter 不在 PATH 就把完整路径写进 `CLAUDE.local.md`。）
- **每条 PR 合入 `develop` 后固定加跑「目录枚举型守卫」整批**（35 条，一条命令 ~40 秒）——这批守卫用 `listSync(recursive: true)` 扫 `lib/` / `test/` / `integration_test/` 全树，**新 PR 的新文件自动落进它们的扫描面，而定向测试按功能域挑，结构上永远挑不到它们**。实测代价：不跑就是「刚合的 PR 把红带进 develop」，一天翻车四次、其中一条在 develop 上躺了一整天跨 5 条 PR；跑了之后累计 30 条合并零红。完整清单、单条命令、以及「清单过期了怎么按行为反向枚举重新推导」见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md) 的「合并后必跑：目录枚举型守卫清单」。
- Android 资源/manifest/Gradle/权限/通知/前台服务/打包改动：再加 `gradlew :app:assembleRelease`（在 `hibiki/android/`；Windows 用 `.\gradlew.bat`）。
- 阅读器/导入/播放/布局问题，声明「修好了」前必须用真实模拟器或用户指定设备复测原始失败路径并留证据（见 [docs/agent/integration-testing.md](docs/agent/integration-testing.md)）。
- 集成测试操作真 app **一律焦点驱动（`FocusDriver` / `tester.sendKeyEvent`，禁止 `tester.tap` 或坐标点击）**：`Tab` 遍历→检测控件类型→Switch/按钮确认用 `Enter`（**不要用空格**——App 已把裸空格中和为 `DoNothingIntent`，焦点确认统一走 Enter / 手柄 A，见 `hibiki/lib/src/shortcuts/global_navigation.dart`）、Slider/Stepper/Segmented 用方向键→断言真写穿 DB/真生效→还原。同一份测试三端可跑（模拟器 `-d emulator-<port>` / Windows 离屏 `hibiki/tool/run_windows_itest.ps1` / Mac 跨机 `tool/run_mac_itest.ps1`），完整流程见 [docs/agent/integration-testing.md](docs/agent/integration-testing.md) 的「焦点驱动操作」。

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
| 加功能/修 bug/合并的分级快车道：难度分级、子代理分工、并行时间线、验证分级、**并发伪红判别**、**合并后必跑的目录枚举型守卫清单**、**输出可信 ≠ 结论可信** | [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md) |
| 5 平台构建 / Melos / bootstrap + 依赖补丁机制 / 发布通道与版本号规则 / galgame helper Windows 随包与在线更新 | [docs/agent/build.md](docs/agent/build.md) |
| Apple 签名：iOS TestFlight / macOS Developer ID 公证 / 仓库 secrets 清单 / 证书轮换 / 签名排障 | [docs/agent/apple-signing.md](docs/agent/apple-signing.md) |
| 模拟器集成测试三层架构 / 焦点驱动（禁坐标点击）/ AnkiDroid provisioning / ADB 降级 / DB 查询 / 测试素材 | [docs/agent/integration-testing.md](docs/agent/integration-testing.md) |
| 持续审查模式 / docs/reviews 报告格式 / 回归记录 | [docs/agent/review-process.md](docs/agent/review-process.md) |
| 丢快捷键 / 丢鼠标事件：媒体页焦点所有权、`FocusReclaimCause` 分流、WebView 键盘桥 | [docs/agent/focus-ownership.md](docs/agent/focus-ownership.md) |
| reader_hibiki 构成 / TTU 残留辨析 / WebView / 恢复 / 分页 / 有声书遮挡调试 | [docs/agent/reader-debugging.md](docs/agent/reader-debugging.md) |
| Computer Use 可见巡检 / 离屏、非焦点抓真实像素 / 确定性开页 debug 钩子 / 证据留存 | [docs/agent/computer-use-testing.md](docs/agent/computer-use-testing.md) |
| Windows app 外打开视频（文件关联 / argv / 拖拽）数据流 / single-instance WM_COPYDATA 转发 | [docs/agent/external-video-open.md](docs/agent/external-video-open.md) |
| 全量快捷键 / 手柄 / 鼠标绑定盘点快照（2026-06-11） | [docs/agent/shortcuts-inventory.md](docs/agent/shortcuts-inventory.md) |
| Galgame 用户报告 / 脱敏 probe / adapter 骨架 / 离线 replay / 双架构验证 / 真机证据 | [docs/agent/galgame-hooking.md](docs/agent/galgame-hooking.md) |

## 模块索引

| 模块 | 语言 | 职责 / 接入方式 | 文档 |
|---|---|---|---|
| `hibiki/` | Dart | Flutter 主应用：UI/阅读器/视频/导入/设置 | [hibiki/CLAUDE.md](hibiki/CLAUDE.md) |
| `packages/fushi_core/` | Dart | DB schema（50 表）/偏好/语言配置 | [CLAUDE.md](packages/fushi_core/CLAUDE.md) |
| `packages/fushi_dictionary/` | Dart | 词典引擎 Dart 侧/FFI 绑定/多格式导入（C++ 在 `native/hoshidicts/`） | [CLAUDE.md](packages/fushi_dictionary/CLAUDE.md) |
| `packages/fushi_anki/` | Dart | Anki 集成（AnkiDroid + AnkiConnect） | [CLAUDE.md](packages/fushi_anki/CLAUDE.md) |
| `packages/fushi_audio/` | Dart | 字幕解析/有声书播放/音频匹配 | [CLAUDE.md](packages/fushi_audio/CLAUDE.md) |
| `packages/fushi_platform/` | Dart | TTS/平台集成/存储路径抽象 | [CLAUDE.md](packages/fushi_platform/CLAUDE.md) |
| `packages/flutter_inappwebview_windows/` | Dart+C++ | inappwebview Windows fork | [CLAUDE.md](packages/flutter_inappwebview_windows/CLAUDE.md) |
| `packages/fushi_torrent/` | Dart | 内置 torrent 引擎 FFI 绑定 + `EmbeddedTorrentEngine`（path 依赖） | — |
| `packages/gamepads_windows/` | Dart+C++ | gamepads Windows vendored fork（BUG-116 崩溃修复，path override） | — |
| `packages/gamepads_android_stub/` | Dart | `gamepads_android` no-op stub（防启动 ClassCastException，path override） | — |
| `native/hoshidicts/` | C++ | 词典查询/导入引擎（上游深度 fork；`hoshidicts_external/` 为 vendored 第三方）；FFI/JNI 编入 app | [UPSTREAM.md](native/hoshidicts/UPSTREAM.md) |
| `native/hibiki_torrent/` | C++ | libtorrent 2.x C ABI bridge；FFI，Windows 预编译 DLL 随包 | [README.md](native/hibiki_torrent/README.md) |
| `services/log-backend/log-collector/` | Go | 报错日志接收端（自有服务器 + EdgeOne 版）；独立部署（原 `server/`，改名消与同步层 `hibiki_sync_server.dart`/`SyncBackendType.hibikiServer` 的三义撞词） | [README.md](services/log-backend/log-collector/README.md) |
| `services/log-backend/cf-worker/` | JS | 报错日志接收端（Cloudflare Worker + D1 版，与 Go 版择一）；独立部署 | [README.md](services/log-backend/cf-worker/README.md) |
| `tools/browser-extension/` | JS | 浏览器查词扩展（根级 `tools/`，非 `tool/`） | — |
| `third_party/` | — | 11 个 path-override vendored 补丁包 + 1 个 CI 自编二进制（ffmpeg-min，Windows 最小化 ffmpeg.exe）：carousel_slider、desktop_drop、fading_edge_scrollview、ffmpeg_kit_flutter、flutter_inappwebview_android、media_kit_libs_{android,ios,macos,windows}_video、media_kit_video、network_to_file_image；vendor 原因见 `hibiki/pubspec.yaml` dependency_overrides 逐包注释。另有 `m_extension_server/`（**不是** pub 包）：Mihon 桌面 sidecar 的 Kotlin 源码，上游 GitHub 仓库已删除，按 MPL-2.0 整树 vendored 在 `upstream_src/`（pristine）+ `overlay/`（Hibiki 安全边界）+ `server-build.gradle.patch`，构建走 `tool/mihon/build_desktop_runtime.{sh,ps1}`，规则见该目录 `UPSTREAM` | — |
| `references/ReinaManager` | — | git submodule：galgame 库信息架构参考（AGPL-3.0，不参与构建） | — |

> 完整架构、技术栈、构建命令、致谢见 [README.md](README.md)。`file_picker` 用 pub.dev 版（**不是** fork）。依赖补丁机制（vendored vs apply-patches）见 [docs/agent/build.md](docs/agent/build.md)。

## 始终用中文回复

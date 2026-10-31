# CLAUDE.md 细则原文

根 `CLAUDE.md` 为省每轮上下文，把下列长条目压成了摘要；这里保留拍板时的完整原文（含起因、日期、例外与实测数据）。摘要与本文冲突时以本文为准，并修正摘要。

## worktree 初始化

- 新建 worktree 后（无论 `EnterWorktree`、手动 `git worktree add` 还是其它工具创建），第一件事在该 worktree 里跑 `pwsh -File tool/setup_worktree.ps1`（Windows 用 `powershell -ExecutionPolicy Bypass -File tool/setup_worktree.ps1`）：它从主 checkout 把本地真值密钥（`google_oauth_secret.dart` / `log_upload_secret.dart` 等**所有 skip-worktree 文件**，清单动态读取无需硬编码）搬进来并在本 worktree 续上 `skip-worktree`（真值不显示 dirty、绝不会误提交），再调 `tool/bootstrap.ps1`（pub get + 打补丁）。**别再手动 cp 密钥桩或逐个配置**。只跑 `flutter analyze` / `flutter test` 时入库的占位/空值已够编译；真值仅在 worktree 里真机验证 Google Drive 登录 / 日志上传时才需要。只搬密钥不跑 bootstrap 用 `-SkipBootstrap`。

## 工具栏默认展开

- **工具栏 / 顶栏动作默认展开、空间不足才收起（用户 2026-10-06 拍板）**：顶栏、阅读器 / 播放器 / 库页的动作按钮默认全部平铺显示，**只有宽度放不下时**才按优先级把放不下的收进「⋯」溢出菜单（最常用的最后收）；不许固定写死成「收起 / 更多」菜单。一律复用 `FushiFloatingTopBar` 的 `adaptiveOverflow`（`fushi/lib/src/utils/components/fushi_floating_toolbar.dart`，测试 `fushi/test/widgets/fushi_floating_top_bar_adaptive_overflow_test.dart`），不另写测宽逻辑。**底部浮动工具栏 / 主导航底栏默认纯图标**：文字只进 tooltip 与无障碍语义（Semantics label 用原文案），命中区 ≥48dp，不画组间分隔线。出厂默认的「相机模式条」样式（`AdaptiveNavBarStyle.modeStrip`，2026-10-23 拍板设为默认）同样纯图标（2026-10-24 用户拍板去掉当前项名字）。**主导航的选中高亮一律是该目的地的 M3E 专属多边形**（底栏、各底栏样式与侧栏同一套，`fushi/lib/src/utils/adaptive/nav_shape.dart` 的 `NavMorphShape` / `navShapeOf`，用户 2026-10-24 拍板），不再画药丸。

## 分段选择用设计系统组件

- **分段选择一律用设计系统组件，禁止裸 `SegmentedButton`（用户 2026-10-16 拍板：「分段选择器还是老样式，用 m3e，写进规则吧都用新的」）**：单选分段用 `adaptiveSegmentedButton(...)`（`fushi/lib/src/utils/adaptive/adaptive_widgets.dart`；Material = M3E 胶囊分段、Apple = iOS 分段），设置行用 `AdaptiveSettingsSegmentedRow`；多选 / 竖排 / 允许空选等 `SegmentedButton` 同参需求用 `FushiSegmentedButton`（Material = M3E 连接式按钮组）。页面里直接 `SegmentedButton(...)` 会绕过设计系统分派、画出旧版 MD3 描边分段。守卫 `fushi/test/build/segmented_button_m3e_guard_test.dart`（只豁免组件实现文件自身）。

## 存量 Dart 重写成 Rust

- **存量 Dart 可以为优化或收编进计算型子系统而重写成 Rust，但不为「统一语言」本身重写**。动因只认两种：① 实测出性能问题（CPU 热点、内存、卡顿）；② 把散落在 Dart 里的计算逻辑收编进某个胖核心子系统，让状态归 Rust、减少跨边界次数。UI、平台插件与 method channel、WebView JS 桥、i18n，以及只做 IO / 编排而没有上述两种动因的代码留在 Dart（这些瓶颈不在 CPU，搬过去只多一层 FFI、丢热重载）。重写按上面的粗粒度规则整段搬：搬了就删 Dart 版、不留回退，原生库是硬依赖（加载失败明确报错，测试找不到库要失败而非 skip），删之前用旧实现生成固定输入→输出向量做回归测试；PR 写端到端耗时（含 FFI 与拷贝，不只量内核），不设提速倍数门槛，唯一不搬的理由是边界加粗后端到端仍不比 Dart 快（写明原因）。

## 合并 PR 看作者

- **合并 PR 要看作者**：只有 `hajisensai`（仓库所有者）与 `W1ght` 的 PR 可以在常规审查后直接合并；**其他任何人的 PR 一律先问用户拿许可再合**，哪怕用户说过「全部合并」——那句话不覆盖后来新出现的第三方 PR。许可的可追溯形态是给 PR 打 `merge-approved` 标签。CI 侧有一条会变红的门 `.github/workflows/pr-merge-gate.yml`（白名单被守卫测试 `fushi/test/tools/pr_merge_gate_allowlist_guard_test.dart` 钉死）；它默认是建议性的——本仓刻意不设分支保护，因为日常大量直推 develop，加 required check 会把直推一起挡掉。要改白名单必须用户点头。

## 工具脚本归属

- 工具脚本归属：根 `tool/` = `setup_worktree.ps1` / `bootstrap.ps1` / `native_libs.ps1`（备 Rust 原生硬依赖：同源码产物优先从兄弟 worktree 拷，否则 cargo 编，本机装了 sccache 就自动挂上跨 worktree 共用依赖编译缓存；旧 worktree 测试报缺 `fushi_compute` / `fushi_fsrs` / `fushi_web_core` 库时单独跑它，不必手设 `FUSHI_*_LIB`）/ `bug.dart` / `check_release_policy.ps1`；`fushi/tool/` = `i18n_sync.dart` / `run_windows_itest.ps1` / `comprehensive_test_runner.dart` / `pre_push_check.dart`（可选的本地预检，不是推送门）/ `update_suite_timings.dart`（用 CI 单测分片上传的 `unit-test-events-*` 事件日志刷新 `tool/test_flow/suite_timings.json`，`--file-shard` 按它均衡各片；新增大量测试或分片明显不均时跑一次）。

## Flutter 版本

- Flutter 版本**只有一个：`3.47.6`，必须用 3.47（本地与 CI 同版）**——`fushi/.fvmrc` 与所有 workflow 的 `flutter-version` 同钉 `3.47.6`（守卫 `fushi/test/build/flutter_version_single_source_guard_test.dart`），本地 analyze / test / `pub get` / `flutter run` 一律用它（本机路径 `D:/flutter_sdk/flutter_3.47.6/bin`，见 `CLAUDE.local.md`）：3.47 起 Material / Cupertino 拆成 pub 包、本仓已迁移，**3.44 及更早版本根本编不过本仓**；用别的版本跑过 `pub get` / `flutter test` 的 worktree，`.dart_tool/hooks_runner` 会留下旧格式缓存（报 `Invalid kernel binary format version`），删掉后用 3.47.6 重跑。`tool/pre_push_check.dart` 第 0 步强制比对。升级时 `.fvmrc` 与全部 workflow 一起改（2026-10-06 由 3.44.0 升到 3.47.6），**并且**把 `ci/patches/flutter-engine/<版本>/`（Windows 引擎 + ANGLE 补丁，合成器内 HDR）移植到新基线、重编发布引擎产物（守卫按 `.fvmrc` 找补丁目录，见 [docs/agent/build.md](docs/agent/build.md)「依赖补丁」）。pubspec 的 `flutter: "^3.47.0"` 是下限；Dart SDK 约束见 pubspec。最低 Android API 24，`compileSdk 36` / `targetSdk 35`。

## material_ui 迁移

- **Material / Cupertino 走 pub 包 `material_ui` / `cupertino_ui`**（Flutter 3.47 起从 SDK 拆出；2026-10-06 迁移）：fushi/、packages/、third_party/ vendored 包一律 `import 'package:material_ui/material_ui.dart'` / `'package:cupertino_ui/cupertino_ui.dart'`，**禁止新写 `package:flutter/material.dart` / `cupertino.dart`**——SDK 内与新包同名符号是不同类型，混用编译常能过、运行时 Theme / Material 祖先却互相看不见（守卫 `fushi/test/build/design_widgets_import_guard_test.dart`；合并带旧 import 的分支后跑 `bash tool/migrate_design_widgets.sh` 收尾）。本地化用 `GlobalMaterialLocalizations.delegates`（material_ui 的，已含 Cupertino + Widgets）。仍用旧 SDK Material/Cupertino 的第三方包（flutter_markdown、liquid_glass_widgets、macos_ui 等；flutter_colorpicker 已 vendored 到 `third_party/flutter_colorpicker` 并改用 material_ui，见其 PATCHES.md）靠三个 entry point 根上的 `LegacyDesignCompatibility`（`lib/src/utils/adaptive/legacy_design_compat.dart`：两个官方 CompatibilityBridge + 一层透明旧 Material）读到 app 主题；公开 API 收旧类型的（flutter_markdown 的 `MarkdownStyleSheet.fromTheme`）在调用处用 `as legacy` 前缀取桥出来的旧 Theme。`dynamic_color` 已升 2.x（依赖 material_ui，ColorScheme 同型）。

## Impeller

- **渲染后端五端全线 Impeller，不保留 Skia 回退（所有者 2026-10-24 拍板，`docs/specs/2026-10-23-music-module-design.md` D13）**：Windows runner 钉 `ImpellerSwitch::Enabled`（合成器内 HDR 的 Impeller 移植在 `ci/patches/flutter-engine/<版本>/engine-impeller-hdr.patch`），Android 无任何 `--enable-impeller=false`（含 `:popup` 热引擎，BUG-2790 改走 TLHC），iOS / macOS / Linux 用引擎默认。渲染问题按根因在 Impeller 上修，禁止新增关 Impeller 的开关、manifest / plist 键或启动参数。

## 五平台与 Apple 设计系统

- 5 平台均出包（Android/iOS/macOS/Windows/Linux）：`auto` 下五个平台统一走 Material Design 3；Cupertino / macOS renderer 仅保留为隐藏内部能力。**Apple（Cupertino）设计系统（所有者 2026-10-13 拍板）**：组件悬浮面实色（`glassMaterialTier` 钉成 off，悬浮胶囊 / 面板统一 `fushiAppleSolidFloatingDecoration`），窗口级 Mica（Windows 11）/ vibrancy（macOS）保留——开关只认 `windowBackdropRequestedOf`（设计系统 + 系统「降低透明度」+ 增强对比度），**不读**组件材质档；按压缩放 / 悬停放大与 MD3 一样照常（`FushiPressScale` / `FushiHoverLift` 不按设计系统关闭）。桌面端 EPUB 渲染：Windows 依赖 fork 的 `flutter_inappwebview_windows`；Linux 依赖 vendored 的 `packages/flutter_inappwebview_linux`（WPE WebKit，薄注册层运行时 dlopen 实现库，缺 WPE / 不允许 user namespace 时 app 照常启动、WebView 位置显示原因）。**Linux App 只能从源码构建**：CI 不构建 Linux App（只有 `linux-server`），构建 / 运行依赖与 Docker 验证法见 [docs/agent/build.md](docs/agent/build.md)「Linux 桌面（源码构建）」。**macOS 只出 Apple Silicon（arm64），不再支持 Intel Mac**（Runner `EXCLUDED_ARCHS = x86_64`，随包原生件全部只出 arm64，见 build.md「平台与 SDK」）。

## iOS 商店合规

- **iOS 版按 App Store 合规少三类能力**，其余四平台不受影响：① 内置 / 预置外部发现源与 provider 目录、「浏览」模块的「发现」页签、只为它们存在的各库页「发现」子标签（含用户添加的 BT 站、视频域资源索引器与在线发现 provider）；② 在线漫画源宿主（Mihon 扩展 / mokuro.moe 卷下载）与在线视频源宿主（Aniyomi 扩展，`onlineVideoSource`）、在线小说源宿主（LNReader 插件，`onlineNovelSource`）；③ 下载中心（torrent / 磁力 / 直链队列，含外接 qBittorrent）。理由都不是「iOS 做不到」而是审核指南不允许，所以判据**只在 `fushi/lib/src/models/store_compliance.dart` 的 `StoreRestrictedCapability` 写一次**，`ModuleId.browse`（原「下载」模块）的 `availableOn` 委托到它，消费端一律问这两处、不各自写 `Platform.isIOS`。**用户自己填地址的服务器 iOS 保留**（用户 2026-10-27 拍板）：OPDS、AList / OpenList、Kavita、Audiobookshelf、Jellyfin / Emby / Plex 的设置、浏览、阅读 / 串流与「下载到本机」照常——App Store 5.2.3 限制的是从未授权第三方来源下载 / 保存媒体与促成非法分享，连接用户自己的服务器不在此列（KyBook / Panels / Chunky、Komga / Kavita 客户端、ShelfPlayer / plappa 等同类应用均已上架）；判据是同文件的 `userConfiguredServersAvailableOn`（不是受限能力），iOS 的发现源注册表只登记这些用户服务器源，iOS 上也不预填任何服务器地址。**Aidoku 已整体移除**（iOS / macOS 宿主、`native/aidoku_runtime` Rust 源码与 Dart 功能层全部删除）：只剩冻结的持久化名——在线漫画描述符的 `runtime: aidoku` wire 值（`OnlineMangaRuntimeKind.aidoku`，分派到一律回报不可用的 `LegacyAidokuLibraryAdapter`，旧书架条目仍可列出 / 读已下载章 / 删除）与磁盘目录 `<数据库目录>/aidoku`；漫画/视频/书的本地库与阅读播放能力一概保留。**游戏模块在 iOS 上保留**（用户 2026-10-06 拍板）：iOS 的游戏只有串流接收（`GamesModuleForm.streamClient`，从已配对 Windows 主机启动并串流），不算受限能力，不进 `StoreRestrictedCapability`。守卫 `fushi/test/build/ios_store_compliance_guard_test.dart`——这条边界失效是静默的（本地与 CI 全绿、上架才被拒），改动这三块前先读它。

## i18n 全排序与合并驱动

- **17 份 i18n json 顶层 key 全排序（2026-10-15 起）**，守卫 `fushi/test/i18n/i18n_keys_sorted_guard_test.dart` 钉死：`--add`（及无参补全）插到字典序位置而不是末尾，不同 PR 的新增落在文件各处、按行就能合并；手改 json 往末尾追加会让守卫变红，修法 `--sort`。字典序相邻的 key 剩下的冲突交给**按 key 三方合并驱动** `fushi/tool/i18n_merge_driver.dart`（`.gitattributes` 已接，驱动命令由 `tool/setup_worktree.ps1` 写进仓库级 git config；主 checkout 没跑过 setup 就手动 `git config merge.fushi-i18n-json.driver "dart fushi/tool/i18n_merge_driver.dart %O %A %B"`）。驱动只对**本地** merge 生效，GitHub 网页合并不认——PR 页显示 i18n 冲突时本地 `git merge origin/develop` 即可自动解决；两边把同一 key 改成不同值（或一改一删）时驱动退出 1、在该 key 处留 `<<<<<<< ours` / `>>>>>>> theirs` 冲突块（文件此时不是合法 JSON），手工选值后再 `--sort`。`strings.g.dart` 自 2026-11 起**不入库**（37 MB、两千多个版本，历史约 676 MB），不再有它的合并冲突：`fushi/tool/gen_i18n.dart` 跑 `dart run slang` + `dart format`，戳记（json / `slang.yaml` / `pubspec.lock` / Dart SDK + 输出哈希）存 `fushi/.dart_tool/fushi_gen_i18n.stamp`，输入没变秒退；`tool/bootstrap.ps1` / `bootstrap.sh`、melos bootstrap post 钩子、dist worker 的 `worker_prepare.sh`、每个在 `fushi/` 跑 `flutter pub get` 的 CI job（复合 action `.github/actions/gen-i18n`）都在 pub get 之后调它，守卫 `fushi/test/build/strings_g_dart_untracked_guard_test.dart`。CI 只有**编 app 或在 `fushi/` 下跑 `flutter|dart analyze|test|run`** 的 job 才接（守卫按 step 解析 working-directory / `cd` / `echo … &&`，多接少接都红）；无头服务端的 job（server-gate、build-multiplatform 的 linux-server、release-server）不接——`fushi_server` 的依赖闭包不含 `package:fushi`，且 release-server 是带 `source_ref` 的 workflow_call，可能检出还没有这个 action 的旧提交。本地切分支 / 合并后的过期由三层兜：① `fushi/tool/heavy.dart` 在本机（未外包）跑 `fushi/` 下的 flutter / dart / gradlew 编译类命令前先用该命令自己那份 SDK 的 dart 跑生成器，生成失败整条命令失败（`test_flow/heavy_i18n.dart`，测试 `fushi/test/tools/heavy_i18n_test.dart`）；② `tool/setup_worktree.ps1` 即使 `-SkipBootstrap` 也跑 `tool/git_hooks/gen_i18n.sh setup`（依赖已解析时约 1 秒、不联网；没 pub get 过就说明后跳过，交给 bootstrap）；③ `tool/git_hooks/install.sh`（setup_worktree / `bootstrap.sh` 调）往 `git rev-parse --git-path hooks`（主 checkout 与所有 worktree 共用；设了 `core.hooksPath` 就是那里）的 `post-checkout` / `post-merge` 写一段 `# >>> fushi gen-i18n` 标记块（插在 shebang 之后、重跑原地替换、标记外的用户钩子行不动，非 sh 钩子只警告不碰），块里只在当前树有 `tool/git_hooks/gen_i18n.sh` 时调它；它跳过文件级 checkout、没 pub get 过的新 worktree、`pubspec.lock` 比 package_config 新（该跑 bootstrap）的情况，用 package_config 记下的 `flutterRoot` 那份 dart 生成，生成失败只大声报错不让 git 命令变红（git 撤销不了已完成的 checkout / merge，硬门在 ①）。rebase、解冲突后的提交不触发钩子，靠 ①；不经 heavy 直接跑 flutter 时手动 `dart fushi/tool/gen_i18n.dart`。新加 CI job 或本地编译入口记得接上。

## 推送前只跑 analyze

- **推送前只跑 analyze（2026-10-02 用户拍板，取代 09-30 的「推送前一条命令」）**：推 PR / 直推 develop 前唯一的本地门是在 `fushi/` 下跑全量 `dart tool/heavy.dart -- flutter analyze --no-pub`（与 CI 同版本 3.47.6，含 test 目录，CI 把 warning 当致命），过了就推；单测、源码扫描守卫与全量套件一律交给 PR / develop CI，红了按 CI 日志修。**全量 analyze 只在最后跑一次（2026-10-25 用户拍板）**：开发中改完一处不跑全量 analyze（要早看就 `dart analyze <改动文件>`）；一个分支只在 push 前跑一次；批量合并只在集成后的结果上跑一次，**不逐分支各跑一遍**——每次是 2–3 分钟加一个 3.4–4 GB 的 dart 进程，CI 本来就跑 analyze 且不在关键路径上。`tool/pre_push_check.dart`（analyze + 目录枚举守卫 + 按改动点名的守卫与测试）**不再是推送门**，也不要主动跑：完整模式一次 3–15 分钟、多会话并发时还要排本机租约，用户判断不值。工具保留，只在你自己想先在本地筛一遍守卫时用（`--quick` 只跑守卫类、`--list` 只看会跑什么）。**已知代价**：9/20–30 上游 36 个 PR 的 CI 红里有 18 个红在源码扫描守卫上、analyze 只抓得到 1 个——这类回归现在会到 PR CI 才暴露，推完要看 PR CI 结论，不能把「analyze 过了」说成「CI 会绿」。

## Dart/Flutter 改动的测试纪律

- Dart/Flutter 改动（在 `fushi/` 下）：`dart format` 改动文件 + push 前全量 `flutter analyze`（唯一推送门，见上一条）；测试只在开发中按需定向跑你新增 / 改动的那几个测试文件（`flutter test <目标> --no-pub`，不是推送门；**几个文件合成一次调用** `flutter test a_test.dart b_test.dart`，别逐个调——每次调用固定约 84 秒（build hooks ~23 s + 首个 suite 编译 ~58 s），之后每多一个文件只加 ~1.5 s），守卫与全量套件由 PR CI 兜底（真单测门是 Build Release APK 的 Run unit tests）；**本地不跑全量测试门**（用户 2026-09-06 拍板：合入 `develop` 前**不再**本地跑 `dart run tool/flutter_test_failures.dart --no-pub` 或裸 `flutter test` 全量，太慢；以后任何任务都不要主动跑，也不要拿它当合并前置条件），本地只跑定向测试。**全量 / 大批量测试走跨机分流 `dart tool/dist_test.dart --config=D:/fushi-dist/workers.local.json`，定向少量文件仍走 `dart tool/heavy.dart -- flutter test ...`（用户 2026-10-27 拍板）**：要跑全量或成片目录时不再单机裸跑，交给 dist_test 按各机实测速度动态分批（设计 `docs/specs/2026-10-24-distributed-unit-tests.md`）；该路径是所有者主力机上的 worker 配置（git 忽略），别的机器没有这份配置就照旧只跑定向。dist_test 判绿只认末行 `DIST TEST VERDICT` 与退出码。定向跑也**判绿只认退出码 + 实际执行数**：裸 `flutter test ... | tail -N` 的退出码是 `tail` 的、恒为 0，构建失败时零测试执行会被伪装成通过（BUG-1157）。分级判据见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md)。**测试红了不等于代码坏了**：本机 5~10 个 agent 并发，实测有三类并发伪红（互抢 `sqlite3.dll` / 宿主 IPC 崩溃致 suite 装载失败 / 结果文件被抢致零输出），**遇红先分型再动手**，且**不许拿「可能是伪红」当借口跳过真红**、**零测试执行的红也不算红**——症状、定性办法和三条判别纪律见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md) 的「并发伪红判别」。（工具链：本地与 CI 同为 3.47.6，见「当前技术事实」；本机 flutter 不在 PATH 就把完整路径写进 `CLAUDE.local.md`。）

## 合并后必跑目录枚举型守卫

- **每条 PR 合入 `develop` 后固定加跑「目录枚举型守卫」整批**（51 条，一条命令 ~62 秒）——这批守卫用 `listSync(recursive: true)` 扫 `lib/` / `test/` / `integration_test/` 全树，**新 PR 的新文件自动落进它们的扫描面，而定向测试按功能域挑，结构上永远挑不到它们**。实测代价：不跑就是「刚合的 PR 把红带进 develop」，一天翻车四次、其中一条在 develop 上躺了一整天跨 5 条 PR；跑了之后累计 30 条合并零红。完整清单、单条命令、以及「清单过期了怎么按行为反向枚举重新推导」见 [docs/agent/fast-workflow.md](docs/agent/fast-workflow.md) 的「合并后必跑：目录枚举型守卫清单」。

## Android 真机优先

- **Android 设备选择：真机优先**（用户 2026-09-30 拍板）。开发 / 复现 / 验证前先 `adb devices`：列出了真机（非 `emulator-*`）就直接用 adb 操控真机，**检测不到 adb 设备才起模拟器**。真机上的纪律：① 不卸载、不覆盖用户装的 app——签名或版本对不上时用临时 `applicationIdSuffix` 编测试包并行安装（`build.gradle` 这行不提交），绝不为装测试包清用户数据；② 要模拟别的形态（手机尺寸 / 横屏等）用 `wm size` / `wm density` / `cmd window user-rotation`，测前记下原值（用户可能本来就有 density 覆盖），测完按原值还原，连同改过的常亮、旋转一起还原，并卸掉自己装的测试包。

## 集成测试焦点驱动

- 集成测试操作真 app **一律焦点驱动（`FocusDriver` / `tester.sendKeyEvent`，禁止 `tester.tap` 或坐标点击）**：`Tab` 遍历→检测控件类型→Switch/按钮确认用 `Enter`（**不要用空格**——App 已把裸空格中和为 `DoNothingIntent`，焦点确认统一走 Enter / 手柄 A，见 `fushi/lib/src/shortcuts/global_navigation.dart`）、Slider/Stepper/Segmented 用方向键→断言真写穿 DB/真生效→还原。同一份测试两端可跑（模拟器 `-d emulator-<port>` / Windows 离屏 `fushi/tool/run_windows_itest.ps1`），完整流程见 [docs/agent/integration-testing.md](docs/agent/integration-testing.md) 的「焦点驱动操作」。

## 大合并后 TestFlight

- **每次大合并进 `develop` 后必须有一次 TestFlight（debug 通道）上传**（用户 2026-10-14 拍板）。「大合并」= 一次批量合入多条 PR，或一条大型功能 PR 合入 `develop`。合并 push 后核对该 push 的发布序列（`git rev-list --count HEAD + 2000`；本地浅克隆算不准，用 `gh api -i "repos/hajisensai/fushi/commits?sha=develop&per_page=1"` 的 Link 头 `page=N; rel="last"` 取真 commit 数）：`% 3 == 0` 时 push 的 `release-desktop.yml` 会自动传 TF（仍要确认那条 run 没被后续 push 顶掉）；否则补发 `gh workflow run release-desktop.yml --repo hajisensai/fushi --ref develop -f channel=debug -f testflight_only=true`（只传 TF、不发 Release）。细节见 [docs/agent/build.md](docs/agent/build.md)「Apple 签名与 TestFlight」。

# 架构审计：i18n-tooling-tests-ci

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

工程基础设施的现状：CI 由 38 个 workflow 组成，其中 release-desktop.yml 4509 行、build-multiplatform.yml 2374 行、release.yml 2252 行，另有 16 个 composite action。本地这一侧有 setup_worktree / bootstrap（ps1 和 sh 各一份）、native_libs.ps1、heavy.dart、dist_test.dart，以及 claude_hooks 里的一批 mjs，ps1、sh、dart、py、mjs 五种语言混用。

不变式几乎全靠守卫测试维持：一共 1085 个 *_guard_test.dart，其中 936 个用 readAsStringSync 读源码做文本匹配，578 个扫 lib/，715 个用 indexOf / methodBody 切片，没有一个用 package:analyzer。为了让这种做法站得住，又叠了三层补丁：1266 行的手写多语言词法器 source_guard.dart、给 70 个守卫用的规模哨兵 scan_scale.dart、再加一条「守卫的守卫」source_guard_adoption_test。整树扫描的守卫和按功能域挑选的定向测试互不对应，PR 的快门挑不到它们，于是红会被合进 develop，只能靠 fast-workflow.md 里的「合并后必跑」清单人工补跑。

原生 Rust crate 的接线是「crate 数 × 平台数 × workflow 数」逐个手写：CMake、gradle、macOS bundle 脚本、bootstrap、setup-fushi-* action、native-*-gate、每个 crate 一份三四百行的硬依赖守卫。工具链版本号号称「单一真相源」（.fvmrc 和 names.sh），实际上 Flutter 钉版在 workflow 里抄了 21 次，Rust 的 '1.95.0' 抄了 15 次以上，靠守卫或注释「与 X 一致」维持。原生库的源码内容键有三套独立实现（ps1、sh、names.sh），已经出过 BUG-4988。i18n 是 17 份整体大 json，每份 1.56 万 key，冲突只靠本地的合并驱动兜着：GitHub 服务器端不用这个驱动，驱动本身还出过 BUG-5537，弄坏了 SDK。

总体看，这个域的主要问题是同一个事实缺少登记源，于是用守卫测试和注释维持各处同步，而不是用结构（生成、复用、类型或 lint）让漂移根本写不出来。

## text-guards-instead-of-analyzer-lints

**上千个源码文本 grep 守卫在兜本该由 analyzer lint 保证的代码不变式，并为此长出词法器、规模哨兵、元守卫三层补丁**

- 类型：守卫代替结构；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- 统计（find + grep，已执行）：fushi/ 下 1085 个 *_guard_test.dart，936 个 readAsStringSync，578 个读 lib/，715 个用 indexOf/methodBody 切片，0 个 import package:analyzer
- fushi/test/helpers/source_guard.dart:5-21 与 :206-1254：1266 行手写 Dart/JS/CSS/HTML/# 注释词法器，外加 methodBody/balancedBlockFrom/switchCaseBody 等切片器，注释里自述三类洞来自「没有真的分辨词法状态」
- fushi/test/helpers/scan_scale.dart:3-12：自述这批目录枚举守卫有系统性假绿（「扫不到任何文件」和「扫到但无违规」同样是绿），只好给 70 个文件加规模哨兵，并要求手填 measured/atLeast
- fushi/test/tools/source_guard_adoption_test.dart 与 docs/bugs/BUG-1358-schema-guard-handwritten-comment-strip.md:4-12：新守卫手写 startsWith('//') 剥注释，被元守卫判红，develop 因此红
- docs/agent/fast-workflow.md:131-137：根因原文是「定向测试按功能域挑，而目录枚举型守卫的触发面与功能域正交」，一天之内四次把红合进 develop，只能靠合并后的人工清单补跑
- fushi/test/build/host_route_sync_io_guard_test.dart:8-50：用正则 (\w+Sync)\( 加手写白名单禁止同步 IO；同类的「UI isolate 禁同步 IO」守卫另有 9 个（srs_store_open_off_ui_isolate、video_playback_sync_io、video_network_mount_sync_io、reader_illustrations_off_ui_isolate、embedded_torrent_off_ui_isolate 等），每加一块热路径就要新写一份正则守卫

机制：代码层面的不变式（禁止同步 IO、禁止 Platform.isIOS、禁止裸组件或某种 import、某调用必须经由某入口）没有可执行的静态分析通道，只能写成 test/ 里读文本的 flutter test。文本匹配不认识语法，所以要先补词法器；匹配会悄悄失效，所以要补规模哨兵；有人绕过 helper，所以要补元守卫。这些守卫读文件是按字符串路径，不走 import，tests_for_changes 无从推出依赖关系，PR 快门挑不到它们，又得补「合并后必跑」清单。每多一个不变式，就多写一个文件、一套正则、一个哨兵数字。

根本方案：新建 packages/fushi_lints（analysis_server_plugin / analyzer AST 插件），在各包 analysis_options.yaml 的 plugins 段注册。`flutter analyze` 已经是推送前的唯一本地门，也是 PR 快门的必跑项，并且天然扫全树，所以「与功能域正交」的问题会直接消失。规则的作用域由一份 fushi_lints.yaml（目录 glob → 规则）加少量注解（如 `@UiIsolateCode` / `@offUiIsolate`）声明，不再在测试里手写扫描根。第一批迁移：① 10 个 off-UI-isolate 守卫合成一条 `no_sync_io_in_ui_isolate`，按 AST 判断方法调用的静态类型（dart:io 的 *Sync 方法和标了 @syncIo 的 helper），不按名字后缀，白名单随之取消；② 禁止 Platform.isIOS（白名单只有 store_compliance.dart）；③ 禁止 package:flutter/material.dart / cupertino.dart；④ 禁止裸 SegmentedButton 等 UI 硬规则；⑤ 其余「X 只能经由 Y 调用」类守卫。迁走一条就删掉对应的 *_guard_test.dart。全部迁完后删 source_guard.dart 里的 Dart 词法与切片部分、scan_scale.dart、source_guard_adoption_test.dart、banned_comment_strip.dart，并把 fast-workflow.md 的「合并后必跑」清单缩到只剩非 Dart 守卫。以后新增一条代码不变式，只需在 fushi_lints 里加一个 rule 类和它的 analyzer 单测（正反例）。行为测试照旧保留；CMake / YAML / pbxproj 这类非 Dart 守卫交给下面的登记源加生成方案，不做 lint。需核实（推测）：Flutter 3.50 自带的 Dart 版本下 `flutter analyze` CLI 能否输出插件诊断，迁移第一步先用一条规则验证。

要动：fushi/test/helpers/source_guard.dart；fushi/test/helpers/scan_scale.dart；fushi/test/tools/source_guard_adoption_test.dart；fushi/test/**/_guard_test.dart（578 个扫 lib/ 的）；fushi/analysis_options.yaml；packages/*/analysis_options.yaml；新增 packages/fushi_lints/；docs/agent/fast-workflow.md（合并后必跑清单）；fushi/tool/tests_for_changes.dart

核验说明：文本守卫的规模和三层补丁基本属实：find 出 1073 个 *_guard_test.dart（审计写 1085，量级对），fushi/analysis_options.yaml:10 只 include 了 flutter_lints，仓库里没有任何 analysis_server_plugin 或 custom_lint。

但「PR 快门挑不到目录枚举型守卫，只能靠合并后人工补跑」这条机制已经过时。.github/workflows/main.yml:913「Run affected tests (guards + direct importers of the changed files)」跑的是 pre_push_check.dart --gate=0；fushi/tool/pre_push_check.dart:334-340、437 会解析 fast-workflow.md 里的枚举守卫清单（少于 40 条直接报错），每条 PR 整批跑。fushi/tool/tests_for_changes.dart:1-40、86-95 另外按测试源码里的路径字面量推导非 Dart 树的触发面。所以 fast-workflow.md:131-137 说的四次带红进 develop 是 2026-08 的历史起因，不是现状。迁成 lint 的价值仍然成立：analyze 天然扫全树，可以去掉词法器、规模哨兵和元守卫，也不用再靠文档表维护清单。

方案风险：① analyzer 插件规则按单个库分析，不能做跨文件或跨资产的不变式（例如「每个 ctl_<域>_routes 都有对应的 op_descriptions」、i18n 引用、注册表一一对应），这类不能删守卫，只能另找结构化方案。② 1073 个守卫里不少扫 test/、tool/、docs、CMake、YAML，lint 覆盖不到，「全部迁完删 source_guard.dart」的终态估得过满。③ 插件会拖慢全树 analyze，分析进程内存也要涨；analyze 是推送前的唯一本地门，又外包给 dist 机器，要实测耗时，别让门本身变慢。④ fushi/pubspec.yaml:7 写的是 sdk >=3.8.0，analysis_options 顶层的 plugins 段要求运行时 SDK 支持新插件机制（推测 Flutter 3.50 自带的 Dart 已满足），还要确认 flutter analyze 和 dist worker 都会输出插件诊断。⑤ 迁移期间同一条不变式会有守卫和 lint 两份，要按条原子替换。

修正后的方案（以此为准）：保留 fushi_lints 方向，但限定范围：只迁「单文件、可按 AST 或静态类型判定」的 Dart 不变式（禁同步 IO 用静态类型判 dart:io 的 *Sync、Platform.isIOS 白名单、禁 material.dart/cupertino.dart import、禁裸 SegmentedButton、裸 Card 这类 M3E 规则、「X 只能经由 Y 调用」），每迁一条就在同一个 PR 里删掉对应守卫，并同步删 fast-workflow.md 枚举清单里那一行。跨文件注册类不变式改成由登记源生成代码，或者用一个 Dart 静态检查 CLI（package:analyzer 解析全树）在 analyze 同一步执行，不再写成 flutter test。fast-workflow.md 的枚举守卫表不该再当 pre_push_check 的配置来解析：清单改为由守卫文件里的声明（例如 `// guard-scope: lib/`）自动收集，或者干脆随迁移消失。第一步先用一条规则在 flutter analyze 和 dist worker 上实测诊断能否输出、全树耗时增加多少，再决定推进。

## native-crate-registry

**每个 Rust 原生 crate 都要在约 10 处逐一手写接线，再配一份三四百行的硬依赖守卫逐条钉住**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- tool/native_libs.ps1:64 的 $NativeTestCrates 清单；:28-29 的注释又手写一遍「checkFushi*Native 查的那五个」
- tool/bootstrap.sh:43-80 第三次手写同一份 crate 清单，并逐行调 build_macos_dylib.sh / build_linux_so.sh
- fushi/android/app/build.gradle:461、483、504、525、549：五个结构相同的 checkFushi{Compute,Rwkv,Music,Corpus,WebCore}Native 任务
- fushi/macos/bundle_fushi_{aacs,compute,corpus,fsrs,music,p2p,rwkv,torrent,web_core}.sh 共 9 份脚本，每份还要单独挂进 Runner.xcodeproj/project.pbxproj 的 buildPhases
- diff 过的 .github/actions/setup-fushi-compute/action.yml 与 setup-fushi-music/action.yml：把 crate 名替换掉之后只剩注释不同（同类共 5 个 action，539 行）
- fushi/test/build/fushi_music_hard_dependency_guard_test.dart:7-22：文件头列出每个 crate 要钉住的 7 类接线点（Windows/Linux CMake、macOS、iOS 伞形库、Android gradle、bootstrap、CI）；compute/corpus/music/rwkv 四份此类守卫共 1374 行
- native-*-gate.yml 共 11 个 workflow：native-music-gate.yml 与 native-p2p-gate.yml 替换 crate 名后只差约 90 行，大多是注释和 ABI 列表

机制：「有哪些原生 crate、各自要在哪些平台出包、是否硬依赖、带哪些 feature 和 external_sources」这个事实没有登记源。每个消费方（CMake、gradle、Xcode、bootstrap、CI action、gate workflow）都按 crate 逐份复制粘贴；copy-if-present 是默认写法，照抄一处就会让缺库变成静默跳过，于是每个 crate 再配一份几百行的文本守卫。新增一个 crate 要改十几个文件，再写一份守卫。

根本方案：新建 native/crates.toml 作为唯一登记源：name、required(bool)、platforms、android_abis、test_features、id_audit、external_sources、artifact_name。消费方都改成读这一份：① fushi/{windows,linux}/cmake/fushi_native.cmake 提供 `fushi_native_libs()`，遍历登记源，对 required 项一律 FATAL_ERROR 并 install，删掉各 CMakeLists 里逐个写的块；② build.gradle 循环登记源注册 checkFushiNative_<name>，删掉五份手写任务；③ macOS 只留一个 bundle_fushi_native.sh 和一个 pbxproj build phase，按登记源拷贝，删 9 份 bundle_*.sh；④ bootstrap.ps1、bootstrap.sh、native_libs.ps1 读登记源（ps1 用 ConvertFrom-Json 读 json 版，或者登记源直接写成 crates.json），删掉三处硬编码清单；⑤ 只留一个 .github/actions/setup-fushi-native（input: crates、android-abis），删掉 setup-fushi-{compute,music,corpus,rwkv}；⑥ 只留一个 native-gate.yml：先由 plan job 按改动路径和登记源算出 matrix，再跑统一的构建、ABI 校验、cargo test 步骤，删掉 11 个 native-*-gate.yml（galgame / fushidicts 这类 C++ 模块可保留独立 gate）。守卫缩成一条：登记源与 native/fushi_* 目录及各 crate 的 build_* 脚本一一对应，删掉 4 份 hard_dependency 守卫。以后新增 crate 只需在 crates.toml 加一段，再提供 build_* 脚本。

要动：新增 native/crates.toml；tool/native_libs.ps1；tool/bootstrap.ps1；tool/bootstrap.sh；fushi/windows/CMakeLists.txt；fushi/linux/CMakeLists.txt；fushi/android/app/build.gradle；fushi/macos/bundle_fushi_*.sh；fushi/macos/Runner.xcodeproj/project.pbxproj；fushi/ios（check_fushi_*.sh）；fushi/tool/dist_test/worker_build.sh；fushi/tool/dist_test/worker_prepare.sh；fushi/tool/dist_test/worker_setup.sh；fushi/tool/dist_test/worker_setup.ps1；.github/actions/setup-fushi-*；.github/workflows/native-*-gate.yml；.github/actions/native-store-names/names.sh；fushi/test/build/fushi_*_hard_dependency_guard_test.dart

核验说明：接线确实是逐个 crate 手写。fushi/macos 下有 9 份 bundle_fushi_*.sh；.github/actions 下有 setup-fushi-{compute,corpus,music,rwkv,anki-sync}；native-*-gate.yml 共 12 个（含审计没列的 native-shell-thumbs-gate.yml 和 onnx-plugin、fushidicts、galgame、torrent）；docs/agent/build.md:134、141 逐个 crate 描述 CMake FATAL_ERROR、bundle 脚本、iOS check、gradle check 和对应守卫。names.sh:81-91 又有一份 crate→目录清单。现状里找不到单一登记源，也找不到「有意分散」的设计说明。

方案风险：① CMake 没有 TOML 解析器，gradle（Groovy）读 TOML 也要额外依赖，登记源用 JSON 更合适（CMake 3.19+ 有 string(JSON)，PS 5.1 有 ConvertFrom-Json，bash 用 jq），或者由一个生成器产出各端片段。② iOS 走伞形 staticlib（fushi_ios_umbrella 一次链入 7 个 crate），不是逐个 crate 出包，登记源要把这层聚合表达出来，check_fushi_*.sh 也要按 ABI 导出符号（ffc_abi_version 等）校验，所以每个 crate 需要 abi_symbol 字段。③ fushi_p2p 和 fushi_fsrs 是可选库（build.md 原话「与 fushi_p2p / fushi_fsrs 相反」），required 字段要准确迁移，不能一律 FATAL_ERROR。④ fushi_anki_sync 有自己的工具链（rust-toolchain.toml 写的是 1.97.1）和 protoc，登记源要能表达每个 crate 的工具链。⑤ 合并成一个 native-gate.yml 后，路径过滤从 on.paths 挪进 plan job，必须保证非相关 PR 不会冷启 matrix。⑥ 硬依赖守卫缩成一条之前，先确认各端消费方确实全部读登记源，否则守卫减了，漂移反而没人兜。

修正后的方案（以此为准）：登记源用 native/crates.json，不用 toml。字段包括 name、required、platforms、android_abis、ios_umbrella（bool）、abi_symbol、toolchain_file（缺省为根 rust-toolchain.toml）、external_sources、test_features、id_audit。消费方：CMake 用 string(JSON) 遍历；gradle 用 JsonSlurper；macOS 单一 bundle 脚本用 jq 或 plutil；iOS 单一 check 脚本按 abi_symbol 逐个查伞形库；ps1 用 ConvertFrom-Json；names.sh 和 worker 用 jq。其余按审计原方案（单个 setup-fushi-native、单个 native-gate，C++ 模块保留独立 gate），并加一条结构守卫：crates.json 与 native/fushi_*（排除 C++ 模块）目录一一对应。

## desktop-workflow-fork

**release-desktop.yml 与 build-multiplatform.yml 各自完整复制了 Windows / macOS / iOS 构建 job，靠注释「同一口径」维持一致**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- wc：release-desktop.yml 4509 行，其中 windows job 在 :152-1416、macos 在 :1416-2608、ios 在 :3041-3871；build-multiplatform.yml 2374 行，macos 在 :915-1546、ios 在 :1546-1692、windows 在 :1692-2374
- 按 step 名比对（comm，已执行）：两边 windows job 分别有 72 / 64 个 step，其中 47 个同名（Build fushi_{compute,corpus,fsrs,music,p2p,rwkv,web_core} DLL、libtorrent vcpkg 缓存、Mihon runtime、galgame helper 等）；macOS 两边 59 / 54 个 step，37 个同名
- release-desktop.yml:608-612 注释写着「与 build-multiplatform.yml windows job 的 fushi_web_core 同一口径」，一致性只靠注释约定
- build-multiplatform.yml:247-249 注释：烘焙密钥注入曾被逐字抄进 11 个 job，抄到 TMDB 出现 3 个变体，正式包里 TMDB 恒为「未配置」而 CI 全绿（BUG-1588）。这是复制带来的漂移已经实际发生过一次
- fushi/test/build 下 13 个读 workflow 的守卫，以及 fushi/test 里 85 个读 .github/workflows 的测试中 61 个用 indexOf 切 YAML、只有 4 个用 package:yaml；例如 release_workflow_main_sync_guard_test.dart:24-34 靠 '    - name: ' 的缩进切 step

机制：出包流程没有用 reusable workflow（workflow_call）按平台抽出来。PR 构建和正式发布各写一份几百步的 job，原生库、缓存、密钥、Mihon、galgame helper 这些步骤只能复制。复制品会漂移（BUG-1588 是先例），于是又加上按缩进切文本的 workflow 守卫来钉，这些守卫在 YAML 改格式时就会失效。

根本方案：按平台抽出 reusable workflow：.github/workflows/_build-windows.yml、_build-macos.yml、_build-ios.yml、_build-linux.yml、_build-android.yml，均为 on: workflow_call，inputs 包括 mode（pr|release）、channel、sign、upload-artifact。只有签名、公证、上传这几步按 mode 分支。build-multiplatform.yml、release-desktop.yml、release.yml 缩成只做 plan、channel、publish 的薄调用方（预计合计减少 3000 行以上）。原生库构建步骤并入上一条的 setup-fushi-native，Mihon、galgame helper、libtorrent 各抽成 composite action。守卫方面：删掉针对两份复制品同步的文本守卫，剩下的 workflow 不变式改用 package:yaml 解析后断言（或放进 ci-config-gate 跑 actionlint 加一个小的 YAML 结构检查脚本），禁止 indexOf 切 YAML。以后改出包步骤，只需改对应平台的 _build-*.yml 一处。

要动：.github/workflows/release-desktop.yml；.github/workflows/build-multiplatform.yml；.github/workflows/release.yml；.github/workflows/main.yml；新增 .github/workflows/_build-*.yml；.github/actions/*；fushi/test/build/*workflow*_guard_test.dart；fushi/test/build/release_*_guard_test.dart

核验说明：已核对三个文件的行数：release-desktop.yml 4509 行、build-multiplatform.yml 2374 行、release.yml 2252 行。两边都有成组同构的步骤，例如 build-multiplatform.yml:475/497/514 和 release-desktop.yml:566/596/616 是同一组 Rust DLL 构建。workflow_call 目前只有 release-server.yml 和 server-gate.yml 在用，说明出包流程没有抽成可复用工作流，而仓库里已有先例。BUG-1588 是复制漂移已经实际发生过的证据。

方案风险：① 跨 workflow 统一的 release 序列（docs/agent/build.md:106）依赖 fetch-depth 0 加 git rev-list --count。被调用的工作流要自己完整 checkout，或者由调用方算好 seq 作为 input 传进去，不能各算各的。② 两条发布 workflow 的 concurrency 组按设计各自独立、并行上传同一个 Release，挪进 reusable workflow 后组名和 cancel-in-progress 语义要保持不变（守卫 release_workflow_concurrency_guard_test）。③ 发布门的 environment 只挂在 publish job 上（release_publish_gate_guard_test），构建 job 不能因为抽成可复用工作流而带上 environment。④ 被调用方读 secrets 需要显式传 secrets 或写 secrets: inherit；调用嵌套和单次运行内的可复用工作流个数都有上限。⑤ PR 快门与全量分层（pr_tiered_gate_guard_test）由 plan job 的输出驱动，薄调用方要原样透传这些开关。⑥ 已有的几十条 workflow 文本守卫会成片失效，必须与重构同一个 PR 改成用 package:yaml 解析后断言，或者换成 actionlint 加结构检查。

## toolchain-pin-copies

**Flutter / Rust 工具链钉版号称单一真相源，实际在 workflow 里抄了 36 处以上，靠守卫或注释对齐；本地 cargo 完全没有钉版**

- 类型：守卫代替结构；规模 S；价值 high；不改外部行为
- 核验：部分成立

证据：

- grep：flutter-version: '3.50.0' 在 11 个 workflow 里共出现 21 处（如 build-multiplatform.yml:238/439/943/1571/1714、main.yml:271/675/871、release-desktop.yml:205/1450/3075）
- fushi/test/build/flutter_version_single_source_guard_test.dart:6-13 与 :21-41：真相源 fushi/.fvmrc 无法被 workflow 引用，只好用正则扫全部 workflow、比对字符串
- native-store-names/names.sh:34 P2P_RUST=1.95.0 被注释称为工具链真相源，但 native-p2p-gate.yml:50、native-compute-gate.yml:58/100、native-fsrs-gate.yml:62/139、native-music-gate.yml:49、native-rwkv-gate.yml:80/112、native-web-core-gate.yml:49/91、main.yml:545、release-server.yml:345、actions/fushi-web-core-linux/action.yml:18 都直接写死了 toolchain: '1.95.0'
- native-music-gate.yml:45、native-rwkv-gate.yml:76/108 的注释「工具链钉法与 native-fsrs-gate.yml 一致（Rust 1.95.0）」：一致性靠注释链式互指
- 仓库根和 native/ 下都没有 rust-toolchain.toml（cat 返回 No such file）：本地 cargo test --profile quick 用的是机器上任意版本的 rustc，与 CI 的 1.95.0 可能不一致（推测，未在本机核对 rustc 版本）

机制：版本号写在工具无法读取的位置：.fvmrc 无法直接喂给 subosito/flutter-action，names.sh 的变量在不 source 它的 job 里用不到，于是每个 job 就地抄字面量。升级要改几十处，靠守卫或注释提醒。Rust 侧连守卫都没有，只有注释。

根本方案：① 新增 .github/actions/setup-fushi-flutter：用 jq 读 fushi/.fvmrc 后调用 subosito/flutter-action（cache 等参数集中在这里）；全仓 21 处 subosito 调用一律换成它。ci-config-gate 加一条 YAML 结构检查：composite 之外不得出现 subosito/flutter-action 或 flutter-version 字面量。删掉 flutter_version_single_source_guard_test.dart（pre_push_check 第 0 步改读 .fvmrc）。② 仓库根新增 rust-toolchain.toml（channel = "1.95.0"，并列出 targets 和 components）：rustup 在本地和 CI 都会自动遵循它，dist worker 同样适用；workflow 里删掉 dtolnay/rust-toolchain 的 toolchain 字面量（直接用 rustup 加 toolchain 文件，或由一个小 step 从 toml 读出后传给 dtolnay）；names.sh 的 P2P_RUST 改为从 rust-toolchain.toml 解析，cargo-ndk 版本同样只登记一处。以后升级 Flutter 只改 .fvmrc，升级 Rust 只改 rust-toolchain.toml。

要动：fushi/.fvmrc；新增 rust-toolchain.toml；新增 .github/actions/setup-fushi-flutter；.github/workflows/*.yml；.github/actions/native-store-names/names.sh；.github/actions/fushi-web-core-linux/action.yml；.github/workflows/ci-config-gate.yml；fushi/tool/pre_push_check.dart；fushi/test/build/flutter_version_single_source_guard_test.dart

核验说明：Flutter 部分属实：flutter-version: 共 21 处，分布在 11 个 workflow 和 flutter-engine-overlay action 里，靠 flutter_version_single_source_guard_test 维持一致。

Rust 部分有夸大。names.sh:34 的 P2P_RUST 实际经 native-store-names 的 outputs.p2p_rust 被约 25 个构建步骤引用（build-multiplatform.yml:475 起、release-desktop.yml:566 起、release.yml:685/738、native-cache-warm.yml:231），真正写死 '1.95.0' 的是 16 处，集中在各 native-*-gate、main.yml:545、release-server.yml:345/605、fushi-web-core-linux/action.yml:18（审计漏了 native-shell-thumbs-gate.yml:47）。「没有 rust-toolchain.toml」也不完全对：native/fushi_anki_sync/rust-toolchain.toml 存在（1.97.1），而且 .github/actions/setup-fushi-anki-sync/action.yml:11-23 已经实现了「CI 从 toml 读 channel、不用 dtolnay」，这正是审计方案的现成先例，审计没有引用。

方案风险：① 根 rust-toolchain.toml 不能写 targets：rustup 会在每台开发机和 dist worker 上自动装下全部 iOS/Android target。targets 应由各 job 自己 rustup target add。② fushi_anki_sync 自己的 toml（1.97.1）离得更近，会覆盖根 toml，这是有意的，要保留，不能被「全仓统一」误改。③ names.sh 把 P2P_RUST 折进产物名哈希，改成读 toml 后，哈希的身份字符串必须仍包含工具链版本，否则升级 Rust 后会复用旧产物。④ 版本改由 toml 决定后，dtolnay 装的版本会被 toml 覆盖，最好整体改用 rustup 加 toml，避免装两套。

修正后的方案（以此为准）：Flutter 部分按原方案，抽 setup-fushi-flutter 读 fushi/.fvmrc。Rust 部分：仓库根新增 rust-toolchain.toml，只写 channel="1.95.0" 和 profile="minimal"，不写 targets。照 setup-fushi-anki-sync 的写法，抽出一个 composite action，从 toml 读 channel 并 rustup 安装，可带 targets input。names.sh 的 P2P_RUST 改为从根 toml 解析，继续作为 output 并折进哈希。16 处写死的版本号全部换成这个 action。fushi_anki_sync 保留自己的 toml。

## native-source-key-triple-impl

**原生库「源码内容键」有 ps1 / sh / names.sh 三套实现，算法不一致，已出过 BUG-4988**

- 类型：缺单一登记源；规模 M；价值 medium；不改外部行为
- 核验：部分成立

证据：

- tool/native_libs.ps1:91-130 Get-NativeSourceTree：读 external_sources.txt，手工拼出 git blob 头再算 SHA-1，注释自称与 native_source_key.sh「逐字节同一算法」
- tool/native_source_key.sh:1-31：同一算法的 bash 版，注释写明是为 BUG-4988（legacy_text.rs 改了但 fushi_music 的键不变、没有重编）补上的；dist worker（fushi/tool/dist_test/worker_build.sh:224、worker_prepare.sh:107）调用它
- native-store-names/names.sh:54-64 tree_hash：第三套算法（对 git ls-tree -r 的输出过滤掉 .md 后取 sha256），而且全文件没有出现 external_sources（grep 结果中无此行），CI 原生产物库的键与本地 / worker 的键是两套语义
- names.sh:81-91 又手写了一份 crate→目录 清单（P2P、IOS_NATIVE、ANKI_SYNC 等），这是 crate 清单的第四份副本

机制：「一份原生产物对应哪棵源码」本来是一个函数，却因为三个运行环境（Windows 本地 PS 5.1、Linux worker、GitHub runner）各写了一份。external_sources 这个概念后来才加进来，只补进了其中两份；names.sh 目前碰巧没有出错，是因为 IOS_NATIVE 把 fushi_compute 整个目录列了进去（推测：任何其他 crate 一旦新增 external source，CI 产物库就会复用旧产物，重演 BUG-4988）。

根本方案：按 vendored_binaries.py 的先例（「三端共用的唯一实现」）新建 tool/native_key.py：输入 crate 名，读上一条的 native/crates.toml（external_sources、附加身份信息如 toolchain/ndk/features），输出一个键。native_libs.ps1 通过 Python 调它（vendored_binaries.ps1 已有找 Python 的逻辑可复用），worker 和 names.sh 也调它；删掉 Get-NativeSourceTree 的手工 SHA-1、native_source_key.sh 和 names.sh 的 tree_hash，names.sh 里的 crate 目录清单也一并删除、改读登记源。用一条 py 单测钉住「external source 变化 ⇒ 键变化」，替代 native_external_sources_stamp_guard_test 的跨语言文本比对。

要动：tool/native_libs.ps1；tool/native_source_key.sh；.github/actions/native-store-names/names.sh；fushi/tool/dist_test/worker_build.sh；fushi/tool/dist_test/worker_prepare.sh；新增 tool/native_key.py；fushi/test/build/native_external_sources_stamp_guard_test.dart；fushi/test/build/native_store_names_single_source_guard_test.dart

核验说明：ps1 和 sh 两份实现确实并存，但它们是同一算法：tool/native_libs.ps1 的 Get-NativeSourceTree 与 tool/native_source_key.sh:1-31 都是「tree <树>」加每行「<路径> <blob>」再走 git hash-object，有守卫钉住。审计说「算法不一致」，对这两份不成立。

names.sh 的 tree_hash 是另一套，但那是有意设计：它服务 CI 产物库，身份里还折进了 runner image/os/arch、CC/CXX、工具链版本，并且有意排除 .md（注释里写了理由）。它确实不读 external_sources，不过它命名的产物只有 iOS 伞形库、p2p、torrent、galgame、mihon、anki_sync；IOS_NATIVE 本身就把 native/fushi_compute 整个目录列了进去（names.sh:85），所以 fushi_music 的 external source（legacy_text.rs，见 native/fushi_music/external_sources.txt）已被覆盖。重演 BUG-4988 的前提是 P2P、TORRENT 或 ANKI_SYNC 将来新增 external source，这个风险真实但面窄。names.sh:81-91 的 crate 目录清单确实是又一份副本。

方案风险：① 本地 Windows 改为依赖 Python：vendored_binaries.ps1 已有找 Python 的先例，可以接受，但 native_libs.ps1 是 bootstrap 必经之路，缺 Python 时必须响亮失败，不能静默降级。② names.sh 的身份维度（image、arch、CC、工具链、排除 .md）与本地键的语义不同，不能强行合成一个键，只能共用「源码树」这一部分。③ 改键会导致所有缓存冷启一次（可接受，不涉及持久化）。

修正后的方案（以此为准）：只统一「crate 的源码集合」这一个函数：由 native/crates.json 的 dirs 和 external_sources 决定，输出路径列表或源码树哈希。本地和 worker 的键 = 源码树哈希；names.sh 的键 = 源码树哈希 + 运行环境身份（image、arch、CC、工具链），继续排除 .md。实现可以是 py，也可以保持 sh 加 ps1 两份，但输入一律读登记源；names.sh 的目录清单改为从登记源生成。再加一条测试：登记源里任一 crate 的 external_sources，都必须出现在三个消费方的输入集合里。

## i18n-monolith-merge-driver

**17 份各 1.56 万 key 的整体 i18n json 是全仓最热的冲突点，只靠本地合并驱动、锁目录和排序守卫兜着，驱动本身还弄坏过 SDK**

- 类型：补丁叠补丁；规模 XL；价值 medium；不改外部行为
- 核验：部分成立

证据：

- wc：fushi/lib/i18n/strings.i18n.json 15675 行（约 15673 个 key），17 种语言各一份
- git log --since=2026-10-28：一个月内有 1579 个提交改动 strings.i18n.json
- fushi/tool/i18n_merge_driver.dart:27-31：自述「GitHub 的服务器端合并不用自定义驱动」，PR 页照样显示冲突；CI 和没跑过 setup 的 clone 退回行级合并
- docs/bugs/BUG-5537-i18n-merge-driver-corrupts-flutter-sdk.md:3-5：驱动在 linked worktree 里继承了 GIT_DIR，把 Flutter SDK 的 flutter.version.json 改写成 2.9.1；修法是再包一层 tool/git_hooks/i18n_merge_driver.sh 来 unset 环境变量，又是一层补丁
- 子代理纪律把 i18n json 列为必须先 mkdir 拿锁的共享文件（CLAUDE.md 嵌入的代理定义与 fast-workflow.md:50 第⑤条），并发写入只能靠人工锁串行化

机制：所有域的文案集中在单一扁平文件，并按 key 全排序。任意两条 PR 只要都加了 key，在 GitHub 上就可能冲突（排序后相邻的 key），17 份文件同时冲突。为此叠了按 key 合并的驱动、驱动的 shell 包装、驱动注册（setup_worktree）、排序守卫和并发锁，层层都是对冲突的补救，冲突的根源一直没动。

根本方案：按 key 已有的 `<域>_` 前缀拆分：启用 slang namespaces，目录改为 fushi/lib/i18n/<domain>/<domain>_<locale>.i18n.json（域的清单来自 naming.md 的前缀表，作为唯一登记）。i18n_sync.dart 按前缀自动路由到对应文件，--add / --rename 的用法不变；跨域 rename 由它负责搬移。拆分后冲突只发生在同一域、同时改相邻 key 的情况，git 的行级合并基本够用，可删掉 i18n_merge_driver.dart、tool/git_hooks/i18n_merge_driver.sh、setup_worktree.ps1 里的驱动注册以及 .gitattributes 的 merge= 行，锁也细化到每个域（或取消）。代价：生成的访问器变成 t.<domain>.<rest>，需要用 i18n_sync 一次性 codemod 全部调用点（机械改写，可以脚本化）；运行时行为和翻译内容不变。这是用户不可见的大改，建议列入拍板台，与 slang 版本确认（namespace 的生成形态）一起评估；如果不接受访问器改名，退一步只能保留现状。

要动：fushi/lib/i18n/*.i18n.json；fushi/slang.yaml；fushi/tool/i18n_sync.dart；fushi/tool/gen_i18n.dart；fushi/tool/i18n_merge_driver.dart；tool/git_hooks/i18n_merge_driver.sh；tool/setup_worktree.ps1；.gitattributes；fushi/lib/**（t.xxx 调用点 codemod）；fushi/test/**/i18n_keys_sorted_guard_test.dart；docs/agent/naming.md

核验说明：现状属实：fushi/lib/i18n 下 17 份整体 json；.gitattributes:59 配了 merge=fushi-i18n-json；fushi/tool/i18n_merge_driver.dart:27-31 自己写明 GitHub 服务器端不用这个驱动、CI 退回行级合并；驱动的 shell 包装（tool/git_hooks/i18n_merge_driver.sh）是为处理 GIT_DIR 继承加的。

但审计给的根本方案代价判断过重，而且漏了更便宜的形态。slang namespace 会把访问器从 t.xxx 改成 t.<domain>.xxx，全部调用点都要 codemod，i18n_sync、gen_i18n、翻译工具和相关守卫也都要改。

方案风险：① 访问器改名会波及全部调用点和守卫，还会和所有在途 PR 冲突，等于一次全仓 rebase 风暴。② 域前缀并不严格，跨域 key、旧 key 能否稳定路由需要先量。③ naming.md 的前缀表不是机器可读的登记源。④ slang.yaml 里有 flat_map: false 等约束（BUG-4640、BUG-1589），namespace 生成形态对 AOT 体积和 gen_snapshot 栈的影响要实测。⑤ 拆成多份文件后锁粒度虽然变细，但同一个 PR 涉及多个域时仍要拿多把锁。

修正后的方案（以此为准）：推荐「源文件按域拆分、整体 json 改为生成物」：入库的真相源是 fushi/i18n_src/<domain>/<locale>.json（每个域一个文件），i18n_sync 按前缀路由读写；gen_i18n 先把它们合并成现在的 lib/i18n/strings*.i18n.json，再交给 slang 生成。合并出来的整体 json 和 strings.g.dart 一样 gitignore、不入库，访问器 t.xxx 保持不变，不需要 codemod。冲突面缩到同域相邻 key，之后可以删掉合并驱动、shell 包装、setup_worktree 里的注册和 .gitattributes 的 merge= 行。整体 json 不再入库，所有直接读它的工具和守卫都要改成先跑 gen_i18n 或改读 i18n_src，迁移前先 grep 出完整的消费方清单。迁移本身是一次性的机械拆分，用户不可见，拿到用户点头后执行。

## 核验补充（审计漏掉的）

- fushi/tool/pre_push_check.dart:334-340、437 在运行时解析 docs/agent/fast-workflow.md 里的 markdown 表格，拿它当 PR 快门的枚举守卫清单（少于 40 条就报错）。文档本身成了 CI 配置：改表格格式或改名会直接影响门禁，文档和代码的漂移由此变成门禁行为的漂移。守卫的作用域应当在守卫文件里声明、由工具收集，不该靠文档表。
- fushi/tool/tests_for_changes.dart:17-40 用测试源码里的路径字面量（不剥注释，故意偏向过度触发）推导触发面，另外还有 `// tests-for-changes:` 声明（:306-320）。这是给『文本守卫按字符串读文件』补上的第二套索引，本身也要靠 tests_for_changes_guard_test 兜着，属于审计第一条补丁链的又一层，审计没有计入。
- native/fushi_anki_sync/rust-toolchain.toml 加 .github/actions/setup-fushi-anki-sync/action.yml:11-23 已经是『从 toml 读工具链』的现成先例，与其它 crate 的 dtolnay 写死字面量是两种并存的工具链机制，审计没有发现这个先例。
- Rust 工具链字面量还有一处审计没列：.github/workflows/native-shell-thumbs-gate.yml:47；native-*-gate 实际是 12 个（含 shell-thumbs、onnx-plugin），不是 11 个。
- flutter-version 的钉版也出现在 composite action .github/actions/flutter-engine-overlay/action.yml 里。新建 setup-fushi-flutter 时，要把这个 overlay action 一并收编或与它组合，否则就有两个 Flutter 入口。

# 单元测试跨机分流（dist_test）设计

日期：2026-10-24　状态：第一期（本机 + 自己的 Mac）、第二期（朋友机器：shim / 暂停 / 资源上限 / 种子仓）、第三期（红 suite 跨机复跑分型、平台原因跳过报告、桌面集成测试分流 `--itest`）已实现。朋友真机与 Tailscale 共享尚未接入，见「第二期实现」末尾的验证范围。

## 集成测试分流（`--itest`，2026-10-25）

### 形态

- `dart tool/dist_test.dart --itest [integration_test/<f>_test.dart ...]`：只跑清单 `fushi/tool/test_flow/dist_itests.json` 里的文件（显式给的路径也必须在清单里），每个文件在清单列出的**每个**平台各跑一次（一个文件 × 一个平台 = 一个单元，能力 `itest`）。清单而不是扫描：`integration_test/` 大部分是要真盘 / 真游戏 / 真机 / `--dart-define` 素材的探针，文件里没有任何东西能说明它属于哪种。不接受 flutter 参数。
- 只有配置里声明了 `itest` 能力的 worker 接，且只在每台机器的第一个槽位（同机共享屏幕 / GPU / app 级服务）。`ssh-shim`（朋友机器）声明 `itest` 直接是配置错误；shim 的 `run` 只认数字并发，`worker_run.sh itest` 经 shim 不可达（契约测试钉住）。
- 本机 Windows worker 走 `tool/run_windows_itest.ps1`（隔离的唯一真相源：APPDATA / LOCALAPPDATA / TEMP / USERPROFILE 重定向、WebView2 profile、进程归属核对）；Mac worker 经 ssh 跑 `worker_run.sh itest`，设 `FUSHI_TEST_HIDDEN`（离屏、不抢焦点）与 `FUSHI_TEST_ROOT`（全新数据根）。
- **一台机器每轮只编一次 app**：`tool/dist_test/itest_entry.sh` 按清单生成 `integration_test/.dist/entry.dart`（git-ignored），import 全部清单文件，启动时按环境变量 `FUSHI_DIST_ITEST` 选跑哪一个；先 `flutter build <os> --debug -t` 它，之后每个文件一次 `flutter drive --use-application-binary`——每个文件仍是独立进程、独立数据根，测试本身不改。数据根只经环境变量传（dart-define 改不了已编好的二进制，也会让构建输入每次不同）。Mac 侧按「检出提交 + entry 内容」打戳，同一轮后续批次不再编。
- `flutter drive` 没有 json reporter：每个文件回一行 `{"type":"fushiItest", path, exitCode, ms, tail}`（tail 是 app 的进度行加输出末 40 行，base64），协调者展开成标准事件（一个文件一个 suite、一个以文件命名的测试），判绿 / 计时 / 复跑 / 跳过报告照旧。**drive 在全部测试 skip 时也退出 0**：进度行显示一个都没跑的判红（「这个平台上什么都没跑，清单不该列它」）；部分 skip 进「Skipped for a platform reason」。进度行在 Mac 带 `flutter: ` 前缀、Windows 不带，两种都认。
- Windows 绿的那次启动的证据目录（隔离数据根，约 20 MB）用完即删，红的留着分型；分流模式不截 PrintWindow 图（脚本自己注明那些图对 Flutter / WebView 通常是空白）。

### 为什么要「一次编译」：实测

第一版每个文件一次 `flutter test -d <os> <file>`。按 json 事件拆开，单文件耗时几乎全在加载：

| | 每文件加载（编译 + 启动） | 测试本身 |
|---|---|---|
| Mac M4 | 45 s（代码没变也是） | 3–40 s |
| 本机 Windows | 80–130 s（冷编 357 s） | 4–40 s |

`flutter test -v` 显示原因：桌面集成测试的构建目标是 flutter_tools 每次新生成在临时目录里的 `listener.dart`（`-dTargetFile=/var/folders/.../flutter_test_listener.XXXX/listener.dart`），所以每次都是一份新构建——`kernel_snapshot_program` 每次重编 20 s，build hooks 重跑，什么都复用不上；同一个 entry、同样参数连跑也一样。这是 `flutter test -d` 的固有行为，调参数绕不过。换成「编一次 + `drive --use-application-binary`」后在 Mac 上：`home_keyboard` 54 s → 12 s（测试 9 s），`module_gating` 66 s → 23 s（测试 21 s）。

整轮（22 个候选文件 × 两平台，本机 + Mac 并行）：旧做法跑了约 60 分钟还没跑完（见下面的挂死问题，两台都被剔除，8 个文件没跑）；新做法 15 分 33 秒跑完全部 44 个单元。清单定稿后的验收数字见「验收」。

### 顺带修掉的问题

- **基础设施重试从没生效过**（第一期起）：「超时 / 断连的批次退回队列重试一次」靠 `DistBatch.attempts`，但它从没被加过，而退回的批次会被重新切成新批次、计数归零——一个每次都挂死的 suite 会一直重试到所有 worker 都被剔除（实测 `reader_keyboard` 两台各挂 17 分钟后两台都被剔除）。改为队列按**单元**记「已重试过」：每个单元只重试一次，第二次仍是基础设施失败就记红、归咎于 suite 而不计入 worker 的剔除计数。单元测试同样受益。
- **suite 路径匹配把 `integration_test/a_test.dart` 当成 `test/a_test.dart`**（`matchKnownSuite` 只认 `test/` 锚点，落在 `integration_test/` 里面）：改为在任意 `/` 边界截后缀匹配。
- **隔离泄漏（app 侧真 bug）**：`browser_extension_installer.dart` 直接取平台 app-support 目录、不认 `FUSHI_TEST_ROOT`。Mac 上 debug 包与正式版同 bundle id，集成测试一启动就把用户真实的 `hibiki-browser-extension/` 删掉重写，`fushi-defaults.js` 里换成测试实例的 token（实测 Mac 上该目录 10-25 14:53 被改写，正是探针启动的时刻）。改为测试根下落进测试根（生产路径不变：扩展按绝对路径被浏览器记住，不能跟数据根搬家）。

### 已知残留风险

- Mac 上 debug 包与正式版同 bundle id（`app.fushi.reader`），`NSUserDefaults`（`~/Library/Preferences/app.fushi.reader.plist`，`shared_preferences` 已被测试根接管，但窗口位置等系统级写入不经它）与 WebKit 缓存（`~/Library/Caches/app.fushi.reader/WebKit`）按 bundle id 共享，环境变量隔离不到。实测两处 10-25 有改动，但该机同时开着用户的正式版，分不清是谁写的。根治要让测试构建换 bundle id，未做。
- `lib/` 里还有约 20 处直接调 `getApplicationSupportDirectory()` / `getApplicationDocumentsDirectory()`、不经 `AppPaths` 的测试根分支（制卡增强的临时文件、图标偏好、更新下载等）；这轮清单内的测试没有走到它们（实测本机与 Mac 的真实数据目录除上面两处外无改动），但新加进清单的测试可能走到。

### 清单与验收

清单收录的 11 个文件是两轮独立实测里两平台都绿的：`app_smoke`、`card_source_return`、`comprehensive_imports`、`comprehensive_reader_lookup`、`comprehensive_settings`、`desktop_reader_columns_dom`、`desktop_reader_css_dom`、`desktop_settings_smoke`、`home_keyboard`、`module_gating`、`regression`。

验收（2026-10-25，本机 Windows + M4 Mac，清单全量）：`DIST TEST VERDICT: PASSED - 22 tests ran on 2 worker(s)`，墙钟 **9 分 41 秒**。Mac 编一次后单文件 5–23 s；Windows 首批含编译 164 s，之后单文件 17–49 s——Windows 是瓶颈（11 个文件串行），每次启动仍有约 15 s 的固定开销（PowerShell + runner 的进程归属核对 + drive 连接）。旧做法同样 11 个文件仅 Windows 一侧就要约 22 分钟。

候选里**两平台都红、没进清单**的（CI 从不跑它们，红是早就坏了的测试，不是分流引入的；修它们是另一件事）：

| 文件 | 症状（两平台一致） |
|---|---|
| `feature_flows` | 找不到图标 `IconData(U+0EEBC)` 的控件 |
| `navigation_stability` | 遍历设置目的地时抛 `StateError` |
| `reader_caret` | 找不到 `book_entry_fushi://book/Pagination Test…` 的书架条目 |
| `reader_dictionary` | 断言 `Expected: true, Actual: false`（阅读器查词） |
| `reader_keyboard` | `FlutterError.onError` 未还原的断言后**挂死**到超时 |
| `reader_pagination` / `reader_popup_caret` / `reader_settings_layout_reachability` / `settings_validation` / `user_path` | 测试失败（日志见实测输出目录） |
| `video_position_restore` | Windows 红；Mac 上因缺素材整文件 skip |
| `video_player` | `skip: true`（要真机 + `fixtures/sample.mp4`），桌面上什么都不跑 |

## heavy.dart 自动外包（`--offload` / `--analyze` / `--build`，2026-10-30）

用户：「我电脑上好卡，但是其他电脑上很闲」。`tool/heavy.dart` 在排本机租约前，把能外包的重活自动交给本工具：

- `flutter test`（test/ 下）→ `dist_test.dart --offload`：worker 只用非 `local` 的机器；它们都没接（不可达 / 忙 / 暂停 / 平台不符）时退出码 75（`kDistOffloadDeclined`），heavy.dart 改在本机照原样跑；跑了一部分后剩下的（平台钉死、机器掉线）由 `local` worker 在租约下补跑。忙的机器只再问 `--busy-retries=2` 次。
- `flutter analyze` → `dist_test.dart --analyze`：按 config 顺序，先问 `jobBlocker()`（shim 机器发 `hello`，看 `analyze=yes` / `paused`，不满足就不 lock / push / prepare），第一台 prepare 成功且接活的机器跑 `worker_analyze.sh`，输出与退出码原样带回；都不接 → 75。
- shim 新动词 `analyze <slot> [--[no-]fatal-infos|warnings]`：选项白名单，路径走 stdin 由 `worker_analyze.sh` 校验（只许 `lib/ test/ tool/ integration_test/ test_driver/ bin/` 下已存在的路径，拒 `..`），与 `run` 同一套暂停 / 空闲内存门槛。信任面不变：同样是跑请求方仓库里的代码（analyzer），不回传任何文件。
- **其它 package 的测试**（第二轮）：`packages/<name>/` 下的 `flutter test` / `dart test` → `--offload --package=packages/<name>`。协调者按包目录发现 suite（路径仍是包内的 `test/...`），包没有耗时表与人工钉表，按文件大小估重；包名经 flutter 参数 `--fushi-package=<name>` 带给 `worker_run.sh`，它先剥掉这个参数再 `cd ../packages/<name>`，按 pubspec 有没有 `sdk: flutter` 选 `flutter test --no-pub` 或 `dart test`（与 CI 一致）。旧 shim 的 `check_flutter_arg` 本来就放行 `--name=朴素值`，跑的又是快照里新的 `worker_run.sh`，所以朋友不用重装 shim 就能接包测试。
- **`--coverage`**（第二轮）：同样经 flutter 参数带过去，`worker_run.sh` 给每个 `flutter test` 进程加 `--coverage-path=<state>/coverage.info`，跑完把 lcov base64 成一行 `{"type":"fushiCoverage","lcov":"..."}` 接在事件流里；本地 worker 直接读自己的文件。协调者把这些行从事件流里摘出来（不进 jsonl / 判绿），**按不可信数据校验**：只收 `SF:` 能落到该包 `lib/` 下（相对路径，或对方 checkout 的绝对路径在 `/<包名>/lib/` 处截断）、不含 `..` 的记录和 `DA:` 行，其余丢弃并计数；合并后重算 `LF` / `LH` 写到 `--coverage-out`。纯 Dart 包（`dart test --coverage=<目录>` 写的是 VM json）不外包 coverage。
  - **coverage 每个测试进程有一笔固定开销**（2026-10-30 实测）：采集器向 VM 要 `forceCompile` 的源码报告（一个小 suite 就拉进本 app 的 2185 个库），flutter tool 在单个主 isolate 里合并，占满一核——本机 9.5 分钟、M4 Mac 7.3 分钟，测试本身 0 秒。只有进程里第一个 suite 付这笔钱，之后的 suite 复用它的 coverable-line 缓存（Mac 上两个 suite 串行 7.5 分钟，第二个 2 秒）；但并发起跑的 suite 在第一个合并完之前都看到空缓存、各付一遍（两个并发超过 10 分钟）。所以 coverage 批次：`--concurrency=1`（`kDistCoverageConcurrency`，worker_run.sh 与本机 worker 都强制）；每台机器一次领走自己的整份（`distChunkBudgetMs(coverage: true)`，不切 4 分钟小批）；批次超时另加 `kDistCoverageProcessCost`（20 分钟，最慢实测的两倍）× 这批在那台机器上拆成的进程数（`DistWorker.processCount`：远端 Windows 按 24000 字符、本机按 6000 字符拆段）。旧版按普通批次 10 分钟超时，两批都在合并途中被杀、lcov 为空。
- **编译检查**（第二轮，`heavy.dart --check-only`）→ `dist_test.dart --build -- <命令>`：`flutter build apk|appbundle|windows|macos`（macOS 只认 `--debug`，那一套签名是 ad-hoc「Sign to Run Locally」，在谁的机器上都能签）与 `gradlew :app:assemble*|:app:bundle*`。命令先过 `distBuildOf` 白名单（`--debug|--profile|--release`、`--split-per-abi`、`--target-platform=android-*`、`--[no-]tree-shake-icons`、`-Ptarget-platform=`），其余一律本机——尤其 `--dart-define`（值可能是秘密）、`-t`（路径）、iOS / ipa（要本机签名）。worker 只取平台合适的（Android 任意、Windows / macOS 只在同平台），先发 `hello` 看 `build=` 列出的工具链（Android：SDK + NDK + cargo-ndk；Windows：带 C++ 工作负载的 VS；macOS：Xcode + CocoaPods），再 lock / push / prepare，然后 shim 新动词 `build <slot> flutter|gradle ...` 交给 `worker_build.sh`。
  - `worker_build.sh` 再按同一白名单校验，缺工具链以退出码 78（`kDistToolchainMissing`）报「没编」而不是红，协调者换下一台；构建带主人的 `prepare.env`（Gradle / CMake 要下载）；输出全写文件、结束后再打印（Gradle / Flutter 的守护进程会继承 stdout 把 ssh 通道挂住），Android 结束后 `gradlew --stop` 不占主人内存。
  - Android 的两道硬门：`app/build.gradle` 要求 release 构建有 `key.properties`，还要求每个目标 ABI 都有 `fushi_compute / rwkv / music / corpus / web_core` 的 `.so`。`.so` 在 worker 上用 `build_android_so.sh` 按 ABI 编、按 crate 源码树哈希缓存；签名用 worker 上 `keytool` 现生成的一次性 key（`dist-check.jks` + 带标记的 `key.properties`，已有不带标记的 `key.properties` 就不碰）。**真 key 永不离开本机**，这也是能把 release 编译检查外包的前提。
  - 只回传构建日志与退出码，产物留在那台机器的 build/ 里（下次增量）。所以 heavy 只在显式 `--check-only` 时外包：没写就是要产物，照旧本机。
  - **远端红 ≠ 代码红**：对方的 SDK / NDK / VS 版本可能和本机不同。heavy 拿到红的编译检查会在本机再编一次，以本机结果为准；绿的直接采信。
  - 主人可在 `limits` 写 `ALLOW_BUILD=0` 关掉编译检查（`hello` 回 `build=off`，`build` 动词拒绝）。
- 仍不外包：要在本机用产物的构建、集成测试（占对方屏幕）、`--update-goldens`（golden 钉平台，只有本机标了 `golden`）、`--merge-coverage` / `--file-reporter` / 分片参数。
- **外包模式的收尾与回退（2026-10-31）**：`--offload` / `--analyze` / `--build` 下，配置缺失 / 无效 / 非 JSON、快照失败、参数被拒、内部异常一律退 75 并打 `DIST OFFLOAD: declined: <原因>`，由 heavy.dart 回本机跑（不再退 64 / 1 判红）；Ctrl-C、SIGTERM 与 `--max-minutes=N`（heavy.dart 传入）都经 `tool/test_flow/dist_stop.dart`：先 abandon prepare、再 `cancel()` 杀远端批次 / analyze / 构建、最后 `finish()` 释放 checkout 锁与租约，然后退 130 / 143 / 124（测试 `test/tools/dist_stop_test.dart`、`test/tools/dist_test_decline_test.dart`）。带 `--name` / `--plain-name` / `--tags` / `--exclude-tags` 时，单批零匹配（退 79 + `done: success` + 无错误）不判红，整次运行仍须 ≥1 条（`distTestFilterActive`，`dist_results_test.dart`）。`--concurrency=N` 给每台 worker 的并发封顶（`distEffectiveConcurrency`）。
- 判定纯函数 `tool/test_flow/heavy_offload.dart`，测试 `test/tools/heavy_offload_test.dart`；构建白名单 `distBuildOf`（`dist_plan_test.dart`）；coverage 校验合并 `tool/test_flow/dist_coverage.dart`（`dist_coverage_test.dart`）；`hello` 判定 `distJobBlocker`（`dist_workers_test.dart`）；shim / worker 脚本契约 `test/tools/dist_shim_test.dart`。

## 第二期实现：朋友机器（`ssh-shim`）

### 形态

- worker 种类 `ssh-shim`：朋友机器上这把 key 在 `authorized_keys` 里钉死成 `restrict,command=` 只能进 `~/.fushi-worker/shim`（即 `fushi/tool/dist_test/worker_shim.sh` 的副本）。协调者发的每个请求都是 shim 的一个动词，拿不到 shell：

  | 动词 | 作用 |
  |---|---|
  | `hello` | 平台、Flutter 版本、核数、空闲内存 / 磁盘、槽位上限、是否暂停（`--status` 用它） |
  | `lock <slot> <runId>` | 抢该槽位 checkout 的整轮锁（同第一期的 `mkdir` 锁 + 心跳 + 15 分钟接管），借种子仓 / 首槽位的对象库 |
  | `git-receive-pack '<work\|work-N>'` | 收快照推送；只认这两种名字，映射到 shim 自己的目录，且必须先 `lock` |
  | `prepare <slot> <sha>` | checkout + clean + `worker_prepare.sh`（只带主人的 `prepare.env`） |
  | `run <slot> <concurrency> [flutter 参数]` | 跑一批，测试文件从 stdin 读（`worker_run.sh` 逐行校验） |
  | `analyze <slot> [--[no-]fatal-*]` | `flutter analyze`，路径从 stdin 读（`worker_analyze.sh` 校验） |
  | `build <slot> flutter\|gradle ...` | 编译检查（`worker_build.sh`），只回日志与退出码 |
  | `kill <slot>` / `finish <slot> <runId>` | 停批次 / 删本轮 ref 并释放自己的锁 |

  请求先过字符集 `[A-Za-z0-9_ ,.:=+-]`（不认引号 / `$` / `;` / 反引号 / 斜杠），再逐参数按模式校验；flutter 参数只认 `--name`、`--name=朴素值` 或紧随其后的朴素值（不能以 `-` 开头），协调者在本机先用同一套规则拒绝（`shimRequest`），不把会被拒的请求发出去。
- 主人侧设置全在 `~/.fushi-worker/`，请求方一个都改不了：`limits`（`MAX_SLOTS` 默认 1、`MAX_CONCURRENCY` 默认核数/2、`MIN_FREE_MEM_MB` 默认 4096、`MIN_FREE_DISK_GB` 默认 20；只按 `KEY=数字` 解析、不执行）、`path`（Flutter / cargo 的 bin，sshd 的非交互 shell 不读 profile）、`prepare.env`（只给准备步骤，如代理）、`seed`（公开仓的裸 clone）、`pause`。因此 `ssh-shim` 配置里出现 `workdir` / `seedRepo` / `path` / `prepareEnv` 直接报配置错误。
- **暂停**：`bash ~/.fushi-worker/shim pause|resume|status`（不经 ssh 直接跑就是主人的开关）。暂停后 `lock` / `run` 回 `busy: paused`（退出码 75），协调者把这台本轮剔除、批次原样退回队列，别的机器接走。正在跑的批次主人可以等它跑完，也可以 `kill`（被当成失联，转给别的机器）。
- **资源上限**：`run` 前看空闲内存，低于 `MIN_FREE_MEM_MB` 回 `busy: low memory`，协调者把批次退回队列、30 秒后再问，连续 20 次仍忙才剔除；`lock` 前看磁盘。`--concurrency` 被钳到 `MAX_CONCURRENCY`，槽位超出 `MAX_SLOTS` 直接拒绝。
- **种子仓**：仓库全历史约 6 GB，首推全量对朋友上行不现实。`worker_setup` 默认 `git clone --bare` 公开仓到 `~/.fushi-worker/seed`，首槽位 checkout 借它的对象库，推送只带种子之后的新提交；次槽位借首槽位。
- **Windows worker**：Windows 的 sshd 默认给 cmd，给不了 POSIX shell，所以 Windows worker 只能是 `ssh-shim`（`ssh-trusted` + `windows` 报配置错误）。`worker_setup.ps1` 写一个 `shim.cmd` 用 Git Bash 起 shim，强制命令指向它（账户 profile 路径不能带空格）。worker 端三个脚本在 Git Bash 下的差异：原生库走 `tool/native_libs.ps1`（自带戳记）；杀进程树按 `/proc/<pid>/winpid` 用 `taskkill /T`；Windows 命令行上限 32767，一批按 24000 字符拆成连续几个 `flutter test` 进程（协调者按 `start` 事件拆段合并，与本机 worker 一致）。`worker_kill.sh` 先停 `worker_run.sh` 本身（`runner.pid`，它的 trap 带走测试树），拆段时不会再起下一段。
- **Windows worker 的退出码会被压成 1**（2026-10-30 实测：同一个未知动词，Mac shim 回 2、Windows shim 回 1；sshd 经账户的 shell 和 `shim.cmd` 起 shim，失败一律成 1）。所以 shim 与 worker 脚本拒活时在 stderr 末行带固定前缀——`busy: `（75）、`error: `（2）、`toolchain: `（78）——stdout 为空的失败由协调者按前缀还原退出码（`distRemoteExitCode`），旧 shim 不重装也成立。此前 wight-win 内存不足回的 busy 被当成三个红批次。
- **超时 / 取消一定杀干净**：`worker_kill.sh` 在发任何信号之前先把 `runner.pid` 与 `run.pid` 两棵进程树整个收集下来（`worker_run.sh` 的 trap 一退出就删 `run.pid`），先 TERM，10 秒后还活着的一律 KILL。flutter tool 在 Dart 里处理 TERM，而 coverage 合并是几分钟的同步循环，TERM 要等它跑完才轮得到（实测超时被杀的批次在 Mac 上又占满一核跑了 30 分钟）。各脚本的心跳用 `touch -c`：锁目录被释放后，残留的心跳也不会把它重建成普通文件、挡住下一轮的 `mkdir`。
- macOS 自带 bash 3.2：worker 端脚本只用 3.2 能跑的语法（无 `mapfile`）。

### 一次性准备（朋友执行）

1. 建专用低权限账户（Windows 普通用户 / macOS standard user，账户名不带空格），装 Git、Flutter（`.fvmrc` 的版本）、Rust（Windows 还要 MSVC 生成工具）；Windows 还要启用 OpenSSH Server。
2. 在该账户下：macOS / Linux `bash worker_setup.sh "<公钥行>"`；Windows `powershell -ExecutionPolicy Bypass -File worker_setup.ps1 -PublicKey "<公钥行>"`。脚本装 shim、写默认设置、克隆种子仓、把公钥以 `restrict,command=` 形式追加进 `authorized_keys`（Windows 同时把该文件 ACL 收到本账户 + SYSTEM），最后自检 `hello`。
3. Tailscale：朋友把这台机器**共享（node sharing）**给你的账号；你的 tailnet ACL 只放行本机 → 这台的 22 端口。验证：从朋友机器 `tailscale ping` / `ssh` 你的本机应当不通（共享是单向的）。
4. 你这边：`ssh-keygen -t ed25519 -f ~/.ssh/fushi_dist_ed25519` 专用一把；`workers.local.json` 加一条 `{"kind": "ssh-shim", "host": "fushitest@<机器>.ts.net", "os": "windows|macos", "identity": "~/.ssh/fushi_dist_ed25519"}`；`--status` 看到 `hello` 输出即通。

### 验证范围（2026-10-25）

- 契约测试：`fushi/test/tools/dist_shim_test.dart` 真跑 shim（注入、越权路径、未加锁的后续步骤、锁的归属、槽位上限、`limits` 不被执行、暂停、内存门槛、flutter 参数），`dist_workers_test` 覆盖配置与 `shimRequest`。
- 端到端（见「实测」）：用一个测试传输（按 sshd 强制命令的方式把客户端命令放进 `SSH_ORIGINAL_COMMAND` 再起 shim）分别在本机 Git Bash（= Windows worker 路径）和真实 Mac（经 ssh，bash 3.2）上跑通 lock → push → prepare → run → 复跑 → finish。
- 实测（2026-10-25，`test/tools` 83 suite + 工作区里 3 个临时探针：必红 / 只在非 shim 机器红 / 以平台原因跳过；探针不入库）：
  - 本机 + loopback shim（Git Bash，全新 checkout）：首次准备 267 s（种子仓让推送秒级完成；大头是四个 Rust crate 冷编译），再跑一轮准备 6 s，两台按速度分到 44 / 39 个 suite，墙钟 3 分 42 秒。复跑分型三种结果（两台都红 / 只在本机红）与平台跳过报告全部按预期出现。
  - 忙与暂停：把 shim 的 `MIN_FREE_MEM_MB` 调到不可能满足，协调者打出 `busy: low memory …; asking again in 30s`，门槛调回后同一批照常跑完、判绿；`pause` 后 `--status` 显示 `paused=yes`，跑一轮时该机在 `lock` 处被剔除，本机独跑判绿。
  - 本机 + 真实 Mac（经 ssh，bash 3.2，复用 `~/fushi-dist/work`）：准备 1 s（缓存命中），Mac 分到 50 个 suite（含两个只能在 macOS 跑的），649 个测试，墙钟 2 分 50 秒；两个红探针在 Mac 上复跑，分型正确。
  - 首推暴露的问题已修：深路径下 Windows 收包撞 MAX_PATH（shim 给 Windows checkout 设 `core.longpaths`）；flutter 参数校验曾放过 `-x`（朴素值不许以 `-` 开头，两端同改，契约测试覆盖）。
- **没验证到的**：真实 sshd 的 `restrict,command=` 生效与 Windows OpenSSH 经 `shim.cmd` 起 Git Bash 这一层（本机按规定不跑 sshd，Mac 上没改 `authorized_keys`）、Tailscale 单向性。朋友接入时按上面第 3、4 步各验一次。

## 第三期实现（部分）

- **红 suite 跨机复跑分型**：主队列跑完后，每个红 suite（有 error 事件或零事件的；整批红又定位不到 suite 时取整批）单独在**另一台机器**（不是同机另一个槽位：同机共享磁盘 / 内存 / 负载，分不出本机伪红）上能跑它的 worker 再跑一次，最快的机器优先，每台串行。报告 `summary.md` 的「Red suites re-run on another machine」逐条写「两台都红 = 真红」「只在 X 红」或「没复跑：原因」。**判绿结论不因复跑改变**，「只在 X 红」仍要按 `docs/agent/fast-workflow.md` 的并发伪红判别分型。红 suite 超过 20 个不复跑（整轮已经坏到复跑解释不了）。worker 在复跑结束后才释放锁 / 租约。
- **平台原因跳过报告**：json 事件里 `skip` 且 `skipReason` 带平台字样（windows / macos / linux / platform / host）的测试列进「Skipped for a platform reason」——这是静态扫描没看到的宿主依赖、覆盖在那台机器上悄悄丢了。**只报告不回写**：宿主依赖按根因修，手工钉选进 `dist_affinity.json` 必须写原因（与第一期的规则一致），所以原设计的 `suite_affinity.json` 自动回写不做。
- 集成测试分流：已做（桌面 Windows / macOS，见文首「集成测试分流」；Android 模拟器 / iOS 不在范围内）。

## 第一期实现（与下文设计的差异以此为准）

### 用法

```
cd fushi
dart tool/dist_test.dart                     # 全量
dart tool/dist_test.dart test/reader         # 子树 / 文件
dart tool/dist_test.dart --workers=self-mac  # 只用部分机器
dart tool/dist_test.dart --status            # 各机器在线 / 版本 / 负载
dart tool/dist_test.dart --dry-run           # 看哪些 suite 只能在哪跑
```

其它 `--flag` 原样传给每个 `flutter test`。末行 `DIST TEST VERDICT: PASSED|FAILED - ...`，退出码 0 才是绿。日志在 `.codex-test/dist/<runId>/`（`summary.md`、每批 `batch-<id>.<worker>.jsonl` / `.stderr.log`、`prepare.<worker>.log`、`timings.<worker>.json`）。

### 文件

入口 `fushi/tool/dist_test.dart`；模块 `fushi/tool/test_flow/dist_{plan,snapshot,workers,results,console}.dart`；worker 端脚本 `fushi/tool/dist_test/worker_{prepare,run,kill}.sh`（随快照推过去，与代码同版本）；配置 `fushi/tool/dist_test/workers.local.json`（`.gitignore`，从 `workers.example.json` 复制）；手工钉选 `fushi/tool/test_flow/dist_affinity.json`。契约测试 `fushi/test/tools/dist_{plan,snapshot,results,workers}_test.dart`。

### 调度：按实测速度动态分块（取代原设计的固定批次）

- 队列里是单个 suite（「放置单元」：同时门控 Windows 与 macOS 的 suite 是两个单元），不预先切批。
- 每个 suite 的权重 = CI 实测耗时 + 每 suite 固定开销 1.5 s（`kDistSuiteOverheadMs`：一个 `flutter test` 进程逐个编译 suite，这笔开销 CI 表里没有，Mac 上实测约 1.5 s/suite）。权重只决定相对大小。
- 每台机器的速度 = 各批「墙钟 / 权重」的指数滑动平均（`DistSpeed`，最新一批权重 0.6）。不用累计平均：队列先发重的、后发小的，小 suite 的固定开销占比高，比值在一轮里会漂（M4 Mac 从 0.26 漂到 0.67），累计平均跟不上，曾让一个「4 分钟」的批跑了 768 s。
- 机器空闲时现切下一批（`distChunkBudgetMs`，guided self-scheduling）：取它能跑的剩余工作 × 它的速度占在线机器速度和的比例 ÷ 2；按它自己的速度换算，限制在 20 s～4 min 墙钟之间；还没测过速度的机器先领 1 分钟的探测批。快机器领得多，收尾时块自动变小，没有尾批比例之类的常数。
- 钉选优先：只有部分机器能跑的 suite 先发；同类里重的先发，收尾都是小 suite。
- 失联 / 超时的批原样退回队列（可能被别的机器以不同切法领走）；测试失败不重试。

### worker

- 种类：`local`（本 checkout，经 heavy 租约整轮持有一个槽位，并发缺省取 heavy 的 4）与 `ssh-trusted`（自己的机器，普通 shell）。`ssh-shim`（朋友机器，强制命令）留给第二期。
- `slots`：同一台机器开 N 个独立 checkout（`work`、`work-2`…，后者用 alternates 共享前者的对象库，原生库按戳记从前者拷），各跑一个 `flutter test`。同一 checkout 里并行两个进程会抢 `build/native_assets`，所以不能共用。**实测 M4 Mac（16 GB）开 3 槽总吞吐反而略低于 1 槽**：瓶颈是每个 suite 单独编译出的上百 MB dill 写盘（磁盘持续 500+ MB/s、5000 IOPS）和换页，所以示例配置是 1 槽；IO 更强的机器再加。
- 远端整轮锁：每个远端 checkout 用 `mkdir .git/fushi-dist/lock` 原子抢占，写入 runId；被占就让这台退出本轮（报 `busy: in use by dist_test run …`），别的机器照跑。`worker_run.sh` / `worker_prepare.sh` 每分钟刷新锁 mtime 作心跳，15 分钟无心跳视为协调者已死、可接管。拿到锁之后才清残留进程。runId 带随机后缀。
- Mac 首次准备：`~/fushi-dist/work` 本身就是推送目标（`refs/dist/<runId>`），`seedRepo`（如 `dev/hibiki`）作 alternates，首推只传增量（实测 85 MB）。pub cache 与 `~/dev/hibiki` 共用。准备步骤按内容哈希记在 `.git/fushi-dist/`，命中即跳过。`prepareEnv`（代理）只给准备步骤，准备时顺手跑一个小测试把 native-asset hook 缓存建好。
- 准备脚本的输出先写远端文件再回显：pub / cargo 留下的后台进程会继承 ssh 通道导致连接永不关闭（实测挂住过）。
- Windows 上远端命令用系统 OpenSSH（`C:\Windows\System32\OpenSSH\ssh.exe`，`FUSHI_DIST_SSH` 可覆盖）：Git for Windows 自带的 msys `ssh.exe` 在 Dart 给的管道上做 select 模拟，长输出会卡死在半行（实测一批卡 10 分钟）。快照推送仍用 git 自己的 ssh。
- 本机 `flutter.bat` 走 `cmd.exe`，命令行上限 8191 字符，本机 worker 把一批拆成多个连续进程（每个 ≤6000 字符路径），事件流按 `start` 拆段合并判绿。

### 环境

- 测试进程不带代理变量（`HTTP(S)_PROXY` / `ALL_PROXY` / `NO_PROXY`），与 CI 一致：本机 shell 里的 `NO_PROXY=127.0.0.1` 会让 ffmpeg 忽略显式 `-http_proxy`，`media_server_mining_relay_test` 因此伪红过。
- **不弹窗**：控制台程序由「没有控制台的进程」启动时会各自新开一个可见窗口抢焦点。dist_test 启动先用 `GetConsoleProcessList` 自检，没有控制台就拒绝运行（`GetConsoleWindow` 区分不了「无控制台」和 agent shell 那种「无窗口控制台」）。所有子进程用默认模式启动、共享这个控制台；守卫测试禁止 detached / `Start-Process` / `start` / `wt`。两轮全量期间的窗口探针没有任何归属于 dist_test 的新窗口；探针抓到的周期性 cmd 窗口来自计划任务 `ClaudeDesktopSessionSync`（每 10 分钟 `cmd.exe /c …pythonw.exe`，上次运行时刻与弹窗吻合）。

### 判绿

- 每批：退出码 0、有 `done: success`、≥1 个测试、交给它的每个 suite 都有 `suite` 事件（零执行算红）。
- `--workers=` 只选部分机器时，只能在没选上的平台跑的 suite 计为「没跑」、整轮判红。
- 平台亲和：测试文件里的 `Platform.isWindows/isMacOS`、`@TestOn`、能力标签（golden / realdata / ffmpeg / chrome）静态扫描钉选；`dist_affinity.json` 只放「宿主依赖在被测代码里、扫描看不到」且**暂时修不了**的 suite，每条写原因；目前为空。宿主相关的红按根因修，不往表里塞。

### macOS 宿主上暴露的测试宿主依赖（2026-10-25 已按根因修）

在 Mac 上跑全量第一次暴露了一批「只在 Windows / Linux 宿主上碰巧绿」的测试，全部按根因修掉，`dist_affinity.json` 清空：

| suite | 根因 | 修法 |
|---|---|---|
| `storage_usage_view_test` | 默认缓存根在 macOS 上调 path_provider `getTemporaryDirectory()`，平台通道回复进不了 FakeAsync | 测试注入缓存根与 docs 归属 |
| `lnreader_cover_image_test`、`app_image_file_service_retry_test`、`app_http_image_proxy_test` | flutter_cache_manager 在 macOS 宿主上选 sqflite 插件仓库，测试进程没有插件 | `AppImageCacheManager.debugRepositoryOverride`，`flutter_test_config.dart` 全套钉 JSON 仓库（= Windows/Linux 原行为） |
| `fushi_desktop_title_bar_subtree_identity_test` | 标题栏按真实宿主分支（红绿灯 / AppKit resize） | `FushiDesktopTitleBar.debugHostPlatform`（默认真实宿主），测试钉宿主并补 macOS 用例；源码守卫同步 |
| `fushi_popup_surface_glass_test` | 原生材质可用性按真实宿主 | 用例钉既有 `debugNativeMaterialHostSupported` |
| `desktop_mini_window_mode_test` | 退出全屏按真实宿主走 macos_window_utils，其方法等一个只有 `main()` 会完成的 completer | `DesktopMiniWindowMode.debugExitFullscreenOverride` |
| `video_mine_queue_dialog_test` | 赌真实目录删除在 100 ms 内完成（Mac 负载下不成立） | 在 root zone 跑 discard 并精确等它完成 |
| `custom_font_weight_css_test` | 验证的是 Chromium WebView（WebView2 / Android）字体栈；macOS 版 Chrome 用 CoreText，与任何产品路径都不对应 | `@TestOn('!mac-os')` 声明适用宿主（扫描器据此钉到 Windows，覆盖不丢） |

### 实测

- 第二轮（2026-10-24，本机 + Mac 3 槽，旧的固定批次）：4532 suite 全跑到、39 793 测试、墙钟 52 分钟；本机 3021 suite / 47.6 分，Mac 1527 suite。收尾被 Mac 最后一个整批拖住。
- 验收轮（2026-10-25，本机 + Mac 1 槽，动态分块）：4532 suite 全跑到、39 797 测试、墙钟 57 分 39 秒；Mac 忙 56 分 08 秒（2055 suite），本机忙 57 分 16 秒（2493 suite），两边几乎同时收尾，最后一批只有十几个 suite。Mac 单槽比上轮 3 槽多跑 35% 的 suite。墙钟比上轮长是因为本机同时被其它会话占满（这一轮 0.73 墙钟/权重）。
- 仍红且与分流无关：本机 5 个起真 Chrome 的阅读器 suite（`highlight_lanes_test` 等），绕开 dist_test 直接跑也红；CI 上 chrome 标签缺 Chrome 时自跳过，所以 CI 没覆盖到它们。

## 目标与边界

把 `fushi/test/` 全量单测（约 4.4k 个 suite，CI 实测串行合计 ≈48 suite-分钟）自动分到多台机器上并行跑，结果汇总成一份与 `tool/flutter_test_failures.dart` 同口径的报告。

机器（所有者 2026-10-24 确认）：

| 机器 | 角色 | 网络 |
|---|---|---|
| 本机 Windows（RTX 5090 那台） | **协调者** + worker | — |
| 自己的 Mac（M4 Air，`shfaifsj@192.168.1.34`） | worker | 局域网，SSH 已通 |
| 朋友的 Windows | worker | 异地，Tailscale |
| 朋友的 Mac | worker | 异地，Tailscale |

已定前提：

- 只做 `fushi/test/` 单元测试；集成测试（`integration_test/`，要真 app / 显示器 / 模拟器）放第二期。
- Windows 与 Mac 的结果合并算一次全量；平台相关的 suite 钉在对应平台跑（见「亲和性」）。
- 朋友的机器随时可派活，但限并发、限内存，朋友随时可一键暂停。
- **连接方向只允许 协调者 → worker**。朋友的机器任何情况下都不能连到本机：本机不开入站端口、不跑 sshd、不做反向转发、不转发 ssh-agent。

## 总体结构

```
本机（协调者）  dart tool/dist_test.dart
   │  1. 打快照提交（含未提交改动，剔除密钥真值）
   │  2. git push 快照 → 各 worker 的裸仓（经 SSH）
   │  3. 按实测耗时切批次，放进按平台分的队列
   │  4. 每个 worker 槽位循环：ssh 领一批 → 跑 → 流式回传 json 事件
   │  5. 汇总、判绿、刷新各机器耗时表
   ▼
 worker：常驻 checkout + pub cache + 原生库缓存，只做 checkout/跑测试
```

协调者是一个 Dart CLI（`fushi/tool/dist_test.dart` + `fushi/tool/test_flow/dist_*.dart`），复用现有部件：

- 切分权重：`suite_timings.json` + `suiteShardWeights`（`tool/test_flow/suite_timings.dart`）；
- 判绿口径：`flutter_test_failures.dart` 的失败过滤与「实际执行数 ≥ min-tests」；
- 本机重活：本机 worker 槽位一律经 `tool/heavy.dart` 租约，与其它会话共享槽位。

## 1. 代码同步：快照提交

worker 必须跑**和本机完全一致**的代码，包括没提交的改动。

1. 用临时索引造快照：`GIT_INDEX_FILE=<scratch>/dist.index`，`git read-tree HEAD` → `git add -A -- . ':!<排除清单>'` → `git write-tree` → `git commit-tree -p HEAD`，得到快照 SHA；不碰真实索引、不动 stash（stash 栈全 worktree 共享）。
2. **密钥真值硬排除**：排除清单 = `git ls-files -v | grep '^S'`（所有 skip-worktree 文件，即 `setup_worktree.ps1` 搬进来的 `google_oauth_secret.dart` / `log_upload_secret.dart` 等）。临时索引里这些文件**没有** skip-worktree 位，不排除的话 `git add` 会把真值加进快照推到朋友机器上——这是本设计最危险的一步，必须有守卫：
   - 协调者推送前对快照逐一核对：排除清单里每个路径在快照树里的 blob 必须等于 HEAD 里的 blob（即入库占位值），不等就中止；
   - 契约测试 `fushi/test/tools/dist_snapshot_secret_guard_test.dart`：临时仓里造一个 skip-worktree 文件写入假真值，断言快照树里仍是占位值（并做变异实测：去掉排除逻辑必须变红）。
3. 推送：每台 worker 有一个裸仓 `~/fushi-dist.git`，`git push <worker> <sha>:refs/dist/<runId>`。增量推送，平时只传几十 KB；首次用 `git bundle` 离线带过去或让 worker 直接从 GitHub clone（Mac 经代理拉大增量会断，见 CLAUDE.local.md，首次走局域网推）。
4. worker 常驻 checkout `~/fushi-dist/work`：`git checkout --detach --force <sha>` + `git clean -fdx -e .dart_tool -e build -e native/*/prebuilt`，保留缓存。跑完删 `refs/dist/<runId>`，裸仓定期 `gc`。
   - **每次 push 同时强推 HEAD 到常驻的 `refs/dist/base`**（`distPushRefspecs`，2026-10-30）：receive-pack 只公布 ref、不公布 batch 用的 detached HEAD，跑完又删了 `refs/dist/<runId>`，于是下一次 push 找不到共同历史、把整个仓库历史重发一遍——实测 wight-win 一次 push 596 秒，比 analyze 本身还慢。`refs/dist/base` 跨运行保留，push 只传增量；`finish` 只删运行自己的 ref，旧 shim 不用重装。测试 `dist_snapshot_test.dart` 按发送端 `Total N` 计数（接收端会把小包解包并静默丢掉已有对象，数对象数看不出来）。prepare 日志每步带耗时（`== push (exit 0, 596s)`），慢在哪一步直接可见。
   - **Windows 编译检查的插件链接**（2026-10-30）：CMake 经 `windows/flutter/ephemeral/.plugin_symlinks` 下的链接找每个插件。wight-win 上 worker 的 ssh 会话里，**原生程序穿不过任何重解析点**——flutter 建的目录符号链接、手建的 junction 都不行（Git Bash 自己解析链接所以看得到；`cmd dir` 报找不到；CMake 报 18 个插件目录不存在）。这是机器环境问题，远端查不到更深，需机器主人在该账户下排查（安全软件过滤驱动、sshd 登录令牌等）。处理：`worker_build.sh` 构建前建一个 junction 再用 cmd 穿过它，不通就以 78（`toolchain:`）退出——换机或回本机，不当红构建，也不白编一遍再本机复核。探测通过后跑 `plugin_junctions.dart`，按 `.flutter-plugins-dependencies` 把每个 Windows 插件重建成 junction：flutter 只在依赖文件变化时才重建链接，指向别的 pub cache 的旧链接会一直留着；目录符号链接还要开发者模式 / 特权，junction 不要。旧链接用 `rmdir` 删（只删链接、不碰目标）。测试 `dist_plugin_junctions_test.dart`（仅 Windows）。prepare 的 `ready` 行带脚本自身耗时：wight-win 上脚本 5 秒，其余约 60 秒是 shim 端 checkout / clean。

## 2. worker 环境

每台 worker 一次性准备（脚本 `tool/dist_test/worker_setup.ps1` / `worker_setup.sh`，在 worker 上由其所有者执行）：

- Flutter **3.47.6**（与 `.fvmrc` 一致；协调者每次领活前比对 `flutter --version`，不一致拒绝派活）；
- Rust 工具链（编 `fushi_compute` / `fushi_fsrs` / `fushi_web_core` / `fushi_rwkv` 四个测试硬依赖）；
- 专用低权限账户 `fushitest`（Windows 为普通用户，Mac 为 standard user），所有文件只落它的 home。

每轮跑之前 worker 侧的「准备」步骤，按内容哈希缓存，命中就跳过：

| 步骤 | 缓存键 | 未命中耗时（估） |
|---|---|---|
| `flutter pub get --enforce-lockfile` + `ci/apply-patches.sh` | 全部 `pubspec.lock` + `ci/patches/` 哈希 | 1–2 分钟 |
| 原生测试库 | 各 `native/fushi_*/` 源码树哈希（同 `tool/native_libs.ps1` 的判据） | 首次 5–10 分钟，之后增量 |

准备失败的 worker 本轮直接退出队列，批次由其它机器接走；报告里写明哪台、为什么。

## 3. 调度：动态批次队列

不用静态 `--file-shard=i/N`：四台机器快慢不一、朋友的机器可能中途离线，静态切分会被最慢的一台拖住。

- **批次**：按 `suite_timings.json` 的耗时，把 suite 依 LPT 顺序（重的在前）装成约 3 suite-分钟一批（约 40–80 个文件）。每批是一次 `flutter test --no-pub --reporter json <files...>`，摊薄每次进程启动与编译预热的固定开销；批太小开销占比高，太大尾部不均。批大小是参数，首轮实测后定。
- **槽位**：每台 worker 配 `slots`（同时跑几个 `flutter test` 进程）。每个槽位是协调者里的一个循环：从自己能接的队列取一批 → 一次 ssh 执行 → 读回 json 事件流 → 取下一批。快机器自然多领。
- **亲和性**（「平台相关的钉住」）：每个 suite 算出可跑的平台集合，进对应队列：
  - `@TestOn(...)` / `onPlatform:` / 文件内 `Platform.isWindows` / `isMacOS` / `isLinux` 门控（静态扫描，约 200 个文件）→ 只进对应平台队列；同时门控两个平台的文件在两个平台**各跑一次**；
  - `golden` 标签 → 只进参考平台（本机 Windows）；
  - `realdata` 标签（要本机真素材）→ 只进本机；
  - `ffmpeg` / `chrome` 标签 → 只进声明了该能力的 worker（worker 配置里 `capabilities`，准备阶段实测 ffmpeg / node+Chrome 能起才算）；
  - 其余 → 公共队列，任何 worker 都能接。
  - 静态扫描会漏：汇总时若某 suite 的 skip 原因带平台字样（json 事件里的 `skipReason`），记进 `tool/test_flow/suite_affinity.json`（入库，下次直接钉），报告里列出来。
- **掉线与超时**：ssh 断开或单批超过「预估耗时 × 3 + 5 分钟」→ 杀掉该批（按进程树）→ 原样放回队列头，换机器重跑；同一批连续在两台机器上失联才判失败。只对**失联**重派，测试失败不重试（见下）。
- 尾部：队列空了以后，仍在跑的批次不复制推测执行（会白占朋友的机器），由它跑完。

## 4. 判绿与失败分型

- 绿 = 所有批次退出码为 0 **且** 汇总执行数 ≥ 本轮预期 suite 里的测试数下限 **且** 每个排进队列的 suite 都有 `suite` + `done` 事件。任何 suite 没有结果（零执行）一律算红，不能被当成通过（BUG-1157 同一个坑）。
- 测试失败**不自动重跑掩盖**。失败的 suite 在汇总后自动在**另一台同平台机器**上单独再跑一次，只用于分型、不改变结论：
  - 两台都红 → 真红；
  - 只在一台红 → 报告标「仅 <机器> 红」，附两份输出，留给人 / reviewer 按 `docs/agent/fast-workflow.md`「并发伪红判别」分型。本轮结论仍是红。
- 报告落 `.codex-test/dist/<runId>/`：`summary.md`、每批原始 json 事件、每台机器的准备日志。终端只打总表和失败清单。

## 5. 耗时表与机器速度

- 汇总后用各批 json 事件里的 suite 耗时刷新本地的 `tool/test_flow/suite_timings.local.json`（不入库，按机器分列）；切批时用「该 suite 在目标机器的实测值」，没有则用 CI 值 × 该机器的速度系数（系数 = 该机器所有已测 suite 的中位比值）。
- 入库的 `suite_timings.json` 仍只由 CI 事件刷新（`update_suite_timings.dart`），不混入个人机器数据。

## 6. 朋友机器的资源约束

- 默认 `slots: 1`，每个 `flutter test` 带 `--concurrency=<n>`（默认 `n = 逻辑核数 / 2`），内存封顶沿用 `heavy_budget.dart` 的判据：worker shim 领活前读空闲内存，低于阈值就回「忙」，协调者把该批让给别人，30 秒后再问。
- **朋友侧暂停开关**：worker 机上 `~/.fushi-worker/pause` 文件存在即拒绝领活（shim 第一步检查）。朋友不需要懂任何东西，建个空文件或跑 `fushi-worker pause` 即可；正在跑的批次被他 kill 掉会被当成失联，自动转给别的机器。
- 只在 `fushitest` 账户下跑，不装服务、不开机自启；工作目录与缓存总量设上限（默认 30 GB），超出时清最旧的缓存。

## 7. 安全模型（重点）

威胁有两个方向，分别处理。

### 7.1 保护本机（朋友的机器不能碰到你的电脑）

- **网络单向**：朋友在**他自己的** Tailscale tailnet 里，用 Tailscale 的「共享机器（node sharing）」把他的两台机器分享给你的账号。共享是单向的：你的设备能连被共享的机器，被共享的机器连不进你的 tailnet。不要让朋友加入你的 tailnet，也不要反过来共享本机。在你 tailnet 的 ACL 里再加一层：只允许本机访问共享进来的那两台的 22 端口。
- **本机不开任何入站**：不装 / 不启用 sshd，不做 `ssh -R` 反向转发；协调者生成的 ssh 命令统一带 `-o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no`，并在 `~/.ssh/config` 对这两台写死同样的选项。**ssh-agent 转发是最容易被忽略的口子**：一旦转发，朋友机器上的管理员能借你的 agent 以你的身份登录你的其它机器 / GitHub。
- **专用密钥**：给分流单独生成一把 `~/.ssh/fushi_dist_ed25519`，只用于这两台，不复用你登录 GitHub / Mac 的那把。泄露最坏只影响这两台 worker。
- **不带出任何秘密**：快照剔除密钥真值（第 1 节守卫）；ssh 不传环境变量（不设 `SendEnv`），协调者不把 `HTTPS_PROXY` 等本机配置传过去；worker 侧测试只用入库占位值，与 CI 一致。
- **回传内容是不可信数据**：worker 回来的只有 json 事件流与日志文本（`--coverage` 时事件流里多一行 base64 的 lcov 文本，按 7.1 同样当数据校验：只收该包 `lib/` 下的记录，不按其中路径写任何文件）。协调者严格按 json 解析，只读字段、不执行回传内容中的任何命令或路径；写报告时路径一律落在 `.codex-test/dist/<runId>/` 之下（拒绝 `..`）。

### 7.2 保护朋友（你只能在他机器上做「跑测试 / analyze / 编译检查」这几件事）

- 朋友的 `fushitest` 账户 `authorized_keys` 里这把 key 写成：
  `restrict,command="~/.fushi-worker/shim" ssh-ed25519 AAAA... fushi-dist`
  `restrict` 关掉端口转发 / agent / X11 / pty；`command=` 强制所有连接只能进 shim。
- shim（`tool/dist_test/worker_shim.sh` / `.ps1`，朋友装之前可以通读，脚本很短）只认几个动词，参数逐个校验：
  - `hello` → 回报平台、Flutter 版本、核数、空闲内存、能力、是否暂停；
  - `git-receive` → 只允许 `git-receive-pack '~/fushi-dist.git'`（推快照）；
  - `prepare <sha>` → checkout + pub get + 原生库（只在 `~/fushi-dist/` 内）；
  - `run <sha> <batchId>` → 从 stdin 读文件清单，每行必须匹配 `^test/[A-Za-z0-9_/.-]+_test\.dart$` 且文件存在，然后跑 `flutter test`，stdout 回 json 事件；
  - `cleanup <runId>`。
  其它一律拒绝。你拿到这把 key 也开不了 shell。
- 编译检查（2026-10-30 第二轮加入）与跑测试是同一级别的信任：测试本来就在朋友机器上执行仓库里的任意代码，Gradle / CMake 构建脚本也是仓库里的代码。它**不**扩大到「朋友产出的二进制在你电脑上运行」：产物从不回传，回来的只有日志文本和退出码；release 签名用 worker 上现生成的一次性 key，真 key 不出本机。主人可用 `ALLOW_BUILD=0` 关掉。
- 需要明说的残余风险：测试代码本身就是你仓库里的任意 Dart 代码，shim 管不住测试里写了什么。朋友在给你跑代码，信任关系是「朋友信任你提交的代码」；专用低权限账户把影响限制在 `fushitest` 的 home 里。

### 7.3 自己的 Mac

已有 `shfaifsj@192.168.1.34` 免密登录，是你自己的机器，不走 shim，协调者直接 ssh 执行同样的步骤。但仍用快照剔除密钥（规则统一，不为自己的机器开例外），并遵守 CLAUDE.local.md 里的 PATH 拼法（非交互 ssh 不读 `~/.zshrc`，`$HOME/flutter_3.47.6/bin` 放最前）。

## 8. 配置

`fushi/tool/dist_test/workers.local.json`（`.gitignore` 排除，只在本机）：

```json
{
  "workers": [
    { "name": "self-win", "kind": "local", "os": "windows", "slots": 2, "capabilities": ["ffmpeg", "chrome", "golden", "realdata"] },
    { "name": "self-mac", "kind": "ssh-trusted", "host": "shfaifsj@192.168.1.34", "os": "macos", "slots": 2,
      "path": ["$HOME/flutter_3.47.6/bin", "/opt/homebrew/bin", "$HOME/.cargo/bin"] },
    { "name": "friend-win", "kind": "ssh-shim", "host": "fushitest@friend-win.<tailnet>.ts.net", "os": "windows", "slots": 1,
      "identity": "~/.ssh/fushi_dist_ed25519" },
    { "name": "friend-mac", "kind": "ssh-shim", "host": "fushitest@friend-mac.<tailnet>.ts.net", "os": "macos", "slots": 1,
      "identity": "~/.ssh/fushi_dist_ed25519" }
  ]
}
```

用法：

```
cd fushi
dart tool/dist_test.dart                 # 全量
dart tool/dist_test.dart test/reader     # 只分流某个子树
dart tool/dist_test.dart --workers=self-win,self-mac
dart tool/dist_test.dart --status        # 各 worker 在线 / 暂停 / 版本 / 缓存
```

## 9. 预期收益（估算，需实测）

- 串行合计 ≈48 suite-分钟（CI Linux 口径）。本机单跑全量时编译 + 加载是大头，四台机器有效并行后，理想情况在 **8–12 分钟**（每台约 1/4 工作量 + 每台 1–2 分钟固定开销 + 跨网尾部）。朋友机器的速度和上行带宽决定最后能压到多少，第一期跑完用实测替换这里的估算。
- 只改了一个子树时直接 `dist_test.dart test/<子树>`，批次少于 worker 数时自动只用最快的几台。

## 10. 分期

1. **第一期：本机 + 自己的 Mac**（都在局域网、都是自己的机器）。实现快照 + 推送 + 准备缓存 + 动态队列 + 亲和性 + 汇总判绿，跑通全量并拿到两台机器的真实耗时与速度系数；契约测试：快照密钥守卫、批次切分覆盖（并集 = 全部 suite、无重复）、亲和性扫描、json 事件汇总（含零执行判红）。
2. **第二期：接入朋友的两台**。worker_setup 脚本、shim、Tailscale 共享 + ACL、暂停开关、资源上限；用 `--status` 和一次子树分流验证，再跑全量。
3. **第三期**：失败分型的跨机复跑、`suite_affinity.json` 自动回写、按需加入集成测试（单独设计）。

## 待实测确认

- Windows OpenSSH 会话里跑 `flutter test`（无桌面会话）是否有个别单测依赖窗口站 / 字体服务；有就记进亲和性钉回本机。
- Tailscale 共享机器的单向性在你和朋友的实际账号上验证一次：从朋友机器 `tailscale ping` / `ssh` 你的本机应当不通。
- 每批进程固定开销（启动 + 编译预热）的真实值，决定批大小。

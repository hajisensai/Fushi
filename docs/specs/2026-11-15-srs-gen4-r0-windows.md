# SRS 协议 4 换代 R0：Windows 真二进制新旧互拒与升级实测（2026-11-20）

规划 `2026-11-15-srs-gen4-g7-g11-plan.md` §6「R0 实测（D2 的版本 × 平台）」的 Windows 部分。只做 Windows 本机，
**Android / macOS / iOS 真机、Linux 服务端、fushi_server beta 都没做**（见文末「缺口」）。

## 1. 被测二进制

| 角色 | 版本 | 来源 | sha256 |
|---|---|---|---|
| 旧（协议 3，最新正式版） | v3.3.0（3.3.0+1368，提交 a2638e03） | Release `v3.3.0` 的 `fushi-3.3.0-windows-setup.exe`，innounp 解包，不运行安装器 | 安装包 `7fcf9d90…88ee`；`fushi.exe` `eb5e5177a809f787d57f416190af1af8803805498a06a0a187f6e96af894c842` |
| 旧（协议 2 之前，D2 点名） | v3.0.1（3.0.1+1356，提交 185dcfdd） | Release `v3.0.1` 的 `fushi-3.0.1-windows-setup.exe`，同上 | 安装包 `bb565de7…b495`；`fushi.exe` `9340f5fb7ef624a5d1174dbc156e49c98a3f6f74393e9614b3489a07dff555cf` |
| 新（协议 4） | 集成分支 `pr/srs-gen4-switch` `0bf8472f40`（产品代码；本分支只加了实测工具与 itest） | 本 worktree `dart tool/heavy.dart -- flutter build windows --release --no-pub`（exit 0，1911 s） | `fushi.exe` `1f64d2bb8edf6422131211ee7dd7ca7c0c27cc57dd07c1f8d072a762c5d6e36f`；主库 schema 159、`srs4.db` schema 40024 |

安装包 sha256 与 `tool/srs_old_binary/versions.json` 钉死的一致（`srs_old_binary.py fetch` 校验过）。下载物放
`D:/fushi-r0/versions/<版本>/`，只运行解出的 `fushi.exe`。

## 2. 隔离与驱动

- 每个进程独立数据根：`FUSHI_TEST_ROOT`（release 包也认，`fushi/lib/src/startup/test_environment.dart`）+ `APPDATA` /
  `LOCALAPPDATA` / `TEMP` / `USERPROFILE` / WebView2 / `FUSHI_CTL_DIR` 全部指到运行目录（`tool/srs_old_binary` 的 `App`）。
  `FUSHI_TEST_HIDDEN=1` 离屏、跳过单实例守卫。本机真实用户库 `D:/APP/HIBIKI_date` 没碰过。同一时刻只跑一个实例，
  收尾按 PID（控制通道 `/api/admin/app/quit`，超时只结束本缓存二进制 / 本 worktree 构建目录下的进程）。
- 驱动：
  - `tool/srs_old_binary/r0_win.py`：数据根跨进程保留，按 JSON 步骤表调控制通道，记录前后 `app-support/` 顶层每个文件的
    sha256、抹掉 SQLite 头 24–27 / 92–95（规划 D3 批准的已知例外）后的 sha256、主库 `PRAGMA user_version`、`srs.db` /
    `srs4.db` 的 `srs_meta` 与逐表行数。
  - `tool/srs_old_binary/srs_old_binary.py`（既有装置）：`seed` / `run --action sync-location|restore-backup`，本分支给 `run`
    加了 `--exe`（新版本对旧输入跑同一套动作）。
  - `fushi/integration_test/srs_gen4_r0_migrate_itest.dart`（Windows 离屏 runner，焦点驱动）：新版本经界面迁移。
- 截图：离屏 release 窗口的 `PrintWindow` 抓回来是全黑（`D:/fushi-r0/runs/20261118-102437-r0-explore2/shots/`，与
  run-fushi 技能文档一致），所以 release 进程的证据是控制通道回应 + 库文件；真像素只有 itest 的 `captureFlutterFrame`。
- 证据目录：`D:/fushi-r0/runs/<时间>-r0-<格>/evidence.jsonl`（r0_win）、`D:/fushi-r0/runs/<时间>-<动作>/`（装置）、
  `D:/fushi-r0/M/*.log|*.json`（摘要）、`fushi/.codex-test/windows-itest/r0-*/`（itest）。均不入库。

## 3. 种子数据

`D:/fushi-r0/A/old-root-pristine`：v3.3.0 自己建的数据根（2026-11-18，`A1-old-seed`）：控制通道 `anki/mine` 制 6 张卡
（猫 犬 鳥 魚 馬 牛），经互联主机的远程复习端点 `answerAndStudy` 真作答两轮共 12 次。`srs.db` schema 26，
`srs_cards_cache` 6 行、`srs_review_logs` 12 行，主库 schema 146，sha256 `2cc51c40…c09c`。同时导出整包备份
`D:/fushi-r0/A/old-backup.zip`（appVersion 3.3.0、schemaVersion 146，sha256 `af132156…78af6`）。

## 4. 结果矩阵

（见下各节；「✔」= 符合规划要求，「✘」= 缺陷，「—」= 没做到，写明原因）

### 4.0 总表

| 格 | 内容 | 结论 | 证据 |
|---|---|---|---|
| (a) | v3.3.0 建库 / 制卡 / 复习 → 新版本迁移 | ✔ 数据：6 卡 / 12 日志逐卡逐条一致；✔ 迁移页 / 进度页 / 迁移后复习页 debug 真像素（复核轮 `r0-a-zone4`）；转圈的原因证实是 itest 的错误 zone 错位；— release 迁移页像素仍没有；✔ 第二轮复核：开了焦点导航后 Tab 走到「开始升级」、Enter 开始迁移（`r0-a-focus`；复核轮走不到是 itest 没开焦点导航开关） | `r0-a-migrate3`、`r0-a-zone4`、`r0-a-focus`、`D:/fushi-r0/M/a3-compare-v2.json` |
| (a2) | 新 release 只打开旧根、不迁移 | ✔ SRS 不动；✘?（规划外）主库被升到 159，见 (c0) | `20261120-124602-r0-a2-new-first-open` |
| (b) | 迁移后旧版本再打开 | ✔ 显式拒绝、不写（SRS 层字节比对，只有 D3 例外字节） | `20261120-142928-r0-b1-v330-swap`、`20261120-143005-r0-b2-v301-full` |
| (c) | 迁移途中硬结束 | ✔ 提交前硬结束：旧库字节不变、v3.3.0 照常可用（SRS 层），新版本重开后重新迁移、逐卡一致 | `r0-c-kill2`、`20261120-144625-r0-c1-v330-killed`、`r0-c-resume` |
| (c0) | 新版本打开过的根，旧版本再开 | 旧版本整个 app 起不来（主库 schema 159 > 146 / 118），SRS 文件不动 | `20261120-124632-r0-c0-old-after-new-open`、b2 |
| (d) | 文件夹位置三态 | ✔ 只有旧 → 新加入；✔ 两代都有 → 旧版本不动目标；✔ 只有新 → 旧版本不动目标；— 旧版本的提示文字没看到像素 | `D:/fushi-r0/M/d/*.json` |
| (e) | 备份四个方向 | ✔ 新备份 → v3.3.0 / v3.0.1 拒绝；✔ 旧备份 → 新（合并）按设计要用户确认；✘→✔ 旧备份 → 新（覆盖）卡片 ID 与日志脱钩，复核轮按根因修了（BUG-4989），修后 release 重跑 6/6 卡、12/12 条日志逐条一致；— `.fushisrs` 四向没有自动化入口 | `D:/fushi-r0/M/e1-*.json`、`e2.json`、`e1r-fix-compare.json` |

### 4.1 (a) 旧版本数据 → 新版本迁移

- 驱动：`srs_gen4_r0_migrate_itest.dart`（debug 构建，Windows 离屏 runner），种子 `A/old-root-pristine/app-support` 原样拷进隔离根。
  `heavy.dart -- run_windows_itest.ps1 … -RunId r0-a-migrate3`，exit 0（ran 289 s）。
- **迁移页没出来**：复习页在 90 s + 作废列表后再 30 s 里一直转圈。探针（`isolated-root/app-documents/srs_r0_probe.txt`）：
  `srsStorageProvider` / `srsStoreProvider` 状态都是 `AsyncError(SrsStoreNotMigrated(needsMigration))`、`isLoading=false`，
  牌组列表 `AsyncLoading`；三个 provider 的 `.future` 5 s 内都不完成；`error_log.txt` 有 7 条 `UncaughtZone SrsStoreNotMigrated`
  （`SrsCore.openInBackground` 的 isolate 错误）。状态已是错误、`.future` 却不完成、同时报 UncaughtZone，符合「Future 的错误跨不过
  error zone 边界」：itest 的测试 zone 与 app 的 `runZonedGuarded` zone 混用。佐证：同一类数据根（`M/a`、`M/v`）用 **release 包**
  打开并导航到复习页 45 s，错误日志里 0 条 UncaughtZone。provider 链本身单测无误：新增
  `fushi/test/srs/srs_deck_list_not_migrated_test.dart`（4 例：先读库 / 修订号跳的组合），库报要迁移时牌组列表 10 s 内以
  `SrsStoreNotMigrated` 落定（exit 0，+4）——它只说明**单 zone 下** provider 链能落定，复现不了 itest 里的转圈，不能当「判为环境问题」
  的依据。第一轮的结论「判为 itest 环境问题」当时**未证实**（复核意见），复核轮补了判别实验（下一条）。
- **复核轮判别（`r0-a-zone2` / `r0-a-zone3` / `r0-a-zone4`，同一份种子，debug itest，各 exit 0、实际执行 1 条用例）**：假设是存储 / store
  两层由 app 启动时在 `main.dart` 的 `runZonedGuarded`（错误 zone A，常驻装配 `srsAppRuntimeProvider` 的 `readStore`）里先建，缓存的
  `.future` 落在 A；itest 的 binding 在测试文件 `main` 里初始化，帧回调（复习页 / 牌组列表 build）跑在另一个错误 zone，Dart 的错误不跨错误
  zone 投递，帧 zone 里 await 那个已失败的 future 永远等不到、错误按 A 的未捕获错误记日志（`UncaughtZone`）。实验：90 s 转圈、三个 `.future`
  5 s 都超时之后，**在帧回调里**走复习页错误态「重试」同一条作废（`retrySrsStoreOpen` 的口径：只作废失败的存储 / store 两层），重建出的
  future 落在帧 zone。结果三轮都一样：作废后迁移页随即出现（`after frame-zone retry: found=true`，牌组列表从 `AsyncLoading` 变成
  `AsyncError(SrsStoreNotMigrated)`），屏上文字「复习库升级 | 这个版本用新的格式保存复习数据。升级会把现有的卡片和复习记录转换过去；
  旧库会原样封存保留，不会删除任何东西。 | 开始升级」。同一份数据、同一个 provider，只换了 future 建在哪个 zone，转圈就消失——**假设成立**。
  正式版 binding 在 zone A 里初始化，帧回调也在 A，不存在这个错位；但这是由机制推出的，**release 上的迁移页像素 / 界面状态仍没直接看到**
  （见下「release 取证」）。
- 真像素（`fushi/.codex-test/windows-itest/r0-a-zone4/screenshots/`）：`r0-01-prompt.png` 迁移页（进场动画中，按钮与图标已出现）、
  `r0-02-progress.png` 进度页（「复习库升级 / 正在升级，期间可以继续使用其他功能。/ 1/10 检查剩余空间 / 最后一步之前都可以取消，取消后一切
  保持原样。/ 取消」）、`r0-03-after.png` 迁移后复习页（6 张待复习、保持率 83%、近 30 天 12 次复习）。迁移 `@62ms running → @275ms parity
  → @398ms committed`，`status after: state=ready`；`error_log` 里 6 条 `UncaughtZone SrsStoreNotMigrated` 都是作废之前的 zone A 打开。
- **「开始升级」的键盘可达性（复核轮没走到，第二轮复核查清并重跑）**：
  - 复核轮现象（`r0-a-zone2` / `zone3` / `zone4`）：Tab 发了 60 次（每次 `sendKeyEvent` 都送达），焦点始终停在同一个无标签 `Focus` 上
    （祖先 `_ActionsScope < Actions < PopScope < ValueListenableBuilder<bool> < HomeSyncExitScope < BackdropGroup …`），按钮
    `FilledButton enabled=true`、`canStart=true`、主库开着；`zone4` 改调按钮的 `onPressed`。当时文档写的「`FocusDriver.requestFocusInside(按钮)`
    也拿不到焦点」**不能当可达性证据**：这个辅助函数只认显式传了 `focusNode` 的 `Focus`，Material 按钮的焦点节点是按钮内部自建的、`Focus`
    widget 上没有，所以它在按钮子树里一个节点都找不到、退去请求祖先节点——拿不到焦点是辅助函数自己的限制造成的假象，与产品无关。
  - 根因（第二轮复核，沿真实代码路径）：那个无标签 `Focus` 是 `HomePage` 的整页键事件 sink（`home_page.dart` 的 `_keyboardFocusNode`，
    `autofocus: true` + `skipTraversal: true`）。焦点停在它上面不动，是因为**实验「键盘/手柄焦点导航」开关默认关着时**，
    `global_navigation.dart` 的 `wrapWithGlobalNavigation` 把裸 Tab / Shift+Tab 中和成 `DoNothingIntent`（用户裁定 TODO-112：没开焦点导航时
    按 Tab 不该有动作）。itest 每次跑在全新隔离根上、偏好恒为默认，而本 itest 自己手写 `sendKeyEvent(tab)`、没先调
    `enableFocusNavigation(tester)`——与 BUG-1106 同根因；手写 Tab 也绕过了守卫 `itest_focus_navigation_prerequisite_guard_test.dart`
    （它只扫 `FocusDriver` 的 `reachAll` / `focusUntil` / `focusWidget`）。**结论：itest 的问题，不是迁移页 / 桌面键盘用户的可达性缺陷。**
    `HomePage.debugSelectTab` 换页与焦点进不进内容无关。
  - 产品侧钉住：新增 `fushi/test/srs/srs_generation_view_keyboard_test.dart`（与 `main.dart` 同构：`wrapWithGlobalNavigation` 包
    `FushiFocusRoot`，页面外套首页那样的 `autofocus` + `skipTraversal` 整页 sink），MD3 / Apple 各两例：开了焦点导航，Tab 从 sink 走到
    「开始升级」、Enter 开始迁移（`runs` 1 次）；没开（默认），Tab 一步不动、焦点留在 sink。4/4 通过；变异实测见交接文档第二轮复核节。
  - itest 改成真的焦点驱动：先 `enableFocusNavigation(tester)`，再 `FocusDriver.focusWidget(开始升级)` + `activate()`（Enter），删掉
    `onPressed` 兜底与 `requestFocusInside` 兜底，走不到就 `expect` 失败（现在也在上面那条守卫的扫描范围里）。重跑 `r0-a-focus`
    （同一份种子 `A/old-root-pristine/app-support`，`heavy.dart -- run_windows_itest.ps1 … -RunId r0-a-focus`）：runner exit 0、
    `+1: All tests passed!`（实际执行 1 条用例）。探针：`focus traversal -> onStart=true … focusOwners=_ActionsScope < Actions <
    _ParentInkResponseProvider < _InkResponseStateWidget < InkWell …`（焦点在按钮的 InkWell 上）→ `pressing Enter` →
    `@382ms phase=committed` → `status after: state=ready`；迁移后屏上文字「6 张 · 新卡 0 · 已掌握 2 | 6 待复习 | 83% 保持率 | 近 30 天 12 次复习」。
    真像素 `fushi/.codex-test/windows-itest/r0-a-focus/screenshots/r0-01-prompt.png`、`r0-03-after.png`；6 卡迁移约 0.4 s，Enter 之后那一帧
    pump 里迁移已经做完，这一轮没抓到进度页（进度页像素见 `r0-a-zone4`）。迁移页仍需「帧回调里重试」才出来（上一条，itest 的 zone 错位）。
  - 另：第一轮 `r0-a-zone` 在 `FocusDriver.focusWidget` 后一言不发挂了 18 分钟（被我按 PID 结束），当时同样没开焦点导航，遍历必然耗尽；
    挂住推测是 `expect` 失败后 live binding 收尾卡住，没再复现（`r0-a-focus` 遍历成功，没走到失败分支）。
- **release 取证**：复核轮试过用 UI Automation 读离屏 release 窗口的无障碍树（`20261120-153615-r0-ui2-release-prompt-view`），
  Flutter 视图只回窗口外壳 1–2 个节点、没有语义子树，取不到界面状态，工具没有入库。release 的迁移页仍只有控制通道证据（500 / 422），留缺口。
- 迁移改走按钮背后的同一个入口 `SrsGen4MigrationController.start()`（`FUSHI_R0_FALLBACK_START=true`），探针：
  `@47ms running → @258ms precondition → @366ms committed`，`status after: state=ready`。迁移后复习页（真像素
  `r0-a-migrate3/screenshots/r0-03-after.png`）：今日 6 张待复习、Default 牌组 6 张 · 已掌握 2、保持率 83%、近 30 天 12 次复习。
- 逐卡比对：`python -I tool/srs_old_binary/r0_compare.py --old A/old-root-pristine/app-support --new <隔离根>/app-support`
  exit 0：`old_cards 6 = new_cards 6`、`old_logs 12 = new_logs 12`、`diffs []`；比的列是 queue / due_day / due_at /
  scheduled_days / reps / lapses / stability / difficulty / last_reviewed_at / deck_id / suspended / note_id 与每卡日志条数。
  新代把带 profile 盐的内置派生 ID 规范化（`alias_ix` 15 行，卡片 6 条 how=2、其余 how=1），比对前经 `alias_ix` 换算（`aliased 30`）。
  **复核轮重比**（`r0_compare.py` 补了两处：换算前记旧卡行数 `old_cards_raw`、两张旧卡换到同一规范 ID 报 `collision` 不再被
  dict 覆盖吞掉；每张卡逐条比日志 `(日志 ID, 时间, 评分, 用时)`，新库取派生的 `stats` 表——`log_ix` 不带评分。单测
  `tool/srs_old_binary/r0_compare_test.py` 4 例，`python -I` 跑 `Ran 4 tests … OK`；拿上一版比对器跑同一份单测 1 失败 2 错误）：
  同一份 `M/a3` 重比 exit 0：`old_cards_raw 6 = old_cards 6 = new_cards 6`、12/12 条日志逐条 ID / 时间 / 评分 / 用时一致、
  `diffs []`（`D:/fushi-r0/M/a3-compare-v2.json`，`aliased 36`：比上次多的 6 次是旧库逐条日志按卡分组时的卡片 ID 换算）。
- 迁移提交后 `controller.outcome` 为 null（探针 `finished … phase=committed outcome=null`）**不是缺陷**：
  `SrsGen4MigrationController.outcome` 的契约就是「提交以外的结论」（`fushi/lib/src/srs/srs_gen4_migration_controller.dart`
  `outcome` 的文档：没开始 / 放弃 / 取消 / 空间不够），`start()` 在 `committed` 分支只调 `onCommitted()`（重开存储）、置
  `phase=committed`，复习页随即换回正常内容，迁移页（`srs_generation_view.dart` 读 `outcome` 只为显示失败原因）不再显示。
  迁移报告 `srs4-migration-report.json`：`profileVerdict pass`，日志新旧 12/12、带日志卡 6/6，`knownDifferences.total 0`。
- 迁移后 `srs.db` 封存：`srs_meta.schema 39999`、`sealed_into srs4.db`、`sealed_from 26`；`srs4.db` schema 40024。

### 4.2 (a2) / (c0) 新版本只打开旧根

- (a2) 新 release 打开 v3.3.0 根（不迁移）：控制通道 `srs/decks|cards|stats` 都是 **500** `SrsStoreNotMigrated(needsMigration)`
  （内部错误码，不是「先迁移」的 4xx；ctl 调用方得自己认文本。**第二轮复核已改**：app 的 `requireSrsCtlStore` 把打开时的代际 / 身份
  状态映射成 **409 + 稳定错误码**——要升级 `srs_needs_migration`、上次升级失败 `srs_migration_failed`、别的进程在升级 `srs_upgrading`、
  只剩封存旧库 `srs_sealed_old_only`、新库旁有没升级的旧库 `srs_legacy_unmigrated`、主库里还有协议 1 复习表 `srs_legacy_main_db`、
  辅助进程里 profile 还没身份 `srs_profile_identity_pending`；真错误仍是 500 `internal`。单测 `fushi/test/ops/ctl_srs_open_blocked_test.dart`。
  这条结论是单测上的，没有拿 release 重跑这一格），`retained` 给 `{"copy":"other"}`；`srs.db` 原样（sha 与抹 D3 后都不变），
  只多了空的 `srs.gen.lock`。**但主库 `fushi.db` 从 146 升到 159。**
- (c0) 之后 v3.3.0 再开这个根：启动即拒绝 `FushiDatabaseDowngradeException: schema v159; this app only understands v146`，
  整个 app 起不来；SRS 文件不动。v3.0.1 同样（v118）。也就是说 **新版本只要打开过一次（哪怕没迁移 SRS），旧版本就不能再用这份数据根**，
  拦人的是主库 schema 门，不是 SRS 代际门。这与规划 (c)「迁移提交前旧版本仍可用」只在 SRS 层成立；主库层是既有行为（主库迁移本来就不可降级），
  不属 gen4 范围。第二轮复核定为**不改行为、写成升级说明条目**（见 §6「升级说明」第 1 条：不可回退）。

### 4.3 (b) 迁移后旧版本再打开

- 主库已是 159，旧版本整个 app 起不来（(c0)），所以单看 SRS 层：把迁移后的 `srs.db*`（封存）、`srs4.db*`、`srs.gen.lock`、迁移报告
  放进 v3.3.0 自己的数据根（主库 146），v3.3.0 打开（`r0_win.py --steps inspect.json`）：
  - 控制通道 `srs/decks|cards|stats` 都是 **422** `复习库还没就绪`；导航到复习页后再查仍是 422。
  - 字节比对：`srs4.db` / `-wal` / `-shm`、`srs.gen.lock`、迁移报告 sha256 全不变；`srs.db` 原始 sha 变了，**抹掉 D3 例外字节（24–27、92–95）后不变**；
    空的 `srs.db-wal` 与 `srs.db-shm` 在关库时被 SQLite 删掉（WAL 模式正常收尾，没有内容）。主库 schema 仍 146。
  - 旧版本复习页上的拒绝提示文字没看到像素（离屏全黑），只有控制通道的拒绝。
- v3.0.1 打开整份迁移后的根：启动拒绝（主库 159 > 118），`srs*` 全部文件 sha256 不变；主库 schema 仍 159（`fushi.db` 文件 sha 变了，是 WAL 折回主文件）。

### 4.4 (c) 迁移途中硬结束

- 硬结束：同一 itest 加 `FUSHI_R0_KILL_AFTER_MS=200`，按下（`controller.start()`）后 248 ms 在 `running` 阶段 `Process.killPid(pid, SIGKILL)`
  （`r0-c-kill2`，runner exit 79 = 进程被杀，预期）。`FUSHI_R0_KILL_AT=precondition` 那一轮没赶上（6 张卡的迁移约 0.4 s，步骤一闪而过，
  `r0-c-kill` 照常提交了），改按时间杀。
- 杀后磁盘：`srs.db` sha256 与种子相同（`2cc51c40…`，一个字节没动），旁边留着 `srs.db-gen4-prepare*`、`srs4.db-migrating*`、`srs.gen.lock`，
  没有 `srs4.db`——停在提交点（`srs4.db-migrating` → `srs4.db` 改名）之前。
- 旧版本仍可用（SRS 层；主库已被新版本升到 159，整个根旧版本起不来，同 (c0)）：把杀后的 `srs*` 文件放进 v3.3.0 自己的根，v3.3.0 打开：
  `srs/decks` 200（Default，review 6，total 6）、`srs/notes?mode=cards` 200（6 张，卡 ID 是旧的带盐 ID）、`stats` 200；`srs.db` 抹 D3 字节后不变
  （原始 sha 变是旧版本自己正常开库）、`srs4.db-migrating*` / `srs.db-gen4-prepare*` / `srs.gen.lock` 字节不变（旧版本不认也不碰）。
- 新版本重开（种子 = 杀后的整个 `app-support`）：开库报 `needsMigration`，重新迁移 `@29ms running → @413ms prepare → @511ms committed`，
  残留的 `-migrating` / `-gen4-prepare` 文件都清掉了；`r0_compare.py` exit 0：6/6 卡、12/12 日志、`diffs []`，迁移报告 `profileVerdict pass`。
- 没做到：提交**之后**、封存 `srs.db` 之前被杀（「补做中断的封存」那条路径）——迁移太快，按时间杀不准；Rust 单测 `migrate_tests.rs` `opening_after_a_lost_seal_finishes_it`、`files.rs` `primary_finishes_a_lost_seal_before_opening` 覆盖这条，这里没在真二进制上实测。

### 4.5 (d) 文件夹同步位置三态

种子 `M/d/loc-h`（v3.3.0 建、profile uid `cc85f3c6…`，制卡 3 张：川 森 雨）推到 `L_old`（只有 v3 目录）。
- 只有旧 → 新加入（d1）：新 release `srs_old_binary.py seed --exe … --profile-uid cc85… --location L1`：牌组 new 3 / total 3；位置里写出
  `v4/`（head、段、`hrt-heritage` 段装着旧设备 ops 1..33、loc、meta `fushi-srs-meta/4` `minReader 4`），`v3/meta.json` 换成
  `{"minReader":4,"moved":"v4"}`，`v3/devices` 与 `v2` 不动。✔
- 两代都有 → v3.3.0（d2）：`run --action sync-location`，判定 `untouched-prompt-unverified`：控制位置文件 5 个、目标位置原样、本机逻辑数据不变。✔
  （v3.0.1 没跑这一格。）
- 只有新 → 旧（d3）：新版本建的 `loc-new-h`（v4 + v3 围栏 + tombstone head + v2 meta），v3.3.0 `untouched-prompt-unverified`（控制位置 4 个文件），
  v3.0.1 `n/a-untouched`，目标原样。✔
- 「两个版本都能连上」：旧版本对新位置是**连上但拒绝写**（目标不动），新版本对旧位置连上并接管；旧版本给用户的提示文字没看到像素（同上）。
- 经界面导航触发同步（`r0_win` 步骤 `navsync*`）两代都没有写出位置，原因没查清，改用装置的 `seed --location` / `sync-location`。

### 4.6 (e) 备份四向

- 新 → 旧（e2）：新 release 整包备份（主库 159）给 v3.3.0 / v3.0.1 恢复：都 **422**「备份来自更新版本的 Fushi（schema 159），先升级 app」，
  目标不动、本机逻辑数据不动。✔（拦人的是主库 schema，SRS 层没走到。）
- 旧 → 新，合并（e1-merge）：控制通道恢复被接受、重启后 SRS 部分 `srsDeclined: needs user confirm (preset=true)`（按设计控制通道不替用户确认，
  文案 `backup_import_success_srs_declined`），牌组 0。界面确认那条路径没驱动到。—
- 旧 → 新，覆盖（e1-replace）：**✘ 缺陷**。`srs4.db` 有 6 卡 / 12 条 `log_ix`，`alias_ix` 也在（换算 30 次），但卡片行是用不带盐的模板 ID
  重新派生的（如笔记 `8505da71` 的卡：旧 `b2e7b23a`，迁移路径得 `b2a1861d`，覆盖恢复得 `0d72d873`），与日志、别名都对不上；6 张全 `hidden=1`、
  `queue new`、`reps 0`；`salt_ix` 只有本机 uid `01a1f75e`（没有备份里的 `01a1ec82`）；恢复后主库 profile uid 是本机的 `01a1f75e`，`collections`
  行 dir 是 `01a1ec82`。app 里卡片总数 0、保持率却算出 6 次复习。`r0_compare.py --old A/old-root-pristine/app-support --new M/e/replace-root/app-support`
  12 条 `missing_in`。根因指向旧备份导入（`dispatch.rs` `legacy_backup_import` → `cmd/backup.rs` `land` → `identity.rs`
  `collection_adopt_with` / `adopt_foreign` 的 Bound 分支只写本机 carry 盐，备份的盐（`legacy::salts`）没进 `salt_ix`），带盐的内置 ID 没能换算到规范 ID。
  属 G11-4 / G9（导入 / 身份），第一轮没改。
  **复核轮已按根因修（BUG-4989，`docs/bugs/BUG-4989-srs-gen4-legacy-backup-replace-drops-backup-salts.md`）**：根因确认在认领结论
  `bound`（本机 profile 已打开过、空集合、目录名大于备份 uid → `rebind_empty` 换绑）之后只写本机盐；`Bound` 的设计是对方的盐随对方的操作到，
  而协议 3 备份里没有任何 `Salts` 操作。修法：`cmd/backup.rs` `land` 在 `bound` 时由本机声明备份 profile 的盐（`legacy::salts`，已过身份确认），
  再落 `import_backup`。没有改成「`Bound` 一律写调用方给的盐」——那样位置认领 / `.fushisrs` 第 2 版也多写一条本机 `Salts`，实测打破 4 条既有测试
  （含 `sync_relay_tests::devices_converge_after_a_join` 两台设备 `canonical_ids` 不一致）。测试 `backup_tests.rs`
  `a_protocol_3_backup_replacing_a_fresh_profile_keeps_its_salts_and_cards`（变异实测：去掉修复变红，只去掉盐断言时卡片 / 日志行比对同样红）。
  **修后 release 实测**：上面同一个 release 的 `fushi.exe`（sha256 不变）换上本分支 release 编的 `fushi_fsrs.dll`（`a3134284…11df`，原 `48e23535…0c07`）
  放在 `D:/fushi-r0/new-fix/Release/`，`srs_old_binary.py run --action restore-backup --restore-mode replace`（`20261120-164345-restore-backup`，
  accepted）→ 重开（`20261120-164425-r0-e1r-fix-reopen`）：`srs/decks` 200 Default review 6 / total 6，`srs/notes?mode=cards` 6 张、卡片 ID
  与迁移路径相同（如 `b2a1861d…`），`stats` young 4 / mature 2；`r0_compare.py` exit 0：`old_cards_raw 6 = new_cards 6`、12/12 条日志逐条
  ID / 时间 / 评分 / 用时一致、`diffs []`（`D:/fushi-r0/M/e1r-fix-compare.json`）。
- `.fushisrs` 四向：新旧两边都没有控制通道入口（只有界面里的导出 / 导入文件对话框），离屏驱动不了系统文件对话框。—

## 5. 缺口

- Android / macOS / iOS 真机、Linux 服务端、fushi_server beta 全没做。
- 迁移提示页、旧版本拒绝提示、同步位置提示都没有 release 真像素（离屏 PrintWindow 全黑，UI Automation 也读不到语义树）；迁移页 / 进度页 /
  迁移后复习页有 debug itest 真像素（`r0-a-zone4`）。
- `.fushisrs` 四向、旧备份「合并」的界面确认路径没驱动。
- (d2) 没跑 v3.0.1。

## 6. 升级说明（给发版说明 / 用户提示用）

1. **不可回退：新版本只要打开过一次数据，旧版本就再也打不开这份数据。** 新版本启动时把主库 `fushi.db` 升到新 schema（R0 实测 146 → 159），
   哪怕复习库还没升级、用户什么都没点；旧版本（实测 v3.3.0 / v3.0.1）启动即报 `FushiDatabaseDowngradeException`，整个 app 起不来（§4.2 (c0)）。
   这是主库迁移的既有行为（主库迁移从来不可降级），不是协议 4 换代引入的，**不改**。规划 (c)「迁移提交前旧版本仍可用」只在 SRS 层成立：
   复习库在提交前确实原样留着（字节不变），但要真回到旧版本，只能用升级前的整包备份恢复到旧版本、或把升级前的数据目录副本放回去。
   发版说明应写：升级前先在旧版本里做一次整包备份；升级后不能直接装回旧版本继续用同一份数据。
2. 复习库升级（协议 3 `srs.db` → `srs4.db`）提交后，旧库原样封存（`srs_meta.sealed_into`），旧版本打开会被显式拒绝、不写（§4.3）；
   封存的旧库作为「旧版本保留副本」留着（D32，有到期状态），设置 › 存储里可以立即删除（要确认、不可撤销），删了之后就没有协议 3 的原文可退了。

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
| (a) | v3.3.0 建库 / 制卡 / 复习 → 新版本迁移 | ✔ 数据：6 卡 / 12 日志逐卡一致；— 提示页：itest 里迁移页没出来（见 (a) 说明），改走 `controller.start()` | `r0-a-migrate3`、`D:/fushi-r0/M/a3-compare.json` |
| (a2) | 新 release 只打开旧根、不迁移 | ✔ SRS 不动；✘?（规划外）主库被升到 159，见 (c0) | `20261120-124602-r0-a2-new-first-open` |
| (b) | 迁移后旧版本再打开 | ✔ 显式拒绝、不写（SRS 层字节比对，只有 D3 例外字节） | `20261120-142928-r0-b1-v330-swap`、`20261120-143005-r0-b2-v301-full` |
| (c) | 迁移途中硬结束 | ✔ 提交前硬结束：旧库字节不变、v3.3.0 照常可用（SRS 层），新版本重开后重新迁移、逐卡一致 | `r0-c-kill2`、`20261120-144625-r0-c1-v330-killed`、`r0-c-resume` |
| (c0) | 新版本打开过的根，旧版本再开 | 旧版本整个 app 起不来（主库 schema 159 > 146 / 118），SRS 文件不动 | `20261120-124632-r0-c0-old-after-new-open`、b2 |
| (d) | 文件夹位置三态 | ✔ 只有旧 → 新加入；✔ 两代都有 → 旧版本不动目标；✔ 只有新 → 旧版本不动目标；— 旧版本的提示文字没看到像素 | `D:/fushi-r0/M/d/*.json` |
| (e) | 备份四个方向 | ✔ 新备份 → v3.3.0 / v3.0.1 拒绝；✔ 旧备份 → 新（合并）按设计要用户确认；✘ 旧备份 → 新（覆盖）卡片 ID 与日志脱钩；— `.fushisrs` 四向没有自动化入口 | `D:/fushi-r0/M/e1-*.json`、`e2.json` |

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
  `SrsStoreNotMigrated` 落定（exit 0，+4）。**结论：判为 itest 环境问题、不是产品缺陷，但 release 的迁移页像素没看到**
  （离屏 release 窗口 PrintWindow 全黑；`--onscreen` 抓屏抓到的是桌面别的窗口，已删）。真机 / 可见窗口复核留缺口。
- 迁移改走按钮背后的同一个入口 `SrsGen4MigrationController.start()`（`FUSHI_R0_FALLBACK_START=true`），探针：
  `@47ms running → @258ms precondition → @366ms committed`，`status after: state=ready`。迁移后复习页（真像素
  `r0-a-migrate3/screenshots/r0-03-after.png`）：今日 6 张待复习、Default 牌组 6 张 · 已掌握 2、保持率 83%、近 30 天 12 次复习。
- 逐卡比对：`python -I tool/srs_old_binary/r0_compare.py --old A/old-root-pristine/app-support --new <隔离根>/app-support`
  exit 0：`old_cards 6 = new_cards 6`、`old_logs 12 = new_logs 12`、`diffs []`；比的列是 queue / due_day / due_at /
  scheduled_days / reps / lapses / stability / difficulty / last_reviewed_at / deck_id / suspended / note_id 与每卡日志条数。
  新代把带 profile 盐的内置派生 ID 规范化（`alias_ix` 15 行，卡片 6 条 how=2、其余 how=1），比对前经 `alias_ix` 换算（`aliased 30`）。
  迁移报告 `srs4-migration-report.json`：`profileVerdict pass`，日志新旧 12/12、带日志卡 6/6，`knownDifferences.total 0`。
- 迁移后 `srs.db` 封存：`srs_meta.schema 39999`、`sealed_into srs4.db`、`sealed_from 26`；`srs4.db` schema 40024。

### 4.2 (a2) / (c0) 新版本只打开旧根

- (a2) 新 release 打开 v3.3.0 根（不迁移）：控制通道 `srs/decks|cards|stats` 都是 **500** `SrsStoreNotMigrated(needsMigration)`
  （内部错误码，不是「先迁移」的 4xx；ctl 调用方得自己认文本），`retained` 给 `{"copy":"other"}`；`srs.db` 原样（sha 与抹 D3 后都不变），
  只多了空的 `srs.gen.lock`。**但主库 `fushi.db` 从 146 升到 159。**
- (c0) 之后 v3.3.0 再开这个根：启动即拒绝 `FushiDatabaseDowngradeException: schema v159; this app only understands v146`，
  整个 app 起不来；SRS 文件不动。v3.0.1 同样（v118）。也就是说 **新版本只要打开过一次（哪怕没迁移 SRS），旧版本就不能再用这份数据根**，
  拦人的是主库 schema 门，不是 SRS 代际门。这与规划 (c)「迁移提交前旧版本仍可用」只在 SRS 层成立；主库层是既有行为（主库迁移本来就不可降级），
  不属 gen4 范围，记在这里供拍板（是否需要在旧版本说明 / 升级提示里讲清）。

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
  属 G11-4 / G9（导入 / 身份），本模块不改，见交接文档本节与 not_done。
- `.fushisrs` 四向：新旧两边都没有控制通道入口（只有界面里的导出 / 导入文件对话框），离屏驱动不了系统文件对话框。—

## 5. 缺口

- Android / macOS / iOS 真机、Linux 服务端、fushi_server beta 全没做。
- 迁移提示页、旧版本拒绝提示、同步位置提示都没有 release 真像素（离屏 PrintWindow 全黑）；迁移后的复习页有 debug itest 真像素。
- `.fushisrs` 四向、旧备份「合并」的界面确认路径没驱动。
- (d2) 没跑 v3.0.1。

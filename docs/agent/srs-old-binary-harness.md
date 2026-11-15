# 冻结的真实旧版本二进制实测装置（SRS 换代）

SRS 存储与同步换代（协议 4，`docs/specs/2026-11-11-srs-generation-break.md`）的 G7 / G8 / G11 合并条件（§8、§9 第 1 项，
所有者 2026-11-11 的硬要求）：用**已发布的发行包**（不是仓库里冻结的旧源码）分别打开封存后的旧 `srs.db` 与新代文件、
对着换代后的同步位置真实跑同步、导入新导出包 / 还原新备份——都必须报错 / 提示升级，且文件 / 位置 / 本机库一个字节不变。

装置在 `tool/srs_old_binary/`：`srs_old_binary.py`（只用 Python 标准库）、`versions.json`（版本与 sha256）、
`srs_old_binary_test.py`（纯逻辑单测，不启动二进制）。只支持 Windows。

## 版本集（versions.json，`default: true` 是默认口径）

| id | 包 | SRS 协议 | 角色 |
|---|---|---|---|
| `v3.0.0` | Release `v3.0.0` 的 `fushi-3.0.0-windows-setup.exe` | 协议 2 之前（复习数据在 `fushi.db`，没有 `srs.db`、没有文件夹位置） | 最后一个协议 2 之前的正式版 |
| `debug-23261-2eb0face` | 存档 prerelease `srs-old-binaries-2026-11`（原来源：Actions run 41660639578 的 `desktop-artifacts-windows`，当时的 debug-rolling 包） | 2（`srs.db` schema 22） | 最后一个只认协议 2 的**已发布**二进制 |
| `debug-23315-b263995`（非默认） | 存档 prerelease（原来源：Actions run 41777877723 的同名产物） | 3 | 最早带协议 3 的已发布二进制 |
| `v3.3.0` | Release `v3.3.0`（Latest）的 `fushi-3.3.0-windows-setup.exe` | 3（`srs.db` schema 26） | 最早带协议 3 的正式版 = 当前最新正式版 |
| `debug-26834-017cdcf` | 存档 prerelease（原来源：Release `fushi-debug-rolling` 的 `fushi-3.3.0-debug.26834-windows-setup.exe`，已被轮换删掉） | 3（`srs.db` schema 29） | 当前最新 debug-rolling（develop 017cdcf） |

为什么是这几个（2026-11-15 核实）：

- 协议 2 在 develop 上是 2026-10-30（`7d3e7ecb148`），协议 3 是 2026-11-04（`fd61bea8a49`）。两者之间**没有发过正式版**：
  v3.0.0（10-17）/ v3.0.1（10-21，prerelease）还没有 sync2，v3.3.0（11-06）已经是协议 3。所以「最后一个只认协议 2 的正式版」不存在，
  用两份顶替：协议 2 之前的最后一个正式版 `v3.0.0`，加上协议 2 时期最后一个 debug-rolling 包（`2eb0face`，11-03，
  `native/fushi_fsrs/src/sync2/segment.rs` 的 `PROTOCOL = 2`）。「最早带协议 3 的正式版」与「最新正式版」都是 v3.3.0。
- **存档**：actions artifact 会过期（`2eb0face` 的 2026-11-17、`b263995` 的 2026-11-18），`fushi-debug-rolling` 的旧资产也会被轮换删掉
  （26834 在 11-15 已经不在了）。所有者 2026-11-15 同意长期存档：三个 debug 包已传到上游 prerelease
  [`srs-old-binaries-2026-11`](https://github.com/hajisensai/Fushi/releases/tag/srs-old-binaries-2026-11)（GitHub 资产 digest 与
  versions.json 的 `installer_sha256` 一致），versions.json 的 `source` 指向它，原来源记在 `source.origin`。v3.0.0 / v3.3.0 在正式 release 里，不重传。
  单测 `test_sources_do_not_expire` 钉住：清单里只允许 `release` 来源、不许指向 `fushi-debug-rolling`。
- 换代之前 debug-rolling 每次 push 都会变：G7 / G8 / G11 合并时若 debug-rolling 已经更新，先把新的安装包
  `gh release upload srs-old-binaries-2026-11 <文件> --repo hajisensai/Fushi` 传进存档，再往 versions.json 里加一条
  （tag 填存档、`origin` 记 run 号与 debug 版本号；sha256 用 `gh release view … --json assets` 的 digest 核对），旧那条留着。

## 获取

```bash
export FUSHI_OLD_BINARY_CACHE=D:/fushi-old-binaries   # 不设则用 tool/srs_old_binary/.cache（gitignored）
python -I tool/srs_old_binary/srs_old_binary.py list
python -I tool/srs_old_binary/srs_old_binary.py fetch --versions all
```

`fetch` 用 `gh` 下载、校验 sha256（不符就重下，最多 5 次；本机代理不稳时 release 下载常被截断），再用 `innounp` 解出 `{app}`
（安装包是 Inno Setup 6.7，`innoextract` 1.9 解不了：`scoop install innounp`）。**不运行安装器**：安装器与用户装的 Fushi 同 AppId，
会改用户的卸载项、可能关掉正在跑的实例。每个版本解出来约 715 MB。

## 隔离（每次启动都这样）

`FUSHI_TEST_HIDDEN=1`（离屏、不抢焦点，并跳过单实例守卫——否则会把启动转交给用户正在跑的 Fushi）、`FUSHI_TEST_ROOT`、
`FUSHI_TEST_RUN_ID`、`FUSHI_CTL_DIR`、`FUSHI_WEBVIEW2_USER_DATA_FOLDER`、`APPDATA`、`LOCALAPPDATA`、`TEMP` / `TMP`、`USERPROFILE`
全部指到 `<缓存>/runs/<时间>-<动作>/<版本>/` 下；数据根就是 `data/`（`srs.db` 在 `data/app-support/`）。
这些版本全都认 `FUSHI_TEST_ROOT` 环境变量（`fushi/lib/src/startup/test_environment.dart`，release 包也认）。
收尾先走控制通道 `/api/admin/app/quit`，超时只结束**可执行文件位于本缓存版本目录下**的进程（按 PID），绝不按名字杀；
同一版本已有进程在跑就拒绝启动。输入（目标文件 / 位置 / 包）一律先拷进运行目录，原件只读、跑完再核一次哈希
（报告的 `original_target_unchanged`）。

## 驱动方式

旧版本里都有桌面控制通道（`fushi_cli` 用的那条：`127.0.0.1` 随机端口 + token，发现文件 `<FUSHI_CTL_DIR>/endpoint.json`），
装置直接调它的 HTTP 路由，不点界面：

| 动作 | 目标 | 放在哪 | 怎么触发 | 「拒绝」的判据 |
|---|---|---|---|---|
| `open-db` | 一个文件（放成 `srs.db`，同名 `-wal` / `-shm` 一起），或一个目录（里面的文件原样放进 `app-support/`，给新代文件用） | `data/app-support/` | 启动即打开；再 `GET /api/admin/srs/decks`、`POST /api/admin/navigation {"page":"srs"}` | `decks` 不是 200 |
| `sync-location` | 位置目录（含 `fushi-srs/<profileUid>/`） | `location/`，并在旧版本 `fushi.db` 的 `preferences` 写 `srs_sync2_folder_locations` 指向它、`srs_sync2_merge_confirmed = b:true` | `POST /api/admin/navigation {"page":"srs"}`（进复习页 = `syncThrottled`，含文件夹位置那一轮） | 位置逐字节没变、本机库逻辑内容没变；提示见下 |
| `restore-backup` | 备份包 | `input/` | `GET /api/admin/backups/info`，`POST /api/admin/backups/restore {"mode":"merge","confirm":true}`（`--restore-mode replace` 可换） | restore 不是 200；是 200 时等 app 自己重启、再读一次 decks |
| `import-export` | `.fushisrs` | `input/` | **已发布版本的控制通道没有 `.fushisrs` 导入入口**（只有复习 › 历史页），只能 `--manual`：窗口放到屏上，人在界面里导入，回车后装置收尾比对 | 人工 |

sync-location 的提示：已发布版本遇到 `minReader` 更高的位置，「需要升级」只进复习页界面（`SrsSyncNotice.backendUnsupported`、
文件夹位置的错误表）与内存里的诊断（`SrsSyncScheduler.roundFailed`，`ErrorLogService.logDiagnostic` 不落盘），**不进任何日志文件、
控制通道也读不到**。所以装置对 sync-location 只能自动判「位置一个字节没变、本机库没变」（结论 `untouched-prompt-unverified`），
提示有没有出现要 `--manual` 把窗口放到屏上人眼看（或截图）。

sync-location 的 profile：位置按 `fushi-srs/<profileUid>/` 分，旧版本只碰自己 profile 的那份。没给 `--state` 且位置里只有一个 uid 时，
装置把旧版本当前 profile 的 uid 改成它（`--profile-uid` 可指定）；给了 `--state`（旧版本自己之前同步过这个位置留下的数据根）就原样用。

报告（`--report`，缺省 `<运行目录>/report.json`）每个版本一条：版本 / 提交 / 协议 / 安装包 sha256、控制通道每次调用的状态与回应、
`prompt_lines`（回应与新增日志里的升级 / 拒绝类句子）、`target`（前后逐文件 sha256 与 added / removed / changed；`open-db` 的
`srs.db` 变了还给 `srs_db_byte_diff` 的偏移）、`local_db`（旧版本自己的 `srs*` 文件前后哈希、`srs_meta`、逻辑内容摘要）、
`verdict`：`rejected`（拒绝且一个字节没变）/ `rejected-sidecars-only`（拒绝了、原有文件没变，只多出 SQLite 的 `-wal` / `-shm` 旁文件）/
`rejected-but-wrote`（拒绝了但写了——红）/ `accepted` / `untouched-prompt-unverified`（sync-location：位置与本机库都没变，
但日志里看不到提示）/ `untouched-but-local-changed`（sync-location：位置没变，本机库有对照解释不了的变化）/
`n/a-untouched` / `n/a-touched`（版本没有这个能力，只记有没有被碰）/ `not-automatable` / `harness-error`。

**本机库怎么判**：旧版本每次启动都会写它自己的 `srs.db`（SQLite 头的改动计数、设备信息、启动记录、首次开同步时把旧库并成操作……），
字节比较没有意义（仍记在 `local_db.files_unchanged`）。所以 `sync-location` / `restore-backup` 在正式那一次之前先做一次**对照启动**：
同样启动、同样进复习页、同样等，只是不给目标（sync-location 的对照对着一个空的占位位置 `control-location/` 同步一轮，首次开同步的
本机变化都落在对照里）。逐表比较行内容（每表行数 + 行摘要；内核注册的 SQL 函数补成返回 NULL 的桩、虚拟生成列不计），
对照里也会变的表 / `srs_meta` 键记在 `control_noise`，正式那一次多出来的才算「本机库被这个动作改了」
（`local_db.unexplained_tables` / `unexplained_srs_meta_keys`）。`--no-control` 关掉对照，改按整库逻辑摘要判。
`--state` 给的是旧设备之前真同步过的数据根时，对照的意义最干净。

新增日志全文在每个版本运行目录的 `new-logs.json`，stdout 在 `stdout-*.log`。`--expect`（逗号分隔的**完整**结论值，例如
`rejected,untouched-prompt-unverified`）时任何一个版本（`n/a-*` 除外）结论不在其中就退出码 1。

## G7 / G8 / G11 怎么用

先用换代分支的 Release 构建造输入（`seed --exe` 把本地构建当一个「版本」在隔离数据根里跑，留下数据根）：

```bash
H="python -I tool/srs_old_binary/srs_old_binary.py"
# 造：新版本在隔离根里同步一个位置、导出一个备份，数据根留在 out/local-xxxx/data
$H seed --exe fushi/build/windows/x64/runner/Release/fushi.exe --location D:/t/loc --backup-out D:/t/new.zip --out D:/t/new
# G7：封存后的旧 srs.db 与新代文件（目录形式：两个文件一起放进 app-support）
$H run --action open-db --target D:/t/new/local-xxxx/data/app-support --expect rejected
# G8：旧版本先在换代前的位置上同步过（seed 每个旧版本，留下各自数据根），新版本换代该位置后，旧版本再同步
$H seed --version v3.3.0 --location D:/t/loc --out D:/t/old --profile-uid <U>
#   …新版本对 D:/t/loc 换代…
$H run --action sync-location --target D:/t/loc --state D:/t/old --expect rejected,untouched-prompt-unverified   # 再加 --manual 人眼确认升级提示
# G11
$H run --action restore-backup --target D:/t/new.zip --expect rejected
$H run --action import-export --target D:/t/new.fushisrs --manual
```

`seed` 的数据根按版本 id 分目录（`<out>/<版本 id>/data`），`run --state <out>` 自动取对应版本那份；旧版本的数据根只能由
同一个或更老的版本造（更新的版本写过的 `fushi.db` / `srs.db`，旧版本照样会因 schema 太新拒绝，那不是在测换代）。

## 冒烟结论（2026-11-15，输入由 `debug-26834-017cdcf` / `v3.3.0` 自己造）

用来证明装置分得清「拒绝」与「接受」、读得到「写没写」。输入：`seed --version debug-26834-017cdcf` 同步出的协议 3 位置
`location-p3`、它的 `srs.db`（schema 29）与备份（`fushi.db` schema 149）；`seed --version v3.3.0` 的 `srs.db`（schema 26）与备份；
两个人造的「换代后」输入：`srs_meta.schema` 改成 40099 的库（模拟 §6.1 封存）、`v3/meta.json` 的 `minReader` 改成 4 的位置（模拟 §4.3 围栏）。

| 动作 / 输入 | v3.0.0 | 2eb0face（协议 2） | v3.3.0 | debug-26834 |
|---|---|---|---|---|
| open-db 协议 3 库（schema 29） | n/a，没碰 | 拒绝（`schema 29 is newer than this build (22)`），**改了头 2 字节** | 拒绝（`… (26)`），**改了头 2 字节** | 接受 |
| open-db v3.3.0 自己的库（schema 26） | — | — | 接受 | 接受（升级） |
| open-db 封存库（schema 40099） | n/a，没碰 | 拒绝，**改了头 2 字节** | 拒绝，**改了头 2 字节** | 拒绝（控制通道 500），**改了头 2 字节** |
| sync-location 协议 3 位置 | n/a，没碰 | 没写（`minReader 3` > 协议 2），提示未核 | 接受，写了 head + seg | 接受，写了 head + seg |
| sync-location 围栏位置（`minReader 4`） | n/a，没碰 | 没写，本机库没变，提示未核 | 没写，本机库没变，提示未核 | 没写，本机库没变，提示未核 |
| restore-backup develop 的备份（schema 149） | 拒绝（`备份来自更新版本的 Fushi（schema 149），先升级 app`） | 拒绝（同） | 拒绝（同） | 接受（合并后自动重启） |
| restore-backup v3.3.0 自己的备份 | — | — | 接受 | — |
| import-export | — | — | `not-automatable` | — |

读法：

- sync-location 每个版本的对照那一轮都往占位位置写了 4 个文件（`control_location_files`），所以「没写目标」不是因为同步根本没跑。
- 四个有 `srs.db` 的已发布版本**对着更新的库拒绝时都会改文件**：只改 SQLite 头的 24–27（文件改动计数）与 92–95（version-valid-for）
  两处、共 2 个字节，页内容与逻辑内容不变。写发生在比 schema 之前：`schema::migrate` 发现太新时返回错误、迁移事务回滚，不会动头；
  在它之前 `Store::open` 的写连接先执行 `PRAGMA auto_vacuum = INCREMENTAL` 与 `PRAGMA journal_mode = WAL`（v3.3.0
  `native/fushi_fsrs/src/store/mod.rs` 的 `open_with_free_space`、`store/schema.rs:495-530`），最可能是这两句之一提交了一次只改头的写
  （没有逐句验证）。**所以「只靠在旧 `srs.db` 里写一个更大的 schema 封存」过不了「一个字节不变」**，G7 要另想办法。
- 实验：封存库再加 Windows 只读属性（`attrib +R`）：三个版本都拒绝（`attempt to write a readonly database`），`srs.db` 一个字节没变，
  但目录里多出 `srs.db-shm`（32 KiB）与空的 `srs.db-wal`（结论 `rejected-sidecars-only`），且给的是只读错误、不是「需要升级」。
- restore 的拒绝来自备份包的 `fushi.db` schema 闸门（`备份来自更新版本`），不是 SRS 自己的检查：与新版本 `fushi.db` schema 相同的
  旧构建（例如换代前最后一个 debug-rolling）会接受新备份——G11 要按这一点挑版本、补 SRS 侧的检查。
- 围栏位置的「需要升级」提示在已发布版本里不落盘（见上），表里写「提示未核」；要人眼确认用 `--manual`。

## 已知局限

- `.fushisrs` 导入在已发布版本里没有非界面入口，只能人工（`--manual`）。
- 只有 Windows 包；Android / iOS / macOS 的旧版本没覆盖（同一份 Dart / Rust 代码，但平台层不同）。
- 无头服务端 `fushi_server` 不在发行资产里，§6.3「服务端先升 / 后升」那几行不能用这个装置演。
- 判据里的「升级类提示」来自日志与控制通道回应的关键词，界面上弹没弹提示要 `--manual` 看。
- 一次只能跑一个版本的一个实例（同一缓存二进制已有进程在跑就拒绝）；每个版本一个动作约 1–3 分钟（含对照启动）。
- `<缓存>/runs/` 不会自动清理（每次运行几十到上百 MB），用完自己删。

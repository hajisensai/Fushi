# Fushi 全量改名 进度台账（保活续工的唯一真相源）

- 计划：`docs/plans/2026-08-06-rename-fushi-migration.md`
- 工作区：`.claude/worktrees/rename-fushi-plan-v2`；每项开工从最新 `origin/develop` 拉分支
- 纪律：每项独立提交 → analyze 全量 + 定向测试 → 合并前 `dart run tool/flutter_test_failures.dart --no-pub` → push develop → **完成后才**勾掉本项并填真实提交哈希
- 保活 cron：已按用户指示关闭（2026-08-07）；改用 fable 子代理并行推进
- ⚠️ 台账只准记已验证的事实；勾选必须带真实 develop 提交哈希

## 执行顺序与状态

- [x] Phase 0 身份对照表（见下；本文件即产出）
- [x] Apple 侧改名：bundle id（#784）、显示名/产物名/资产名（develop `a5022cd56`）
- [x] P6-1 `window.hoshiReader` → `window.fushiReader`（82 文件；分支提交 45865b679，阅读器/有声书/macos 定向 2242 绿）
- [x] P6-3 ttu 清算（develop ee0655c88）：31 个 i18n key →`reader_*`；`setTtu*`→`setReader*`；`'reader_ttu'` 收口 `kReaderSourcePersistedKey`。**白名单**：`ttu_models.dart`/`ttu_filename.dart`（ッツ第三方 wire 契约，文件头注明禁单方改）、`reader_settings.dart` 内 `ttu_*` 现役持久化键值（冻结，P2-2 新包换新键时迁移）
- [x] P6-4a `Ht*`→`Ft*`（11 类；develop 20f50fc10，torrent 定向 147 绿）
- [x] P6-4b（fable 子代理 2af7d512d，develop b1ff91994 批）：107 文件 Sasayaki*→SubtitleRematch*/sentenceAudio*、19 个 i18n key；**4 个持久化冻结点**：{sasayaki-audio} handlebars、handlebar_sasayaki_audio key、sasayakiColor JSON 键、sasayaki:// scheme（落 AudioCue.text_fragment_id 列）、custom_theme_sasayaki_color 偏好键——**实测面 ~500 处远超预估**，且含两个 userspace 契约需先定策略：① Anki handlebars 模板变量（`handlebar_sasayaki_audio` 对应的用户模板变量，乱改破用户现有卡模板）；② `sasayakiColor` 疑似入库的主题自定义色键（custom_theme 持久化待查）。纯内部符号（SasayakiCue/AutoNav/JS 桥）可机械换，两个契约点需映射或冻结
- [x] P6-4c 代码字符串残留 hibiki 清扫 + 白名单收口（develop ab3e558f7 合并批，分支提交 f0874b28b，77 文件：日志标签族 [Hibiki]/[hibiki-*]/[ReaderHibiki] 等→Fushi 形、UA hajisensai/Hibiki 与 hibiki-reader/*→fushi、realm "Fushi Sync"、'Hibiki server' 文案、/api/ping wire 'app' 两端同切 fushi（R11）；desktop_foreground_guard 词干 + updater DisplayIcon 检测补 fushi 真断裂修复）。**剩余独立事项**（i18n 值面/类名族/扩展双值已拆为下面三条 2026-08-07 批）：X-Hibiki-* 互联 wire 头与 basic-auth username 'hibiki'（server 只验 password，装饰性）；%LOCALAPPDATA%\Hibiki（present_watchdog）与 DCIM/hibiki 磁盘路径、qB category 'hibiki'、sync_obfuscator 密钥种子 'hibiki'（持久化/外部契约，冻结）
- [x] P1-1 `MigrationExporter` 核心（`lib/src/migration/migration_exporter.dart`：分批调 createBackup、断点 state.json、幂等跳过；**尚缺**：Android 中转目录取路径接线 + 从设置页触发——归 P1-3 一起做）
- [x] P1-2 `MigrationManifest` v1（`migration_manifest.dart`：归档 sha256+size + 14 表行数 + schema 版本；8 单测绿；对计划的偏差已记回计划 §P1-2）
- [x] P1-3 迁移 UI（develop 0ffb7cc1c + 73b4b6973 + MD3 修正，Android release APK 构建绿）：Android MigrationChannelHandler（探测/拉起/卸载/PROCESS_TEXT）+ `<queries>` + MigrationPage 三态引导 + 设置入口 + 15 i18n key。**验证态**：analyze 绿、Android release APK 构建绿（334.9MB）；真机 E2E 未做（标 implemented_unverified，待 P2 后一起真机跑）
- [x] P1-4a 只读态启动闸门（develop c56a273aa）：`isMigrationReadonly` + init 尾段早退（互联/Yomitan/自动同步/词典自更/下载入库/texthooker 全停）+ PROCESS_TEXT 注销随导出完成触发
- [x] P1-4b 只读态收口（develop 513e49ff2）：openMedia 单闸门（进度/统计/制卡写路径整体不可达）+ dashboard 常驻 banner（打开 Fushi / 重新导出）
**⚠️ Android 过渡版基线 = 513e49ff2**（含完整迁移导出/只读态，包名仍 app.hibiki.reader；发布老包最后版本从此提交出包）。
- [x] P2-1 Android 身份替换（develop 15fd787e0…64386eaf4）：applicationId/namespace/taskAffinity/Java·Kotlin 包目录/label/图标 alias/URL scheme fushi://和 Bonjour _fushi-sync/MethodChannel 前缀五端同 PR；FushiFileProvider/FushiBridge/资源改名；新包名 release APK 构建绿（335.1MB）；全量门 17619 绿
- [x] P2-2 `MigrationImporter`（同批落地）：scan/归档校验/mergeRestore 逐批合并/行数聚合校验/失败保留（4 单测）+ MigrationImportPage + dashboard 检测 banner + 设置入口按运行包名切方向
- [x] P2-3 卸载引导（同批落地）：dashboard 卸载 banner（ACTION_DELETE + resumed 生命周期复查，绝不乐观标成功）
- [x] Phase 3 Windows（develop 215c9cc24 批）：fushi.exe 构建绿+版本信息 Fushi 验证；%APPDATA% 搬迁+documents 容器锚点；fushi.iss（AppId 不变/双 mutex/旧键清理）；全量门 17619 绿（清 39 红含 fork sentinel 与重启标志两处真断裂）。原文案：`fushi.exe`/安装器 AppName/`FushiSingleInstanceMutex` 三处同步/`Fushi.Video` ProgID 迁移+旧键清理/`%APPDATA%\Hibiki`→`Fushi` 搬迁
- [x] Phase 5 更新桥（cdffe37c0）：Windows `synthesizeStableAssetNames` 行随 Phase 3 切 fushi（Android 无更新桥需求：跨包名不能就地更新，迁移链即通道）
- [x] P6-2 `hoshidicts`→`fushidicts`（fable 子代理 4867d9f15，develop b1ff91994 批）：22 个 C ABI 符号、JNI 与 FushiBridge 对齐（修复 P2-1 遗留真断裂）、CMake/xcconfig/CI 全链；合并后 analyze 绿+定向绿。构建门：Android/Windows 待下轮构建复核
- [x] P6-6 native 产物（fable 子代理 e090a6021，develop b1ff91994 批）：三件套 fushi_voice_*、IPC shm/event/marker 两侧同批、fushi_torrent_ffi + DLL 旧名回退、Unity 程序集 Fushi.UnityAudioExtract；1362 定向绿。保留：C++ namespace hibiki_voice_hook（内部符号，需双架构构建验证，后续项）
- [x] P6-5 pub 包名体系（develop 31270161d，fable 子代理批 555785e28+d163b70a0）：`hibiki`→`fushi` app 包 + 6 内部包 + workspace（`fushi_workspace`）+ 全仓 import；app 目录名 hibiki/ 保持（CI/文档路径半径不成比例）
- [x] 收尾：源码扫描守卫（旧代号零残留 + 白名单收口 + 过期豁免检测）（develop ab3e558f7 合并批，分支提交 ddc61451d：`hibiki/test/tools/fushi_rename_guard_test.dart`，扫 hibiki/lib + 6 个 fushi_* 包 lib，剥 Dart+内嵌 JS/CSS 注释，8 类模式；变异实测 2 例转红后还原）
- [~] i18n 17 语言值面 Hibiki→Fushi（分支 worktree-agent-abffb211448d8d229 提交 3027726db，**待合并 develop**）：每语言 ~60 值面 / 共 1018 处（含日志分享主题 hibiki→Fushi、HIBIKI_MOKURO→FUSHI_MOKURO）；**冻结 8 key**：migration_* ×7（指旧 Hibiki app 是正确指称）+ anki_tag_include_hibiki（引用持久化在用户卡上的字面 tag 'hibiki'）；key 集 17 文件校验不变，slang 重生成，media_sources_dialog_test 断言随改
- [~] Hibiki* 类名族 → Fushi*（同分支提交 74d964cc2，**待合并 develop**）：词首 `(?<![A-Za-z0-9])Hibiki(?=[A-Z])` 机械替换，Dart 10113 处 / 1103 文件（含 _Hibiki* 私有类与 drift/生成类）；词中内嵌形态（MangaHibikiPage 等含 hibiki 文件名类、kMagpieHibikiProfilePrefix 值 'Hibiki: '、runningHibikiProcesses wire 键）与 SQL 表名 hibiki_paired_peers 不动，**FushiPairedPeers 补 tableName 钉死旧表名**（否则 build_runner 重生成漂表名破 schema）；连带 run_windows_itest.ps1 / ffigen.yaml / 文档类名指称；守卫新增 'Hibiki*-类名族' 禁模式（变异实测）；本轮不 git mv 含 hibiki 的文件名
- [~] 扩展 wire 'app' 双值兼容（同分支提交 f53cc70f2，**待合并 develop**）：connection-diagnostics.js 接受 'fushi'|'hibiki' 判 connected（node --test 6/6 绿，镜像已同步）；app 端两处 /api/extension/status **仍返回 'hibiki' 不切**（商店老扩展严格比对）。**后续切换条件**：带双值兼容的扩展在商店发布并普及后，才把 hibiki_sync_server.dart / yomitan_api_server.dart 两处切 'app':'fushi'
- [x] 云同步改名（2026-08-07 用户新增指令）主线部分（develop 1b326bc17 批）：删 Hoshi/ッツ 共享 Google Drive 功能（ttuShared 空间/开关/repo 方法/2 i18n key，恒用 appdata 隐藏空间——完整 drive 敏感 scope 随之消除，Phase 4 的重审风险项作废）；kSyncRootFolderName→fushi-data；Google Drive 根远端改名迁移三段
- [x] 云同步改名五 backend 部分（develop ed101c712 批，fable 子代理）：Dropbox/OneDrive/WebDAV/FTP/SFTP/interconnect host 的 fushi-data 迁移
- [x] Phase 4 外部注册台账（agent 无法代办，清单见下；Google 同意屏重审风险已随 Hoshi 功能删除作废）

## Phase 0 身份对照表（唯一真相源）

| 项 | 旧值 | 新值 |
|---|---|---|
| Android applicationId/namespace | `app.hibiki.reader` | `app.fushi.reader` |
| iOS/macOS bundle id | `app.hibiki.reader`（macOS 旧 `com.example.hibiki`） | `app.fushi.reader` ✅已落 |
| 显示名 | Hibiki | Fushi（Apple 侧 ✅已落） |
| URL scheme | `hibiki` | `fushi`（连带 auth/lookup/anki 回调） |
| MethodChannel 前缀 | `app.hibiki.reader/*`、`app.hibiki/*` | `app.fushi.reader/*`、`app.fushi/*`（Dart+Android+iOS+macOS+Windows C++ 同 PR） |
| Bonjour 服务型 | `_hibiki-sync._tcp` | `_fushi-sync._tcp`（两端同 PR，破跨版本互联=计划 R11 已接受） |
| JS 桥全局 | `window.hoshiReader` | `window.fushiReader` |
| 词典引擎 | `hoshidicts` / `libhoshidicts_ffi` | `fushidicts` / `libfushidicts_ffi` |
| 磁盘目录 | `hoshi_books`；`Hibiki/data`；`%APPDATA%\Hibiki` | `fushi_books`；`Fushi/data`；`%APPDATA%\Fushi`（迁移落位） |
| DB 文件 | `hibiki.db` | `fushi.db`（新包新建；导入器读旧库） |
| Windows 单实例 | `HibikiSingleInstanceMutex` / 窗题 `Hibiki` / `hibiki.exe` | `FushiSingleInstanceMutex` / `Fushi` / `fushi.exe`（iss+main.cpp 三处同步） |
| Inno AppId GUID | `{{8F2C1A3E-...}}` | **不变** |
| torrent DTO 前缀 | `Ht*` | `Ft*` |
| torrent DLL | `hibiki_torrent_ffi` | `fushi_torrent_ffi` |
| gal helper | `hibiki_voice_injector.exe` 等三件套 | `fushi_voice_*`（IPC 对象名两侧同 PR） |
| 有声书代号 | `Sasayaki*` / `sasayakiAudioPath` | `SubtitleRematch*` / `sentenceAudioPath` |
| pub 包 | `hibiki` + `hibiki_*` ×6 + `hibiki_workspace` | `fushi` + `fushi_*` + `fushi_workspace` |
| i18n key 前缀 | `ttu_*`、`sasayaki_*` | 按域重命名（`i18n_sync --rename`） |
| 资产名 | `hibiki-*` | macOS/iOS ✅已切；Win/Android 随更新桥 |
| 不改 | Manhhao 署名/域名、Niratan/shishamo/jidoujisho 注释、第三方服务名、GCP 项目 ID、`kLegacyGitHubRepo`、DB 迁移阶梯历史常量 | — |

## Phase 4 用户手动清单（agent 无法代办）

1. Google Cloud：新建 Android OAuth client（包名 `app.fushi.reader` + 新 keystore SHA-1）、新建 iOS client（bundle id）；重下 `google-services.json`；同意屏应用名改 Fushi（敏感 scope 可能触发重审）。
2. Dropbox 控制台：redirect URI `hibiki://auth/dropbox` → `fushi://auth/dropbox`，显示名改。
3. Microsoft Entra：同上 `fushi://auth/onedrive`。
4. TMDB：注册信息改名。
5. ASC：删除绑 `app.hibiki.reader` 的废弃 `fushii` 记录。
6. 新 Android keystore 生成并配到 CI secrets（拍板不复用旧签名）。
7. 浏览器扩展商店条目改名（打包密钥不变）。

> 全量门史：17615 绿(d23fa7f79 P1)→17619 绿(64386eaf4 P2)→17619 绿(215c9cc24 P3)→17619 绿(b1ff91994 P6-2/6/4b 合并批)。

## P7 终局清算（2026-08-07 用户拍板：新 app 零旧名，冻结点全解冻）

口径升级：存量持久化名不再冻结——Fushi 未发过版，存量用户全经迁移进来，旧名在迁移那一刻就地改写；旧字面量只允许活在「读旧数据的迁移代码」里。仓库顶层目录名 `hibiki/` 不在本轮（不进 app 产物，改动牵 CI/文档/Mac 同步，需用户单独确认）。

已落 fushi-mega（未 push develop，等 P7 各流合并后过终局门一起推）：
- [x] 扩展 wire `'app'` 双侧直切 `'fushi'`（扩展从未上架，双值兼容作废）+ Google 新 OAuth 客户端落码（iOS client id + Info.plist scheme + google-services.json 包名/client/证书哈希）——`6b12d38c6`
- [x] Dropbox 切用户自有新 app（App Folder 沙箱 `dv2sk1o33j6pfi8`；旧根 `/hibiki-data` 新 app 够不到=Dropbox 云根迁移失效，设备端为真相源可接受）——`fc3802734`
- [x] 合并门 5 红修复（4 品牌改名更新测试钉 + 1 回滚误改的 HibikiExport 冻结字面量）——`c6362d4c9`（merge `1c552c4ef`）

工作流（各自独立 worktree fable 子代理，完成合并后勾）：
- [x] B 扩展全量清扫（81 文件；agent 被限额 403 打断在 analyze，成果抢救提交 `ffea8f794`，merge `096f8bd31`，analyze+node 198 绿主代理补验）
- [x] W3 JS 桥：`hoshi.local`→`fushi.local` 硬切（取证无落库形态）+ hoshiReader 探针/文档残留；40 文件 `51f4f6f12`，merge `f877c8998`（lib 侧 hoshiReader 已由 P6-1 完成）
- [x] W5 运行时 hoshi 符号族（W3 盘出增补）：camel/大写/CSS/snake/`hibiki-reader` scheme/HOSHI_* 常量 6 族 ~2051 处、245 文件、8 提交（`1c8959019`..`6b25659e1`），守卫 4 禁模式变异实测，reader/lookup/tools/pages 4875 绿主代理补验
- [x] W1 DB 层：`fushi_paired_peers` 表改名（**实际 v68→v69**，任务书 v62 系过期口径）+ `fushi.db` 开库前改名（sidecar 先主文件后、老归档回退）+ fushi_core 清扫；3 提交（`a34881aac`/`335804844`/`992b7db2d`），254+45 定向绿
- [x] W2 存量值改写（7 子项 7 提交，分支 worktree-agent-a9054727d290f1e5b，Drift v70..v73）：W2-1 reader_ttu 族 `ff8e7bd09`（v70：src:reader_ttu: 命名空间+ttu_ shortKey 剥前缀+media_items 源键+current_source 值，两处 profile_settings 形态都改）/ W2-2 sasayaki 族 `54aa41ea0`（v71：sasayaki://→fushi-cue:、sasayakiColor JSON 键、custom_theme 偏好键；{sasayaki-audio} 别名 loadSettings 载入期改写后删枚举，i18n key 删除）/ W2-4 hibikiExport `7ab188959`（启动就地改名+死代码链 getHibikiExportDirectory 删除+白名单双名）/ W2-5 Magpie `102018e99`（'Hibiki: '→'Fushi: '，对账合成序先改名再清孤儿）/ W2-6 wire 键 `264e36ca2`（写侧只写 runningFushiProcesses、读侧旧键回退锚清理条件）/ W2-7 hoshi_books+双键 `9e5df0f85`（v72：extract_dir/image_url 路径段+google_drive_hoshi_compat 清行；目录开库前就地改名；备份归档前缀写新读兼容；hoshi_anki_settings 载入期搬键并修复 AnkiDroid 绕过基类迁移的 W2-2 真洞）/ W2-3 hoshi:// 前缀 `5e5676894`（v73：media_identifier+unique_key 复合/裸双形态+override_title 键双形态；override 封面 hash 文件名启动清扫含 BUG-1317 legacy 形态）。守卫累计新增 10 禁模式全部变异实测；各批定向绿+全量 analyze 零告警；既有环境红仅 update_manifest_publish_race_test（拉不起 bash，未触碰）
- [x] W2 存量值改写（fable 子代理，7 子项 8 提交 ff8e7bd09..5e5676894+93d8f2bf8，Drift v70→v73 + 3 个启动迁移，守卫 +10 禁模式全变异实测；中途 API 断连一次 SendMessage 续跑）。**留人裁决 4 项**：sanitizeTtuFilename/~ttu-star~ 哨兵（bookKey 编码本体，建议永久冻结）、同步 wire ttuCharOffset/TtuProgress（ッツ第三方契约）、hibiki-theme: 分享码前缀（用户间 wire）、用户卡字面 tag 'hibiki'（W7 只改新卡默认值不动存量）
- [x] W4 文件名 git mv（fable 子代理 7 提交 f9034e59d..90f1c74c4）：188 文件（sync 60/reader 21/video 23/manga 5/UI·utils 76/packages 3）+ 词中类名清算；定向 10718 绿；保留 3 个外部契约文件名（Hoshi-Reader 互通、__hibikiRoot 真符号守卫）
- [x] W6 native 目录改名（fable 子代理 4 提交 3d9471891..ba35210ed）：4003 文件纯 mv + 290 处引用/CI/构建标识修正；原生 ctest 19/19 绿；顺修 HIBIKI_TORRENT_LIB 两侧劈叉真 bug
- [x] W7 Anki 新卡默认 tag `fushi`（主代理直做）：fushiTag 常量+Lapis 预览+i18n key `anki_tag_include_fushi` 17 语言（i18n_sync --rename）+登记表/静态守卫/ankimobile 钉值随改；`tagIncludeHibiki` 持久化 JSON 键族冻结；fushi_anki 391 绿
- [x] W8 `hibiki/`→`fushi/` 应用目录改名（fable 子代理 13 提交，tip 11a2dfd17）：mv + workspace/CI/tool/ci/文档/守卫扫描根全套路径；合并时 skip-worktree 密钥文件需先还原占位再 merge；收尾修 2 真红（node 采集脚本旧路径、镜像清单三方对齐排除 README）
- [x] 终局门 PASSED：**17646 tests ran, all tests passed**（fushi-mega 收官态；上一轮 17646-1 的唯一红为 W7 牵动钉值已修）
- 用户侧新增拍板：GitHub 仓库改名（hajisensai/hibiki→fushi + hibiki-hook→fushi-hook）用户未表态；TMDB/ASC 网页操作用户自办

## Phase 5 更新桥发布（2026-08-07/08 实施）

- 分支 `bridge-hibiki-final`（基线 513e49ff2 + 4 提交 6ae4ce55f/81055a76b/d863f0cee）：synthesize 全量切 fushi-*、发布签名走 LEGACY_* secrets、v1.3.2+1205、BUG-1459 安装器残留进程清扫、守卫 macOS/iOS 断言随基线实际资产名切 fushi
- **旧 Hibiki keystore 抢救**：主 checkout key.properties 被新 fushi 值覆盖后，旧密码从 todo2357 worktree 副本找回（hibiki2024/alias hibiki）；材料备份 `C:\Users\wrds\fushi-keys\legacy-hibiki\`（**永久保留，桥再发都靠它**）；CI 配 LEGACY_KEYSTORE_* ×4。⚠️ gh secret set 用 PowerShell 管道会带 CRLF 致 base64 解码失败——8 个 secrets 全部用 `-b` 重配过
- **桌面桥已发布**：debug-rolling `hibiki-1.3.2-debug.10182-windows-setup.exe` + fushi-1.3.2 macos/iOS；update-manifest latest-debug.json 顶层已指 v1.3.2-debug.10182（Windows 老包即刻可升桥）；Android APK run 31195316908 在跑（并发组序列化，排桌面 run 后）
- 首两轮 run 红根因：① 基线守卫要求 hibiki-*-macos.zip 与实际 fushi 资产名不符（守卫配套修复 f7dc39ce8 落在基线后）②LEGACY secret CRLF。均修

外部注册进度（用户侧）：Google 全完成（Android `-o3vcj`/iOS `-a5iep` client 已建已落码，同意屏改名）；新 keystore 已生成（`C:\Users\wrds\fushi-keys\`，SHA1 CC:39:...:B3，4 个 CI secrets 已配，key.properties 已落主 checkout 与本 worktree）；Dropbox 新 app 已建已落码（差 Permissions 勾 scope + redirect URI 两步）；Entra redirect 用户在改；TMDB/ASC 未动。

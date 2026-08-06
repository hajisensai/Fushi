# Hibiki → Fushi 改名与跨包名数据迁移 实现计划

- 日期：2026-08-06（同日用户拍板全量方案，见 §0）
- 基线：`develop@7176ef9a8`
- 状态：**决策已定稿，未开始实现**

---

## 0. 需求理解

将应用从 **Hibiki** 改名为 **Fushi**。用户的硬诉求是「不想让用户在后台看到包名还是 hibiki」，
因此 Android 侧 `applicationId` 必须改，不接受「只改显示名」的省事方案。

改包名在 Android 上等于全新应用，老用户的全部数据（`/data/user/0/app.hibiki.reader/`）
无法被新包读取。故本计划的**主体不是改名本身，而是跨包名的数据迁移链路**。

### 已定决策（2026-08-06 用户拍板：「全部改成 fushi，包括签名、包括目录、包括任何」）

| 决策 | 结论 | 依据 |
|---|---|---|
| Android 改包名 | **改**，新包名 `app.fushi.reader`（用户拍板 fushi；字面量如需调整仅在 Phase 0 定稿时改） | 用户诉求（包名可见性） |
| 迁移方式 | 老包名发过渡版 → 两版并存 → 一键迁移 → 校验 → 引导卸载 | 见 §3 |
| Android 签名 | **新建 fushi keystore**，不复用旧 keystore | 用户拍板「包括签名」；方案不依赖 signature 级权限，无功能损失 |
| iOS bundle id | **改**（`app.hibiki.reader` → `app.fushi.reader`，已落地 PR #784）；**iOS/macOS 旧数据不迁移**（2026-08-07 用户拍板「不用管 ios 和 mac 的旧数据，没人用」），新包全新开始，P2-4 废除 | 用户拍板「所有的」 |
| 桌面端改名 | 改显示名 + 二进制名 + **数据目录**（`%APPDATA%\Hibiki` → `%APPDATA%\Fushi`，一次性搬迁），**Inno `AppId` GUID 保持不变** | `hibiki.iss:14`，AppId 决定覆盖升级；GUID 对用户不可见、不含字样 |
| 卸载旧版 | 由 Fushi 发起 `ACTION_DELETE`，用户手动确认 | Android 无静默卸载能力（§3.3） |
| 内部代号 | **全量清理但只改代码**（标识符/字符串/文件名/产物名），注释一律不管；`hoshi` / `ttu` / `hibiki` / `Ht*` / `sasayaki` 全改（范围普查见 §1.5）；Manhhao/Niratan/shishamo 等第三方名与人名不管、原样保留 | 用户拍板「包括 app 内的 hoshi、hibiki、ttu…等名字」+ 同日二次拍板「改是要改代码，注释无所谓；1/2/3 不管了」 |

### 仍开放（不阻塞 Phase 0/1 设计，发布前定即可）

1. **过渡版的发布通道与最低版本要求**。老用户必须先升到过渡版才有迁移入口。

---

## 1. 现状事实（已核实，含 file:line）

### 1.1 身份标识

| 项 | 当前值 | 位置 |
|---|---|---|
| Android applicationId / namespace | `app.hibiki.reader` | `hibiki/android/app/build.gradle:123,143` |
| iOS bundle id | `app.hibiki.reader` | `hibiki/ios/Runner.xcodeproj/project.pbxproj:421` |
| macOS bundle id | `com.example.hibiki` | `hibiki/macos/Runner/Configs/AppInfo.xcconfig:11` |
| 自定义 URL scheme | `hibiki` | `AndroidManifest.xml:45,167`；`ios/Runner/Info.plist:103` |
| MethodChannel 前缀 | `app.hibiki.reader` | `hibiki/lib/src/utils/misc/channel_constants.dart:7` + Windows C++ 11 处 |
| Windows 单实例 mutex | `HibikiSingleInstanceMutex` | `windows/runner/main.cpp:113`；`update_launcher.cpp:20`；`hibiki.iss:30` |
| Windows 窗口标题（单实例判据） | `L"Hibiki"` | `windows/runner/main.cpp:131,178` |
| Windows 二进制名 | `hibiki` / `hibiki.exe` | `windows/CMakeLists.txt:4`；`Runner.rc:95,97` |
| Inno AppId（**不可改**） | `{{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}` | `hibiki.iss:14` |
| Windows 数据目录 | `%APPDATA%\Hibiki`、`%LOCALAPPDATA%\Hibiki` | 本机实测确认存在 |
| Android 数据根 | `/data/user/0/app.hibiki.reader/`（app 私有） | `app_paths.dart` 走 `path_provider` 默认，`isDesktopPlatform` 才读自定义根（:174,227） |
| 内容目录名 | `Hibiki/data` | `app_paths.dart:defaultDocumentsChildSegments` |
| DB 文件名 | `hibiki.db` | `packages/hibiki_core/.../database.dart:284` |

### 1.2 更新链

- 仓库：`kGitHubRepo = 'hajisensai/hibiki'`，另有 `kLegacyGitHubRepo`
  （`update_checker_release.dart:3,4`）。
- **资产名在旧版二进制里是硬编码的**：`platform_updater.dart:155-157`
  合成 `hibiki-$version-windows-setup.exe` / `hibiki-$version-macos.zip` /
  `hibiki-$version-<abi>.apk`。这是 GFW 无代理时的唯一可用路径
  （TODO-404 / BUG-292：只能从 302 拿 tag，拿不到 GitHub API 资产清单）。
- beta/debug 走 manifest（`update_checker_release.dart:588` `buildReleaseFromManifest`），
  自带真实资产清单，**不受改名影响**。stable 通道受影响。

### 1.3 迁移可复用的现成能力

| 能力 | 结论 | 位置 |
|---|---|---|
| 全量备份导出 UI | **已发布在用户手中**，Android 走系统分享 | `sync_settings_schema/backup.part.dart:145-225` |
| 备份内容 | `hibiki.db` 整库（永远整块，表间有 FK）+ 6 个可选文件树 | `backup_service.dart:19-85` |
| 按业务键增量合并 | ✅ **支持分批导入**，单事务、按业务键 upsert、带 per-category gate | `backup_merge_engine.dart:9-73` |
| 路径 rebase | 已有（为「换数据根」写的） | `backup_service.dart:88-115` |
| 备份元信息 `BackupMeta` | 只有 `bookCount`/`statsCount`/`videoBookCount`/`audiobookCount` + 各 root | `backup_service.dart:266-341` |

### 1.4 已确认的并存冲突

| 冲突 | 证据 |
|---|---|
| 互联服务端口 | `hibiki_sync_server.dart:100` `SyncServerPortInUseException`，端口是固定请求值，两版同开必冲突 |
| PROCESS_TEXT 取词菜单重复 | `AndroidManifest.xml:150` |
| 悬浮窗 / 无障碍 / 通知 / 媒体控制两套 | `AndroidManifest.xml:11,194` |
| `<queries>` 已存在（可低成本扩展） | `AndroidManifest.xml:258-260`（当前只声明 `com.ichi2.anki`） |

### 1.5 内部代号普查（2026-08-06 实测，决定「全量清理」的真实范围）

**范围口径（用户二次拍板）：只改代码（标识符、字符串、文件名、产物名），注释一律不管；
B/C 类（第三方署名/外部域名/第三方 app 名/人名）不管了，原样保留。**

#### A 类：我方内部代号（改，这是 Phase 6 的主体）

| 代号 | 实际角色 | 分布 | 处置 |
|---|---|---|---|
| `hoshi` | JS 桥全局 `window.hoshiReader` | 阅读器 17 个 JS/CSS 注入封装 + `webview.part.dart`(178 处) + `audiobook_bridge.dart`(98 处) 等，运行时符号**不持久化** | 全局改 `window.fushiReader`，机械替换，无迁移需求 |
| `hoshi` | 词典引擎 `hoshidicts`（C++ + FFI + DLL/so 名） | `native/hoshidicts/`、`packages/hibiki_dictionary`（engine 73 处 + FFI 绑定 29 处）；DLL 名随包分发**用户可见** | 改 `fushidicts`：C ABI 符号、库文件名、JNI、CMake target 同步改；上游 fork 基线 `UPSTREAM.md` 记录改名映射 |
| `hoshi` | 磁盘目录 `hoshi_books` | epub/manga importer + storage 5 文件 | **持久化名**：新装写 `fushi_books`；迁移导入器把老目录内容落到新名（§3 P2-2 顺带完成，桌面端在数据目录搬迁时改名） |
| `ttu` | 持久化偏好键 `reader_ttu` / `setTtu*` / 同步 wire 模型 `ttu_models.dart` / DB 迁移阶梯 | `reader_hibiki_source.dart`(101) / `settings_schema_reading.dart`(83) / `reader_settings.dart`(74) / `database.dart`(63) / sync 3 文件 | 旧数据兼容残留（CLAUDE.md 冻结原因是「没有迁移方案」——**本计划就是迁移方案**）：迁移导入时旧键→新键映射一次做完；DB 迁移阶梯里的历史常量保留（只活在 migration 代码里，进白名单） |
| `ttu` | i18n key 前缀 `ttu_*` | `strings.g.dart` 1179 处（生成物），源头在 17 个 `*.i18n.json` | 走 `hibiki/tool/i18n_sync.dart --rename` 批量改（禁手改 json），改完 `dart run slang` |
| `hibiki` | 主身份 + `hibiki.db` 文件名 + 各处字面量 | 全仓 | 原计划 Phase 0-5 已覆盖；DB 文件新包落 `fushi.db`（迁移导入时改名，`database.dart:284`） |
| `hibiki` | **pub 包名体系**：app 包 `hibiki` + `hibiki_core`/`hibiki_audio`/`hibiki_anki`/`hibiki_platform`/`hibiki_dictionary`/`hibiki_torrent` + workspace 名 `hibiki_workspace` | `package:hibiki/` import 出现在 **692 个文件**；Melos workspace + 各 pubspec | 全部改 `fushi*`：包目录名、pubspec `name`、全仓 import 路径、dependency_overrides、Melos 配置一把改（纯机械但爆炸半径最大，独立批次 P6-5） |
| `hibiki` | **galgame helper 产物名**：`hibiki_voice_injector.exe` / `hibiki_voice_hook.dll` / `hibiki_unity_audio_extract.exe` + CMake target/测试名 + adapter 头注释里的组件名 | `native/galgame_hook/`（`build_distribution.ps1:110-200`、`CMakeLists.txt`）、`.github/workflows/voice-hook-helper.yml`、随包 `galgame_helper/` zip | 进程名在任务管理器**用户可见**，全改 `fushi_voice_*`；IPC 契约（shm/pipe 对象名）两侧同 PR 改（CLAUDE.md 硬规则）；`engine-support.yaml` 与 helper 在线更新通道同步 |
| `hibiki` | **torrent native 库**：`hibiki_torrent_ffi` DLL（随 Windows 包分发） | `native/hibiki_torrent/CMakeLists.txt` | 改 `fushi_torrent_ffi`：CMake target、DLL 文件名、Dart FFI `DynamicLibrary.open` 查找名同步 |
| `Ht` | `hibiki_torrent` 的 FFI DTO 类前缀（Hibiki Torrent 缩写）：`HtTorrentStatus` / `HtFileEntry` / `HtPeerInfo` 等 **11 个类** | `packages/hibiki_torrent/` | 改 `Ft*`（Fushi Torrent），纯代码符号无持久化 |
| `sasayaki` | 有声书字幕重匹配子系统代号：`SasayakiRematch` / `SasayakiMatchCodec` / `sasayaki_rematch.dart` | audiobook 域 + anki 2 个 repo + epub_book | 非身份代号，改**描述性英文名**（如 `SubtitleRematch`），不硬套 fushi |

#### B/C 类：不改（用户 2026-08-06 二次拍板「不管了」）

- `Manhhao` 版权行（`popup.js:84`）、外部域名 `hoshi-reader.manhhaoo-do.workers.dev`
  （`preferences_repository.dart:1499`）：第三方署名/别人的服务器，原样保留。
- `Niratan`（约 40 处设计出处注释）、`shishamo`（docs 人名）、`jidoujisho`
  （血统说明注释 7 处）、`Dandanplay` / `Qb*`（弹弹play、qBittorrent 等第三方服务的
  集成类名）：注释一律不改；第三方服务名是真实指称，保留。

> 目标状态：**代码标识符、用户可见字符串、文件/产物名**零 `hoshi`/`ttu`/`hibiki`/`Ht`/
> `sasayaki` 残留（DB 迁移阶梯、迁移导入器映射常量、B 类白名单除外）；注释不设限；
> 守卫测试按此口径固化（§5）。

---

## 2. 关键洞察

1. **老版的数据本身就是最好的备份。** 因此中转文件可以「每批传完即删」，
   不需要额外保留一份完整中转包。卸载老版是唯一不可逆的一步，必须排在全项校验之后。
2. **迁移的可靠性取决于校验的严格程度**，而当前 `BackupMeta` 没有 per-file 摘要，
   只能比对四个计数。这是必须补的能力缺口（§3.2 P2-1）。
3. **两版并存是常态而非瞬态**：用户可能在系统卸载框上点「取消」。
   老版的「已迁移只读态」必须是**持久化状态**，每次启动都生效，直到它真被卸掉。
4. **桌面端的 Hibiki 字样可见面反而更大**（`%APPDATA%\Hibiki`、安装目录、exe 名），
   而改名代价更小（AppId 兜底 + 数据可直接搬）。

---

## 3. 实现分期

关键路径是 Phase 1 → Phase 2。Phase 3/4/5/6 可并行
（Phase 6 中依赖迁移映射的部分——`hoshi_books`/ttu 旧键——落在 P2-2 里）。

### Phase 0：命名决策落地（无代码）

产出一张身份标识对照表（旧值 → 新值），覆盖 §1.1 全部条目，作为后续所有 Phase 的唯一真相源。
**必须先完成**，否则各 Phase 会各自决定命名而漂移。

---

### Phase 1：老包名过渡版（`app.hibiki.reader`，仍叫 Hibiki）

目标：让老用户手里的应用具备「把自己的数据完整交出去」和「交完自我降级」的能力。

#### P1-1 迁移导出器 `MigrationExporter`

新增 `hibiki/lib/src/migration/migration_exporter.dart`。

- 复用 `BackupService.createBackup`，但**按 `BackupCategory` 分批调用**，
  每批产出独立归档写入中转目录，导入方确认后即删该批。
- 批次顺序（**DB 优先**）：
  1. `database + settings + profiles + progress + stats`（无文件树，体积小，一到手 Fushi 即可显示完整书库）
  2. `dictionaryResources`
  3. `books`（`hoshi_books`）
  4. `audiobooks`
  5. `customFonts`
  6. `localAudio`（可选，默认关）
- **`videos` 永不打包**：原文件在用户共享目录，DB 存绝对路径，靠 rebase 接上即可。
- 中转目录：`/storage/emulated/0/Documents/Hibiki/migration/`
  （老版有 `MANAGE_EXTERNAL_STORAGE` 可写；不在 `/Android/data` 下，卸载老版不会被系统清掉）。
- 断点续传：每批完成写入批次状态，中断后从下一批继续。

类型签名（新增 Dart helper 一律显式标注）：

```dart
enum MigrationBatch { core, dictionaries, books, audiobooks, fonts, localAudio }

class MigrationBatchResult {
  const MigrationBatchResult({
    required this.batch,
    required this.archivePath,
    required this.manifest,
  });
  final MigrationBatch batch;
  final String archivePath;
  final MigrationManifest manifest;
}

class MigrationExporter {
  Future<MigrationBatchResult> exportBatch(MigrationBatch batch);
  Future<MigrationPlan> planBatches({required bool includeLocalAudio});
}
```

#### P1-2 迁移清单 `MigrationManifest`

**这是能力缺口，必须新写**（`BackupMeta` 只有四个计数，不足以判定「数据是否正常」）。

每批产出一份 JSON 清单：

- 各表行数（`books` / `video_books` / `reader_positions` / `bookmarks` /
  `reading_statistics` / `reading_hourly_logs` / `video_watch_statistics` /
  `mining_statistics` / `mined_sentences` / `favorite_words` / `profiles` /
  `profile_settings` / `media_type_profiles` / `book_profiles`）
- 每个文件的相对路径 + `size` + `sha256`
- 批次总字节数、源 `schemaVersion`、源 `appVersion`、源包名

> 复用 `backup_service.dart` 已有的 sha256 计算方式，不引入新依赖。

#### P1-3 迁移 UI + 引导

- 设置里新增「迁移到 Fushi」入口（新 i18n key 走 `hibiki/tool/i18n_sync.dart --add`，
  **禁止手改 17 个 json**，改完 `dart run slang`）。
- 三态引导，依据 `getPackageInfo("app.fushi.reader")` 判定：
  - 未安装 → 「下载 Fushi」（跳发布页）
  - 已安装 → 「开始迁移」
  - 迁移完成 → 「打开 Fushi」
- `AndroidManifest.xml:258` 的 `<queries>` 加一行 `<package android:name="app.fushi.reader" />`
  （Android 11+ 不声明则 `getPackageInfo` 查不到）。
- 全部批次导出完成后，拉起 Fushi：
  `getLaunchIntentForPackage` + `startActivity`，带 extra 标记来源为迁移。
  用户点按钮触发、老版在前台 → 属前台启动，不受后台启动限制。

#### P1-4 「已迁移只读态」

持久化标志位（落 `preferences` 表）。置位后**每次启动**都生效：

- **锁写**：不写阅读/观看进度、不制卡、不自动同步、不写统计。
- **主动停互联服务**（避免 `SyncServerPortInUseException` 打到用户脸上）。
- **注销系统级入口**：
  - `PackageManager.setComponentEnabledSetting` 禁用 PROCESS_TEXT activity
    （这样系统取词菜单里才真的少一项，而不是只藏 UI）
  - 停悬浮窗服务、引导用户关闭无障碍服务
- **保留重传通道**：导出入口必须可用。Fushi 校验发现某批缺失时要能回头重传。
- 首屏常驻引导：「数据已迁移到 Fushi，请使用新版本」+ 「重新导出」+ 「打开 Fushi」。

---

### Phase 2：新包名 Fushi（`app.fushi.reader`）

#### P2-1 全局身份替换

按 Phase 0 的对照表替换 §1.1 全部条目。重点：

- `build.gradle` 的 `applicationId` / `namespace`
- Android 侧 20 个 Java/Kotlin 文件的 `package` 声明
- MethodChannel 前缀：`channel_constants.dart:7` + Windows C++ 11 处
  （`flutter_window.cpp` 中 `clipboard_image` / `floating_lyric` / `clipboard_text` /
  `gal_hook_text` / `global_lookup` / `clipboard_panel` / `foreground_selection` /
  `window_capture` / `audio_loopback` / `voice_hook` / `magpie`）
  + `packages/hibiki_anki` 的 8 处测试常量 + `macos/Runner/AppDelegate.swift:26`
- FileProvider authority 用 `${applicationId}` 变量，**自动跟随**，无需手改
- `taskAffinity`（`AndroidManifest.xml:127,141`）
- URL scheme `hibiki` → 新 scheme（连带 `hibiki://auth/*`、`hibiki://lookup`、
  `hibiki://ankiFetch|ankiSuccess`）

#### P2-2 迁移导入器 `MigrationImporter`

- 首启（以及每次启动、迁移未完成时）扫描 `Documents/Hibiki/migration/`。
  **不依赖 intent extra**——用户自己手动点开 Fushi 也要能触发；intent 只是加速。
- 逐批导入：走 `BackupMergeEngine` 的 merge 模式（按业务键 upsert，
  已确认支持多次调用累加，不是整库替换）。
- **导入即改名**（跨包名迁移是持久化名换代的唯一窗口，一次做完，见 §1.5）：
  - DB 文件落地为 `fushi.db`（新包首启即以新名建库）；
  - `hoshi_books` 目录内容落到 `fushi_books`，DB 路径列 rebase 同步指向新名；
  - `reader_ttu` 等旧偏好键 → 新键映射表（单一常量文件收口，老键只在导入器出现）。
- 每批导入后立即按 `MigrationManifest` 全项校验：
  - 表行数逐项相等
  - 文件 `size` + `sha256` 逐个相等
  - 任一项不符 → 该批标记失败、保留中转文件、提示重传，**绝不进入卸载流程**
- 校验通过 → 删该批中转文件，进入下一批。

#### P2-3 卸载引导

全部批次校验通过后：

- 提示「迁移成功，卸载旧版 Hibiki？」
- `Intent(Intent.ACTION_DELETE, Uri.parse("package:app.hibiki.reader"))`
  → **系统卸载确认框，用户手动点确认**。
  （`PackageInstaller.uninstall()` 需要 `DELETE_PACKAGES`，
  属 `signature|privileged`，普通应用拿不到，无静默卸载可能。）
- 卸载框关闭后**重新 `getPackageInfo` 复查**——用户可能点了「取消」。
  查得到 = 未完成，保持引导状态，不要乐观标记成功。
- 确认卸载后清理 `Documents/Hibiki/migration/` 残留。

#### P2-4 iOS 迁移 —— **已废除**（2026-08-07 用户拍板）

iOS/macOS 旧数据不迁移（「不用管 ios 和 mac 的旧数据，没人用」）：
新 bundle id（PR #784 已落地）全新开始，不做导出/导入通道，R10 随之作废。
Phase 3 中 macOS 侧数据目录同理不搬（bundle id 变更后 `path_provider`
自动落新目录）；Windows 数据搬迁**保留**（Windows 有存量用户）。

---

### Phase 3：桌面端改名

- **`hibiki.iss:14` 的 `AppId` GUID 一个字都不能动**——它决定 Inno 走覆盖升级还是并存安装。
- 可改：`AppName` / `DefaultDirName` / `DefaultGroupName` / `OutputBaseFilename`。
- **必须同步改的三处**（改一处不改另两处会出问题）：
  `hibiki.iss:30` 的 `AppMutex` + `main.cpp:113` 的 `CreateMutexW` +
  `main.cpp:131` 的 `FindWindowW(nullptr, L"Hibiki")`。
  安装器有一段自定义 `OpenMutexW` 等待逻辑（`hibiki.iss:119-141`，TODO-549 修的死锁）
  依赖 mutex 名一致，不同步改会在文件占用时装坏。
- **exe 改名会让用户的视频文件关联静默失效**：`hibiki.iss:64-90` 注册的
  `Software\Classes\Applications\hibiki.exe\*` 和 `Hibiki.Video` ProgId 会指向不存在的 exe。
  → 安装器需要新增迁移步骤：写新 ProgID + 清理旧键。
- `%APPDATA%\Hibiki` → 新目录：需要一次性数据搬迁（桌面端可直接读写，
  不存在 Android 的隔离问题，复用 `data_root_migrator.dart` 的思路）。

---

### Phase 4：第三方注册

| 服务 | 动作 |
|---|---|
| Google Android OAuth client | **必须新建**（绑包名 + SHA-1，包名不可编辑），重下 `google-services.json` |
| Google iOS OAuth client | **必须新建**（绑 bundle id），同步改 `google_drive_auth.dart:107` + `Info.plist` 反转 scheme |
| Google desktop / web client | 不绑包名，**原样可用** |
| Google 同意屏 | 改应用名。⚠️ Hoshi 兼容模式用完整 `drive` 敏感 scope，若已过验证，改名可能触发重新审核 |
| Google Cloud 项目 ID `hibiki-reader` | **永久不可改**，只能改 display name |
| Dropbox（`lt0ufixv6si14dc`） | 改 redirect URI（`hibiki://auth/dropbox`）+ 显示名，**不必重建 app** |
| Microsoft Entra（`49f7e6d1-...`） | 同上（`hibiki://auth/onedrive`） |
| TMDB | 更新注册信息（应用名/网址），key 不失效 |
| 浏览器扩展 | `tools/browser-extension/manifest.json` 的 `name`；商店 ID 绑打包密钥不绑名字，不换 ID |
| Bangumi 请求 UA | `bangumi_client.dart:50`、`book_metadata_scraper.dart:76` |

---

### Phase 5：更新链过渡

- **CI 必须在过渡期同时上传两套资产名**（`hibiki-*` 与 `fushi-*`，内容相同）。
  否则所有已发布旧版本在 GFW 无代理路径下会 404
  （`platform_updater.dart:155-157` 的合成名是编译进旧二进制的，改不了）。
- 过渡期长度按「老版本存量衰减」定，建议不短于两个大版本周期。
- `kGitHubRepo` 若改仓库名：GitHub 有 301，但要实测 302 tag 解析那条路
  （代码里已有 `kLegacyGitHubRepo` 先例，说明改过一次并留了回退）。

---

### Phase 6：内部代号全量清理（范围见 §1.5，可与 Phase 3/4/5 并行）

按依赖顺序拆六个独立可合并的批次（注释一律不动，见 §1.5 口径）：

1. **P6-1 运行时符号**：`window.hoshiReader` → `window.fushiReader`
   （17 个 JS/CSS 注入封装 + webview part + audiobook/highlight bridge；
   不持久化，纯机械替换 + 阅读器真机冒烟）。
2. **P6-2 词典引擎改名**：`hoshidicts` → `fushidicts`
   （C ABI 符号、DLL/so 文件名、JNI、CMake target、FFI 绑定、`UPSTREAM.md` 改名映射；
   五平台构建全过才能合）。
3. **P6-3 ttu 残留清算**：i18n `ttu_*` key 走 `i18n_sync --rename` 批量改 +
   `dart run slang`；`setTtu*` 方法/`ttu_models.dart` 类型改名；
   持久化旧键的读取集中到迁移导入器的映射表（P2-2），主代码零 `ttu` 字样。
   DB 迁移阶梯中的历史常量保留（migration-only，白名单）。
4. **P6-4 字面量清扫**：代码字符串/文件名里残留的 `hibiki`/`Hibiki`
   （迁移代码对 `app.hibiki.reader` / `Documents/Hibiki/migration` 的有意引用
   收口到单一常量文件，进白名单）；`Sasayaki*` → 描述性英文名；`Ht*` → `Ft*`。
5. **P6-5 pub 包名体系**：`hibiki` app 包 + 6 个 `hibiki_*` 包 + `hibiki_workspace`
   → `fushi*`：目录名、pubspec `name`、**692 个文件的 `package:hibiki/` import**、
   dependency_overrides、Melos 配置。一把过、单独 PR（爆炸半径最大但纯机械，
   合并窗口内不与任何其它 PR 并行——全仓 import 改动跟谁都冲突）。
6. **P6-6 native 产物名**：galgame helper 三件套
   （`hibiki_voice_injector.exe` / `hibiki_voice_hook.dll` / `hibiki_unity_audio_extract.exe`
   → `fushi_voice_*`，任务管理器可见）+ IPC shm/pipe 对象名**两侧同 PR**（CLAUDE.md 硬规则）
   + `voice-hook-helper.yml` 发布名 + `engine-support.yaml`；
   `hibiki_torrent_ffi` DLL → `fushi_torrent_ffi`（CMake target + Dart `DynamicLibrary.open`）。
   helper 改名后必须重发（在线更新通道 + 随包 zip 同步）。

**硬边界（不改，守卫白名单固化）**：注释（一律不设限）、Manhhao 版权行、
`manhhaoo-do.workers.dev` 域名、第三方服务集成名（`Dandanplay*`/`Qb*` 等）、
Inno `AppId` GUID、Google Cloud 项目 ID、`kLegacyGitHubRepo` 类历史兼容常量、git 历史。

---

## 4. 风险登记

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | 用户不升级过渡版就卸载老版 | **数据永久丢失，无法挽救** | 公告 + 过渡版尽早发 + 在老包名多发几个版本让存量升上来 |
| R2 | 跨包名 restore 的路径 rebase 未实测 | 导入后书打不开 | Phase 2 落地必须真机跑通并断言 DB 路径列已改写（见 §5） |
| R3 | 存储不足导致导出失败 | 迁移中断 | 分批 + 传完即删；导出前预检可用空间并报出所需值 |
| R4 | 用户在系统卸载框点「取消」 | 两版长期并存，端口/菜单/悬浮窗冲突 | 只读态持久化，每次启动生效直到真被卸掉 |
| R5 | 用户在老版继续读书导致进度分叉 | 两边进度对不上 | 导出完成即进只读态锁写 |
| R6 | Google 敏感 scope 改名触发重新审核 | Drive 同步中断 | Phase 4 先在测试项目验证，正式改名前留缓冲 |
| R7 | Windows exe 改名后文件关联失效 | 双击视频无反应 | 安装器新增 ProgID 迁移 + 旧键清理 |
| R8 | `hoshidicts` 改名破坏 FFI/JNI 符号解析 | 词典整体不可用（核心功能） | P6-2 独立批次，五平台构建 + 词典查询集成测试全过才合并 |
| R9 | ttu 旧偏好键映射漏项 | 老用户阅读器设置静默回默认值 | 映射表从 `settings_schema_reading.dart`/`reader_settings.dart` 反向枚举生成，单测断言逐键覆盖 |
| R10 | iOS 手动通道用户中途放弃 | 数据滞留老包，误卸载即丢失 | 只读态在导出完成前不置位；未完成迁移时老包保持完全可用 |
| R11 | 老 Hibiki ↔ 新 Fushi 互联同步跨版本不兼容 | 过渡期多设备用户同步断链 | 明确不支持跨名互联：迁移引导要求全设备一起换代，wire 层拒绝旧标识并给明确报错 |

---

## 5. 验证矩阵

| 层级 | 内容 |
|---|---|
| 单测 | `MigrationManifest` 的生成/比对（行数 + 文件摘要）；批次规划纯函数；只读态谓词 |
| 单测 | `BackupMergeEngine` 多次调用累加不互相覆盖（当前无此用例，需补） |
| 守卫 | 源码扫描：不得再出现旧包名字面量（除迁移代码里对 `app.hibiki.reader` 的**有意**引用，白名单收口到单一常量） |
| 守卫 | 源码扫描扩展到全部旧代号：`hoshi` / `ttu` / `hibiki` / `Ht` DTO 前缀 / `sasayaki` 在**代码标识符与字符串**层零残留（注释行剥除后再匹配；白名单=§1.5 B 类 + DB 迁移阶梯 + 迁移导入器常量文件；匹配带词边界，防短名子串假阳） |
| 单测 | ttu 旧键→新键映射表逐键覆盖（从设置 schema 反向枚举，防 R9 漏项） |
| 守卫 | 新守卫必须做变异实测（把断言字面量塞进注释后确认测试转红） |
| 集成 | **真机**：老版导出 → 装新包 → 导入 → 直接查 DB 断言路径列已 rebase、书能打开、进度对得上 |
| 集成 | 焦点驱动（`FocusDriver` / `sendKeyEvent`，禁坐标点击），Enter 确认不用空格 |
| 构建 | `flutter analyze`（含 test）+ `dart run tool/flutter_test_failures.dart --no-pub`（只认末行 verdict + 退出码）|
| 构建 | Android 资源/manifest 改动 → `hibiki/android/` 下 `.\gradlew.bat :app:assembleRelease` |
| 合并后 | 目录枚举型守卫整批（35 条，见 `docs/agent/fast-workflow.md`） |

---

## 6. 我的保留意见

按 CLAUDE.md「发现问题直接说」：

改 Android 包名的收益是**消除部分国产 ROM 应用详情页里的包名字样**——原生 Android
的应用信息页不显示包名，文件管理器也看不到（数据在 `/data/user/0/` 而非 `/Android/data/`）。
代价是 R1：**所有没走完迁移的老用户数据永久丢失**，这个损失面无法用技术手段消除。

对比之下桌面端的 Hibiki 字样可见面更大（`%APPDATA%\Hibiki`、安装目录、exe 名），
而改名代价小得多（AppId 兜底 + 数据本地可搬）。

如果哪天想收缩范围，**保 Android 包名、只改桌面端 + 全平台显示名**是性价比最高的切法，
本计划的 Phase 3/4/5 可以独立成立。

**2026-08-06 用户已明确拍板全量方案**（包名、签名、目录、内部代号一律 fushi），
上述意见仅留档，按全量执行。同日二次拍板收窄口径：**只改代码，注释不管**；
Manhhao/Niratan/shishamo 三处（第三方署名、外部域名、第三方 app 名、人名）**不管了**，
原样保留（见 §1.5）。

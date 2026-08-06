# Fushi 全量改名 进度台账（保活续工的唯一真相源）

- 计划：`docs/plans/2026-08-06-rename-fushi-migration.md`
- 工作区：`.claude/worktrees/rename-fushi-plan-v2`；每项开工从最新 `origin/develop` 拉分支
- 纪律：每项独立提交 → analyze 全量 + 定向测试 → 合并前 `dart run tool/flutter_test_failures.dart --no-pub` → push develop → **完成后才**勾掉本项并填真实提交哈希
- 保活 cron：`db6ae32b`（每小时 :43，7 天过期；全部完成后 CronDelete）
- ⚠️ 台账只准记已验证的事实；勾选必须带真实 develop 提交哈希

## 执行顺序与状态

- [x] Phase 0 身份对照表（见下；本文件即产出）
- [x] Apple 侧改名：bundle id（#784）、显示名/产物名/资产名（develop `a5022cd56`）
- [ ] P6-1 `window.hoshiReader` → `window.fushiReader`（运行时符号，机械替换 + 阅读器测试）
- [ ] P6-3 ttu 清算：`ttu_*` i18n key `i18n_sync --rename`、`setTtu*`/`ttu_models.dart` 改名、旧持久化键读取收口到单一常量
- [ ] P6-4 字面量清扫：`Ht*`→`Ft*`、`Sasayaki*`→`SubtitleRematch*`/`sentenceAudioPath`、代码字符串残留 hibiki 收口白名单
- [ ] P1-1 `MigrationExporter`（分批导出，复用 BackupService，中转 `Documents/Hibiki/migration/`）
- [ ] P1-2 `MigrationManifest`（表行数 + 文件 sha256 清单 + 单测）
- [ ] P1-3 迁移 UI 三态引导 + `<queries>` 声明 `app.fushi.reader` + 导完拉起 Fushi
- [ ] P1-4 已迁移只读态（锁写/停互联/注销 PROCESS_TEXT/保留重传/常驻引导）
- [ ] P2-1 Android 身份替换：applicationId/namespace/taskAffinity/Java 包目录/URL scheme/MethodChannel 常量（Dart+五端原生同 PR）
- [ ] P2-2 `MigrationImporter`（首启扫描/逐批 merge 导入/manifest 全项校验/失败保留重传）
- [ ] P2-3 卸载引导（ACTION_DELETE + getPackageInfo 复查取消分支）
- [ ] Phase 3 Windows：`fushi.exe`/安装器 AppName/`FushiSingleInstanceMutex` 三处同步/`Fushi.Video` ProgID 迁移+旧键清理/`%APPDATA%\Hibiki`→`Fushi` 搬迁
- [ ] Phase 5 更新桥：Win/Android `synthesizeStableAssetNames` 切 fushi（随 Phase 2/3 同 PR；发布时机用户定）
- [ ] P6-2 `hoshidicts`→`fushidicts`（C ABI/DLL/JNI/CMake/FFI/UPSTREAM.md；五平台构建门）
- [ ] P6-6 native 产物：gal helper 三件套 `fushi_voice_*` + IPC 对象名两侧同 PR + `hibiki_torrent_ffi`→`fushi_torrent_ffi`
- [ ] P6-5 pub 包名体系：`hibiki`→`fushi` app 包 + 6 内部包 + workspace + 全仓 import（最后做，单独 PR，不与他人并行）
- [ ] 收尾：源码扫描守卫（旧代号零残留 + 白名单收口）+ 变异实测
- [x] Phase 4 外部注册台账（agent 无法代办，清单见下）

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

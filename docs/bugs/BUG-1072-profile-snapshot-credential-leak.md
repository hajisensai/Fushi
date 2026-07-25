## BUG-1072 · 备份/Profile 分享泄漏凭据：判定散落三处且兜底锁死 sync_ 前缀，profile_settings 通道无判定

- **报告**：2026-07-25（用户：wrds，起因是审查一份准备公开分发的 9.3 GB 词典/本地音频备份包）
- **真实性**：✅ 真 bug（默认导出路径即触发）

### 根因

「一条 pref 能不能离开本设备」的判定被复制成三份，各自演化，且没有任何一份覆盖 `profile_settings` 表：

1. `hibiki/lib/src/sync/backup_service.dart:1341-1349`（改前）——白名单 `SyncRepository.deviceLocalPrefKeys` + `key LIKE 'sync_%password%' / 'sync_%token%' / 'sync_%secret%' / 'sync_%private_key%'` 的 SQL 兜底。
2. `hibiki/lib/src/profile/profile_repository.dart:354-362`（改前）——白名单 + 子串兜底，但 `if (!lower.startsWith('sync_')) return false;` 把兜底锁死在 `sync_` 家族。
3. `hibiki/lib/src/profile/profile_keys.dart:90-98`（改前）——`isExcludedPref` **完全没有凭据判定**，只筛 app 状态键。

由此两类真实泄漏：

- **不以 `sync_` 开头的凭据全员漏网**：`media_source_secret_<id>`（SFTP/FTP 密码 + 私钥 PEM，base64 明文，`hibiki/lib/src/media/source/media_source_credential_store.dart:37`）、`qb_connection_config`（qBittorrent WebUI 明文密码 JSON，`hibiki/lib/src/models/preferences_repository.dart:968`）、`yomitan_api_key` / `jimaku_api_key` / `manga_cloud_ocr_api_key` / `video_scraper_tmdb_api_key`。三处判定一个都拦不住。
- **`profile_settings` 是一条无人看守的旁路**：`ProfileRepository.snapshotCurrentSettings`（`profile_repository.dart:131-141`）把**全部** Drift prefs 逐行复制进 `profile_settings`，而导出只 DELETE `preferences`。`defaultBackupExportCategories()`（`hibiki/lib/src/sync/sync_settings_schema/backup.part.dart:8-11`）默认勾选 `profiles`，所以只要设备切换过一次 Profile，`preferences` 那份删了也白删——凭据以 `category='pref'` 行原样躺在导出的 `hibiki.db` 里。

同一缺口还导致一个独立的行为 bug：`applyProfile` 用快照覆盖当前 prefs，于是切换 Profile 会把 A Profile 快照里的同步凭据写进 B Profile；这些 key 按定义是设备本地的，本就不该跟 Profile 走。

### 影响范围

- 触发条件：默认导出（不取消勾选 `settings`/`profiles`）+ 曾切换过 Profile。
- 已核实**不受影响**的：`AnkiConnect` host/port/apiKey 存 SharedPreferences 而非 Drift（`packages/hibiki_anki/lib/src/base_anki_repository.dart:63-80`），不进 zip；日志/崩溃文件从不打包。
- 本次起因的那份 `hibiki-backup-2026-07-15.hibiki.zip` 经实际解包核对**不含凭据**（`excludedCategories` 含 `settings` + `profiles`，`preferences` 仅 2 行、`profile_settings` 0 行），属于用户手动取消勾选而侥幸避开，不能作为代码无缺陷的证据。

### 修复

- **[x] ① 已修复** — 判定收敛为唯一真相源 `PrefRedactionPolicy`（新增 `hibiki/lib/src/sync/pref_redaction_policy.dart`），形状兜底不再锚定任何前缀，并补上 `media_source_secret_` 前缀族与 `qb_connection_config` 等点名键。四个调用点全部改道：
  - `backup_service.dart` `_stripCredentials` 改用该谓词，并新增 `_stripCredentialRowsFromProfileSnapshots` 同时清 `profile_settings` 的 `category='pref'` 行（存量快照无需 schema 迁移）；
  - `backup_service.dart` `_readDeviceLocalPrefs`（导入侧保留）改为用**同一谓词**过滤全部 prefs，而非枚举固定清单——剔除与保留由此在构造上无法漂移（前缀族 `media_source_secret_<id>` 本就无法枚举）；
  - `profile_keys.dart` `isExcludedPref` 前置该谓词，一处收敛即覆盖快照的写/读/剪枝三条路径，顺带修掉上面的跨 Profile 凭据串号；
  - `profile_repository.dart` `_isCredentialOrDeviceLocalPref` 退化为对该谓词的委托。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/sync/pref_redaction_policy_test.dart`（新增）：白名单全覆盖、旧 `sync_`-锚定实现漏掉的 7 个 key 逐一断言、形状兜底不锚前缀、13 个普通设置/内容 key 的零误伤守卫。
  - `hibiki/test/sync/backup_service_test.dart`（新增 3 例，端到端 export→import）：非 `sync_` 凭据不进 zip；**Profile 快照里的凭据不进 zip**（本 bug 的核心证据，同时断言真实 per-profile 偏好仍随包旅行）；导入保留本机被剔除的凭据（对称性，防「导出擦除→导入不还原」造成永久凭据丢失）。
  - `hibiki/test/profile/profile_keys_test.dart`（新增 4 例）：快照排除凭据、委托共享策略的防漂移守卫、真实 per-profile 偏好不被误排除、`BackupService.profilePrefCategory` 与 `ProfileKeys.categoryPref` 钉死一致。

### 备注

误伤面已核：全仓 128 个真实 pref key 中命中形状兜底的只有 3 个 `*_api_key`，全为真凭据；其余同形状字符串均为 i18n 标签，永不落 `preferences` 表。

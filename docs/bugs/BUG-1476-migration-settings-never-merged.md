## BUG-1476 · 跨包名迁移不搬任何设置：merge 引擎从不消费 settings 类别
- **报告**：2026-08-09（用户：迁移到 Fushi 后「互联之类的配置项没同步」）
- **真实性**：✅ 真 bug，已在用户真机（192.168.1.50，11.4GB 库完整迁移成功）取到硬证据
- **[x] ① 已修复** — 主因 `db94dc6db`（Fushi 侧：迁移接管老包 `preferences`，
  insert-if-absent）+ 次因 `802bd6f00`（bridge 侧：迁移导出不再剥设备本地数据）
- **[x] ② 已加自动化测试** — `fushi/test/sync/backup_merge_import_test.dart`
  （接管生效 / 不覆盖本库状态标记 / 默认不接管，共 3 例）+
  `hibiki/test/migration/migration_keeps_device_local_test.dart`（默认仍剥 /
  迁移保留，2 例）。两侧均做过变异实测：还原实现后对应用例转红。
- **备注**：互联只是用户最先注意到的一项，实际范围是**全部偏好**。

### 真机证据

用户老包 11.4GB 数据全部导入成功（6 批校验通过、内容树落地、中转目录已清）后，
从 `app.fushi.reader` 拉出 `files/fushi.db` 直接数行：

| 表 | 行数 | 说明 |
|---|---|---|
| `preferences` | **21** | 重度用户（26 部词典/11GB 库）本应数百条 |
| `fushi_paired_peers` | **0** | 互联配对设备 + token 全无 |
| `sync_baselines` | **0** | |
| `manga_online_sources` / `manga_extensions` | **0** | 在线源、扩展、信任签名全无 |
| `epub_books` | 4 | 内容表正常 |
| `reading_statistics` | 39 | 内容表正常 |

那 21 条 key 逐条看，**没有一条是用户设置**：6 条 `audiobook_pos_*`、
`favorite_sentences`、`audio_source_configs`、`local_audio_dbs`（恰好是 merge
引擎明确点名合并的三类），其余全是 Fushi 自身初始化标记（`first_time_setup`、
`prefs_version`、`builtInTagsSeeded`、`active_profile_id`、`*_migrated`、
`app_ui_scale`、`src:reader_fushi:margin_*`）。

即：阅读器字体/主题/行距/翻页、视频播放、Anki 制卡模板、快捷键、界面语言、
互联、同步后端——**一条都没搬过来**。

### 根因（两层，主因不修则次因白修）

**主因 · `fushi/lib/src/sync/backup_merge_engine.dart:140-167`**

merge 的完整执行序列里**没有任何 `preferences` 整表合并，也没有 `_wants('settings')`
分支**。只有三处点名的 pref 合并：`_mergeFavoriteSentencePrefs()`、
`_mergeAudiobookPositionPrefs()`、`_mergeAudioSourcePrefs()`。

而迁移在 `fushi/lib/src/migration/migration_exporter.dart:36`
（`categoriesForBatch`）给**每一批**都声明了 `BackupCategory.settings`，导入侧
`BackupService.mergeRestoreBackup` 把它转成 `enabledCategoryNames` 传给引擎——
引擎从不读它。**`settings` 在 merge 路径下是空承诺。**

这是语义错配：merge 的设计语义是「把**另一台**设备的**内容**并进来，不动本机
设置」（这对备份合并完全正确）；迁移要的是「同一台手机上把老包的一切原样搬到
新包」。迁移直接复用了 merge，语义正好相反。

**次因 · `fushi/lib/src/sync/backup_service.dart:1365 `_stripCredentials`**

导出侧还会主动剥离，三件事：
1. `PrefRedactionPolicy.isDeviceLocalOrCredential` 命中的 pref 行整删——白名单
   `SyncRepository.deviceLocalPrefKeys`（`sync_repository.dart:858`）含
   `serverEnabled`/`serverPort`/`serverPassword`、
   `fushiClientUrls`/`fushiClientToken`/`fushiClientUrl`、`deviceId`、
   `lanRequiresPin`、`serverTlsEnabled`、WebDAV/FTP/SFTP/OneDrive/Dropbox 全部
   地址与凭据、同步后端类型、`download_save_root`。
2. `_stripCredentialRowsFromProfileSnapshots` 删 Profile 快照里的 pref 行。
3. `_deviceLocalTables`（`backup_service.dart:527`）整表 DELETE：
   `fushi_paired_peers`、`sync_baselines`、全部 `manga_*`。

这条规则本身**没错**——它的前提是「备份要离开本机去另一台设备，明文 token 不能
漂过去」（BUG-816）。错在迁移复用了它：迁移是同一台手机、同一个用户、只换包名，
前提不成立。

### 实施后的形态

主因用 **insert-if-absent** 而不是覆盖：目标库是刚建的新包，已写入属于它自己的
状态标记（`prefs_version`、`first_time_setup`、`active_profile_id`、`*_migrated`）。
这些描述「本库处于什么状态」，拿老包的值去盖会让新库自称成另一个 schema 状态，
是真正会毁库的一步。`NOT EXISTS` 守卫天然把它们挡住，同时放行老包独有的用户设置。

**用户需重新导出一次才能拿回设置**：修复在导出/导入两侧，而用户的中转文件在上一轮
导入成功后已被删除。老包仍在设备上，重跑 `core` 批（6.9MB）即可，merge 幂等。

### 原修复方向（已按此实施）

1. **主因**：迁移不能走「merge 的 settings 空承诺」。要么给 merge 引擎补一条
   真正的 `preferences` 合并（迁移语义下用 source-wins，而非备份合并的
   target-wins），要么给迁移单独一条不经 merge 的设置落地路径。
   **只改次因无效**——导出侧不剥了，导入侧照样不读。
2. **次因**：给 `createBackup` 加显式的去向参数（如
   `BackupAudience{shared, sameDeviceMigration}`），迁移模式下跳过
   `_stripCredentials` 的三步。

**安全权衡必须显式记录**：迁移中转目录是 `Documents/Hibiki/migration/`（共享
存储）。不剥离意味着明文 token/密码短暂落在那里。缓解事实：Android 11+ 分区
存储下其他 app 读不到该目录的非媒体文件（正是本轮遇到的 `PathAccessException`
根源），且导入成功后中转文件立即删除（本轮真机已验证目录被整个清掉）。桌面端
无此隔离，实施时要单独判断。

### 影响范围

- 已迁移用户：内容（书/词典/有声书/统计/进度/评分）完好，**设置需手工重配**。
- 老包仍在设备上时可挽救：修好后只需重新导出 `core` 批（6.9MB，秒级）再导入一次，
  merge 幂等，不会重复内容。

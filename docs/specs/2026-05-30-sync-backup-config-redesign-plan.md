# 同步与备份配置重排 实现计划

> **执行说明**：本计划逐任务执行，每任务 `dart format` + 相关测试 + 编译 + commit。最后跑全量 `flutter test` 并做 Opus code review，发现问题修复后重审，循环到通过。配套设计：[2026-05-30-sync-backup-config-redesign-design.md](./2026-05-30-sync-backup-config-redesign-design.md)。

**Goal:** 同步设置页按后端作用域重排层级、移除假 SMB 并入 WebDAV、根因修复 folder_cache/audiobook_pos/备份导入三项，零破坏。

**Architecture:** 全部为 Drift `preferences` 键值层改动，无 schema bump、无迁移表、无 `*.g.dart` 重生成。SyncRepository 是配置枢纽与"设备本地 key"唯一真相源；设置页 `visibleSections` 纯函数驱动作用域门控。

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4，Drift，Slang i18n（`tool/i18n_sync.dart`）。

**执行顺序（依赖）：** F2 → deviceLocalPrefKeys → F1 → SMB 迁移 → SMB 移除 → F3 导入 → UI 重排 → i18n → 全量验证 → 审查循环。

**验证命令（仓库 `hibiki/` 下）：**
```
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test <路径>
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
```

---

## Task 1 — F2: audiobookPos 统一走 SyncRepository

**Files:** Modify `hibiki/lib/src/sync/sync_repository.dart`、`sync_manager.dart:348/445`、`sync_compare_dialog.dart:139`；Test `hibiki/test/sync/sync_repository_audiobook_pos_test.dart`(new)

- [ ] 在 SyncRepository 内容同步区后加：
```dart
// ── Per-book audiobook position (synced) ──────────────────────────
static const _keyAudiobookPositionPrefix = 'audiobook_pos_';

/// 每本书的有声书播放位置（毫秒）。默认 0 表示无记录。
Future<int> getAudiobookPosition(int bookId) =>
    _db.getPrefTyped<int>('$_keyAudiobookPositionPrefix$bookId', 0);
Future<void> setAudiobookPosition(int bookId, int positionMs) =>
    _db.setPrefTyped<int>('$_keyAudiobookPositionPrefix$bookId', positionMs);
```
- [ ] `sync_manager.dart:348` → `await _repo.setAudiobookPosition(book.id, posMs);`
- [ ] `sync_manager.dart:445` → `final posMs = await _repo.getAudiobookPosition(book.id);`
- [ ] `sync_compare_dialog.dart:138-140` → 用 `SyncRepository(db).getAudiobookPosition(local.id)`，**保留** `if (localAudioMs == 0) localAudioMs = null;`（nullable 契约）。
- [ ] 测试：`set(7,1234)`→`getPrefTyped<int>('audiobook_pos_7',0)==1234`；旧 `setPrefTyped('audiobook_pos_7',9)`→`getAudiobookPosition(7)==9`；默认 0。
- [ ] `flutter test test/sync/sync_repository_audiobook_pos_test.dart` 通过 → commit `refactor(sync): route audiobook position through SyncRepository`。

## Task 2 — SyncRepository.deviceLocalPrefKeys（F3 依赖）

**Files:** Modify `sync_repository.dart`；Test `hibiki/test/sync/sync_device_local_keys_test.dart`(new)

- [ ] 加静态清单（含 legacy hibiki_client_url；**不含** SMB（Task5 删）、**不含** 行为开关、**不含** folder cache、**不含** audiobook_pos）：
```dart
/// 导入备份时必须保留在本设备、不能被备份覆盖的 key（凭据/后端选择/服务器配置）。
/// 行为开关(auto/stats/audiobook/content)与内容(audiobook_pos_*)随备份恢复，不在此列；
/// folder cache 不还原、下次同步重建。
static const List<String> deviceLocalPrefKeys = <String>[
  _keyBackendType,
  _keyDesktopCredentials,
  _keyOneDriveToken,
  _keyDropboxToken,
  _keyWebDavUrl, _keyWebDavUsername, _keyWebDavPassword,
  _keyFtpHost, _keyFtpPort, _keyFtpUsername, _keyFtpPassword, _keyFtpUseTls,
  _keySftpHost, _keySftpPort, _keySftpUsername, _keySftpPassword, _keySftpPrivateKey,
  _keyServerEnabled, _keyServerPort, _keyServerPassword,
  _keyHibikiClientUrls, _keyHibikiClientToken, _keyHibikiClientUrl,
];
```
- [ ] 测试：断言含 `sync_backend_type`/`sync_webdav_password`/`sync_server_password`/`sync_hibiki_client_token`；断言**不含** `sync_auto_enabled`/`sync_content_enabled`/`sync_folder_cache`/`sync_root_folder_id`/任何 `audiobook_pos_` 前缀。
- [ ] commit `feat(sync): single source of truth for device-local pref keys`。

## Task 3 — F1: 重试不再清空磁盘 folder 缓存

**Files:** Modify `sync_manager.dart:69-72`；Test `hibiki/test/sync/sync_manager_folder_cache_test.dart`(new 或并入现有)

- [ ] 删除第 71 行 `await _repo.clearFolderCache();`，保留 `_backend.clearCache();`：
```dart
      if (e.isRetryable) {
        _backend.clearCache();
        // 仅丢内存态让重试重新解析；磁盘缓存保留，避免一次瞬时错误就让
        // 后续每次会话全量重做文件夹查找。陈旧 ID 会被后端拒绝(404/auth)后
        // 在错误路径自愈。后端切换/登出仍显式清缓存（有意失效）。
        try {
```
- [ ] 测试：用 fake backend 首调抛 retryable `SyncBackendError`、二调成功；预置 `setRootFolderId('root')`/`setFolderCache({'A':'a'})`；`syncBook` 后断言 `getRootFolderId()=='root'`（未被清空）。
- [ ] commit `fix(sync): keep folder cache across retryable errors (root-cause)`。

## Task 4 — SMB→WebDAV 一次性启动迁移

**Files:** Modify `sync_repository.dart`（加 `migrateSmbToWebDav`）、`app_model.dart`（initialise 挂载，994 后）；Test `hibiki/test/sync/sync_smb_migration_test.dart`(new)

- [ ] SyncRepository 加（用原始 key 字符串，迁移代码不依赖将被删的常量）：
```dart
/// 一次性迁移：把已废弃的 SMB(WebDAV 网关) 配置并入 WebDAV，删除全部 sync_smb_* 死键。
/// 仅当 WebDAV 对应项为空时搬运，绝不覆盖用户已有的 WebDAV 配置。幂等。
Future<void> migrateSmbToWebDav() async {
  final smbUrl = await _getStringOrNull('sync_smb_webdav_url');
  final smbUser = await _getStringOrNull('sync_smb_username');
  final smbPass = await _getStringOrNull('sync_smb_password'); // base64, 原样搬
  final backend = await _getStringOrNull(_keyBackendType);
  if (backend == 'smb') {
    if (smbUrl != null && (await _getStringOrNull(_keyWebDavUrl)) == null) {
      await _setString(_keyWebDavUrl, smbUrl);
    }
    if (smbUser != null && (await _getStringOrNull(_keyWebDavUsername)) == null) {
      await _setString(_keyWebDavUsername, smbUser);
    }
    if (smbPass != null && (await _getStringOrNull(_keyWebDavPassword)) == null) {
      await _setString(_keyWebDavPassword, smbPass); // 已是 base64
    }
    await _setString(_keyBackendType, SyncBackendType.webDav.name);
  }
  for (final k in const <String>[
    'sync_smb_webdav_url','sync_smb_username','sync_smb_password',
    'sync_smb_host','sync_smb_share','sync_smb_domain',
  ]) {
    await _deleteKey(k);
  }
}
```
- [ ] `app_model.dart` 在 `_database = HibikiDatabase(...)` / `_databaseOpened = true`（994）之后、任何同步使用前加：
```dart
      await SyncRepository(_database).migrateSmbToWebDav();
```
（需 `import 'package:hibiki/src/sync/sync_repository.dart';`）
- [ ] 测试：预置 `sync_backend_type='smb'`+`sync_smb_webdav_url/username/password`+`sync_smb_host`，跑 `migrateSmbToWebDav`，断言 backend=='webDav'、`getWebDavUrl/Username/Password` 落地、全部 `sync_smb_*` 已删；再断言"已有 webdav 不被覆盖"分支；幂等（再跑一次无变化）。
- [ ] commit `feat(sync): one-shot SMB→WebDAV migration on startup`。

## Task 5 — 移除假 SMB 后端与全部死代码

**Files:** Delete `hibiki/lib/src/sync/smb_sync_backend.dart`；Modify `sync_backend.dart`(enum+resolve)、`sync_repository.dart`(删 SMB 区 322-355)、`sync_settings_schema.dart`(删 `_SmbConfigWidget`、`sync.smb_config` item、`_isBackendSelectable`/`_backendLabel` 的 smb 分支、import)

- [ ] `sync_backend.dart`：删 `enum` 内 `smb,`；删 `resolveSyncBackend` 的 `case SyncBackendType.smb: return SmbSyncBackend.instance;`；删 `import '.../smb_sync_backend.dart';`。
- [ ] `sync_repository.dart`：删 322-355 整个 SMB 区（6 常量 + 12 访问器）。
- [ ] `sync_settings_schema.dart`：删 `import smb_sync_backend.dart`、`SettingsCustomItem(id:'sync.smb_config'...)`(71-78)、`_SmbConfigWidget` 整类(1249-1378)、`_isBackendSelectable` 的 `case smb`(842)、`_backendLabel` 的 `case smb`(871-872)。
- [ ] `flutter analyze` 0 error（编译验证消除所有 smb 引用）。
- [ ] commit `refactor(sync): remove fake SMB backend (folds into WebDAV)`。

## Task 6 — F3: 偏好感知的备份导入 + 崩溃恢复

**Files:** Modify `hibiki/lib/src/sync/backup_service.dart`、`app_model.dart`(挂 recover)、`sync_settings_schema.dart`(导入弹窗加说明)；Test `hibiki/test/sync/backup_import_preserve_test.dart`(new)

- [ ] backup_service.dart 顶部加 `import 'package:hibiki/src/sync/sync_repository.dart';`；常量加 `static const String _preserveSidecar = 'hibiki.db.sync-preserve.json';`。
- [ ] 重写 `importBackupFiles`（保留前读→sidecar→交换→写回→清扫）：
```dart
static Future<void> importBackupFiles({
  required String dbDirectory,
  required String zipPath,
}) async {
  final dbPath = p.join(dbDirectory, _dbName);
  final bytes = await File(zipPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final dbFile = archive.findFile(_dbName);
  if (dbFile == null) throw StateError('No $_dbName in backup archive');

  // 1) 交换前：从当前库读出设备本地 sync 配置，先落 sidecar（崩溃安全），再覆盖。
  final sidecar = File(p.join(dbDirectory, _preserveSidecar));
  final currentDb = File(dbPath);
  Map<String, String> preserved = const <String, String>{};
  if (currentDb.existsSync()) {
    preserved = await _readDeviceLocalPrefs(dbDirectory);
    await sidecar.writeAsString(jsonEncode(preserved));
    await currentDb.copy('$dbPath.pre-restore.bak');
  }
  final walFile = File('$dbPath-wal');
  if (walFile.existsSync()) await walFile.delete();
  final shmFile = File('$dbPath-shm');
  if (shmFile.existsSync()) await shmFile.delete();

  // 2) 覆盖为备份库字节。
  await currentDb.writeAsBytes(dbFile.content as List<int>);

  // 3) 把保留的设备本地配置写回新库。
  if (preserved.isNotEmpty) {
    await _applyPrefs(dbDirectory, preserved);
  }

  // 4) 成功清扫 sidecar + bak（避免磁盘泄漏）。
  await _safeDelete(sidecar.path);
  await _safeDelete('$dbPath.pre-restore.bak');
}

static Future<Map<String, String>> _readDeviceLocalPrefs(String dir) async {
  final db = HibikiDatabase(dir);
  try {
    final all = await db.getAllPrefs();
    final out = <String, String>{};
    for (final k in SyncRepository.deviceLocalPrefKeys) {
      final v = all[k];
      if (v != null) out[k] = v;
    }
    return out;
  } finally {
    await db.close();
  }
}

static Future<void> _applyPrefs(String dir, Map<String, String> prefs) async {
  final db = HibikiDatabase(dir);
  try {
    for (final e in prefs.entries) {
      await db.setPref(e.key, e.value);
    }
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

static Future<void> _safeDelete(String path) async {
  try {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  } catch (_) {/* best-effort cleanup */}
}

/// 启动时调用：若上次导入在覆盖后崩溃（sidecar 残留），把保留配置补写回当前库。
static Future<void> recoverPendingImport(String dbDirectory) async {
  final sidecar = File(p.join(dbDirectory, _preserveSidecar));
  if (!sidecar.existsSync()) return;
  try {
    final raw = await sidecar.readAsString();
    final map = (jsonDecode(raw) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v as String));
    if (map.isNotEmpty) await _applyPrefs(dbDirectory, map);
  } catch (_) {/* corrupt sidecar: drop it */}
  await _safeDelete(sidecar.path);
  await _safeDelete(p.join(dbDirectory, '$_dbName.pre-restore.bak'));
}
```
- [ ] `app_model.dart`：在 `migrateSmbToWebDav()` 调用之前加 `await BackupService.recoverPendingImport(_databaseDirectory.path);`（先恢复再迁移）。需 `import '.../backup_service.dart';`（若未导入）。
- [ ] `sync_settings_schema.dart` 导入确认弹窗 `_showConfirmDialog` 内容追加一行 `t.backup_import_preserve_sync_note`（Task 8 加 key）。
- [ ] 测试：构造一份"已 strip 密钥"的备份 zip + 一个含 `sync_backend_type='webDav'`/`sync_webdav_password` 的当前库；调 `importBackupFiles`，断言导入后库里这些设备本地 key 仍在、`sync_auto_enabled` 来自备份、`sync_folder_cache` 不存在、sidecar/bak 已删；单独测 `recoverPendingImport`：手写 sidecar→调用→断言写回且 sidecar 删除。
- [ ] commit `fix(backup): preserve device-local sync config across import (root-cause)`。

## Task 7 — UI 5 组重排 + 作用域门控

**Files:** Modify `sync_settings_schema.dart`（`buildSyncBackupDestination` + 加 `_isOAuthBackend`、账户段 visible、LAN visible、`_BackendSelectorWidget.onChanged` 复位 ftp_tls）；Test `hibiki/test/sync/sync_settings_visibility_test.dart`(new)

- [ ] 加纯函数：
```dart
bool _isOAuthBackend(SyncBackendType t) =>
    t == SyncBackendType.googleDrive ||
    t == SyncBackendType.oneDrive ||
    t == SyncBackendType.dropbox;
```
- [ ] 重排 `buildSyncBackupDestination` 为 5 组（见设计 §5）：
  - 组1 `t.sync_section_method`：后端选择；账户(visible `_isOAuthBackend`)；WebDAV/FTP/SFTP/Hibiki 配置框(沿用现有 backendType 门控)；LAN 发现(visible `==hibikiServer`)。
  - 组2 `t.sync_section_host_server`(footer `t.sync_section_host_server_footer`)：server_mode。
  - 组3 `t.sync_section_content`：auto/statistics/audiobook/content 四开关。
  - 组4 `t.sync_section_actions`：compare。
  - 组5 `t.sync_section_backup`：export/import。
- [ ] 账户段从独立 section 移入组1，并加 `visible: (ctx) => _isOAuthBackend(_syncSettings(ctx).backendType)`。
- [ ] `_BackendSelectorWidget.onChanged`：在 `setBackendType` 后，若旧值==ftp 且新值!=ftp，`await repo.setFtpTlsEnabled(false);`（清残留）。
- [ ] 测试：对每个 `SyncBackendType` 构造 `SettingsContext`，调 `buildSyncBackupDestination().visibleSections(ctx)`，断言 section.title/item.id 集合匹配设计 §5 矩阵（账户仅 OAuth、LAN 仅 hibikiServer、无 `sync.smb_config`、服务器/内容/操作/备份恒在）。
- [ ] commit `feat(sync): regroup sync & backup settings by backend scope`。

## Task 8 — i18n（新 key，删 SMB key）

**Files:** 经 `hibiki/tool/i18n_sync.dart`；禁止手改 json。

- [ ] `dart run tool/i18n_sync.dart --remove sync_backend_smb`（及其它仅 SMB key，若 i18n_sync 报残留）。
- [ ] `--add` 新 key（en/zh）：`sync_section_method`、`sync_section_host_server`、`sync_section_host_server_footer`、`sync_section_content`、`sync_section_actions`、`sync_section_backup`、`backup_import_preserve_sync_note`。
- [ ] 运行 slang 生成 `strings.g.dart`；`flutter test test/i18n`（完整性）通过。
- [ ] commit `i18n(sync): section keys for regrouped settings; drop SMB`。

## Task 9 — 全量验证

- [ ] `dart format .`
- [ ] `flutter analyze`（0 error）
- [ ] `flutter test`（全绿）
- [ ] 失败即根因修复后重跑；commit `test: …` / `fix: …`。

## Task 10 — Opus code review 循环

- [ ] spawn code-reviewer subagent（**`model: "opus"`**，hibiki/CLAUDE.md 硬性），审本批 diff 对照设计：作用域矩阵、SMB 迁移幂等与不覆盖、F1 自愈、F3 崩溃恢复与密钥不泄露、向后兼容。
- [ ] 按 `superpowers:receiving-code-review` 处理：合理项修复、可疑项核实；修完重审，循环到通过。
- [ ] 通过后最终 commit（如有）。

---

## Self-Review（对照设计自检）

- Spec §5 层级 → Task 7 ✓；§6 F1/F2/F3 → Task 3/1/6 ✓；§7 SMB 移除+迁移 → Task 4/5 ✓；§8 i18n → Task 8 ✓；§10 测试 → 各任务 test + Task 9 ✓。
- 类型一致：`getAudiobookPosition/setAudiobookPosition`、`deviceLocalPrefKeys`、`migrateSmbToWebDav`、`recoverPendingImport`、`_isOAuthBackend` 全程同名。
- 无占位：每任务含具体文件/行、可运行命令、测试要点。
- 顺序依赖：Task2(deviceLocalPrefKeys) 先于 Task6(F3 引用它)；Task4(迁移用字符串字面量) 不依赖 Task5 删除的常量；Task5 删 SMB 后 Task8 才清 i18n。

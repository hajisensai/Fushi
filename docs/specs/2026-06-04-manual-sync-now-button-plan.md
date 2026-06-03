# 「立即同步」按钮 + 同步反馈 实现计划

> REQUIRED SUB-SKILL: superpowers:executing-plans。步骤用 `- [ ]` 勾选。

**Goal:** 同步设置加「立即同步」按钮，一键触发完整双向全量同步（绕过自动同步开关 + 5 分钟冷却，仍尊重各资产 gate 与后端认证）；反馈用「行内转圈 + 完成 SnackBar 摘要」（用户已选），把当前被丢弃的 `SyncRunReport` 摘要出来。

**Architecture:** `sync_auto_trigger.dart` 新增 `runManualFullSync()`（复用 `_autoSyncMutex`/`_syncingIds`/`syncInProgress`，但不查 `isAutoSyncEnabled`、不查冷却，返回 `ManualSyncResult{outcome, report}`）。设置里加 `SettingsCustomItem` → `_SyncNowWidget`（照搬现成 `_BackupExportWidget`：本地 `_syncing` 转圈 + 完成 `_showSnackBar` 摘要）。

**Tech Stack:** Flutter 3.44.0；Slang i18n（i18n_sync + slang）；现有 `SyncOrchestrator.run()` 返回 `SyncRunReport`。

**当前事实（已核）:** `syncInProgress` 仅驱动 `home_page.dart:248` 的 PopScope 挡返回键；全量同步无进度/无摘要（report 在 `sync_auto_trigger.dart:108` 被丢）。手动入口仅 `sync.compare`(books-only)。`_BackupExportWidget`(`sync_settings_schema.dart:597`) 是异步带转圈反馈的既有范式。三目录来源同 `home_page.dart:62-68`。

---

### Task 1: runManualFullSync（sync_auto_trigger.dart）

**Files:** Modify `hibiki/lib/src/sync/sync_auto_trigger.dart`

- [ ] **Step 1: 加结果类型 + 函数**（放在 `_runAutoSyncAll` 之后）

```dart
/// 手动「立即同步」的结果。
enum ManualSyncOutcome { completed, notConfigured, busy }

class ManualSyncResult {
  const ManualSyncResult(this.outcome, [this.report]);
  final ManualSyncOutcome outcome;
  final SyncRunReport? report;
}

/// 用户手点"立即同步"：跑完整双向全量同步（同 [triggerAutoSyncOnAppOpen]），
/// 但绕过自动同步开关与 5 分钟冷却（手动是显式意图）。仍尊重各资产 gate 与后端
/// 认证；与后台同步共用 [_autoSyncMutex]，避免并发改 singleton backend 状态。
Future<ManualSyncResult> runManualFullSync({
  required HibikiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
}) async {
  if (!_syncingIds.add('__all__')) {
    return const ManualSyncResult(ManualSyncOutcome.busy);
  }
  _activeSyncs++;
  syncInProgress.value = true;
  try {
    return await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      final backend = resolveSyncBackend(await repo.getBackendType());
      await backend.restoreAuth(repo);
      if (!await backend.isAuthenticated) {
        return const ManualSyncResult(ManualSyncOutcome.notConfigured);
      }
      final orchestrator = SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: dictionaryResourceRoot,
        audioDatabaseRoot: audioDatabaseRoot,
        tempDir: tempDir,
        syncStats: await repo.isSyncStatsEnabled(),
        syncAudioBookPosition: await repo.isSyncAudioBookEnabled(),
        syncContent: await repo.isSyncContentEnabled(),
        syncAudioBookFiles: await repo.isSyncAudioBookFilesEnabled(),
        syncDictionary: await repo.isSyncDictionaryEnabled(),
      );
      final SyncRunReport report = await orchestrator.run();
      return ManualSyncResult(ManualSyncOutcome.completed, report);
    });
  } finally {
    _syncingIds.remove('__all__');
    _activeSyncs--;
    syncInProgress.value = _activeSyncs > 0;
  }
}
```

> 不 catch：错误冒泡给按钮 widget 渲染 `friendlySyncErrorDetail`。`SyncRunReport`/`SyncOrchestrator`/`SyncRepository`/`Directory`/`HibikiDatabase` 均已在该文件 import。

- [ ] **Step 2: analyze**

Run: `cd hibiki && flutter analyze lib/src/sync/sync_auto_trigger.dart`
Expected: No issues.

---

### Task 2: i18n 11 键

**Files:** `hibiki/lib/i18n/*`（经脚本 + slang）

- [ ] **Step 1: 加键**

```bash
cd hibiki
dart tool/i18n_sync.dart --add sync_now 'Sync now' '立即同步'
dart tool/i18n_sync.dart --add sync_now_hint 'Run a full two-way sync with the cloud now' '立即与云端做一次完整双向同步'
dart tool/i18n_sync.dart --add sync_now_busy 'A sync is already running' '同步进行中，请稍候'
dart tool/i18n_sync.dart --add sync_now_no_changes 'no changes' '无新增'
dart tool/i18n_sync.dart --add sync_now_done 'Synced · $detail' '同步完成 · $detail'
dart tool/i18n_sync.dart --add sync_now_failed_suffix ' · $count failed' ' · $count 项失败'
dart tool/i18n_sync.dart --add sync_now_books_in '↓$count books' '↓$count 本书'
dart tool/i18n_sync.dart --add sync_now_dicts_in '↓$count dictionaries' '↓$count 词典'
dart tool/i18n_sync.dart --add sync_now_dicts_out '↑$count dictionaries' '↑$count 词典'
dart tool/i18n_sync.dart --add sync_now_audio_in '↓$count audiobooks' '↓$count 有声书'
dart tool/i18n_sync.dart --add sync_now_audio_out '↑$count audiobooks' '↑$count 有声书'
```

- [ ] **Step 2: 生成 + 格式化**

```bash
cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart
```
Expected: `t.sync_now` / `t.sync_now_done(detail:...)` / `t.sync_now_books_in(count:...)` 等生成；带 `$` 的为带参函数。

---

### Task 3: _SyncNowWidget + 接入 schema

**Files:** Modify `hibiki/lib/src/sync/sync_settings_schema.dart`

- [ ] **Step 1: import**

确认/追加：`import 'package:hibiki/src/sync/sync_auto_trigger.dart';`（提供 `runManualFullSync`/`ManualSyncResult`/`ManualSyncOutcome`）。

- [ ] **Step 2: 在 `sync.compare` 之前插入按钮项**

`sync_section_actions` 的 items 列表，`SettingsActionItem(id: 'sync.compare', ...)` 之前加：

```dart
          SettingsCustomItem(
            id: 'sync.sync_now',
            icon: Icons.sync,
            builder: (SettingsContext ctx) =>
                _SyncNowWidget(settingsContext: ctx),
          ),
```

- [ ] **Step 3: 加 _SyncNowWidget**（放在 `_BackupExportWidget` 附近，文件末尾的 widget 区）

```dart
class _SyncNowWidget extends StatefulWidget {
  const _SyncNowWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SyncNowWidget> createState() => _SyncNowWidgetState();
}

class _SyncNowWidgetState extends State<_SyncNowWidget> {
  bool _syncing = false;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      final AppModel appModel = widget.settingsContext.appModel;
      final ManualSyncResult result = await runManualFullSync(
        db: appModel.database,
        dictionaryResourceRoot: appModel.dictionaryResourceDirectory,
        audioDatabaseRoot:
            Directory('${appModel.appDirectory.path}/audiobooks'),
        tempDir: appModel.temporaryDirectory,
      );
      if (!mounted) return;
      switch (result.outcome) {
        case ManualSyncOutcome.notConfigured:
          _showSnackBar(context, t.sync_compare_unavailable);
        case ManualSyncOutcome.busy:
          _showSnackBar(context, t.sync_now_busy);
        case ManualSyncOutcome.completed:
          _showSnackBar(context, _summary(result.report!));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          context,
          t.sync_error(message: friendlySyncErrorDetail(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _summary(SyncRunReport r) {
    final List<String> parts = <String>[
      if (r.booksImported > 0) t.sync_now_books_in(count: r.booksImported),
      if (r.dictionariesImported > 0)
        t.sync_now_dicts_in(count: r.dictionariesImported),
      if (r.dictionariesExported > 0)
        t.sync_now_dicts_out(count: r.dictionariesExported),
      if (r.audiobooksImported > 0)
        t.sync_now_audio_in(count: r.audiobooksImported),
      if (r.audiobooksExported > 0)
        t.sync_now_audio_out(count: r.audiobooksExported),
    ];
    final String head =
        parts.isEmpty ? t.sync_now_no_changes : parts.join(' · ');
    final String done = t.sync_now_done(detail: head);
    return r.errors.isEmpty
        ? done
        : '$done${t.sync_now_failed_suffix(count: r.errors.length)}';
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: t.sync_now,
      subtitle: t.sync_now_hint,
      icon: Icons.sync,
      controlBelow: true,
      trailing: _syncing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton(
              onPressed: _syncNow,
              child: Text(t.sync_now),
            ),
    );
  }
}
```

> 需 `SyncRunReport` 类型可见 → 确认 `sync_settings_schema.dart` 已 import `sync_orchestrator.dart`（`isReservedSyncFolderName`/`SyncRunReport` 同文件）；compare 已用其常量，按需补 import。

- [ ] **Step 4: analyze**

Run: `cd hibiki && flutter analyze lib/src/sync/sync_settings_schema.dart lib/src/sync/sync_auto_trigger.dart`
Expected: No issues.

---

### Task 4: 接线守卫测试

**Files:** Modify `hibiki/test/settings/settings_redesign_static_test.dart`

- [ ] **Step 1:** 把 `'lib/src/sync/sync_settings_schema.dart'` 的预期列表（line 37-40）追加两项：

```dart
    'lib/src/sync/sync_settings_schema.dart': <String>[
      'SettingsDestination buildSyncBackupDestination',
      'SettingsDestinationId.syncBackup',
      'sync.sync_now',
      'runManualFullSync',
    ],
```

- [ ] **Step 2: 跑该测试**

Run: `cd hibiki && flutter test test/settings/settings_redesign_static_test.dart --no-pub`
Expected: PASS。

---

### Task 5: 全量验证 + 提交

- [ ] **Step 1:** `cd hibiki && dart format`（仅本轮文件）：`lib/src/sync/sync_auto_trigger.dart lib/src/sync/sync_settings_schema.dart test/settings/settings_redesign_static_test.dart`
- [ ] **Step 2:** `flutter analyze`（无新增 error）
- [ ] **Step 3:** `flutter test --no-pub`（绿；既有 7 个并发 agent 的预存失败不计）
- [ ] **Step 4:** 提交（只 stage 本轮文件：sync_auto_trigger / sync_settings_schema / i18n / static test / 本计划）

> Android 无改动，无需 assembleRelease。
> **设备复测（声明修好前）**：真机点「立即同步」→ 行内转圈 → 完成 SnackBar 摘要；未配置后端 → "请先设置同步"；正在同步再点 → "进行中"。

---

### Task 6: Opus 代码审查

- [ ] 派生 code-reviewer 子代理（`model: "opus"`）：核 runManualFullSync 绕过冷却/auto-enable 是否正确、mutex/syncInProgress 记账无泄漏、错误冒泡、摘要边界（全 0→无新增、有错→后缀）、与后台 `_runAutoSyncAll` 行为不冲突、i18n 11 键完整。

---

## Self-Review
- 覆盖：①按钮（Task3）②一键全量绕冷却（Task1）③反馈=转圈+SnackBar 摘要（Task3 `_summary`）④未配置/忙提示 ⑤尊重 gate（用 repo.isSync*Enabled）⑥守卫（Task4）。
- 占位符：无。
- 类型一致：`ManualSyncResult`/`ManualSyncOutcome`/`runManualFullSync` Task1 定义，Task3 一致引用。
- 风险：manual 与后台 sweep 都用 `_syncingIds.add('__all__')`+`_autoSyncMutex`，并发安全；report 现在被消费（不再丢弃）。

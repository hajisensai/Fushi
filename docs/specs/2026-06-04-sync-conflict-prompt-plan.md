# 同步冲突弹窗确认 实现计划（Phase 1：阅读进度）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 所有派生子代理用 `model: "opus"`。

**Goal:** 让阅读进度的「双边真分叉」在同步时弹窗让用户选方向，而不是被静默 last-write-wins 覆盖；单边改动仍自动同步、阅读中不被打断。

**Architecture:** 新增 `SyncBaselines` 表记录每本书进度维度「上次同步双方一致的版本」，做三方判定（local/remote/base）。冲突时同步跳过该项、不写 base；经全局 navigatorKey + 「在书内不弹」闸门弹复用的 `SyncCompareDialog` 冲突视图，用户选向后写 base。

**Tech Stack:** Dart/Flutter 3.44.0、Drift（hibiki_core schema v14→v15）、Slang i18n、Riverpod。

设计来源：`docs/specs/2026-06-04-sync-conflict-prompt-design.md`。有声书位置是 Phase 2（本计划不含），见 design 第 6 节。

---

## 文件结构

| 文件 | 责任 | 动作 |
|---|---|---|
| `packages/hibiki_core/lib/src/database/tables.dart` | `SyncBaselines` 表定义 | 改 |
| `packages/hibiki_core/lib/src/database/database.dart` | schemaVersion 15 + v15 迁移 + 基线 CRUD | 改 |
| `hibiki/lib/src/sync/sync_progress_resolver.dart` | 纯函数三方判定 | 新建 |
| `hibiki/lib/src/sync/ttu_models.dart` | `SyncResult.conflict` 枚举值 | 改 |
| `hibiki/lib/src/sync/sync_manager.dart` | 接入 base：判定→跳冲突→成功写 base；`SyncBookResult.conflict` | 改 |
| `hibiki/lib/src/sync/sync_orchestrator.dart` | `SyncRunReport.conflicts` 汇总 | 改 |
| `hibiki/lib/src/sync/sync_auto_trigger.dart` | `ManualSyncResult.conflicts` 透出 | 改 |
| `hibiki/lib/src/sync/sync_conflict_prompter.dart` | 弹窗调度器（闸门+单飞+snooze+navigatorKey） | 新建 |
| `hibiki/lib/src/sync/sync_compare_dialog.dart` | `hasConflict` 收紧读 base；Apply 后写 base；冲突 only 模式 | 改 |
| `hibiki/lib/src/pages/base_source_page.dart` | 关书后拿 report 触发 prompter | 改 |
| `hibiki/lib/src/pages/implementations/home_page.dart` | app 启动后触发 prompter | 改 |
| `hibiki/lib/src/sync/sync_settings_schema.dart` | `_syncNow` 冲突弹窗 + 「N 冲突待解决」入口 | 改 |
| `hibiki/lib/i18n/*.i18n.json` | 冲突弹窗文案（经 i18n_sync.dart） | 改 |

---

## Task 1: `SyncBaselines` 表 + v15 迁移 + CRUD

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/tables.dart`
- Modify: `packages/hibiki_core/lib/src/database/database.dart`
- Test: `hibiki/test/database/sync_baselines_test.dart`（新建）
- Test: `hibiki/test/database/migration_test.dart`（扩展）

- [ ] **Step 1: 加表定义**

在 `tables.dart` 末尾追加（紧跟既有表风格，无外键——assetKey 是跨设备字符串身份，不指向本机 epub_books.id）：

```dart
// ── sync_baselines ──────────────────────────────────────────────────
// 每本书每个同步维度「上次同步成功时双方一致的版本」（共同祖先），
// 用于三方分叉检测。assetKey = sanitizeTtuFilename(book.title)（跨设备稳定）。
@DataClassName('SyncBaselineRow')
class SyncBaselines extends Table {
  TextColumn get assetKey => text()();
  TextColumn get dimension => text()(); // 'progress'（Phase 2 再加 'audiobook'）
  IntColumn get baseVersion => integer()();

  @override
  Set<Column> get primaryKey => {assetKey, dimension};
}
```

- [ ] **Step 2: 注册表 + bump schemaVersion + v15 迁移**

`database.dart`：在 `@DriftDatabase(tables: [...])` 列表（`database.dart:50` 上方那串）的 `BookProfiles,` 后加一行 `SyncBaselines,`。

把 `int get schemaVersion => 14;`（`database.dart:59`）改为 `=> 15;`。

在 `onUpgrade` 链最后一个 `if (from < 14)` 块之后、`}` 之前，追加：

```dart
          if (from < 15) {
            await m.createTable(syncBaselines);
          }
```

- [ ] **Step 3: 加 CRUD（database.dart 内 `HibikiDatabase` 类的方法区，紧邻其它 CRUD）**

```dart
  // ── sync baselines ──────────────────────────────────────────────
  /// 读某资产某维度的基线版本；无记录返回 null。
  Future<int?> getSyncBaseline(String assetKey, String dimension) async {
    final SyncBaselineRow? row = await (select(syncBaselines)
          ..where((t) => t.assetKey.equals(assetKey) & t.dimension.equals(dimension)))
        .getSingleOrNull();
    return row?.baseVersion;
  }

  /// 写/更新基线版本（主键 assetKey+dimension upsert）。
  Future<void> setSyncBaseline(
    String assetKey,
    String dimension,
    int baseVersion,
  ) =>
      into(syncBaselines).insertOnConflictUpdate(SyncBaselinesCompanion(
        assetKey: Value(assetKey),
        dimension: Value(dimension),
        baseVersion: Value(baseVersion),
      ));

  /// 删某资产所有维度基线（删书时 GC，可选调用）。
  Future<void> deleteSyncBaselines(String assetKey) =>
      (delete(syncBaselines)..where((t) => t.assetKey.equals(assetKey))).go();
```

- [ ] **Step 4: 跑代码生成**

Run: `cd hibiki && flutter pub run build_runner build --delete-conflicting-outputs`（或项目惯用的 `dart run build_runner build`）。
Expected: `database.g.dart` 重新生成，含 `SyncBaselines` / `SyncBaselineRow` / `SyncBaselinesCompanion`，无报错。

- [ ] **Step 5: 写 CRUD 测试**

`hibiki/test/database/sync_baselines_test.dart`：

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  setUp(() => db = HibikiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('getSyncBaseline returns null when absent', () async {
    expect(await db.getSyncBaseline('BookA', 'progress'), isNull);
  });

  test('set then get round-trips and upserts', () async {
    await db.setSyncBaseline('BookA', 'progress', 1000);
    expect(await db.getSyncBaseline('BookA', 'progress'), 1000);
    await db.setSyncBaseline('BookA', 'progress', 2000);
    expect(await db.getSyncBaseline('BookA', 'progress'), 2000);
  });

  test('dimension is part of the key', () async {
    await db.setSyncBaseline('BookA', 'progress', 1000);
    expect(await db.getSyncBaseline('BookA', 'audiobook'), isNull);
  });

  test('deleteSyncBaselines removes all dimensions for asset', () async {
    await db.setSyncBaseline('BookA', 'progress', 1000);
    await db.deleteSyncBaselines('BookA');
    expect(await db.getSyncBaseline('BookA', 'progress'), isNull);
  });
}
```

- [ ] **Step 6: 跑测试**

Run: `cd hibiki && flutter test test/database/sync_baselines_test.dart`
Expected: PASS（4 个）。

- [ ] **Step 7: 扩迁移测试（v14→v15 建表）**

在 `hibiki/test/database/migration_test.dart` 沿用既有「升级到最新版后表可用」套路，加断言：升级后 `getSyncBaseline('x','progress')` 不抛异常（表存在）。若该文件用 schema dump 比对，按其现有风格补 v15 期望。

Run: `cd hibiki && flutter test test/database/migration_test.dart`
Expected: PASS。

- [ ] **Step 8: 同步更新 hibiki_core 模块文档版本号**

`packages/hibiki_core/CLAUDE.md` 把「schemaVersion=13」「21 张表」更新为 15 / 22 张表（顺手修正既有过期数字）。

- [ ] **Step 9: Commit**

```bash
git add packages/hibiki_core/lib/src/database/tables.dart \
        packages/hibiki_core/lib/src/database/database.dart \
        packages/hibiki_core/lib/src/database/database.g.dart \
        packages/hibiki_core/CLAUDE.md \
        hibiki/test/database/sync_baselines_test.dart \
        hibiki/test/database/migration_test.dart
git commit -m "feat(sync): add SyncBaselines table (schema v15) for conflict detection"
```

---

## Task 2: 纯函数三方判定 `resolveProgressSync`

**Files:**
- Create: `hibiki/lib/src/sync/sync_progress_resolver.dart`
- Test: `hibiki/test/sync/sync_progress_resolver_test.dart`

- [ ] **Step 1: 写失败测试（全判定表）**

`hibiki/test/sync/sync_progress_resolver_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_progress_resolver.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

void main() {
  group('resolveProgressSync', () {
    test('both null -> synced', () {
      expect(resolveProgressSync(local: null, remote: null, base: null),
          ProgressResolution.synced());
    });
    test('only remote -> import (single side)', () {
      expect(resolveProgressSync(local: null, remote: 100, base: null).direction,
          SyncDirection.importFromTtu);
    });
    test('only local -> export (single side)', () {
      expect(resolveProgressSync(local: 100, remote: null, base: null).direction,
          SyncDirection.exportToTtu);
    });
    test('local==remote -> synced', () {
      final r = resolveProgressSync(local: 100, remote: 100, base: 50);
      expect(r.isConflict, isFalse);
      expect(r.direction, SyncDirection.synced);
    });
    test('local==base, remote moved -> import (remote single-side)', () {
      expect(
          resolveProgressSync(local: 50, remote: 100, base: 50).direction,
          SyncDirection.importFromTtu);
    });
    test('remote==base, local moved -> export (local single-side)', () {
      expect(
          resolveProgressSync(local: 100, remote: 50, base: 50).direction,
          SyncDirection.exportToTtu);
    });
    test('both moved off base, differ -> CONFLICT', () {
      final r = resolveProgressSync(local: 120, remote: 100, base: 50);
      expect(r.isConflict, isTrue);
    });
    test('no base, differ -> CONFLICT (legacy bootstrap)', () {
      final r = resolveProgressSync(local: 120, remote: 100, base: null);
      expect(r.isConflict, isTrue);
    });
    test('no base, equal -> synced', () {
      expect(resolveProgressSync(local: 100, remote: 100, base: null).direction,
          SyncDirection.synced);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/sync/sync_progress_resolver_test.dart`
Expected: FAIL（`sync_progress_resolver.dart` 不存在 / 符号未定义）。

- [ ] **Step 3: 实现纯函数**

`hibiki/lib/src/sync/sync_progress_resolver.dart`：

```dart
import 'package:hibiki/src/sync/ttu_models.dart';

/// 三方判定结果：要么给出自动同步方向，要么标记为冲突（需用户裁决）。
class ProgressResolution {
  const ProgressResolution._(this.direction, this.isConflict);
  factory ProgressResolution.synced() =>
      const ProgressResolution._(SyncDirection.synced, false);
  factory ProgressResolution.auto(SyncDirection d) =>
      ProgressResolution._(d, false);
  factory ProgressResolution.conflict() =>
      const ProgressResolution._(SyncDirection.synced, true);

  final SyncDirection direction; // isConflict 时无意义
  final bool isConflict;

  @override
  bool operator ==(Object other) =>
      other is ProgressResolution &&
      other.direction == direction &&
      other.isConflict == isConflict;
  @override
  int get hashCode => Object.hash(direction, isConflict);
}

/// 基于「共同祖先 base」的三方分叉检测（纯函数，全部输入为毫秒时间戳）。
/// - 单边存在 / 单边偏离 base → 自动方向（与历史 last-write-wins 在这些场景一致）。
/// - 双边都偏离 base 且彼此不等，或无 base 而双边不等 → 冲突。
ProgressResolution resolveProgressSync({
  required int? local,
  required int? remote,
  required int? base,
}) {
  if (local == null && remote == null) return ProgressResolution.synced();
  if (local == null) return ProgressResolution.auto(SyncDirection.importFromTtu);
  if (remote == null) return ProgressResolution.auto(SyncDirection.exportToTtu);
  if (local == remote) return ProgressResolution.synced();
  // 此处 local != remote。
  if (base != null && local == base) {
    return ProgressResolution.auto(SyncDirection.importFromTtu); // 仅远端动
  }
  if (base != null && remote == base) {
    return ProgressResolution.auto(SyncDirection.exportToTtu); // 仅本地动
  }
  // base==null 双边不等，或双边都偏离 base → 真分叉。
  return ProgressResolution.conflict();
}
```

> 注意：本函数刻意**不**做同毫秒打平的 progress-fraction 比较（那是 `local==remote` 才触发的旧 HBK-AUDIT-047 边界，这里 `local==remote` 已直接 synced）。Task 3 接线时，冲突由用户裁决，单边方向仍交给既有 `_handleImport/_handleExport`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/sync/sync_progress_resolver_test.dart`
Expected: PASS（9 个）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/sync_progress_resolver.dart \
        hibiki/test/sync/sync_progress_resolver_test.dart
git commit -m "feat(sync): pure three-way progress conflict resolver"
```

---

## Task 3: SyncManager 接入 base（判定→跳冲突→成功写 base）

**Files:**
- Modify: `hibiki/lib/src/sync/ttu_models.dart`（加 `SyncResult.conflict`）
- Modify: `hibiki/lib/src/sync/sync_manager.dart`
- Test: `hibiki/test/sync/sync_manager_conflict_test.dart`（新建）

- [ ] **Step 1: 加枚举值 + SyncBookResult 携带冲突信息**

`ttu_models.dart:163` 的枚举加一项：

```dart
enum SyncResult {
  synced,
  imported,
  exported,
  skipped,
  conflict,
}
```

`sync_manager.dart` 的 `SyncBookResult`（`sync_manager.dart:15`）加两个可选字段（用于汇总冲突供弹窗显示）：

```dart
  const SyncBookResult({
    required this.direction,
    required this.title,
    this.characterCount,
    this.error,
    this.conflictAssetKey,
    this.conflictDimension,
  });
  // ...既有字段...
  final String? conflictAssetKey;
  final String? conflictDimension;
```

`classifySyncApply`（`sync_manager.dart:40`）的 switch 加 `SyncResult.conflict` 分支，归为 `noop`（冲突不算 applied 也不算 failed）：

```dart
    case SyncResult.synced:
    case SyncResult.skipped:
    case SyncResult.conflict:
      return SyncApplyOutcome.noop;
```

- [ ] **Step 2: 写失败测试（manager 级冲突）**

`hibiki/test/sync/sync_manager_conflict_test.dart`，复用 `sync_compare_delete_test.dart` 里的 fake backend 套路（或 `sync_repository_test.dart` 的内存 db）。核心断言三条：
1. 双边都偏离 base → `syncBook` 返回 `direction == SyncResult.conflict`，且 `conflictAssetKey == sanitizeTtuFilename(title)`；不写 reader position，不改 base。
2. 仅本地偏离 base → 正常 export，且**成功后 base 更新为本地时间戳**。
3. 仅远端偏离 base → 正常 import，且成功后 base 更新为远端时间戳。

```dart
// 形态示意（按既有 fake backend 接口补全 progress 文件名/时间戳构造）：
test('both diverged from base -> conflict, no write, base unchanged', () async {
  // seed: local updatedAt=120, remote progress ts=100, base=50
  final r = await manager.syncBook(book: book, syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge, syncAudioBook: false);
  expect(r.direction, SyncResult.conflict);
  expect(r.conflictAssetKey, sanitizeTtuFilename(book.title));
  expect(await db.getSyncBaseline(sanitizeTtuFilename(book.title), 'progress'), 50);
  // local position untouched:
  final pos = await db.getReaderPosition(book.id);
  expect(pos!.updatedAt, 120);
});
```

> 实现者按 `_FakeSyncBackend` 现有能力构造「远端有 progress 文件且时间戳=100」的场景（参考 `sync_compare_delete_test.dart` 与 `ttu_filename_test.dart` 的 `progress_1_6_<ts>_<frac>.json` 命名）。

- [ ] **Step 3: 跑测试确认失败**

Run: `cd hibiki && flutter test test/sync/sync_manager_conflict_test.dart`
Expected: FAIL（当前 manager 无 base 逻辑，会自动 last-write-wins 而非 conflict）。

- [ ] **Step 4: 接线 `_syncBookOnce`**

在 `sync_manager.dart` 的 `_syncBookOnce`（`sync_manager.dart:177` 一带）计算方向处：当 `direction == null`（自动）时，先读 base 跑 `resolveProgressSync`：

```dart
import 'package:hibiki/src/sync/sync_progress_resolver.dart';
// ...
final String assetKey = sanitizeTtuFilename(book.title);
final int? remoteTs = syncFiles.progress != null
    ? parseProgressTimestamp(syncFiles.progress!.name)
    : null;
if (direction == null) {
  final int? base = await _db.getSyncBaseline(assetKey, 'progress');
  final res = resolveProgressSync(
    local: localPosition?.updatedAt,
    remote: remoteTs,
    base: base,
  );
  if (res.isConflict) {
    return SyncBookResult(
      direction: SyncResult.conflict,
      title: book.title,
      conflictAssetKey: assetKey,
      conflictDimension: 'progress',
    );
  }
  syncDir = res.direction;
} else {
  syncDir = direction; // 手动指定方向（compare Apply）走原路
}
```

成功落地后写 base（在 `_handleImport` 返回 `imported` / `_handleExport` 返回 `exported` 之后）。最稳妥：在 `_syncBookOnce` 末尾、拿到 result 后统一写：

```dart
if (result.direction == SyncResult.imported && remoteTs != null) {
  await _db.setSyncBaseline(assetKey, 'progress', remoteTs);
} else if (result.direction == SyncResult.exported) {
  final int exportedTs = /* 本次写到远端文件名里的时间戳，见 _handleExport */;
  await _db.setSyncBaseline(assetKey, 'progress', exportedTs);
} else if (result.direction == SyncResult.synced &&
    localPosition?.updatedAt != null) {
  await _db.setSyncBaseline(assetKey, 'progress', localPosition!.updatedAt);
}
```

> 实现者需确认 `_handleExport` 用的导出时间戳来源（它把 local `updatedAt` 写进远端 progress 文件名）。让 base = 该值，保证下次双方一致。若 export 用 `localPosition.updatedAt` 原值，则 `exportedTs = localPosition!.updatedAt`。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd hibiki && flutter test test/sync/sync_manager_conflict_test.dart`
Expected: PASS（3 个）。

- [ ] **Step 6: 回归既有 manager 测试**

Run: `cd hibiki && flutter test test/sync/`
Expected: 既有 sync 测试全绿（单边/同步行为不变）。如有依赖 `SyncResult` 穷举 switch 的测试需补 `conflict` 分支。

- [ ] **Step 7: Commit**

```bash
git add hibiki/lib/src/sync/ttu_models.dart hibiki/lib/src/sync/sync_manager.dart \
        hibiki/test/sync/sync_manager_conflict_test.dart
git commit -m "feat(sync): three-way progress conflict detection in SyncManager"
```

---

## Task 4: 冲突汇总进 report（orchestrator + manual sync）

**Files:**
- Modify: `hibiki/lib/src/sync/sync_orchestrator.dart`
- Modify: `hibiki/lib/src/sync/sync_auto_trigger.dart`
- Test: `hibiki/test/sync/sync_orchestrator_test.dart`（若存在则扩，否则新建针对 report 汇总的小测）

- [ ] **Step 1: `SyncRunReport` 加冲突列表**

`sync_orchestrator.dart:31` 的 `SyncRunReport` 加：

```dart
  /// 本轮被判为冲突、已跳过自动解决的项（assetKey）。
  final List<SyncConflict> conflicts = <SyncConflict>[];
```

新增小数据类（同文件或 ttu_models.dart）：

```dart
class SyncConflict {
  const SyncConflict({required this.assetKey, required this.dimension, required this.title});
  final String assetKey;
  final String dimension;
  final String title;
}
```

- [ ] **Step 2: orchestrator 收集冲突**

在 `SyncOrchestrator.run()` 处理每本书结果处（`sync_orchestrator.dart:155` 一带），当 `result.direction == SyncResult.conflict` 时 `report.conflicts.add(SyncConflict(assetKey: result.conflictAssetKey!, dimension: result.conflictDimension!, title: result.title));`（不计入 booksImported，不进 errors）。

- [ ] **Step 3: `ManualSyncResult` 透出冲突**

`sync_auto_trigger.dart:126` 的 `ManualSyncResult` 已带 `report`；无需新字段（`report.conflicts` 即可）。确认 `runManualFullSync` 返回的 `report` 含 conflicts（Step 2 已填）。

- [ ] **Step 4: 测试**

新建/扩 `hibiki/test/sync/sync_orchestrator_test.dart`：构造一本冲突书，跑 orchestrator，断言 `report.conflicts.length == 1 && report.booksImported == 0 && report.errors.isEmpty`。

Run: `cd hibiki && flutter test test/sync/sync_orchestrator_test.dart`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/sync_orchestrator.dart hibiki/lib/src/sync/sync_auto_trigger.dart \
        hibiki/test/sync/sync_orchestrator_test.dart
git commit -m "feat(sync): collect skipped conflicts into SyncRunReport"
```

---

## Task 5: 冲突弹窗调度器 `SyncConflictPrompter`

**Files:**
- Create: `hibiki/lib/src/sync/sync_conflict_prompter.dart`
- Test: `hibiki/test/sync/sync_conflict_prompter_test.dart`

职责：给一组 `SyncConflict` + 上下文（navigatorKey、isMediaOpen 闸门），决定**是否/此刻弹**，并去重/防骚扰。本任务先做**纯决策逻辑**（可单测），实际弹窗在 Task 7 接 `SyncCompareDialog`。

- [ ] **Step 1: 写失败测试（决策逻辑）**

`hibiki/test/sync/sync_conflict_prompter_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';

SyncConflict _c(String k, int l, int r) =>
    SyncConflict(assetKey: k, dimension: 'progress', title: k)
      ..localVersion = l
      ..remoteVersion = r; // 见 Step 3：指纹用 local/remote

void main() {
  test('manual source always prompts (ignores in-book gate & snooze)', () {
    final p = SyncConflictPrompter();
    expect(
        p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.manual, inBook: true),
        isTrue);
  });
  test('auto source does not prompt while in book', () {
    final p = SyncConflictPrompter();
    expect(
        p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.auto, inBook: true),
        isFalse);
  });
  test('auto source does not prompt on background', () {
    final p = SyncConflictPrompter();
    expect(
        p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.background, inBook: false),
        isFalse);
  });
  test('auto prompts when out of book, then snoozes same fingerprint after dismiss', () {
    final p = SyncConflictPrompter();
    final cs = [_c('A', 1, 2)];
    expect(p.shouldPrompt(conflicts: cs, source: ConflictSource.auto, inBook: false), isTrue);
    p.markDismissed(cs); // 用户取消
    expect(p.shouldPrompt(conflicts: cs, source: ConflictSource.auto, inBook: false), isFalse);
    // 版本变化 -> 重新弹
    final cs2 = [_c('A', 1, 3)];
    expect(p.shouldPrompt(conflicts: cs2, source: ConflictSource.auto, inBook: false), isTrue);
  });
  test('single-flight: not while a dialog is open', () {
    final p = SyncConflictPrompter();
    p.dialogOpen = true;
    expect(p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.manual, inBook: false),
        isFalse);
  });
}
```

- [ ] **Step 2: 跑确认失败**

Run: `cd hibiki && flutter test test/sync/sync_conflict_prompter_test.dart`
Expected: FAIL（类不存在）。

- [ ] **Step 3: 实现决策逻辑**

先给 `SyncConflict` 加可空 `localVersion` / `remoteVersion`（Task 4 的类），供指纹用：

```dart
class SyncConflict {
  SyncConflict({required this.assetKey, required this.dimension, required this.title});
  final String assetKey;
  final String dimension;
  final String title;
  int? localVersion;
  int? remoteVersion;
  String get fingerprint => '$assetKey|$dimension|$localVersion|$remoteVersion';
}
```

`hibiki/lib/src/sync/sync_conflict_prompter.dart`：

```dart
import 'package:hibiki/src/sync/sync_orchestrator.dart';

enum ConflictSource { manual, auto, background }

/// 决定冲突弹窗的「是否/此刻弹」+ 会话级防骚扰。纯内存、随会话失效。
class SyncConflictPrompter {
  bool dialogOpen = false;
  final Set<String> _snoozed = <String>{};

  bool shouldPrompt({
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
  }) {
    if (conflicts.isEmpty) return false;
    if (dialogOpen) return false; // 单飞
    if (source == ConflictSource.background) return false; // 看不到，攒着
    if (source == ConflictSource.auto && inBook) return false; // 阅读中不打断
    if (source == ConflictSource.auto &&
        conflicts.every((c) => _snoozed.contains(c.fingerprint))) {
      return false; // 整组都被本会话忽略过
    }
    return true;
  }

  void markDismissed(List<SyncConflict> conflicts) {
    for (final c in conflicts) {
      _snoozed.add(c.fingerprint);
    }
  }
}
```

- [ ] **Step 4: 跑确认通过**

Run: `cd hibiki && flutter test test/sync/sync_conflict_prompter_test.dart`
Expected: PASS（5 个）。

- [ ] **Step 5: 接 Task 3/4，填 localVersion/remoteVersion**

回到 `sync_manager.dart` 构造 conflict 的 `SyncBookResult` 时一并带上 local/remote 时间戳；orchestrator（Task 4 Step 2）创建 `SyncConflict` 时赋 `..localVersion = .. ..remoteVersion = ..`。补一行回归测试断言 fingerprint 含两端版本。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/sync/sync_conflict_prompter.dart hibiki/lib/src/sync/sync_orchestrator.dart \
        hibiki/lib/src/sync/sync_manager.dart hibiki/test/sync/sync_conflict_prompter_test.dart
git commit -m "feat(sync): conflict prompt scheduler (in-book gate + single-flight + session snooze)"
```

---

## Task 6: `SyncCompareDialog` — hasConflict 收紧读 base + Apply 写 base + 仅冲突模式

**Files:**
- Modify: `hibiki/lib/src/sync/sync_compare_dialog.dart`
- Test: `hibiki/test/sync/sync_compare_conflict_test.dart`（新建，复用现有 fake 套路）

- [ ] **Step 1: 写失败测试**

断言：
1. 给 base 使「单边改动」的 entry，`SyncCompareEntry.hasConflict == false`（不进冲突分组）。
2. 「双边偏离 base」的 entry，`hasConflict == true`。
3. 调 `showSyncCompareDialog(..., conflictsOnly: true)` 时只渲染冲突项。
4. 在冲突项选 `useLocal` 并 Apply 后，`getSyncBaseline(assetKey,'progress')` == 本地版本（解决即写 base）。

（结构沿用 `sync_compare_delete_test.dart` 的 `pumpDialog` + 焦点驱动断言。）

- [ ] **Step 2: 跑确认失败**

Run: `cd hibiki && flutter test test/sync/sync_compare_conflict_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现**

- `_fetchCompareData`（`sync_compare_dialog.dart:88`）对每本书额外 `await db.getSyncBaseline(assetKey, 'progress')`，存入 `SyncCompareEntry` 新增字段 `int? base`。
- 把 `hasConflict`（`sync_compare_dialog.dart:55`）改为调 `resolveProgressSync(local: localUpdatedAt, remote: remoteUpdatedAt, base: base).isConflict`。
- `SyncCompareDialog` 加可选 `bool conflictsOnly`；`build`（`sync_compare_dialog.dart:642` 一带）当 `conflictsOnly` 时只渲染 conflicts 分组、隐藏 others/词典分组。
- `showSyncCompareDialog` 透传 `conflictsOnly`。
- Apply 应用某方向成功后（compare 用显式 direction 走 manager），Task 3 的「成功写 base」逻辑会覆盖此路径——确认 manager 在 `direction != null` 分支也写 base（Step 4 of Task 3 的写 base 段对 imported/exported 同样生效，因为它按 result.direction 判定，与 direction 是否手动无关）。

- [ ] **Step 4: 跑确认通过 + 回归既有 compare 测试**

Run: `cd hibiki && flutter test test/sync/sync_compare_conflict_test.dart test/sync/sync_compare_delete_test.dart`
Expected: PASS（含既有删除测试不回归）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/sync_compare_dialog.dart hibiki/test/sync/sync_compare_conflict_test.dart
git commit -m "feat(sync): tighten compare hasConflict to baseline; write base on resolve"
```

---

## Task 7: 接线三触发点 + 立刻同步弹窗

**Files:**
- Modify: `hibiki/lib/src/sync/sync_conflict_prompter.dart`（加实际 `present()` 方法）
- Modify: `hibiki/lib/src/pages/base_source_page.dart:101`（关书后）
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart:62,101`（app 启动 / 后台）
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart:638`（`_syncNow`）
- Test: `hibiki/test/sync/sync_conflict_present_test.dart`（widget）

- [ ] **Step 1: prompter 加 `present()`（用 navigatorKey 弹 compare 冲突视图）**

```dart
import 'package:flutter/widgets.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
// ...
  Future<void> present({
    required GlobalKey<NavigatorState> navigatorKey,
    required HibikiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
  }) async {
    if (!shouldPrompt(conflicts: conflicts, source: source, inBook: inBook)) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return; // HBK-AUDIT-012：null 安全
    dialogOpen = true;
    try {
      final bool? resolved = await showSyncCompareDialog(
        context: ctx, db: db, backend: backend, conflictsOnly: true,
      );
      if (resolved != true) markDismissed(conflicts); // 取消/未解决 -> snooze
    } finally {
      dialogOpen = false;
    }
  }
```

> 单例：在 `AppModel` 持有一个 `final SyncConflictPrompter syncConflictPrompter = SyncConflictPrompter();`（`app_model.dart`），供各触发点共用同一 snooze/单飞状态。

- [ ] **Step 2: 关书后触发（base_source_page.dart）**

`triggerAutoSyncAfterClose` 当前 fire-and-forget。改为让其回调带回 report，或在调用点改用一个返回 `Future<SyncRunReport?>` 的变体。最小改动：给 `triggerAutoSyncAfterClose` 加可选 `void Function(SyncRunReport)? onReport`，`_runAutoSync` 跑完把 report 回调出来；`base_source_page.dart:101` 传入回调：

```dart
triggerAutoSyncAfterClose(
  db: appModel.database,
  mediaIdentifier: identifier,
  onReport: (report) {
    if (report.conflicts.isEmpty) return;
    appModel.syncConflictPrompter.present(
      navigatorKey: appModel.navigatorKey,
      db: appModel.database,
      backend: /* 已解析的 backend，见 _runAutoSync 内 */,
      conflicts: report.conflicts,
      source: ConflictSource.auto,
      inBook: appModel.isMediaOpen, // 关书后应为 false
    );
  },
);
```

> `_runAutoSync` 目前只 sync 单本书（按 mediaIdentifier）。它内部已解析 backend；把 backend 一并经 `onReport` 暴露或在回调内重新 `resolveSyncBackend`。实现者选最小耦合方式。

- [ ] **Step 3: app 启动触发（home_page.dart:62）**

`triggerAutoSyncOnAppOpen` 同样加 `onReport`；回调里 `source: ConflictSource.auto, inBook: appModel.isMediaOpen`（启动时一般 false）。`triggerAutoSyncOnBackground`（home_page.dart:101）**不接弹窗**（source 概念上是 background，本就不弹）。

- [ ] **Step 4: 立刻同步弹窗（sync_settings_schema.dart:638）**

`_syncNow` 的 `ManualSyncOutcome.completed` 分支，跑完后：

```dart
case ManualSyncOutcome.completed:
  final report = result.report!;
  _showSnackBar(context, summarizeSyncReport(report));
  if (report.conflicts.isNotEmpty) {
    await appModel.syncConflictPrompter.present(
      navigatorKey: appModel.navigatorKey,
      db: appModel.database,
      backend: resolveSyncBackend(await SyncRepository(appModel.database).getBackendType()),
      conflicts: report.conflicts,
      source: ConflictSource.manual, // 主动操作，不受 snooze/in-book 约束
      inBook: appModel.isMediaOpen,
    );
  }
```

- [ ] **Step 5: widget 测试**

`hibiki/test/sync/sync_conflict_present_test.dart`：用 `wrapWithGlobalNavigation`（见 `test/widgets/settings_value_row_gamepad_test.dart:92`）+ 内存 db + fake backend，构造含 1 个冲突的 report，调 `prompter.present(... source: manual ...)`，`pumpAndSettle`，断言冲突解决对话框出现（`find.byType(SyncCompareDialog)` 或冲突标题文本）；再测 `source: auto, inBook: true` 时不弹。

Run: `cd hibiki && flutter test test/sync/sync_conflict_present_test.dart`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/sync/sync_conflict_prompter.dart hibiki/lib/src/sync/sync_auto_trigger.dart \
        hibiki/lib/src/pages/base_source_page.dart \
        hibiki/lib/src/pages/implementations/home_page.dart \
        hibiki/lib/src/sync/sync_settings_schema.dart \
        hibiki/lib/src/models/app_model.dart \
        hibiki/test/sync/sync_conflict_present_test.dart
git commit -m "feat(sync): present conflict dialog on book-exit, app-open, and manual sync"
```

---

## Task 8: 设置页「N 个冲突待解决」入口 + i18n

**Files:**
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart`（在 `sync.compare` 行附近加冲突入口）
- Modify: `hibiki/lib/i18n/*.i18n.json`（经 i18n_sync.dart）

- [ ] **Step 1: 加 i18n keys（禁手改 17 文件）**

```bash
cd hibiki
dart run tool/i18n_sync.dart --add sync_conflict_title "Resolve sync conflicts" "解决同步冲突"
dart run tool/i18n_sync.dart --add sync_conflict_count "{count} conflict(s) to resolve" "{count} 个冲突待解决"
dart run tool/i18n_sync.dart --add sync_conflict_none "No conflicts" "无冲突"
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 2: 设置页入口（手动兜底，被 snooze 时也能进）**

在 `sync_settings_schema.dart` 的 `sync.compare` 行（`:211`）旁加一行 `sync.conflicts`：title=`t.sync_conflict_title`，onTap 重算当前冲突集（跑一次只读对比，或直接打开 `showSyncCompareDialog(conflictsOnly: true)`）。子标题用 `t.sync_conflict_count(count: n)` / `t.sync_conflict_none`。

> 冲突数 N = 用 `_fetchCompareData` 结果里 `hasConflict` 计数（Task 6 已把 hasConflict 收紧成真分叉），无需新查询路径。

- [ ] **Step 3: i18n 完整性测试**

Run: `cd hibiki && flutter test test/i18n/`
Expected: PASS（17 语言 key 完整）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/sync/sync_settings_schema.dart hibiki/lib/i18n/
git commit -m "feat(sync): settings entry + i18n for resolving conflicts"
```

---

## Task 9: 全量验证

- [ ] **Step 1: 格式化**

Run: `cd hibiki && dart format .`

- [ ] **Step 2: 静态分析**

Run: `cd hibiki && flutter analyze`
Expected: No issues（或仅既有无关告警）。

- [ ] **Step 3: 全量测试**

Run: `cd hibiki && flutter test`
Expected: 全绿（含新增 + 既有回归）。

- [ ] **Step 4: 设备复测（声明修好前必做，见 CLAUDE.md 验证纪律）**

真机/模拟器走一遍：两设备造一个进度真分叉 → 关书后弹冲突对话框 → 选方向 → 验 DB base 写入 + 对端再同步不再冲突；阅读中不弹；切后台不弹。留证据（截图）。

- [ ] **Step 5: 最终 commit（若设备复测有微调）**

```bash
git add -p   # 只 stage 本轮相关文件
git commit -m "test(sync): device verification for progress conflict prompt"
```

---

## Self-Review 记录

- **Spec 覆盖**：design §3（基线/三方）→Task1-3；§3.3 兜底→Task2 测试 + Task3；§3.4 写 base 时机→Task3 Step4；§4（弹窗时机/闸门/防骚扰）→Task5+Task7；§5（compare 收紧 + 入口）→Task6+Task8；§7（测试）→各 Task 测试 + Task9；§6 有声书=Phase2 明确不在本计划。
- **类型一致**：`SyncResult.conflict`、`SyncConflict{assetKey,dimension,title,localVersion,remoteVersion,fingerprint}`、`resolveProgressSync→ProgressResolution{direction,isConflict}`、`SyncConflictPrompter{shouldPrompt,markDismissed,present,dialogOpen}`、`getSyncBaseline/setSyncBaseline/deleteSyncBaselines`、`ConflictSource{manual,auto,background}` 全程同名。
- **已知需实现者落地确认点**（非占位符，是真实代码依赖）：① `_handleExport` 导出时间戳来源（写 base 用同一值）；② `_runAutoSync` 把已解析 backend 经 `onReport` 暴露 vs 回调内重解析，取最小耦合；③ migration_test 既有断言风格。

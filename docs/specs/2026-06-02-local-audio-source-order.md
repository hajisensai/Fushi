# 本地音频库内「子来源顺序 + 逐源启用」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans 逐任务实现。Steps 用 checkbox 跟踪。

**Goal:** 让用户在「管理音频来源」对话框里，对每个本地音频库（如 `android.db`，内含 nhk16 / daijisen / forvo / oald10 等子来源）**调整子来源优先级顺序**并**逐个启用/禁用**；查词命中多来源时按此顺序选第一个启用的来源。

**Architecture:** 子来源顺序/启用是 native 选音频的依据，真相源放在 `LocalAudioManager` / `LocalAudioDbEntry`（喂 native 的那套），**与对话框 `AudioSourceConfig` 批量保存解耦**——子来源编辑即时持久化并重推 native，不走 onSave 批量。native（Android Java）和桌面（`LocalAudioDb` sqlite3）两条查询路径都要：① 枚举库内 `SELECT DISTINCT source`；② 查询时按「每库各自的来源优先级」过滤禁用源、排序选第一。UI 在本地库行加「编辑来源」入口，开子对话框（拖拽调序 + 逐源开关）。

**Tech Stack:** Dart/Flutter + Riverpod + Slang；Android `TtsChannelHandler.java`（SQLiteDatabase）；桌面 `package:sqlite3`；i18n 经 `tool/i18n_sync.dart`。

**已锁定决策（用户确认）：** 调序 **+** 逐源启用/禁用；顺序**每库各自一份**。

**前置事实（已核验）：**
- DB schema：`entries(expression, reading, file, source)` + `android(file, source, data BLOB)`。
- 当前 native/桌面查询都是 `... WHERE expression=? AND reading=? LIMIT 1`（再退化到仅 expression），**首个命中即返回，无来源优先级**——本功能在 develop 及历史里均不存在，是新增。
- native 入口 `handleSetLocalAudioDb` 现只收 `paths: List<String>`；`handleQueryLocalAudio`/`handleExtractLocalAudio` 按 `dbIndex` 定位已打开的 DB。
- 桌面 `LocalAudioDb.queryMeta/extractBlob/queryAndExtract`（`lib/src/utils/misc/local_audio_db.dart`）。
- `LocalAudioDbEntry`（`lib/src/models/local_audio_manager.dart`）现为 `{path, displayName, enabled}`，存 `local_audio_dbs` pref（JSON 数组）。

**验证门槛（CLAUDE.md 强制）：** 涉 Android 原生改动 → 须 `gradlew :app:assembleRelease`；涉音频/导入 → 须真机复测原始失败路径并留证据（`.codex-test/`）。

---

## File Structure

| 文件 | 责任 | 改动 |
|---|---|---|
| `lib/src/models/local_audio_source_pref.dart` | 新 `LocalAudioSourcePref{name,enabled}` + JSON | Create |
| `lib/src/models/local_audio_manager.dart` | `LocalAudioDbEntry.sources` 字段；native push 带来源配置；`setSourcesFor` | Modify |
| `lib/src/utils/misc/tts_channel.dart` | `setLocalAudioDbs` 传结构化配置；新 `listLocalAudioSources` | Modify |
| `lib/src/utils/misc/local_audio_db.dart` | `listSources`；`queryMeta` 按 order+enabled 选源 | Modify |
| `lib/src/models/app_model.dart` | `listLocalAudioSources(path)`、`setLocalAudioDbSources(path,prefs)` 委托 | Modify |
| `android/.../TtsChannelHandler.java` | `setLocalAudioDb` 收来源配置；`queryLocalAudio` 按序选源；新 `listLocalAudioSources` | Modify |
| `lib/src/pages/implementations/local_audio_sources_dialog.dart` | 新子对话框：枚举+合并+拖拽+逐源开关 | Create |
| `lib/src/pages/implementations/dictionary_settings_dialog_page.dart` | 本地库行加「编辑来源」入口 | Modify |
| `lib/i18n/*.i18n.json` + `strings.g.dart` | 新 key | Modify |
| 各测试文件 | 单测 | Create/Modify |

**数据形状（持久化 JSON，`local_audio_dbs`）：**
```json
[{"path":"/.../local_audio_1.db","displayName":"android.db","enabled":true,
  "sources":[{"name":"nhk16","enabled":true},{"name":"forvo","enabled":false}]}]
```
- `sources` 为**优先级序**（首=最高）。空 = 尚未配置 → native/桌面退回「DB 自然顺序、全部启用」（向后兼容旧 entry）。
- 展示时把存的 `sources` 与库内 `DISTINCT source` 合并：存里有的保序，库里新出现的追加（默认启用），库里已消失的丢弃。

**native 传参（`setLocalAudioDb`）：** `paths` 保留兼容；新增 `dbConfigs: List<Map>`，每项 `{path, order:List<String>(仅启用源，按优先级), }`。native 用 `order` 既当过滤白名单又当排序键；空 order 表示该库不限制（全启用、自然序）。

---

## Task 1: i18n keys

新增（避开 Slang `{}` 插值，文案不含花括号）：

| key | en | zh-CN |
|---|---|---|
| `local_audio_edit_sources` | `Edit sources` | `编辑来源` |
| `local_audio_source_order_title` | `Source priority` | `来源顺序` |
| `local_audio_no_sources` | `No sources found in this database` | `此数据库未发现可用来源` |

- [ ] **Step 1:** （`cd hibiki`）
```bash
dart tool/i18n_sync.dart --add local_audio_edit_sources "Edit sources" "编辑来源"
dart tool/i18n_sync.dart --add local_audio_source_order_title "Source priority" "来源顺序"
dart tool/i18n_sync.dart --add local_audio_no_sources "No sources found in this database" "此数据库未发现可用来源"
dart run slang && dart format lib/i18n/strings.g.dart
```
- [ ] **Step 2:** `git add hibiki/lib/i18n && git commit -m "i18n(audio): keys for local-db source priority editor"`

---

## Task 2: `LocalAudioSourcePref` 模型

**Files:** Create `lib/src/models/local_audio_source_pref.dart`；Test `test/models/local_audio_source_pref_test.dart`

- [ ] **Step 1: 测试（先失败）**
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';

void main() {
  test('round trips through json', () {
    const LocalAudioSourcePref p = LocalAudioSourcePref(name: 'nhk16', enabled: false);
    final LocalAudioSourcePref restored =
        LocalAudioSourcePref.fromJson(p.toJson());
    expect(restored, p);
  });
  test('defaults enabled to true on malformed json', () {
    final LocalAudioSourcePref p =
        LocalAudioSourcePref.fromJson(<String, dynamic>{'name': 'forvo'});
    expect(p.name, 'forvo');
    expect(p.enabled, isTrue);
  });
}
```
- [ ] **Step 2:** `flutter test test/models/local_audio_source_pref_test.dart --no-pub` → FAIL
- [ ] **Step 3: 实现**
```dart
import 'package:flutter/foundation.dart';

@immutable
class LocalAudioSourcePref {
  const LocalAudioSourcePref({required this.name, this.enabled = true});

  factory LocalAudioSourcePref.fromJson(Map<String, dynamic> json) =>
      LocalAudioSourcePref(
        name: json['name'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );

  final String name;
  final bool enabled;

  LocalAudioSourcePref copyWith({bool? enabled}) =>
      LocalAudioSourcePref(name: name, enabled: enabled ?? this.enabled);

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'enabled': enabled};

  @override
  bool operator ==(Object other) =>
      other is LocalAudioSourcePref &&
      other.name == name &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(name, enabled);
}
```
- [ ] **Step 4:** test → PASS
- [ ] **Step 5:** commit `feat(audio): add LocalAudioSourcePref model`

---

## Task 3: `LocalAudioDbEntry.sources` + LocalAudioManager 持久化/重推

**Files:** Modify `lib/src/models/local_audio_manager.dart`；Test `test/models/local_audio_manager_test.dart`（若无则新建）

- [ ] **Step 1: 测试（先失败）** — sources 往返 + setSourcesFor 重推
```dart
// 关键断言：
// 1. LocalAudioDbEntry(sources:[...]) toJson/fromJson 往返保 sources。
// 2. setEntries 后 entries 带回 sources。
// 3. setSourcesFor(path, prefs) 只改该 path 的 sources，其余不动。
```
（按现有 `local_audio_manager` 的测试风格写；用临时目录 + PreferencesRepository。）

- [ ] **Step 2:** 运行 → FAIL

- [ ] **Step 3: 实现**

`LocalAudioDbEntry` 加字段：
```dart
final List<LocalAudioSourcePref> sources; // 优先级序；空=未配置
```
构造/`fromJson`/`toJson`/`copyWith`/`==`/`hashCode` 都纳入 `sources`（fromJson：`(json['sources'] as List?)?.map(...).toList() ?? const []`；toJson：仅当非空才写 `sources`）。

`setEntries` 序列化已自动覆盖（toJson 含 sources）。`enabled` 的源用于喂 native：
```dart
List<String> _enabledSourceOrder(LocalAudioDbEntry e) =>
    e.sources.where((s) => s.enabled).map((s) => s.name).toList();
```
把对 native 的推送从「只传 paths」改为传结构化配置（见 Task 4 的 TtsChannel 签名）：
```dart
Future<void> _pushNative(List<LocalAudioDbEntry> enabledDbs) =>
    TtsChannel.instance.setLocalAudioDbs(
      enabledDbs
          .map((e) => LocalAudioDbConfig(
              path: e.path, sourceOrder: _enabledSourceOrder(e)))
          .toList(),
    );
```
`setEntries` 末尾改调 `_pushNative(dbs.where((e)=>e.enabled).toList())`（替换原 `TtsChannel.instance.setLocalAudioDbs(paths)`）。`setLocalAudioEnabled(true)`/`bindForNativeHandler` 同样改用 `_pushNative`；`false` 推空列表。

新增：
```dart
Future<void> setSourcesFor(
    String path, List<LocalAudioSourcePref> prefs) async {
  final List<LocalAudioDbEntry> dbs = List<LocalAudioDbEntry>.of(entries);
  final int i = dbs.indexWhere((LocalAudioDbEntry e) => e.path == path);
  if (i < 0) return;
  dbs[i] = dbs[i].copyWith(sources: prefs);
  await setEntries(dbs); // setEntries 内已重推 native
}
```
（`copyWith` 加 `List<LocalAudioSourcePref>? sources` 参数。）

- [ ] **Step 4:** test → PASS
- [ ] **Step 5:** commit `feat(audio): per-db source prefs in LocalAudioDbEntry + native re-push`

---

## Task 4: TtsChannel — 结构化配置 + 枚举来源

**Files:** Modify `lib/src/utils/misc/tts_channel.dart`

- [ ] **Step 1: 实现**

新增轻量配置类（同文件顶部或 local_audio_source_pref.dart 旁）：
```dart
class LocalAudioDbConfig {
  const LocalAudioDbConfig({required this.path, this.sourceOrder = const []});
  final String path;
  final List<String> sourceOrder; // 仅启用源，按优先级；空=全启用自然序
}
```

`setLocalAudioDbs` 改签名为 `Future<bool> setLocalAudioDbs(List<LocalAudioDbConfig> dbs)`：
- 桌面分支：记 `_desktopDbPaths = dbs.map((d)=>d.path)` **并**记 `_desktopDbConfigs = dbs`（供 queryMeta 用，见 Task 5）。
- Android：`invokeMethod('setLocalAudioDb', {'paths': [...], 'dbConfigs': [{'path':..., 'order':[...]}, ...]})`。

更新内部旧调用 `bindForNativeHandler(path)` 等所有 caller 到新签名（全仓 grep `setLocalAudioDbs` 改完）。

新增枚举：
```dart
Future<List<String>> listLocalAudioSources(String dbPath) async {
  if (!_isSupported) return LocalAudioDb.listSources(dbPath);
  try {
    final Object? r = await _channel.invokeMethod(
        'listLocalAudioSources', {'path': dbPath});
    return (r as List?)?.cast<String>() ?? const <String>[];
  } catch (e, st) {
    ErrorLogService.instance.log('TtsChannel.listLocalAudioSources', e, st);
    return const <String>[];
  }
}
```

`queryLocalAudio` 桌面分支改用带配置的 `LocalAudioDb.queryMeta(path, expr, reading, order: _desktopDbConfigs[i].sourceOrder)`（Task 5）。

- [ ] **Step 2:** `flutter analyze lib/src/utils/misc/tts_channel.dart` → 修所有 caller 编译错。
- [ ] **Step 3:** commit `feat(audio): TtsChannel structured db config + listLocalAudioSources`

---

## Task 5: 桌面 `LocalAudioDb` — 枚举 + 按序选源

**Files:** Modify `lib/src/utils/misc/local_audio_db.dart`；Test `test/utils/misc/local_audio_db_test.dart`（用内存/临时 sqlite 建小库）

- [ ] **Step 1: 测试（先失败）** — 建一个含 `entries`/`android` 的临时 db，同一 (expr,reading) 插入 source=A 和 source=B：
```dart
// order=['B','A'] → queryMeta 返回 source 'B'
// order=['A'] (B 被禁用,不在 order) → 返回 'A'
// order=[] → 返回任意一个（自然序，不报错）
// listSources 返回 {'A','B'}
```
- [ ] **Step 2:** 运行 → FAIL
- [ ] **Step 3: 实现**

新增：
```dart
static List<String> listSources(String dbPath) {
  if (dbPath.isEmpty || !File(dbPath).existsSync()) return const <String>[];
  Database? db;
  try {
    db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    final ResultSet rows =
        db.select('SELECT DISTINCT source FROM entries');
    return rows
        .map((Row r) => r['source'])
        .whereType<String>()
        .toList();
  } catch (e, st) {
    ErrorLogService.instance.log('LocalAudioDb.listSources', e, st);
    return const <String>[];
  } finally {
    db?.dispose();
  }
}
```

`queryMeta` 增可选 `List<String> order = const []`。逻辑：order 为空 → 保持原 LIMIT 1 行为；非空 → 取所有匹配行，过滤 `source ∈ order`，按 `order.indexOf(source)` 排序取第一：
```dart
static ({String file, String source})? queryMeta(
  String dbPath, String expression, String reading,
  {List<String> order = const <String>[]}) {
  // ...openReadOnly...
  ResultSet rows = db.select(
    'SELECT file, source FROM entries WHERE expression = ? AND reading = ?',
    <Object?>[expression, reading]);
  if (rows.isEmpty) {
    rows = db.select(
      'SELECT file, source FROM entries WHERE expression = ?',
      <Object?>[expression]);
  }
  if (rows.isEmpty) return null;
  final List<({String file, String source})> cands = <({String file, String source})>[
    for (final Row r in rows)
      if (r['file'] is String && r['source'] is String)
        (file: r['file'] as String, source: r['source'] as String),
  ];
  if (cands.isEmpty) return null;
  if (order.isEmpty) return cands.first;
  ({String file, String source})? best;
  int bestRank = 1 << 30;
  for (final c in cands) {
    final int rank = order.indexOf(c.source);
    if (rank < 0) continue;          // 禁用/未列入 → 跳过
    if (rank < bestRank) { bestRank = rank; best = c; }
  }
  return best;                        // 全被过滤掉 → null（该库无启用源命中）
}
```
`queryAndExtract` 增 `List<List<String>> orders` 或改为接收 `List<LocalAudioDbConfig>`；最简：给 `queryAndExtract` 传 `List<({String path, List<String> order})>`，逐库带 order 调 queryMeta。更新其 caller。

- [ ] **Step 4:** test → PASS
- [ ] **Step 5:** commit `feat(audio): desktop LocalAudioDb source enumeration + ordered selection`

---

## Task 6: Android `TtsChannelHandler.java` — 配置 + 按序选源 + 枚举

**Files:** Modify `android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java`

- [ ] **Step 1: 实现**

`handleSetLocalAudioDb`：解析 `dbConfigs`（`List<Map>`），建 `path -> List<String> order` map；打开 DB 时按 path 取出对应 order，存进与 `localAudioDbs` 平行的 `List<List<String>> localAudioDbOrders`（index 对齐）。`closeAllAudioDbsLocked` 同步清 orders。

`handleQueryLocalAudio`：把 `LIMIT 1` 查询改为取全部匹配行，按该库 order 选第一：
```java
List<String> order = localAudioDbOrders.get(i); // 与 db 同 index
cursor = db.rawQuery(
    "SELECT file, source FROM entries WHERE expression = ? AND reading = ?",
    new String[]{expression, reading != null ? reading : ""});
// 无命中再退化到仅 expression（同现逻辑）
// 在 Java 侧：遍历 cursor 收集 (file,source)，按 order 选 rank 最小且 rank>=0 的；
//   order 为空 => 取第一行（兼容旧库）
```
抽一个私有 `pickByOrder(List<String[]> rows, List<String> order)` 返回选中行或 null。

新增 method case `"listLocalAudioSources"`：按 `path` 找到已打开 DB（或临时打开），`SELECT DISTINCT source FROM entries`，回传 `List<String>`。

- [ ] **Step 2: 构建验证（CLAUDE.md：Android 原生改动）**
```bash
cd hibiki/android && ./gradlew.bat :app:assembleRelease
```
Expected: BUILD SUCCESSFUL。
- [ ] **Step 3:** commit `feat(audio): android handler honors per-db source order + enumeration`

---

## Task 7: AppModel 委托

**Files:** Modify `lib/src/models/app_model.dart`

- [ ] **Step 1: 实现**
```dart
Future<List<String>> listLocalAudioSources(String path) =>
    TtsChannel.instance.listLocalAudioSources(path);

Future<void> setLocalAudioDbSources(
        String path, List<LocalAudioSourcePref> prefs) async {
  await _localAudioManager.setSourcesFor(path, prefs);
  notifyListeners();
}

List<LocalAudioSourcePref> sourcePrefsForLocalDb(String path) =>
    _localAudioManager.entries
        .firstWhere((LocalAudioDbEntry e) => e.path == path,
            orElse: () => const LocalAudioDbEntry(path: '', displayName: ''))
        .sources;
```
- [ ] **Step 2:** `flutter analyze lib/src/models/app_model.dart`
- [ ] **Step 3:** commit `feat(audio): AppModel delegates for local-db source prefs`

---

## Task 8: 子对话框 `LocalAudioSourcesDialog`

**Files:** Create `lib/src/pages/implementations/local_audio_sources_dialog.dart`；Test `test/pages/local_audio_sources_dialog_test.dart`

行为：进入时把「已存 prefs」与「`listLocalAudioSources` 枚举结果」**合并**（存里保序、库里新增追加默认启用、库里消失丢弃）；展示 loading 态直到枚举返回；空库显示 `t.local_audio_no_sources`；拖拽/上下调序 + 每行 `Switch.adaptive` 启用；底部「关闭」时 `onApply(prefs)`。

合并工具（@visibleForTesting static）：
```dart
static List<LocalAudioSourcePref> merge(
    List<LocalAudioSourcePref> saved, List<String> discovered) {
  final Set<String> known = saved.map((s) => s.name).toSet();
  return <LocalAudioSourcePref>[
    for (final s in saved)
      if (discovered.contains(s.name)) s,              // 保序、丢弃消失的
    for (final name in discovered)
      if (!known.contains(name)) LocalAudioSourcePref(name: name), // 追加新源
  ];
}
```

- [ ] **Step 1: 测试** — `merge` 三情形（保序 / 追加新源默认启用 / 丢弃消失源）+ widget：给定 fake 枚举与 saved，渲染出对应行数与开关态。
- [ ] **Step 2:** 运行 → FAIL
- [ ] **Step 3: 实现** 对话框（复用 `HibikiDialogFrame`/`HibikiModalSheetFrame`/`ReorderableListView`/`AdaptiveSettingsRow`/`HibikiIconButton`，结构参照 `AudioSourcesDialog`）。
- [ ] **Step 4:** test → PASS
- [ ] **Step 5:** commit `feat(audio): LocalAudioSourcesDialog (reorder + per-source toggle)`

---

## Task 9: 接入主对话框

**Files:** Modify `lib/src/pages/implementations/dictionary_settings_dialog_page.dart` + `lib/src/settings/settings_schema.dart`

`AudioSourcesDialog` 本地库行的 trailing 加一个 `HibikiIconButton(icon: Icons.tune, tooltip: t.local_audio_edit_sources)`，回调 `widget.onEditLocalSources?.call(source.path!)`。新增可选回调字段 `final Future<void> Function(String path)? onEditLocalSources;`。

`settings_schema.dart` 调用处补 `onEditLocalSources: (String path) async { await showSettingsDialog(settingsContext, (_) => LocalAudioSourcesDialog(dbPath: path, savedPrefs: appModel.sourcePrefsForLocalDb(path), listSources: () => appModel.listLocalAudioSources(path), onApply: (prefs) => appModel.setLocalAudioDbSources(path, prefs))); settingsContext.refresh(); }`。

- [ ] **Step 1: 实现** 上述接线 + 更新 `audio_sources_dialog_page_test.dart`（新回调为可选，旧测试不传 → 不渲染按钮，无需大改；可加一条「传 onEditLocalSources + 一个 localAudio 源 → 出现 tune 按钮，点击触发回调」）。
- [ ] **Step 2:** `flutter test test/pages/audio_sources_dialog_page_test.dart test/pages/local_audio_sources_dialog_test.dart --no-pub` → PASS
- [ ] **Step 3:** commit `feat(audio): wire local-db source editor into audio sources dialog`

---

## Task 10: 全量验证 + 设备复测

- [ ] **Step 1:** `cd hibiki && dart format lib test && flutter analyze`（仅本轮不新增问题）
- [ ] **Step 2:** `flutter test test/models/local_audio_source_pref_test.dart test/models/local_audio_manager_test.dart test/utils/misc/local_audio_db_test.dart test/pages/audio_sources_dialog_page_test.dart test/pages/local_audio_sources_dialog_test.dart test/models/app_model_audio_sources_test.dart --no-pub` → 全 PASS
- [ ] **Step 3:** `cd hibiki/android && ./gradlew.bat :app:assembleRelease` → BUILD SUCCESSFUL
- [ ] **Step 4: 真机复测（强制）** 安到设备：导入 `android.db` → 打开「管理音频来源」→ 展开本地音频 → 点某库「编辑来源」→ 拖拽调序 + 关掉某源 → 查一个多来源词，确认播放的是排在最前的启用源；把某源调到第一再查，确认切换。留截图于 `.codex-test/`。
- [ ] **Step 5:** 最终 commit（若有零散收尾）。

---

## Self-Review

- **覆盖：** 调序→Task5/6 查询按 order；逐源启用→order 仅含启用源（禁用即不在 order，被跳过）；每库各自→`LocalAudioDbConfig.sourceOrder` 按 path/index 对齐；枚举→Task4/5/6 `listLocalAudioSources`；UI→Task8/9。✔
- **不造假：** native + 桌面两条真实查询路径都按 order 选源，UI 控件即时落到 native，非空控件。✔
- **向后兼容：** 旧 entry 无 `sources` → order 空 → 退回原 LIMIT-1 全启用行为，旧库照常播放。✔
- **类型一致：** `LocalAudioSourcePref`/`LocalAudioDbConfig`/`setSourcesFor`/`listLocalAudioSources`/`merge` 命名贯穿 Task2–9 一致。✔
- **风险：** ① native `dbConfigs` 与 `localAudioDbs` 的 index 对齐（开库失败要跳过时 orders 也要同步跳过）——Task6 用 path→order map 在开库成功后再 add order，保证对齐。② 7.56GB 库 `SELECT DISTINCT source` 性能——source 有 `idx_android_file_source` 但 entries.source 未必有索引；首次枚举可能慢，UI 给 loading 态（Task8）兜住，必要时 Task6 加 `CREATE INDEX idx_entries_source`。③ 多来源词查询从 LIMIT 1 变取全部行——每词来源数有限（≤源总数），开销可接受。

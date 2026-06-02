# 统一音频来源 + 远端开关拆分 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「查词」设置页里分散的「本地音频」section 并入「管理音频来源」对话框，并把远端 hibiki 拆成「词典远端」「音频远端」两个互不影响的开关。

**Architecture:** 数据层早已统一（`audioSourceConfigs` 是 `localAudioDbs` 的投影）。本计划做三件事：(1) 把本地库的全局总开关 + 添加按钮搬进 `AudioSourcesDialog`，并把本地库文件生命周期（拷贝 / 删除）收口到 `setAudioSourceConfigs` 单一提交点；(2) 删除冗余的独立 section 和 `_LocalAudioDatabasesRow`；(3) 远端音频清理永远为 true 的 `ignoreRemoteLookupEnabled` 死参数，词典远端开关正名。

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4，Riverpod，Drift（不改 schema），Slang i18n（必须走 `hibiki/tool/i18n_sync.dart`）。

**基线：** worktree 分支 `worktree-unified-audio-sources`，基于 develop `f77a562be`。

**通用验证命令（worktree 根目录 `D:/APP/vs_claude_code/hibiki/.claude/worktrees/unified-audio-sources`）：**
- 分析：`cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze`
- 单测（按记忆 `--no-pub` 更快稳）：`cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub <路径>`
- 格式化：`D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat format <文件>`

---

## 文件结构

| 文件 | 责任 | 改动 |
|------|------|------|
| `hibiki/lib/src/models/local_audio_manager.dart` | 本地库存储/拷贝/删除 | 新增 `importFile`（拷贝-only，返回 entry，不持久化）；新增 `deleteFilesFor(path)` 静态/实例删文件 helper |
| `hibiki/lib/src/models/app_model.dart` | 全局状态委托 | `setAudioSourceConfigs` 收口文件生命周期 + 不再自动派生总开关；新增 `importLocalAudioDbFile`；清理 `lookupRemoteAudio` 死参数 |
| `hibiki/lib/src/pages/base_source_page.dart` | reader 自动朗读 | 删 `ignoreRemoteLookupEnabled: true` 实参 |
| `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart` | 词典页朗读 | 同上 |
| `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart` | 弹窗朗读 | 同上 |
| `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart` | 音频来源对话框 | 加总开关行 + 添加本地库按钮 + 构造参数；重置只清远端 |
| `hibiki/lib/src/settings/settings_schema.dart` | 设置 schema | 删独立「本地音频」section + `_LocalAudioDatabasesRow`；wire 对话框新参数；词典远端开关正名 |
| `hibiki/lib/i18n/strings.i18n.json`（经 i18n_sync） | i18n 源 | 新增 `remote_dict_lookup` / `remote_dict_lookup_hint` |
| `hibiki/test/models/local_audio_manager_test.dart` | 单测 | 新建/补充 importFile + 文件删除 |
| `hibiki/test/models/app_model_audio_sources_test.dart` | 单测 | setAudioSourceConfigs 生命周期 + 总开关不自动派生 |
| `hibiki/test/utils/word_audio_resolver_test.dart` | 单测 | hibikiRemote 仅 source.enabled gate（若已存在则补充） |
| `hibiki/test/pages/audio_sources_dialog_page_test.dart` | widget 测 | 总开关 + 添加按钮存在 |

---

## Task 1: 远端音频解耦清理（删死参数 + 词典开关正名）

行为不变（三处调用早已传 `ignoreRemoteLookupEnabled: true`），纯简化 + 正名。先做这块，它独立且低风险。

**Files:**
- Modify: `hibiki/lib/src/models/app_model.dart:2636-2649`
- Modify: `hibiki/lib/src/pages/base_source_page.dart:236-240`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart:121-126`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:215-219`

- [ ] **Step 1: 简化 `lookupRemoteAudio`，删掉 `ignoreRemoteLookupEnabled` 参数与 guard**

`app_model.dart` 把现有方法（2636-2649）整体替换为：

```dart
  Future<String?> lookupRemoteAudio(
    String expression,
    String reading,
  ) async {
    // 远端音频是否查询由「管理音频来源」对话框里的 hibikiRemote 源 enabled 决定
    // （resolveConfigured 只在该源 enabled 时才调用这里）；与词典远端开关 remoteLookupEnabled 无关。
    try {
      return HibikiRemoteLookupClient(repo: SyncRepository(_database))
          .lookupAudioUrl(expression: expression, reading: reading);
    } catch (e, stack) {
      ErrorLogService.instance.log('remoteAudioLookup', e, stack);
      return null;
    }
  }
```

- [ ] **Step 2: 三处调用点删掉 `ignoreRemoteLookupEnabled: true` 实参**

`base_source_page.dart`（236-240）→

```dart
        queryRemoteAudio: (expression, reading) => appModel.lookupRemoteAudio(
          expression,
          reading,
        ),
```

`dictionary_page_mixin.dart`（121-126）→

```dart
        queryRemoteAudio: (expression, reading) =>
            mixinAppModel.lookupRemoteAudio(
          expression,
          reading,
        ),
```

`dictionary_popup_webview.dart`（215-219）→

```dart
      queryRemoteAudio: (expression, reading) => appModel.lookupRemoteAudio(
        expression,
        reading,
      ),
```

- [ ] **Step 3: 分析通过**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/models/app_model.dart lib/src/pages/base_source_page.dart lib/src/pages/implementations/dictionary_page_mixin.dart lib/src/pages/implementations/dictionary_popup_webview.dart`
Expected: No issues（无 "unused parameter" / "too many positional arguments"）。

- [ ] **Step 4: 新增 i18n key `remote_dict_lookup` + `remote_dict_lookup_hint`（经 i18n_sync）**

Run（worktree 根目录）：

```bash
cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat run tool/i18n_sync.dart --add remote_dict_lookup "Remote dictionary lookup" "远端词典查询"
D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat run tool/i18n_sync.dart --add remote_dict_lookup_hint "When local dictionaries miss, query the configured Hibiki server" "本地词典查不到时，查询已配置的 Hibiki 服务器"
```

然后重生成并格式化（记忆 reference_i18n_sync_workflow）：

```bash
cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat run slang
D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat format lib/i18n/strings.g.dart
```

Expected: `strings.g.dart` 出现 `remote_dict_lookup` getter；`git diff --stat` 只动 i18n 相关文件（不应有 124k 行 churn）。

- [ ] **Step 5: 词典远端开关改用新文案**

`settings_schema.dart` 的 `lookup.remote_lookup`（约 838-849）把 `title`/`subtitle` 改为新 key：

```dart
          SettingsSwitchItem(
            id: 'lookup.remote_lookup',
            title: t.remote_dict_lookup,
            subtitle: t.remote_dict_lookup_hint,
            icon: Icons.hub_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.remoteLookupEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setRemoteLookupEnabled(value);
              settingsContext.refresh();
            },
          ),
```

- [ ] **Step 6: 分析 + 提交**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/settings/settings_schema.dart`
Expected: No issues.

```bash
git add hibiki/lib/src/models/app_model.dart hibiki/lib/src/pages/base_source_page.dart hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart hibiki/lib/src/settings/settings_schema.dart hibiki/lib/i18n/strings.i18n.json hibiki/lib/i18n/strings.g.dart
git commit -m "refactor(audio): decouple remote audio from dict remote lookup switch"
```

---

## Task 2: `LocalAudioManager` 拷贝-only 与删文件 helper

为对话框「添加本地库」和「删除时清文件」提供原子能力，不耦合持久化。

**Files:**
- Modify: `hibiki/lib/src/models/local_audio_manager.dart`
- Test: `hibiki/test/models/local_audio_manager_test.dart`

- [ ] **Step 1: 写失败测试 — importFile 拷贝进库目录但不写 prefs**

在 `hibiki/test/models/local_audio_manager_test.dart`（若不存在则新建，含下方 import 与 setUp）追加：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory tmp;
  late LocalAudioManager manager;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tmp = await Directory.systemTemp.createTemp('localaudio_test');
    manager = LocalAudioManager(prefsRepo: prefs, databaseDirectory: tmp);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('importFile copies into store and does NOT persist prefs', () async {
    final Directory src = await Directory.systemTemp.createTemp('src');
    final File source = File('${src.path}/nhk.db');
    await source.writeAsString('sqlite-bytes');

    final LocalAudioDbEntry entry =
        await manager.importFile(source.path, displayName: 'nhk');

    expect(entry.displayName, 'nhk');
    expect(File(entry.path).existsSync(), isTrue);
    expect(entry.path.startsWith(tmp.path), isTrue);
    // 未写 prefs：entries 仍为空
    expect(manager.entries, isEmpty);
    await src.delete(recursive: true);
  });

  test('deleteFiles removes db + wal + shm', () async {
    final File dbf = File('${tmp.path}/x.db')..writeAsStringSync('a');
    final File wal = File('${tmp.path}/x.db-wal')..writeAsStringSync('b');
    final File shm = File('${tmp.path}/x.db-shm')..writeAsStringSync('c');

    await LocalAudioManager.deleteFiles(dbf.path);

    expect(dbf.existsSync(), isFalse);
    expect(wal.existsSync(), isFalse);
    expect(shm.existsSync(), isFalse);
  });
}
```

> 注：若 `HibikiDatabase.forTesting` / `NativeDatabase.memory` 的构造在本仓不同，照 `test/models/preferences_repository_test.dart` 顶部的既有写法对齐 import 与 db 构造（先打开该测试文件确认）。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/models/local_audio_manager_test.dart`
Expected: FAIL（`importFile` / `deleteFiles` 未定义）。

- [ ] **Step 3: 实现 `importFile` 与 `deleteFiles`**

`local_audio_manager.dart` 内，重构 `add` 复用新 `importFile`，并新增静态 `deleteFiles`：

```dart
  /// 把外部 [sourcePath] 拷贝进库目录，返回指向内部副本的 entry（默认启用），
  /// 但**不**写 prefs、**不**通知 native。持久化交给 setEntries / setAudioSourceConfigs。
  Future<LocalAudioDbEntry> importFile(
    String sourcePath, {
    required String displayName,
  }) async {
    final String internalName =
        'local_audio_${DateTime.now().millisecondsSinceEpoch}.db';
    final String internalPath = path.join(_databaseDirectory.path, internalName);
    final File sourceFile = File(sourcePath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(internalPath);
    }
    return LocalAudioDbEntry(
      path: internalPath,
      displayName: displayName,
      enabled: true,
    );
  }

  /// 删除一个本地库的主文件及其 -wal / -shm 旁文件。
  static Future<void> deleteFiles(String dbPath) async {
    if (dbPath.isEmpty) return;
    for (final String suffix in <String>['', '-wal', '-shm']) {
      final File f = File('$dbPath$suffix');
      if (await f.exists()) await f.delete();
    }
  }
```

把现有 `add` 改为复用：

```dart
  Future<void> add(String sourcePath, {required String displayName}) async {
    final LocalAudioDbEntry entry =
        await importFile(sourcePath, displayName: displayName);
    final dbs = List<LocalAudioDbEntry>.of(entries)..add(entry);
    await setEntries(dbs);
  }
```

把现有 `remove` 的删文件循环改为复用 `deleteFiles`：

```dart
  Future<void> remove(int index) async {
    final dbs = List<LocalAudioDbEntry>.of(entries);
    if (index < 0 || index >= dbs.length) return;
    final entry = dbs.removeAt(index);
    await deleteFiles(entry.path);
    await setEntries(dbs);
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/models/local_audio_manager_test.dart`
Expected: PASS（2 个新测试 + 既有测试）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/models/local_audio_manager.dart hibiki/test/models/local_audio_manager_test.dart
git commit -m "feat(audio): add LocalAudioManager.importFile + deleteFiles helpers"
```

---

## Task 3: `setAudioSourceConfigs` 收口文件生命周期 + 停止自动派生总开关

让对话框单一提交点负责：删掉被移除本地库的文件；不再用「任一库启用」覆盖显式总开关。

**Files:**
- Modify: `hibiki/lib/src/models/app_model.dart:2610-2634`
- Modify: `hibiki/lib/src/models/app_model.dart`（新增 `importLocalAudioDbFile` 委托）
- Test: `hibiki/test/models/app_model_audio_sources_test.dart`

- [ ] **Step 1: 写失败测试 — 删除 localAudio 条目后旧文件被删、且不自动改写总开关**

新建 `hibiki/test/models/app_model_audio_sources_test.dart`。先打开 `test/models/` 下任一 AppModel 测试（如 `app_model_test.dart`）确认 AppModel 的测试构造方式（provider container / fake 平台服务），照其样板搭 setUp。核心断言：

```dart
  test('setAudioSourceConfigs deletes files of removed local audio dbs',
      () async {
    // 先 import 两个本地库文件并保存
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    final LocalAudioDbEntry b =
        await appModel.importLocalAudioDbFile(srcB.path, displayName: 'B');
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
      AudioSourceConfig.localAudio(label: 'B', path: b.path, enabled: true),
    ]);
    expect(File(a.path).existsSync(), isTrue);
    expect(File(b.path).existsSync(), isTrue);

    // 移除 B
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
    ]);
    expect(File(a.path).existsSync(), isTrue);
    expect(File(b.path).existsSync(), isFalse); // 文件被清理，不留孤儿
  });

  test('setAudioSourceConfigs does NOT auto-toggle localAudioEnabled',
      () async {
    await appModel.setLocalAudioEnabled(true);
    // 保存一份全部 disabled 的 localAudio
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: false),
    ]);
    // 旧逻辑会把它改成 false；新逻辑保持显式 true
    expect(appModel.localAudioEnabled, isTrue);
  });
```

> `appModel.setLocalAudioEnabled` 需在 AppModel 暴露（见 Step 3）。`srcA`/`srcB` 在 setUp 里用 `Directory.systemTemp.createTemp` 造临时文件。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/models/app_model_audio_sources_test.dart`
Expected: FAIL（`importLocalAudioDbFile`/`setLocalAudioEnabled` 未定义，或文件未被删 / 总开关被改写）。

- [ ] **Step 3: 重写 `setAudioSourceConfigs` 并新增委托**

`app_model.dart` 把 2610-2634 整体替换为：

```dart
  Future<void> setAudioSourceConfigs(List<AudioSourceConfig> sources) async {
    await prefsRepo.setAudioSourceConfigs(sources);
    final Map<String, LocalAudioDbEntry> current = <String, LocalAudioDbEntry>{
      for (final LocalAudioDbEntry db in localAudioDbs) db.path: db,
    };
    final List<LocalAudioDbEntry> nextDbs = <LocalAudioDbEntry>[
      for (final AudioSourceConfig source in sources)
        if (source.kind == AudioSourceKind.localAudio &&
            (source.path?.isNotEmpty ?? false))
          (current[source.path] ??
                  LocalAudioDbEntry(
                    path: source.path!,
                    displayName: source.displayLabel,
                    enabled: source.enabled,
                  ))
              .copyWith(
            displayName: source.displayLabel,
            enabled: source.enabled,
          ),
    ];
    // 删掉被移除本地库的磁盘文件（避免孤儿）。
    final Set<String> nextPaths =
        nextDbs.map((LocalAudioDbEntry db) => db.path).toSet();
    for (final String oldPath in current.keys) {
      if (!nextPaths.contains(oldPath)) {
        await LocalAudioManager.deleteFiles(oldPath);
      }
    }
    await _localAudioManager.setEntries(nextDbs);
    // 不再自动派生 localAudioEnabled —— 全局总开关是对话框顶部的显式控件。
  }

  Future<LocalAudioDbEntry> importLocalAudioDbFile(
    String sourcePath, {
    required String displayName,
  }) =>
      _localAudioManager.importFile(sourcePath, displayName: displayName);

  Future<void> setLocalAudioEnabled(bool value) =>
      _localAudioManager.setLocalAudioEnabled(value);
```

> `setLocalAudioEnabled` 已存在于 `LocalAudioManager`；这里加 AppModel 层委托。确认 `local_audio_manager.dart` 的 import 在 `app_model.dart` 顶部已有（`LocalAudioManager` 已被 `_localAudioManager` 使用，无需新 import）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/models/app_model_audio_sources_test.dart`
Expected: PASS。

- [ ] **Step 5: 跑既有 preferences 测试确认无回归**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/models/preferences_repository_test.dart`
Expected: PASS（`setAudioSourceConfigs persists typed audio sources` 不受影响——它测的是 prefsRepo 层）。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/models/app_model.dart hibiki/test/models/app_model_audio_sources_test.dart
git commit -m "fix(audio): centralize local audio file lifecycle, stop auto-deriving master switch"
```

---

## Task 4: `AudioSourcesDialog` 加全局总开关 + 添加本地库按钮

对话框成为本地音频的唯一管理处。保持「批量编辑 `_sources`、关闭时 `onSave` 提交」模型；新增的总开关与添加按钮通过构造回调注入，保持 widget 可独立测试。

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart`
- Test: `hibiki/test/pages/audio_sources_dialog_page_test.dart`

- [ ] **Step 1: 扩展构造签名（新增 4 个可选参数，保持既有测试兼容）**

`AudioSourcesDialog` 加字段（7-15 行区域）：

```dart
class AudioSourcesDialog extends StatefulWidget {
  const AudioSourcesDialog({
    required this.sources,
    required this.onSave,
    this.localAudioEnabled = false,
    this.onToggleLocalAudio,
    this.onPickLocalDb,
    super.key,
  });

  final List<AudioSourceConfig> sources;
  final void Function(List<AudioSourceConfig>) onSave;

  /// 本地音频全局总开关当前值（决策 B：保留并置于对话框顶部）。
  final bool localAudioEnabled;

  /// 切换全局总开关；立即生效（独立于 _sources 批量提交）。
  final Future<void> Function(bool enabled)? onToggleLocalAudio;

  /// 选文件并拷贝进库目录，返回一个 localAudio 源（已拷贝、未持久化）。
  /// 返回 null 表示用户取消。
  final Future<AudioSourceConfig?> Function()? onPickLocalDb;
```

- [ ] **Step 2: state 持有总开关本地值**

`_AudioSourcesDialogState`（21-29 区域）加：

```dart
class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  late List<AudioSourceConfig> _sources;
  late bool _localAudioEnabled;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = List<AudioSourceConfig>.from(widget.sources);
    _localAudioEnabled = widget.localAudioEnabled;
  }
```

- [ ] **Step 3: body 顶部插入总开关行（仅当回调存在时显示）**

在 `Column`（72 行）的 `children` 最前面、`Flexible(...)` 之前插入：

```dart
              if (widget.onToggleLocalAudio != null) ...<Widget>[
                AdaptiveSettingsRow(
                  title: t.local_audio,
                  icon: Icons.library_music_outlined,
                  trailing: Switch.adaptive(
                    value: _localAudioEnabled,
                    onChanged: (bool value) async {
                      await widget.onToggleLocalAudio!(value);
                      if (mounted) setState(() => _localAudioEnabled = value);
                    },
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
              ],
```

- [ ] **Step 4: 文本框后插入「添加本地库」按钮（仅当回调存在）**

在 `AdaptiveSettingsTextField`（148 行）之后、`Column` children 结尾前插入：

```dart
              if (widget.onPickLocalDb != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.library_add_outlined, size: 18),
                    label: Text(t.local_audio_add_db),
                    onPressed: () async {
                      final AudioSourceConfig? added =
                          await widget.onPickLocalDb!();
                      if (added != null && mounted) {
                        setState(() => _sources.add(added));
                      }
                    },
                  ),
                ),
              ],
```

- [ ] **Step 5: 「重置」只清远端、保留本地库与 hibikiRemote**

把重置按钮 onPressed（187-193 区域）改为：

```dart
              onPressed: () {
                setState(() {
                  final List<AudioSourceConfig> kept = _sources
                      .where((AudioSourceConfig s) =>
                          s.kind != AudioSourceKind.remoteAudio)
                      .toList();
                  _sources = <AudioSourceConfig>[
                    ...kept,
                    ...AudioSourceConfig.fromLegacyUrls(
                      AppModel.defaultAudioSources,
                    ),
                  ];
                });
              },
```

- [ ] **Step 6: 写 widget 测试 — 总开关与添加按钮**

`audio_sources_dialog_page_test.dart` 追加：

```dart
  testWidgets('shows local audio master switch and add button when wired',
      (WidgetTester tester) async {
    bool? toggled;
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: const <AudioSourceConfig>[],
          onSave: (_) {},
          localAudioEnabled: false,
          onToggleLocalAudio: (bool v) async => toggled = v,
          onPickLocalDb: () async => null,
        ),
      ),
    );

    expect(find.byType(Switch).evaluate().isNotEmpty, isTrue);
    expect(find.text(t.local_audio_add_db), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(toggled, isTrue);
  });
```

> `t` 来自 `import 'package:hibiki/i18n/strings.g.dart'`（既有 import）。

- [ ] **Step 7: 运行测试确认通过 + 分析**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/pages/audio_sources_dialog_page_test.dart`
Expected: PASS（含既有 compact-window 测试，因新参数都是可选的）。
Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/pages/implementations/dictionary_settings_dialog_page.dart`
Expected: No issues.

- [ ] **Step 8: 提交**

```bash
git add hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart hibiki/test/pages/audio_sources_dialog_page_test.dart
git commit -m "feat(audio): add local-audio master switch and add-db button to sources dialog"
```

---

## Task 5: settings_schema wire 对话框 + 删除冗余 section/widget

把对话框新参数接到 AppModel，删掉独立「本地音频」section 与 `_LocalAudioDatabasesRow`。

**Files:**
- Modify: `hibiki/lib/src/settings/settings_schema.dart`

- [ ] **Step 1: wire `AudioSourcesDialog` 新参数（lookup.audio_sources, 806-821 区域）**

把 `onTap` 内的 dialog 构造改为：

```dart
            onTap: (SettingsContext settingsContext) {
              final AppModel appModel = settingsContext.appModel;
              return showSettingsDialog(
                settingsContext,
                (_) => AudioSourcesDialog(
                  sources: List<AudioSourceConfig>.from(
                    appModel.audioSourceConfigs,
                  ),
                  onSave: appModel.setAudioSourceConfigs,
                  localAudioEnabled: appModel.localAudioEnabled,
                  onToggleLocalAudio: appModel.setLocalAudioEnabled,
                  onPickLocalDb: () async {
                    final FilePickerResult? result =
                        await FilePicker.platform.pickFiles();
                    final String? path = result?.files.single.path;
                    if (path == null) return null;
                    final LocalAudioDbEntry entry =
                        await appModel.importLocalAudioDbFile(
                      path,
                      displayName: result!.files.single.name,
                    );
                    return AudioSourceConfig.localAudio(
                      label: entry.displayName,
                      path: entry.path,
                      enabled: true,
                    );
                  },
                ),
              );
            },
```

> 确认 `settings_schema.dart` 顶部已 import `FilePicker`（`file_picker`）与 `LocalAudioDbEntry`/`AudioSourceConfig`（经 `models.dart` 导出）。若缺 FilePicker import，按 `_LocalAudioDatabasesRow` 原来用到 FilePicker 的 import 补上（它原本就在本文件里用了 FilePicker）。

- [ ] **Step 2: 删除独立「本地音频」section（961-982 区域）**

删除整段：

```dart
      SettingsSection(
        title: t.local_audio,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.local_audio',
            ... // 整个 section
          ),
          SettingsCustomItem(
            id: 'lookup.local_audio_databases',
            ...
          ),
        ],
      ),
```

- [ ] **Step 3: 删除 `_LocalAudioDatabasesRow` 整个 widget（1357-1557 区域）**

删除 `class _LocalAudioDatabasesRow ...` 到其 State 类结束（`_refresh` 方法后的 `}`），即 Step 文件结构里 1357-1557 整块。保留其后的 `String get customFontsTitlePlaceholder ...`。

- [ ] **Step 4: 分析（确认无悬空引用 / 未用 import）**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/settings/settings_schema.dart`
Expected: No issues。若报 `FilePicker`/`PlatformFile` 等 import 现在 unused，删掉对应未用 import；若报仍被使用则保留。

- [ ] **Step 5: 格式化 + 提交**

```bash
cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat format lib/src/settings/settings_schema.dart
git add hibiki/lib/src/settings/settings_schema.dart
git commit -m "refactor(settings): fold local audio into sources dialog, drop standalone section"
```

---

## Task 6: 全量验证

**Files:** 无（仅运行）

- [ ] **Step 1: 全量分析**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze`
Expected: No issues found.

- [ ] **Step 2: 全量单测**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub`
Expected: All tests passed.（重点关注 `test/models/`、`test/pages/audio_sources_dialog_page_test.dart`、`test/i18n/` 完整性测试）

- [ ] **Step 3: 若 i18n 完整性测试失败**

检查 `test/i18n/` 报哪个 locale 缺 `remote_dict_lookup`/`remote_dict_lookup_hint`。重跑 `dart run tool/i18n_sync.dart`（无参补全缺失 key）+ `dart run slang` + `dart format lib/i18n/strings.g.dart`，再提交。

- [ ] **Step 4: 收尾提交（若 Step 3 有改动）**

```bash
git add hibiki/lib/i18n/
git commit -m "chore(i18n): backfill remote_dict_lookup across locales"
```

---

## Self-Review 备注（计划作者）

- **Spec 覆盖**：4.1 远端拆分→Task 1；4.2 总开关派生修正→Task 3；4.3 对话框整合→Task 2(helper)+Task 4(UI)+Task 5(wire)；4.4 删冗余→Task 5；4.5 i18n→Task 1 Step4 + Task 6 Step3；§6 测试→各 Task 内 TDD + Task 6。
- **行为变更点（已与用户确认接受）**：远端音频不再受词典开关影响（实际早已如此，本次只是删死代码 + 正名）；删除本地库现在会清磁盘文件；总开关不再被自动派生覆盖。
- **类型一致性**：`importFile`/`deleteFiles`（Task 2）= `importLocalAudioDbFile`/`LocalAudioManager.deleteFiles`（Task 3 调用）；`onToggleLocalAudio`=`appModel.setLocalAudioEnabled`（bool→Future<void>，签名一致）；`onPickLocalDb` 返回 `AudioSourceConfig?`。
- **风险**：Task 3 的 AppModel 测试夹具构造需对齐本仓既有 `test/models/app_model*` 样板（provider container / fake platform services）；执行时先读该样板再落笔。

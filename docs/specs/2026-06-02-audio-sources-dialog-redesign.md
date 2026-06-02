# 管理音频来源对话框重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development 或 superpowers:executing-plans 逐任务实现。Steps 用 checkbox（`- [ ]`）跟踪。

**Goal:** 把「管理音频来源」对话框从「一个混合拖拽列表」重构为「远端来源 / 本地音频」两个清晰分组，并修复 URL 零校验、本地导入无进度、无成功反馈、Hibiki Remote 英文写死、总开关命名误导这 6 个真实问题。

**Architecture:** UI 层重构集中在 `dictionary_settings_dialog_page.dart` 的 `AudioSourcesDialog`：state 把 `widget.sources` 按 `kind` 拆成 `_remoteSources`(hibikiRemote+remoteAudio) 与 `_localSources`(localAudio) 两份有序列表，关闭时 `onSave([..._remote, ..._local])` 合并回写。模型层只动 `AudioSourceConfig.hibikiRemote` 的英文写死 label。数据投影/持久化路径（`setAudioSourceConfigs` ↔ `LocalAudioManager`）**完全不动**——保持 reference_audio_sources_model 记录的契约。

**Tech Stack:** Flutter / Riverpod / Slang i18n（`tool/i18n_sync.dart` + `dart run slang`）；现成组件 `SettingsSectionHeader` / `AdaptiveSettingsRow` / `AdaptiveSettingsTextField` / `HibikiIconButton` / `ReorderableListView`。

**已锁定的设计决策（来自用户确认）：**
1. 对话框拆两个分组：远端来源（可拖拽）+ 本地音频（总开关做组头，可展开列 DB 文件）。
2. 自定义远端 URL 校验：必须 `http(s)://` 且含 `{term}` 或 `{reading}`，否则禁用「添加」并提示。
3. Hibiki 互联走**新增 i18n key**，值与同步功能的 `sync_backend_hibiki_server` 镜像一致（en `Hibiki P2P` / zh-CN `Hibiki 互联`）。

**行为变更（需在 PR/commit 说明）：** 保存顺序由「可任意交错」改为「所有远端源在前、本地源在后」。本地音频源全部映射到同一个 `WordAudioResolver.localAudioUrl` sentinel，远端各有 URL；分组后远端整体优先于本地。组内顺序保留。这是两分组设计的必然取舍，用户已确认。

---

## File Structure

| 文件 | 责任 | 改动类型 |
|---|---|---|
| `hibiki/lib/i18n/*.i18n.json`（17 份） | 新增 4 个 key | 经 `i18n_sync.dart --add` 改 |
| `hibiki/lib/i18n/strings.g.dart` | Slang 生成 | `dart run slang` 重生成，勿手改 |
| `hibiki/lib/src/models/audio_source_config.dart` | 去掉 hibikiRemote 英文写死 label | Modify |
| `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart` | `AudioSourcesDialog` 重构 | Modify（大头） |
| `hibiki/test/pages/audio_sources_dialog_page_test.dart` | 适配新结构 + 新增校验/分组测试 | Modify |
| `hibiki/test/models/audio_source_config_test.dart` | hibikiRemote label 断言 | Modify（若有相关断言） |

---

## Task 1: 新增 i18n keys

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本）
- Regenerate: `hibiki/lib/i18n/strings.g.dart`

新增 key（值不含 `{` `}`，避开 Slang 插值）：

| key | en | zh-CN |
|---|---|---|
| `audio_source_hibiki_interconnect` | `Hibiki P2P` | `Hibiki 互联` |
| `audio_sources_remote_group` | `Remote sources` | `远端来源` |
| `audio_source_url_invalid` | `Link must be http(s) and contain a term or reading placeholder` | `链接需为 http(s) 且含 term / reading 占位符` |
| `audio_source_added` | `Audio source added` | `已添加音频来源` |
| `local_audio_imported` | `Audio database added` | `已添加音频数据库` |
| `local_audio_import_failed` | `Failed to import audio database` | `导入音频数据库失败` |

- [ ] **Step 1: 逐 key 执行 `--add`（在 `hibiki/` 下）**

```bash
cd hibiki
dart tool/i18n_sync.dart --add audio_source_hibiki_interconnect "Hibiki P2P" "Hibiki 互联"
dart tool/i18n_sync.dart --add audio_sources_remote_group "Remote sources" "远端来源"
dart tool/i18n_sync.dart --add audio_source_url_invalid "Link must be http(s) and contain a term or reading placeholder" "链接需为 http(s) 且含 term / reading 占位符"
dart tool/i18n_sync.dart --add audio_source_added "Audio source added" "已添加音频来源"
dart tool/i18n_sync.dart --add local_audio_imported "Audio database added" "已添加音频数据库"
dart tool/i18n_sync.dart --add local_audio_import_failed "Failed to import audio database" "导入音频数据库失败"
```

- [ ] **Step 2: 重新生成并格式化（只格式化生成文件）**

```bash
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 3: 校验**

Run: `git diff --stat hibiki/lib/i18n`
Expected: 17 份 json 各 +6 key；`strings.g.dart` 改动行数可控（不是 12 万行 churn——若是，说明漏了 `dart format`）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/i18n
git commit -m "i18n(audio): add hibiki interconnect / remote group / url validation keys"
```

---

## Task 2: 去掉 hibikiRemote 的英文写死 label

**Files:**
- Modify: `hibiki/lib/src/models/audio_source_config.dart:31-37,94-103`
- Test: `hibiki/test/models/audio_source_config_test.dart`

label 纯属展示，UI 会用 i18n 覆盖；写死 `'Hibiki Remote'` 会把英文持久化进 prefs。改为不设 label。

- [ ] **Step 1: 写/改测试（先失败）**

在 `audio_source_config_test.dart` 加：

```dart
test('hibikiRemote does not hardcode an English display label', () {
  final AudioSourceConfig source = AudioSourceConfig.hibikiRemote();
  expect(source.label, isNull);
  expect(source.displayLabel, isEmpty);
  // 不再把英文名持久化进 json
  expect(source.toJson().containsKey('label'), isFalse);
});
```

若文件已有断言 `displayLabel == 'Hibiki Remote'` 之类，一并改掉。

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/models/audio_source_config_test.dart --no-pub`
Expected: FAIL（当前 label == 'Hibiki Remote'）

- [ ] **Step 3: 改实现**

`audio_source_config.dart` factory：

```dart
  factory AudioSourceConfig.hibikiRemote({bool enabled = false}) {
    return AudioSourceConfig._(
      kind: AudioSourceKind.hibikiRemote,
      enabled: enabled,
    );
  }
```

`displayLabel` 的 hibikiRemote 分支：

```dart
      case AudioSourceKind.hibikiRemote:
        return label ?? '';
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/models/audio_source_config_test.dart --no-pub`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/models/audio_source_config.dart hibiki/test/models/audio_source_config_test.dart
git commit -m "fix(audio): drop hardcoded English label on hibikiRemote source"
```

---

## Task 3: 重构 AudioSourcesDialog（核心）

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:34-283`

### 3a. State 拆分与校验工具

state 字段改为：

```dart
class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  late List<AudioSourceConfig> _remoteSources; // hibikiRemote + remoteAudio，有序
  late List<AudioSourceConfig> _localSources;  // localAudio，有序
  late bool _localAudioEnabled;
  bool _localExpanded = false;
  bool _importing = false;
  final TextEditingController _controller = TextEditingController();
  bool _urlValid = false;

  @override
  void initState() {
    super.initState();
    _remoteSources = widget.sources
        .where((AudioSourceConfig s) => s.kind != AudioSourceKind.localAudio)
        .toList();
    _localSources = widget.sources
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
        .toList();
    _localAudioEnabled = widget.localAudioEnabled;
    _localExpanded = widget.localAudioEnabled;
  }

  List<AudioSourceConfig> get _combined =>
      <AudioSourceConfig>[..._remoteSources, ..._localSources];

  static bool isValidRemoteUrl(String text) {
    final String value = text.trim();
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return value.contains('{term}') || value.contains('{reading}');
  }
```

`isValidRemoteUrl` 设为 `static`（`@visibleForTesting` 可单测）。

### 3b. 远端来源分组

`SettingsSectionHeader(t.audio_sources_remote_group)` + 一个 `Flexible` 包 `ReorderableListView.builder`，itemCount=`_remoteSources.length`，onReorder 作用于 `_remoteSources`。每行：

- title：hibikiRemote → `t.audio_source_hibiki_interconnect`；remoteAudio → `source.displayLabel`
- subtitle：hibikiRemote → `t.remote_audio_source`；remoteAudio → `source.url`
- trailing：enable Switch（改 `_remoteSources[index]`）+ 上/下移 `HibikiIconButton` + 删除（hibikiRemote 不可删，`enabled: source.kind != hibikiRemote`）
- key：`ValueKey('audio_remote_${source.kind.wireName}_${source.url ?? index}')`

URL 输入区（在远端列表下）：

```dart
AdaptiveSettingsTextField(
  controller: _controller,
  hintText: 'https://...{term}...{reading}',
  onChanged: (String v) =>
      setState(() => _urlValid = isValidRemoteUrl(v)),
  onSubmitted: (_) => _addRemoteUrl(),
  suffixIcon: Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (!_remoteSources.any((AudioSourceConfig s) =>
          s.kind == AudioSourceKind.hibikiRemote))
        HibikiIconButton(
          icon: Icons.hub_outlined,
          tooltip: t.audio_source_hibiki_interconnect,
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => setState(() =>
              _remoteSources.insert(0, AudioSourceConfig.hibikiRemote())),
        ),
      HibikiIconButton(
        icon: Icons.add,
        tooltip: t.dialog_add,
        enabled: _urlValid,
        padding: EdgeInsets.all(tokens.spacing.gap / 2),
        onTap: _addRemoteUrl,
      ),
    ],
  ),
),
if (_controller.text.trim().isNotEmpty && !_urlValid)
  Padding(
    padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
    child: Text(
      t.audio_source_url_invalid,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  ),
```

`_addRemoteUrl`：

```dart
void _addRemoteUrl() {
  final String text = _controller.text.trim();
  if (!isValidRemoteUrl(text)) {
    _showSnack(t.audio_source_url_invalid);
    return;
  }
  setState(() {
    _remoteSources.add(AudioSourceConfig.remoteAudio(url: text));
    _controller.clear();
    _urlValid = false;
  });
  _showSnack(t.audio_source_added);
}

void _showSnack(String message) {
  final ScaffoldMessengerState? messenger =
      ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}
```

### 3c. 本地音频分组（可展开）

仅当 `widget.onToggleLocalAudio != null` 渲染：

- 组头 `AdaptiveSettingsRow(title: t.local_audio, icon: Icons.library_music_outlined, onTap: 切换 _localExpanded, trailing: Row[ 总开关 Switch.adaptive, 展开 chevron ])`
  - 总开关 onChanged：`await widget.onToggleLocalAudio!(v); if(mounted) setState(()=>_localAudioEnabled=v);`
- 展开后（`_localExpanded`）：`Flexible` 包 shrinkWrap `ListView` 列出 `_localSources`，每行 title=`source.displayLabel`、subtitle=`source.path`、trailing=[enable Switch（改 `_localSources[index]`）, 删除 HibikiIconButton]。
- 末尾「添加本地音频数据库」按钮（仅 `widget.onPickLocalDb != null`），带 `_importing` 进度：

```dart
TextButton.icon(
  icon: _importing
      ? const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2))
      : const Icon(Icons.library_add_outlined, size: 18),
  label: Text(t.local_audio_add_db),
  onPressed: _importing
      ? null
      : () async {
          setState(() => _importing = true);
          try {
            final AudioSourceConfig? added = await widget.onPickLocalDb!();
            if (!mounted) return;
            if (added != null) {
              setState(() {
                _localSources.add(added);
                _localExpanded = true;
              });
              _showSnack(t.local_audio_imported);
            }
            // added == null 表示用户取消，不弹反馈
          } catch (e) {
            if (mounted) _showSnack(t.local_audio_import_failed);
          } finally {
            if (mounted) setState(() => _importing = false);
          }
        },
),
```

### 3d. footer：reset / close 适配新 state

- close：`widget.onSave(_combined); Navigator.pop(context);`
- reset：只重置远端为默认（保留已存在的 hibikiRemote，本地不动）：

```dart
onPressed: () {
  setState(() {
    final bool hadHibiki = _remoteSources
        .any((AudioSourceConfig s) => s.kind == AudioSourceKind.hibikiRemote);
    _remoteSources = <AudioSourceConfig>[
      if (hadHibiki) AudioSourceConfig.hibikiRemote(),
      ...AudioSourceConfig.fromLegacyUrls(AppModel.defaultAudioSources),
    ];
  });
},
```

### 3e. `_sourceSubtitle` / 删除旧 `_addSource`

删除旧 `_addSource()`（被 `_addRemoteUrl` 取代）。`_sourceSubtitle` 不再需要（subtitle 直接在行内算），可删除或保留供 remoteAudio 用——直接行内算，删除该方法。

- [ ] **Step 1: 按 3a–3e 改写 `_AudioSourcesDialogState`**（一次成型，含上面全部代码）
- [ ] **Step 2: 静态分析**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/dictionary_settings_dialog_page.dart`
Expected: No issues.

- [ ] **Step 3: 格式化**

Run: `cd hibiki && dart format lib/src/pages/implementations/dictionary_settings_dialog_page.dart`

---

## Task 4: 适配 + 新增 widget 测试

**Files:**
- Modify: `hibiki/test/pages/audio_sources_dialog_page_test.dart`

- [ ] **Step 1: 重写测试文件**

```dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget buildApp(Widget home) =>
      TranslationProvider(child: MaterialApp(home: Scaffold(body: home)));

  testWidgets('fits a compact desktop window with many remote sources',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp(AudioSourcesDialog(
      sources: List<AudioSourceConfig>.generate(
        12,
        (int i) => AudioSourceConfig.remoteAudio(
            url: 'https://audio.example.com/$i/{term}/{reading}'),
      ),
      onSave: (_) {},
    )));
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('rejects an invalid url and accepts a valid one',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await tester.pumpWidget(buildApp(AudioSourcesDialog(
      sources: const <AudioSourceConfig>[],
      onSave: (List<AudioSourceConfig> s) => saved = s,
    )));

    // 非法输入 → 报错提示出现，add 按钮禁用
    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsOneWidget);

    // 合法输入 → 错误消失
    await tester.enterText(
        find.byType(TextField), 'https://x.com/{term}/{reading}');
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsNothing);
  });

  testWidgets('isValidRemoteUrl enforces http(s) + placeholder', (_) async {
    expect(_AudioUrlProbe.valid('https://x.com/{term}'), isTrue);
    expect(_AudioUrlProbe.valid('http://x.com/{reading}'), isTrue);
    expect(_AudioUrlProbe.valid('https://x.com/audio'), isFalse); // 无占位符
    expect(_AudioUrlProbe.valid('ftp://x.com/{term}'), isFalse); // 非 http(s)
    expect(_AudioUrlProbe.valid('{term}'), isFalse); // 无 scheme/authority
  });

  testWidgets('local audio group expands to reveal add-db button',
      (WidgetTester tester) async {
    bool? toggled;
    await tester.pumpWidget(buildApp(AudioSourcesDialog(
      sources: const <AudioSourceConfig>[],
      onSave: (_) {},
      localAudioEnabled: false,
      onToggleLocalAudio: (bool v) async => toggled = v,
      onPickLocalDb: () async => null,
    )));

    // 折叠态：add-db 按钮不在树里
    expect(find.text(t.local_audio_add_db), findsNothing);

    // 点组头展开
    await tester.tap(find.text(t.local_audio));
    await tester.pumpAndSettle();
    expect(find.text(t.local_audio_add_db), findsOneWidget);

    // 总开关回调
    final Finder masterSwitch = find.descendant(
      of: find.ancestor(
          of: find.text(t.local_audio), matching: find.byType(Row)),
      matching: find.byWidgetPredicate(
          (Widget w) => w is Switch || w is CupertinoSwitch),
    );
    await tester.tap(masterSwitch.first);
    await tester.pumpAndSettle();
    expect(toggled, isTrue);
  });
}

class _AudioUrlProbe {
  static bool valid(String s) => AudioSourcesDialog.isValidRemoteUrl(s);
}
```

> 注：`isValidRemoteUrl` 需在 `AudioSourcesDialog` 上暴露为 `static`（`@visibleForTesting`）。点组头 `t.local_audio` 展开依赖 3c 的 `onTap`。

- [ ] **Step 2: 跑该测试文件**

Run: `cd hibiki && flutter test test/pages/audio_sources_dialog_page_test.dart --no-pub`
Expected: PASS（4 个用例）

---

## Task 5: 全量验证 + 提交

- [ ] **Step 1: 格式化全仓改动**

Run: `cd hibiki && dart format lib test`

- [ ] **Step 2: 静态分析**

Run: `cd hibiki && flutter analyze`
Expected: No issues（至少不新增）。

- [ ] **Step 3: 相关测试**

Run:
```bash
cd hibiki
flutter test test/pages/audio_sources_dialog_page_test.dart test/models/audio_source_config_test.dart test/models/app_model_audio_sources_test.dart --no-pub
```
Expected: 全 PASS。

- [ ] **Step 4: 提交（只 stage 本轮文件，禁止 git add -A）**

```bash
git add hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart \
        hibiki/test/pages/audio_sources_dialog_page_test.dart
git status --short   # 确认没夹带并发 agent 的无关改动
git diff --cached --check
git commit -m "feat(audio): split audio sources dialog into remote/local groups with validation + feedback"
```

- [ ] **Step 5: 设备验证（按 CLAUDE.md：导入/播放路径声明修好前需真机复测）**

在用户指定设备开「管理音频来源」对话框，逐条复验：
1. 远端来源分组拖拽排序 / Hibiki 互联显示中文名
2. 输入非法 URL 被拒 + 提示；合法 URL 可加 + 成功提示
3. 本地音频组头总开关 + 展开列 DB；添加本地库有进度圈 + 成功提示
留证据（截图）于 `.codex-test/`。

---

## Self-Review

- **Spec 覆盖：** 8 条反馈 → 7=Task3c 组头命名/分组；2=Task3c 可展开；3=Task3a 拆分列表；4=Task3c `_importing`；5=Task3b 校验；6=Task3b/3c SnackBar；8=Task1+Task2 i18n；1=Task1/2 综合。✔
- **占位符扫描：** 无 TODO/TBD，所有 step 含真实代码。✔
- **类型一致：** `isValidRemoteUrl`(static) 在 Task3a 定义、Task4 引用；`_remoteSources/_localSources/_combined` 命名贯穿一致；i18n key 名 Task1 定义、Task3 引用一致。✔
- **风险：** ① 双 `Flexible` 列表在 320×240 紧凑窗的布局——Task4 首测覆盖。② SnackBar 需 `ScaffoldMessenger` 祖先——`showSettingsDialog` 在 app 级 Navigator 上，`maybeOf` 兜底不崩。③ 保存顺序语义变更——已在抬头声明。

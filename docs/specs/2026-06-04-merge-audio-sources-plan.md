# 合并音频来源 + 删本地音频总开关 + 新增插首位 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「管理音频来源」对话框的远端/本地两分组合并为单列表，删除本地音频 master 总开关（改由每个来源的 `enabled` 单一 gate），新增来源默认插到列表首位。

**Architecture:** 分两个可独立编译的提交。Task 1 只动 UI 层（对话框 + settings_schema 接线）——此时模型的 master plumbing 仍保留，外部引用不断。Task 2 删模型层 master gate 与 plumbing（`localAudioEnabled`/`setLocalAudioEnabled`/`toggleLocalAudio`）及其全部末端守卫——此时 settings_schema/对话框已不再引用，编译自洽。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0，Riverpod，slang i18n，drift。测试用 `flutter test`（项目工具链）。

设计文档：`docs/specs/2026-06-04-merge-audio-sources-design.md`。

---

## Task 1: 对话框合并单列表 + 插首位 + 去 master UI 参数

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart`（替换 `AudioSourcesDialog` + `_AudioSourcesDialogState`，行 6-471）
- Modify: `hibiki/lib/src/settings/settings_schema.dart`（行 816-817 去掉两参数）
- Test: `hibiki/test/pages/audio_sources_dialog_page_test.dart`（改写 master 用例 + 新增插首位）
- Test: `hibiki/test/pages/local_audio_reorder_test.dart`（去 master 入参）

**实现注记（Step 1 测试写法修正）：** `HibikiIconButton` 用 `Semantics(label: tooltip)` 而非 `Tooltip`，故点「添加」按钮用 `find.byIcon(Icons.add)`（不是 `find.byTooltip`）。又因对话框作为 `MaterialApp.home` 时行尾「关闭」按钮的 `Navigator.pop` 会因根 route 无法出栈而抛，验证 `onSave` 顺序的用例须经一个 `showDialog` host（测试内 `openDialog` helper）打开对话框。已落地的测试以 `test/pages/audio_sources_dialog_page_test.dart` 实际内容为准。

- [ ] **Step 1: 改写对话框测试为新契约（单列表 / 无 master / 插首位）**

把 `hibiki/test/pages/audio_sources_dialog_page_test.dart` 的最后一个 `testWidgets`（`local audio group ... master switch`，行 81-120）整体替换为下面三个用例；其余用例（`isValidRemoteUrl`、`fits a compact desktop window`、`rejects an invalid url`）保持不变：

```dart
  testWidgets('renders local audio rows inline with no master switch and '
      'exposes the add-db entry', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: <AudioSourceConfig>[
            AudioSourceConfig.localAudio(
                label: 'android.db', path: '/a.db', enabled: true),
          ],
          onSave: (_) {},
          onPickLocalDb: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 本地库行直接渲染在统一列表里（无需展开任何分组）。
    expect(find.text('android.db'), findsOneWidget);
    // 「添加本地音频数据库」入口始终可见（不再藏在折叠组里）。
    expect(find.text(t.local_audio_add_db), findsOneWidget);
    // 不再有「本地音频」master 组头。
    expect(find.text(t.local_audio), findsNothing);
  });

  testWidgets('adding a remote url inserts it at the top of the list',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: <AudioSourceConfig>[
            AudioSourceConfig.remoteAudio(
                url: 'https://old.example.com/{term}'),
          ],
          onSave: (List<AudioSourceConfig> v) => saved = v,
        ),
      ),
    );

    await tester.enterText(
        find.byType(TextField), 'https://new.example.com/{term}');
    await tester.pump();
    await tester.tap(find.byTooltip(t.dialog_add));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.first.url, 'https://new.example.com/{term}');
    expect(saved!.length, 2);
  });

  testWidgets('adding a local db inserts it at the top of the list',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: <AudioSourceConfig>[
            AudioSourceConfig.remoteAudio(
                url: 'https://old.example.com/{term}'),
          ],
          onSave: (List<AudioSourceConfig> v) => saved = v,
          onPickLocalDb: () async => AudioSourceConfig.localAudio(
              label: 'new.db', path: '/new.db', enabled: true),
        ),
      ),
    );

    await tester.tap(find.text(t.local_audio_add_db));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.first.kind, AudioSourceKind.localAudio);
    expect(saved!.first.path, '/new.db');
  });
```

并在该测试文件顶部 import 区补上（若缺）：

```dart
import 'package:hibiki/src/models/audio_source_config.dart';
```

（该 import 已存在于行 5，确认即可，无需重复添加。）

- [ ] **Step 2: 跑测试确认编译失败 / 用例失败**

Run: `cd hibiki && flutter test test/pages/audio_sources_dialog_page_test.dart --no-pub`
Expected: FAIL —— 旧对话框仍是两分组 + master，新用例（无 master switch / 插首位）不满足。

- [ ] **Step 3: 重构对话框为单列表 + 插首位 + 删 master 参数**

把 `dictionary_settings_dialog_page.dart` 的行 6-471（`@visibleForTesting class AudioSourcesDialog ...` 到 `_AudioSourcesDialogState` 结束的 `}`，即紧接 `class DictCssEditorDialog` 之前）整体替换为：

```dart
@visibleForTesting
class AudioSourcesDialog extends StatefulWidget {
  const AudioSourcesDialog({
    required this.sources,
    required this.onSave,
    this.onPickLocalDb,
    this.onEditLocalSources,
    super.key,
  });

  final List<AudioSourceConfig> sources;
  final void Function(List<AudioSourceConfig>) onSave;

  /// 选文件并拷贝进库目录，返回一个 localAudio 源（已拷贝、未持久化）；
  /// 返回 null 表示用户取消。
  final Future<AudioSourceConfig?> Function()? onPickLocalDb;

  /// 打开某个本地音频库的「子来源顺序 + 逐源启用」编辑器（按库路径）。
  final Future<void> Function(String path)? onEditLocalSources;

  /// 自定义远端音频 URL 合法性：必须是 http(s) 链接，且至少含一个
  /// `{term}` / `{reading}` 占位符（否则播放时无法代入查词参数）。
  @visibleForTesting
  static bool isValidRemoteUrl(String text) {
    final String value = text.trim();
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return value.contains('{term}') || value.contains('{reading}');
  }

  @override
  State<AudioSourcesDialog> createState() => _AudioSourcesDialogState();
}

class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  /// 统一来源列表（hibikiRemote + remoteAudio + localAudio 混排，顺序即优先级）。
  late List<AudioSourceConfig> _sources;
  bool _importing = false;
  bool _urlValid = false;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = List<AudioSourceConfig>.of(widget.sources);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double maxHeight =
        (MediaQuery.of(context).size.height * 0.55).clamp(128.0, 420.0);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.manage_audio_sources,
        leadingIcon: Icons.graphic_eq_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          // 整体可滚动：列表 shrinkWrap + NeverScrollable，交由外层 SingleChildScrollView
          // 滚动；紧凑窗口下内容超高时整体滚动而非 RenderFlex 溢出。
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildSourceList(tokens),
                SizedBox(height: tokens.spacing.gap),
                _buildUrlField(tokens),
                if (widget.onPickLocalDb != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: _importing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.library_add_outlined, size: 18),
                      label: Text(t.local_audio_add_db),
                      onPressed: _importing ? null : _addLocalDb,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: _resetToDefaults,
              child: Text(t.reset),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () {
                widget.onSave(_sources);
                Navigator.pop(context);
              },
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }

  // ── 统一来源列表 ───────────────────────────────────────────────────────
  Widget _buildSourceList(HibikiDesignTokens tokens) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      // 关掉桌面端自动注入的 ☰ 拖拽手柄（会盖住行尾按钮）；改整行长按拖拽，
      // 全平台统一。上下箭头按钮是无障碍/手柄重排路径。
      buildDefaultDragHandles: false,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _sources.length,
      onReorder: (int oldIndex, int newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final AudioSourceConfig item = _sources.removeAt(oldIndex);
          _sources.insert(newIndex, item);
        });
      },
      itemBuilder: (BuildContext context, int index) =>
          _buildSourceRow(tokens, index),
    );
  }

  Widget _buildSourceRow(HibikiDesignTokens tokens, int index) {
    final AudioSourceConfig source = _sources[index];
    final bool isHibiki = source.kind == AudioSourceKind.hibikiRemote;
    final bool isLocal = source.kind == AudioSourceKind.localAudio;
    final String title =
        isHibiki ? t.audio_source_hibiki_interconnect : source.displayLabel;
    final String subtitle = isHibiki
        ? t.remote_audio_source
        : (isLocal ? (source.path ?? '') : (source.url ?? ''));
    final String keyId = isLocal
        ? 'audio_local_${source.path ?? index}'
        : 'audio_remote_${source.kind.wireName}_${source.url ?? index}';
    return ReorderableDelayedDragStartListener(
      key: ValueKey<String>(keyId),
      index: index,
      child: AdaptiveSettingsRow(
        title: title,
        subtitle: subtitle,
        icon: isLocal ? Icons.audiotrack_outlined : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Switch.adaptive(
              value: source.enabled,
              onChanged: (bool enabled) => setState(() {
                _sources[index] = source.copyWith(enabled: enabled);
              }),
            ),
            HibikiIconButton(
              icon: Icons.keyboard_arrow_up,
              size: 18,
              tooltip: t.move_up,
              enabled: index > 0,
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () => setState(() {
                final AudioSourceConfig item = _sources.removeAt(index);
                _sources.insert(index - 1, item);
              }),
            ),
            HibikiIconButton(
              icon: Icons.keyboard_arrow_down,
              size: 18,
              tooltip: t.move_down,
              enabled: index < _sources.length - 1,
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () => setState(() {
                final AudioSourceConfig item = _sources.removeAt(index);
                _sources.insert(index + 1, item);
              }),
            ),
            if (isLocal &&
                widget.onEditLocalSources != null &&
                (source.path?.isNotEmpty ?? false))
              HibikiIconButton(
                icon: Icons.tune,
                size: 18,
                tooltip: t.local_audio_edit_sources,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => widget.onEditLocalSources!(source.path!),
              ),
            HibikiIconButton(
              icon: Icons.delete_outline,
              size: 18,
              tooltip: t.dialog_delete,
              enabled: !isHibiki,
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () => setState(() => _sources.removeAt(index)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUrlField(HibikiDesignTokens tokens) {
    final bool showError = _controller.text.trim().isNotEmpty && !_urlValid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdaptiveSettingsTextField(
          controller: _controller,
          hintText: 'https://...{term}...{reading}',
          onChanged: (String value) => setState(
            () => _urlValid = AudioSourcesDialog.isValidRemoteUrl(value),
          ),
          onSubmitted: (_) => _addRemoteUrl(),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!_sources.any((AudioSourceConfig s) =>
                  s.kind == AudioSourceKind.hibikiRemote))
                HibikiIconButton(
                  icon: Icons.hub_outlined,
                  tooltip: t.audio_source_hibiki_interconnect,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: () => setState(() => _sources.insert(
                        0,
                        AudioSourceConfig.hibikiRemote(),
                      )),
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
        if (showError)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
            child: Text(
              t.audio_source_url_invalid,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  // ── actions ──────────────────────────────────────────────────────────────
  void _addRemoteUrl() {
    final String text = _controller.text.trim();
    if (!AudioSourcesDialog.isValidRemoteUrl(text)) {
      _showSnack(t.audio_source_url_invalid);
      return;
    }
    setState(() {
      _sources.insert(0, AudioSourceConfig.remoteAudio(url: text));
      _controller.clear();
      _urlValid = false;
    });
    _showSnack(t.audio_source_added);
  }

  Future<void> _addLocalDb() async {
    setState(() => _importing = true);
    try {
      final AudioSourceConfig? added = await widget.onPickLocalDb!();
      if (!mounted) return;
      if (added != null) {
        setState(() => _sources.insert(0, added));
        _showSnack(t.local_audio_imported);
      }
      // added == null 表示用户取消选择，不弹反馈。
    } catch (_) {
      if (mounted) _showSnack(t.local_audio_import_failed);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _resetToDefaults() {
    setState(() {
      final bool hadHibiki = _sources
          .any((AudioSourceConfig s) => s.kind == AudioSourceKind.hibikiRemote);
      final List<AudioSourceConfig> locals = _sources
          .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
          .toList();
      _sources = <AudioSourceConfig>[
        if (hadHibiki) AudioSourceConfig.hibikiRemote(),
        ...AudioSourceConfig.fromLegacyUrls(AppModel.defaultAudioSources),
        ...locals,
      ];
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}
```

- [ ] **Step 4: 去掉 settings_schema 里的 master 两参数**

在 `hibiki/lib/src/settings/settings_schema.dart` 行 811-817，删掉 `localAudioEnabled:` 与 `onToggleLocalAudio:` 两行，改为：

```dart
                (_) => AudioSourcesDialog(
                  sources: List<AudioSourceConfig>.from(
                    appModel.audioSourceConfigs,
                  ),
                  onSave: appModel.setAudioSourceConfigs,
                  onPickLocalDb: () async {
```

（即在 `onSave: appModel.setAudioSourceConfigs,` 与 `onPickLocalDb:` 之间，原来的两行 `localAudioEnabled: appModel.localAudioEnabled,` 和 `onToggleLocalAudio: appModel.setLocalAudioEnabled,` 删除；其余 `onPickLocalDb` / `onEditLocalSources` 块不动。）

- [ ] **Step 5: 改 local_audio_reorder_test 去掉 master 入参**

把 `hibiki/test/pages/local_audio_reorder_test.dart` 行 20-25 的 `AudioSourcesDialog(...)` 改为去掉 `localAudioEnabled` / `onToggleLocalAudio`：

```dart
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: twoLocal,
      onSave: (_) {},
    )));
```

- [ ] **Step 6: 跑对话框相关测试，确认通过**

Run: `cd hibiki && flutter test test/pages/audio_sources_dialog_page_test.dart test/pages/local_audio_reorder_test.dart --no-pub`
Expected: PASS（全部用例绿）。

- [ ] **Step 7: 提交**

```bash
cd "D:/APP/vs_claude_code/hibiki"
git add hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart hibiki/lib/src/settings/settings_schema.dart hibiki/test/pages/audio_sources_dialog_page_test.dart hibiki/test/pages/local_audio_reorder_test.dart docs/specs/2026-06-04-merge-audio-sources-design.md docs/specs/2026-06-04-merge-audio-sources-plan.md
git commit -m "feat(audio): merge audio sources into one list, insert new at top"
```

---

## Task 2: 删模型层 master gate 与 plumbing

**Files:**
- Modify: `hibiki/lib/src/models/app_model.dart`（`enabledAudioSourceConfigs` / legacy fallback / `setAudioSourceConfigs` 再 gate / getter / setter / toggle / 2807 守卫）
- Modify: `hibiki/lib/src/models/local_audio_manager.dart`（getter / setter / toggle / `bindForNativeHandler` 守卫）
- Modify: `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart`（行 101 / 111 守卫）
- Modify: `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`（行 200 / 210 守卫）
- Modify: `hibiki/lib/src/creator/enhancements/local_audio_enhancement.dart`（行 60 守卫）
- Test: `hibiki/test/models/app_model_audio_sources_test.dart`（改写两个 master 用例 + 新增 per-db gate 用例）

- [ ] **Step 1: 改写模型测试为「per-db enabled 唯一 gate」契约**

把 `hibiki/test/models/app_model_audio_sources_test.dart` 的第二、第三个 test（行 97-125，`does NOT auto-toggle localAudioEnabled` 与 `local db enabled survives ... while master is OFF`）整体替换为下面两个用例；第一个 test（`deletes files of removed local audio dbs`，行 76-95）保持不变：

```dart
  test('local db enabled survives a setAudioSourceConfigs round-trip',
      () async {
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    // persist the db as enabled
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
    ]);
    // open then close the dialog: read the projection and save it back
    final List<AudioSourceConfig> projected = appModel.audioSourceConfigs;
    await appModel.setAudioSourceConfigs(projected);
    // the db's real per-db enabled must be preserved across the round-trip
    expect(appModel.localAudioDbs.single.enabled, isTrue);
  });

  test('enabledAudioSourceConfigs gates local audio by per-db enabled only',
      () async {
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    final LocalAudioDbEntry b =
        await appModel.importLocalAudioDbFile(srcB.path, displayName: 'B');
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
      AudioSourceConfig.localAudio(label: 'B', path: b.path, enabled: false),
    ]);
    final List<AudioSourceConfig> enabled = appModel.enabledAudioSourceConfigs;
    final Iterable<AudioSourceConfig> localEnabled = enabled
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio);
    expect(localEnabled.length, 1);
    expect(localEnabled.single.path, a.path);
  });
```

- [ ] **Step 2: 跑模型测试确认编译失败**

Run: `cd hibiki && flutter test test/models/app_model_audio_sources_test.dart --no-pub`
Expected: FAIL —— 旧用例已删除引用 `setLocalAudioEnabled`，但此时该方法仍在；新用例尚未配套（gate 仍含 master）。本步关键是确认改后的测试文件能编译并锁定新契约。（若仅因 master 仍存在而新用例恰好通过，仍继续 Step 3 删 gate。）

- [ ] **Step 3: 删 app_model.dart 的 master gate 与 plumbing**

3a. `enabledAudioSourceConfigs`（行 2537-2544）替换为：

```dart
  List<AudioSourceConfig> get enabledAudioSourceConfigs => audioSourceConfigs
      .where((AudioSourceConfig source) => source.enabled)
      .toList(growable: false);
```

3b. legacy fallback（行 2566）：把

```dart
    if (!localAudioEnabled) return sources;
```

替换为：

```dart
    // 删了 master 总开关后，本地音频是否参与 legacy 回退路径，
    // 由「是否存在已启用的本地库」决定（与 typed-config 路径语义一致）。
    if (!localAudioDbs.any((LocalAudioDbEntry e) => e.enabled)) return sources;
```

3c. `setAudioSourceConfigs`（行 2602-2603）：删掉这两行（注释 + 调用）：

```dart
    // 以当前显式总开关值重新 gate native（不再从 entry 自动派生）。
    await _localAudioManager.setLocalAudioEnabled(localAudioEnabled);
```

3d. 删 `setLocalAudioEnabled` 委托（行 2637-2640，含其上方 doc 注释）：

```dart
  /// 显式设置本地音频总开关（dialog 直接调用）。true → 推 enabled 路径给 native，
  /// false → 推空列表。
  Future<void> setLocalAudioEnabled(bool value) =>
      _localAudioManager.setLocalAudioEnabled(value);
```

3e. 删 `localAudioEnabled` getter（行 2664）与 `toggleLocalAudio`（行 2666-2667）：

```dart
  bool get localAudioEnabled => _localAudioManager.localAudioEnabled;

  void toggleLocalAudio() =>
      _localAudioManager.toggleLocalAudio(notifyListeners);
```

3f. `_AppModelRemoteLookupService.lookupAudio`（行 2807）：删掉这行守卫：

```dart
    if (!_appModel.localAudioEnabled) return null;
```

- [ ] **Step 4: 删 local_audio_manager.dart 的 master plumbing**

4a. 删 `localAudioEnabled` getter（行 70-71）：

```dart
  bool get localAudioEnabled =>
      _prefsRepo.getPref('local_audio_enabled', defaultValue: false);
```

4b. 删 `toggleLocalAudio`（行 207-218）整个方法。

4c. 删 `setLocalAudioEnabled`（行 220-229）整个方法。

4d. `bindForNativeHandler`（行 231-232）：删掉首行守卫，使方法体从 `final dbs = entries;` 开始：

```dart
  Future<void> bindForNativeHandler({bool clearMissingPath = false}) async {
    final dbs = entries;
    if (dbs.isEmpty) return;
```

（即移除 `if (!localAudioEnabled) return;` 一行；方法其余部分按 per-DB `entry.enabled` 过滤，保持不变。）

- [ ] **Step 5: 删末端 query 守卫（mixin / popup / enhancement）**

5a. `dictionary_page_mixin.dart`：删行 101 与行 111 各一行 `if (!mixinAppModel.localAudioEnabled) return null;`（两个 `queryLocalAudio` 回调首行）。

5b. `dictionary_popup_webview.dart`：删行 200 与行 210 各一行 `if (!appModel.localAudioEnabled) return null;`。

5c. `local_audio_enhancement.dart`：把行 60-80 的 `if (appModel.localAudioEnabled) { ... }` 去掉 master 包裹，保留内部 query 逻辑。替换行 60-80 为：

```dart
    // 1. 本地音频库（Yomitan SQLite）：删了 master 总开关后无条件先查；
    //    native 只持有已启用的库，无启用库时返回空，行为与之前一致。
    try {
      final info = await TtsChannel.instance
          .queryLocalAudio(term, reading)
          .timeout(const Duration(milliseconds: 500));
      if (info != null) {
        final int dbIndex = (info['dbIndex'] as int?) ?? 0;
        final path = await TtsChannel.instance.extractLocalAudio(
          info['file']! as String,
          info['source']! as String,
          dbIndex: dbIndex,
        );
        if (path != null && path.isNotEmpty) {
          final file = File(path);
          if (file.existsSync()) return file;
        }
      }
    } on TimeoutException {
      // Fall through
    }
```

- [ ] **Step 6: 跑全量测试 + 静态分析 + 格式化**

```bash
cd "D:/APP/vs_claude_code/hibiki/hibiki"
dart format .
flutter analyze
flutter test --no-pub
```

Expected:
- `dart format` 无意外大改（仅本轮文件）。
- `flutter analyze`：无 error（无 `localAudioEnabled`/`setLocalAudioEnabled`/`toggleLocalAudio` 未定义引用残留；`local_audio_enhancement._generateAudio` 的 `appModel` 参数即使未使用也不报 error）。
- `flutter test`：全绿。

若 analyze 报「`appModel` 参数未使用」之类 info/warning（非 error），保留参数签名不动（其他增强复用同一签名模式），仅当为 error 时才处理。

- [ ] **Step 7: 提交**

```bash
cd "D:/APP/vs_claude_code/hibiki"
git add hibiki/lib/src/models/app_model.dart hibiki/lib/src/models/local_audio_manager.dart hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart hibiki/lib/src/creator/enhancements/local_audio_enhancement.dart hibiki/test/models/app_model_audio_sources_test.dart
git commit -m "refactor(audio): drop local-audio master gate, per-source enabled only"
```

---

## Task 3: 代码审查 + 设备复测标注

- [ ] **Step 1: 代码审查**

调用 `superpowers:requesting-code-review`（spawn code-reviewer subagent，必须 `model: "opus"`），审查两个提交：实现是否符合设计、边界（hibiki 不可删/不可改名、tune 仅 local、插首位、native 推送只含 enabled 库）、向后兼容、有无新引入的特例分支。按反馈修复后重审。

- [ ] **Step 2: 设备复测标注**

代码 + 单测通过后，按 `hibiki/CLAUDE.md`「验证」规则，阅读器/查词/播放路径需真机或用户指定设备复测原始路径：合并列表交互（混排重排/启停/删除/tune）、本地音频播放、新增插首位生效。留证据；未做前在回复中标注「待设备复测」，不声称「修好了」。

---

## Self-Review（已核对）

- **Spec coverage**：① 删 master = Task 2（gate + plumbing 全删，含 4 处末端守卫 + bind + native 再 gate）；② 合并单列表 = Task 1 Step 3（单 `ReorderableListView` + `_buildSourceRow` 按 kind 渲染）；③ 插首位 = Task 1 Step 3 `_addRemoteUrl`/`_addLocalDb` 的 `insert(0, ...)` + Step 1 守卫测试。测试覆盖 = 各 Task 的测试 step。i18n 不增删（设计 §6）。
- **Placeholder scan**：无 TBD/TODO；每个改码 step 含完整代码或精确行替换。
- **Type consistency**：`_sources`（统一列表）、`_buildSourceRow`、`_resetToDefaults`、`AudioSourceConfig.{hibikiRemote,localAudio,remoteAudio,fromLegacyUrls}`、`AudioSourceKind.{hibikiRemote,localAudio,remoteAudio}`、`enabledAudioSourceConfigs`、`localAudioDbs`、`LocalAudioDbEntry.enabled` 均与现有代码签名一致。

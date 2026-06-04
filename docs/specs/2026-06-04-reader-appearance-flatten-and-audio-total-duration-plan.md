# 阅读器「外观」扁平化 + 音频总长度修复 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除阅读器快捷设置弹窗里重复的「外观」子页入口，把主题/字号/行高/段落缩进/视图模式/编辑书籍CSS 直接平铺到弹窗主页；并修复音频进度行「总长度」恒为 0 的问题，改为显示全书所有音频文件时长之和。

**Architecture:**
1. UI 扁平化：`ReaderQuickSettingsSheet` 主页当前的 `_buildQuickControlsSection`（字号/行高/视图模式，是子页的子集）与「外观」导航子页重复。删除子页入口与路由，把子页内容（主题选择器 + schema 投影的 appearance 分组 + 编辑书籍CSS）原样搬到主页，消除两层重复。
2. 音频总长度：`AudiobookPlayerController.duration` 取 `_player.duration`，但 `load()` 用 `preload:false`，播放前 just_audio 不知道时长 → 返回 0；多文件时也只是当前文件而非「所有文件之和」。新增**显示用** getter `totalDuration` / `globalPosition`，从已在内存的对齐 cue（`_allBookCues` 的 per-file `endMs`）推算全书时长与累计位置（load-free，播放前即可用），进度行改用它们。不改 `duration`/`position`/`seek*`（内部 cue 逻辑与锁屏 seek 依赖 per-file 坐标，改了会破坏跳句和锁屏拖动）。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0；Riverpod；just_audio；项目 schema-projected 设置体系（`buildReaderGroupDestination` / `ReaderGroup`）。

---

## File Structure

- `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart` — 新增 `_fileDurationsMs` 字段、`_rebuildFileDurations()`、`totalDuration` / `globalPosition` getter；`setAllBookCues` 末尾重建 per-file 时长。
- `packages/hibiki_audio/test/audiobook/audiobook_total_duration_test.dart`（新建）— 单测 `totalDuration` 全书求和 + 无 cue 回退。
- `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart` — 主页改用平铺的「外观」区；删 `_buildQuickControlsSection` / `_settings` / `_loadSettings`；删 `'appearance'` 导航行与子页 case；进度行改用 `globalPosition`/`totalDuration`；`_formatDuration` 支持小时。
- `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart` — 更新静态断言（不再有 `page:'appearance'`、不再有 `_buildQuickControlsSection`）。
- `hibiki/test/media/audiobook/audiobook_play_bar_theme_chip_test.dart` — 更新 widget 断言（主题/字号等现在主页直接可见，无需点开子页）。

---

## Task 1: 控制器新增全书时长/位置 getter（TDD）

**Files:**
- Modify: `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`（字段区 ~line 59、`setAllBookCues` line 396-404、getter 区 line 236-239）
- Test: `packages/hibiki_audio/test/audiobook/audiobook_total_duration_test.dart`（新建）

- [ ] **Step 1: 写失败测试**

新建 `packages/hibiki_audio/test/audiobook/audiobook_total_duration_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue({
  required int fileIndex,
  required int startMs,
  required int endMs,
}) {
  return AudioCue()
    ..bookUid = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '#s'
    ..text = 't'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = fileIndex;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('totalDuration sums the max endMs of every audio file', () {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    // 文件0 末句 endMs=12000；文件1 末句 endMs=8000 → 全书=20000ms。
    controller.setAllBookCues(<AudioCue>[
      _cue(fileIndex: 0, startMs: 0, endMs: 5000),
      _cue(fileIndex: 0, startMs: 5000, endMs: 12000),
      _cue(fileIndex: 1, startMs: 0, endMs: 8000),
    ]);

    expect(controller.totalDuration, const Duration(milliseconds: 20000));
  });

  test('totalDuration falls back to zero when no cues and no player duration',
      () {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    expect(controller.totalDuration, Duration.zero);
  });

  test('globalPosition is zero before any file is loaded', () {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    controller.setAllBookCues(<AudioCue>[
      _cue(fileIndex: 0, startMs: 0, endMs: 5000),
    ]);

    expect(controller.globalPosition, Duration.zero);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `D:\APP\vs_claude_code\hibiki\packages\hibiki_audio`）: `flutter test test/audiobook/audiobook_total_duration_test.dart`
Expected: 编译失败 — `totalDuration` / `globalPosition` getter 不存在。

- [ ] **Step 3: 加字段 + 重建逻辑**

在 `audiobook_controller.dart` 全书 cue 字段附近（line 59 `List<AudioCue> _allBookCues = [];` 之后）新增：

```dart
  /// 每个音频文件的时长（毫秒），下标 = audioFileIndex。由对齐 cue 的
  /// per-file 最大 endMs 推算（load-free，播放前即可用），供 [totalDuration]
  /// / [globalPosition] 显示用。空 = 无对齐数据，回退到 just_audio。
  List<int> _fileDurationsMs = const <int>[];
```

把 `setAllBookCues`（line 396-404）改为在末尾重建：

```dart
  void setAllBookCues(List<AudioCue> cues) {
    _allBookCues = List<AudioCue>.from(cues);
    final Map<int, int> idMap = <int, int>{};
    for (int i = 0; i < _allBookCues.length; i++) {
      final int? id = _allBookCues[i].id;
      if (id != null) idMap[id] = i;
    }
    _allBookCueIdToIndex = idMap;
    _rebuildFileDurations();
  }

  /// 从全书 cue 推算每个文件时长 = 该文件内 cue 的最大 endMs。
  void _rebuildFileDurations() {
    int maxIdx = -1;
    for (final AudioCue cue in _allBookCues) {
      if (cue.audioFileIndex > maxIdx) maxIdx = cue.audioFileIndex;
    }
    if (maxIdx < 0) {
      _fileDurationsMs = const <int>[];
      return;
    }
    final List<int> durations = List<int>.filled(maxIdx + 1, 0);
    for (final AudioCue cue in _allBookCues) {
      final int idx = cue.audioFileIndex;
      if (idx < 0) continue;
      if (cue.endMs > durations[idx]) durations[idx] = cue.endMs;
    }
    _fileDurationsMs = durations;
  }
```

- [ ] **Step 4: 加 getter**

在 `duration` getter（line 239）之后新增：

```dart
  /// 全书总时长（所有音频文件时长之和）。优先用对齐 cue 推算（播放前即可用，
  /// 无需解码音频）；无 cue 数据时回退到 just_audio 当前文件时长。
  ///
  /// 与 [duration]（per-file，供 seek 钳制）不同，这是显示用的「总长度」。
  Duration get totalDuration {
    if (_fileDurationsMs.isNotEmpty) {
      int sum = 0;
      for (final int ms in _fileDurationsMs) {
        sum += ms;
      }
      if (sum > 0) return Duration(milliseconds: sum);
    }
    return _player.duration ?? Duration.zero;
  }

  /// 全书累计播放位置 = 当前文件之前所有文件时长之和 + 当前文件内位置。
  /// 与 [totalDuration] 配对供进度条显示；无 cue 数据时退化为当前文件位置。
  Duration get globalPosition {
    final int idx = _player.currentIndex ?? 0;
    int base = 0;
    for (int i = 0; i < idx && i < _fileDurationsMs.length; i++) {
      base += _fileDurationsMs[i];
    }
    return Duration(milliseconds: base + _player.position.inMilliseconds);
  }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `flutter test test/audiobook/audiobook_total_duration_test.dart`
Expected: PASS（3 个测试全绿）。

- [ ] **Step 6: 提交**

```bash
git add packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart packages/hibiki_audio/test/audiobook/audiobook_total_duration_test.dart
git commit -m "feat(audiobook): add whole-book totalDuration/globalPosition from alignment cues"
```

---

## Task 2: 进度行改用全书时长 + 支持小时格式

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（`_buildAudioProgressLine` line 666-702、`_formatDuration` line 704-711）

- [ ] **Step 1: 进度行改用全书 getter**

把 `_buildAudioProgressLine`（line 672-677 区）的：

```dart
        final Duration pos = ctrl.position;
        final Duration dur = ctrl.duration;
```

改为：

```dart
        final Duration pos = ctrl.globalPosition;
        final Duration dur = ctrl.totalDuration;
```

（`fraction`、`Text('${_formatDuration(pos)} / ${_formatDuration(dur)}')`、`LinearProgressIndicator(value: fraction)` 均沿用，现两端都是全书坐标，进度条语义一致。）

- [ ] **Step 2: `_formatDuration` 支持小时**

把 `_formatDuration`（line 704-711）替换为：

```dart
  static String _formatDuration(Duration d) {
    final int totalSeconds = d.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final String mm = minutes.toString().padLeft(2, '0');
      return '$hours:$mm:$ss';
    }
    final String mm = minutes.toString().padLeft(2, '0');
    return '$mm:$ss';
  }
```

- [ ] **Step 3: 分析 + 格式化**

Run（在 `hibiki/`）: `flutter analyze lib/src/media/audiobook/reader_quick_settings_sheet.dart`
Expected: No issues（此步骤可能仍有 Task 3 引入前的旧引用，若仅此 step 改动则应干净）。
Run: `dart format lib/src/media/audiobook/reader_quick_settings_sheet.dart`

> 注：本 Task 与 Task 3 同改一个文件，建议连续执行后一次性 analyze/format/commit（见 Task 3 Step 7）。若分开提交，本 Task 单独 commit：

```bash
git add hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart
git commit -m "fix(audiobook): show whole-book total length in reader progress line"
```

---

## Task 3: 「外观」子页扁平化到弹窗主页

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
  - `_buildMainPage` line 298-348（导航行去掉 appearance、主区换平铺外观）
  - `_buildQuickControlsSection` line 350-414（删除）
  - `_buildSubPage` line 416-466（删除 `'appearance'` case）
  - `_buildAppearanceSubPage` line 543-585（改造为带 header 的主页 inline 区）
  - `_settings` line 125 / `_loadSettings` line 162-180 / initState 调用 line 152 / refresh 回调 line 485、523（清理）

- [ ] **Step 1: 主页导航行移除 appearance**

在 `_buildMainPage` 的 `navigationRows`（line 301-333）删除最前面的 appearance 项：

```dart
    final List<Widget> navigationRows = [
      _categoryTile(
        icon: Icons.auto_stories_outlined,
        label: t.section_layout,
        page: 'layout',
      ),
      _categoryTile(
        icon: Icons.touch_app_outlined,
        label: t.settings_destination_reading_controls,
        page: 'behavior',
      ),
      _categoryTile(
        icon: Icons.manage_search_outlined,
        label: t.settings_destination_lookup,
        page: 'lookup',
      ),
      _categoryTile(
        icon: Icons.menu_book_outlined,
        label: t.section_navigation,
        page: 'location',
      ),
      if (widget.controller != null)
        _categoryTile(
          icon: Icons.headphones_outlined,
          label: t.section_audiobook,
          page: 'audiobook',
        ),
    ];
```

- [ ] **Step 2: 主页主区换成平铺外观**

把 `_buildMainPage` 的 children（line 335-347）里 `_buildQuickControlsSection(theme)` 改为 `_buildAppearanceInline(theme)`：

```dart
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildProgressSection(theme),
        SizedBox(height: sectionGap),
        _buildAppearanceInline(theme),
        SizedBox(height: sectionGap),
        AdaptiveSettingsSection(children: navigationRows),
        SizedBox(height: sectionGap),
        _buildActionRow(context),
      ],
    );
```

- [ ] **Step 3: 删除 `_buildQuickControlsSection`，改造外观为 inline**

删除整个 `_buildQuickControlsSection`（line 350-414）。

把 `_buildAppearanceSubPage`（line 543-585）改名为 `_buildAppearanceInline`，并在顶部加 `SettingsSectionHeader(t.display_settings)`：

```dart
  /// 外观区（原「外观」子页内容，现平铺到弹窗主页）：主题选择器 + schema
  /// 投影的 appearance 分组（字号/行高/段落缩进/视图模式）+ 每书「编辑书籍
  /// CSS」导航行（仅在有 extractDir 时显示）。
  Widget _buildAppearanceInline(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget projected = _buildReaderGroupContent(
      ReaderGroup.appearance,
      t.settings_destination_appearance,
    );
    final Widget themeSelector = _buildThemeSelector();
    final List<Widget> children = <Widget>[
      SettingsSectionHeader(
        t.display_settings,
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      ),
      themeSelector,
      projected,
    ];
    if (widget.extractDir != null) {
      children.add(
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsNavigationRow(
              title: t.book_css_editor_edit_css,
              icon: Icons.code_outlined,
              onTap: () async {
                await Navigator.push(
                  context,
                  adaptivePageRoute(
                    builder: (_) =>
                        BookCssEditorPage(extractDir: widget.extractDir!),
                  ),
                );
                await _reloadLayoutLive();
              },
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
```

（`theme` 形参保持签名一致即可，未直接使用不报错——如 analyze 提示未使用，去掉该形参并把调用改成 `_buildAppearanceInline()`。）

- [ ] **Step 4: `_buildSubPage` 删除 appearance case**

在 `_buildSubPage`（line 421-453 的 switch）删除：

```dart
      case 'appearance':
        title = t.settings_destination_appearance;
        content = _buildAppearanceSubPage();
```

其余 case（layout/behavior/lookup/location/audiobook）不动。

- [ ] **Step 5: 清理 `_settings` / `_loadSettings`**

`_settings` 现仅被已删除的 `_buildQuickControlsSection` 读取，连带清理：

- 删字段 `TtuReaderSettings? _settings;`（line 125）。
- 删 `_loadSettings()` 方法（line 162-180）。
- `initState`（line 149-153）删掉 `_loadSettings();` 调用，仅留 `super.initState();`。
- `_settingsContext()` 的 refresh（line 483-488）改为：

```dart
      refresh: () {
        if (!mounted) return;
        setState(() {});
      },
```

- `_buildThemeSelector` 的 refresh（line 520-525）删掉 `_loadSettings();`：

```dart
      refresh: () {
        if (!mounted) return;
        unawaited(_syncThemeSelection());
        setState(() {});
      },
```

> 说明：schema 投影的 appearance 项实时从 `ReaderHibikiSource.instance` 读写，不依赖 `_settings` 内存镜像；删除后 `setState` 重读即生效。

- [ ] **Step 6: 分析 + 格式化**

Run（在 `hibiki/`）: `flutter analyze lib/src/media/audiobook/reader_quick_settings_sheet.dart`
Expected: No issues found. 若报 `_loadSettings`/`_settings`/未使用 import（`TtuReaderSettings` 仍由 `getReaderSettings` 用？确认 `AudiobookBridge.getReaderSettings` 是否还被调用）等，逐一清理。
Run: `dart format lib/src/media/audiobook/reader_quick_settings_sheet.dart`

- [ ] **Step 7: 提交（含 Task 2 同文件改动）**

```bash
git add hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart
git commit -m "refactor(reader): flatten appearance sub-page into quick settings main page"
```

---

## Task 4: 更新静态测试 `reader_quick_settings_sheet_static_test.dart`

**Files:**
- Modify: `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart`（line 6-46）

- [ ] **Step 1: 改第一个测试（层级断言）**

`reader quick settings owns the in-book settings hierarchy`（line 6-18）：删掉 `expect(source, contains("page: 'appearance'"));`（line 12），其余 page 断言保留。

- [ ] **Step 2: 改第二个测试（主页内容断言）**

把 `reader quick settings home exposes only the four quick controls`（line 20-46）整体替换为「主页平铺外观」断言：

```dart
  test('reader quick settings home inlines the appearance controls', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String mainSource = _between(
      source,
      '  Widget _buildMainPage(BuildContext context, ThemeData theme)',
      '  Widget _buildSubPage(BuildContext context, ThemeData theme)',
    );

    // 外观已平铺到主页，不再有独立的「外观」导航子页入口。
    expect(mainSource, contains('_buildAppearanceInline('));
    expect(source, isNot(contains("page: 'appearance'")));
    expect(source, isNot(contains('Widget _buildQuickControlsSection(')));

    // 平铺区包含主题选择器 + schema 投影的 appearance 分组 + 编辑书籍CSS。
    final String inlineSource = _between(
      source,
      '  Widget _buildAppearanceInline(',
      '  Widget _buildLocationSection(ThemeData theme)',
    );
    expect(inlineSource, contains('_buildThemeSelector()'));
    expect(inlineSource, contains('ReaderGroup.appearance'));
    expect(inlineSource, contains('book_css_editor_edit_css'));
  });
```

> 注：`_buildAppearanceInline` 在源码中的下一个方法须确认（本计划假设其后是 `_buildLocationSection`；若排版不同，按实际下一个方法名调整 `_between` 的终止标记）。

- [ ] **Step 3: 运行该测试文件**

Run（在 `hibiki/`）: `flutter test test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
Expected: PASS（全部 9 个 test 绿）。

- [ ] **Step 4: 提交**

```bash
git add hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart
git commit -m "test(reader): update static guards for flattened appearance section"
```

---

## Task 5: 更新 widget 测试 `audiobook_play_bar_theme_chip_test.dart`

**Files:**
- Modify: `hibiki/test/media/audiobook/audiobook_play_bar_theme_chip_test.dart`（line 65-140 的 `in-book settings sheet uses adaptive settings rows`）

- [ ] **Step 1: 改主页断言（主题/字号现在主页直接可见）**

把 line 92-116 区替换为：主页不再有 `settings_destination_appearance` 导航行；主题 + 字号/行高/段落缩进/视图模式直接显示在主页：

```dart
    expect(find.byType(AdaptiveSettingsNavigationRow), findsWidgets);
    // 「外观」子页入口已删除——内容平铺到主页。
    expect(find.text(t.settings_destination_appearance), findsNothing);
    expect(find.text(t.section_layout), findsOneWidget);
    expect(find.text(t.settings_destination_reading_controls), findsOneWidget);
    expect(find.text(t.settings_destination_lookup), findsOneWidget);
    expect(find.text(t.section_navigation), findsOneWidget);
    expect(find.text(t.display_settings), findsOneWidget);

    // 主页直接平铺外观：主题选择器 + 字号/行高/视图模式（schema 投影）。
    expect(find.text(t.ttu_theme), findsOneWidget);
    expect(find.byType(HibikiSchemeSwatch), findsWidgets);
    expect(find.text(t.ttu_font_size), findsOneWidget);
    expect(find.text(t.ttu_line_height), findsOneWidget);
    expect(find.text(t.ttu_view_mode_label), findsOneWidget);
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
```

删除 line 107-118 区「点开 appearance 子页再断言、再点 back」那段（已无子页）：

```dart
    // 删除原有：
    //   await tester.tap(find.text(t.settings_destination_appearance));
    //   await tester.pumpAndSettle();
    //   expect(find.text(t.ttu_theme), findsOneWidget);
    //   ... 以及对应的 arrow_back 返回。
```

- [ ] **Step 2: 修正后续「lookup / layout」导航断言的前置返回**

原 line 117-118 的 `tester.tap(find.byIcon(Icons.arrow_back))`（从 appearance 子页返回）已无意义——此时仍在主页。删掉该返回，直接 `ensureVisible` + tap lookup：

```dart
    await tester.ensureVisible(find.text(t.settings_destination_lookup));
    await tester.tap(find.text(t.settings_destination_lookup));
    await tester.pumpAndSettle();

    expect(find.text(t.auto_read_on_lookup), findsOneWidget);
    expect(find.text(t.pause_on_lookup), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(t.section_layout));
    await tester.tap(find.text(t.section_layout));
    await tester.pumpAndSettle();

    expect(
      find.byType(AdaptiveSettingsSegmentedRow<Object>),
      findsWidgets,
    );
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
```

- [ ] **Step 3: 运行该测试文件**

Run（在 `hibiki/`）: `flutter test test/media/audiobook/audiobook_play_bar_theme_chip_test.dart`
Expected: PASS。若 layout 子页的段落缩进/视图模式因已搬到主页导致 layout 子页 segmented 行不足，按实际 layout 分组渲染结果调整断言（layout 分组本身含 writingMode/margins/columns 等，仍有 segmented + stepper）。

- [ ] **Step 4: 提交**

```bash
git add hibiki/test/media/audiobook/audiobook_play_bar_theme_chip_test.dart
git commit -m "test(reader): assert flattened appearance controls on quick-settings main page"
```

---

## Task 6: 全量验证

- [ ] **Step 1: hibiki_audio 包测试**

Run（在 `packages/hibiki_audio`）: `flutter test`
Expected: 全绿（含新增 total duration 测试）。

- [ ] **Step 2: 主 app 全量分析 + 测试**

Run（在 `hibiki/`）: `dart format --set-exit-if-changed lib test`（如有改动文件未格式化，先 `dart format`）
Run: `flutter analyze`
Expected: No issues found.
Run: `flutter test`
Expected: 全绿。重点关注：
- `test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
- `test/media/audiobook/audiobook_play_bar_theme_chip_test.dart`
- `test/focus/*`（若有断言「外观」导航行的焦点用例，按需更新；`focus_pane_locality_test` / `focus_left_escapes_pane_test` 注释提到的是**全局设置**外观详情，非本弹窗，应不受影响——确认即可）

- [ ] **Step 3: 设备复测（声明修好前必做）**

按 `docs/agent/integration-testing.md` 在真实模拟器/用户指定设备打开一本带有声书的 EPUB：
1. 打开阅读器快捷设置弹窗 → 主页直接看到「主题 + 字号/行高/段落缩进/视图模式 + 编辑书籍CSS」，无「外观」二级入口；改任一项实时生效。
2. 进度区「音频总长度」显示非 0（= 全书总时长，多文件为各文件之和；长书显示 h:mm:ss）。
3. 留截图证据。

---

## Self-Review

- **Spec coverage：** ① 删外观子页 + 内容平铺 → Task 3；② 音频总长度=0 修复（全书总时长）→ Task 1+2；测试同步 → Task 4/5；验证 → Task 6。覆盖完整。
- **Type consistency：** 新增 `totalDuration`/`globalPosition`（`Duration` getter）、`_fileDurationsMs`（`List<int>`）、`_rebuildFileDurations()`（`void`）；UI 新方法 `_buildAppearanceInline`（`Widget`，替换 `_buildQuickControlsSection` + `_buildAppearanceSubPage`）。前后引用名一致。
- **Placeholder scan：** 各 step 均含完整代码/命令/期望输出，无 TODO/TBD。
- **风险点：** 不改 `duration`/`position`/`seekMs`，锁屏 seek 与 cue 跳句保持 per-file 坐标不破坏；锁屏媒体通知仍显示 per-file 时长（本次仅修 app 内进度行，符合用户指向）。全书总时长来自对齐 cue（估算，文件尾无 cue 部分会略少），是 load-free 最佳来源。
```

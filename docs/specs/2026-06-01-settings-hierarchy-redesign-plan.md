# 设置层级重构 实现计划（全局 ↔ 书内统一）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把分散在三处（全局 `DisplaySettingsPage` + 书内手写 sheet + schema 子集）的同一批阅读器设置收敛为 schema 单一真相源，并把全局 10 分组重排为 8 分组；书内面板改为 schema 投影，新增音频进度。

**Architecture:** `SettingsItem` 新增正交维度 `ReaderPlacement`（出现在书内哪组、什么顺序）。全局设置渲染全部 item；书内面板用 `collectReaderItems` 过滤出 `reader != null` 的 item 按组渲染，复用现有 `SettingsRenderer.buildDetailContent`。底层 getter/setter（`ReaderHibikiSource` / `AppModel`）与 `preferences` 存储完全不动。

**Tech Stack:** Dart 3.11.4 / Flutter 3.41.6，Riverpod，Slang i18n（17 语言，`tool/i18n_sync.dart`），schema 驱动设置（`lib/src/settings/`）。

**工作区:** worktree `D:\APP\vs_claude_code\hibiki\.claude\worktrees\settings-hierarchy-redesign`，分支 `worktree-settings-hierarchy-redesign`（基于 develop HEAD）。所有命令在 `hibiki/` 子目录执行。

**命令约定:**
- 分析: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze`
- 测试: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test --no-pub <路径>`（`--no-pub` 见 memory，避免 bootstrap）
- 格式化: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`
- 提交只 stage 本任务文件，禁止 `git add -A`（develop 上有并发 agent）。

---

## 文件结构（决策锁定）

| 文件 | 职责 | 本计划改动 |
|------|------|-----------|
| `lib/src/settings/settings_destination.dart` | schema 数据模型 | 加 `ReaderGroup` / `ReaderPlacement`；`SettingsItem` + 5 个子类透传 `reader` 字段；`SettingsDestinationId` 合并 `readingDisplay`+`readingControls`→`reading`、删 `diagnostics` |
| `lib/src/settings/settings_schema.dart` | 分组定义 + 投影 | 10→8 分组；`DisplaySettingsPage` 的 reader 控件变成 schema item 并标 `reader`；为现有 reader 控件项加 `reader` 标记；新增 `collectReaderItems` + `buildReaderGroupDestination`；重写 `buildReaderQuickSettingsDestination` |
| `lib/src/pages/implementations/display_settings_page.dart` | 全局阅读显示页 | reader 控件上移 schema 后，本页改为渲染 `reading` destination 的「显示+布局」子集（薄页），删手写 `setTtu*` |
| `lib/src/media/audiobook/reader_quick_settings_sheet.dart` | 书内底部抽屉 | 4 个手写设置子页改为 schema 投影渲染；`_buildProgressSection` 加音频进度；保留进度/快捷控制/位置/听书播放控制/操作行 |
| `lib/src/pages/implementations/hibiki_settings_page.dart` | 书内设置对话框 | 适配新 `buildReaderQuickSettingsDestination`（签名不变，仅行为变；预计无需改） |
| `lib/i18n/*.i18n.json` | 17 语言文案 | 经 `tool/i18n_sync.dart` 增 `settings_destination_reading` 等新标题 key |
| `test/settings/settings_redesign_static_test.dart` | 结构静态断言 | 改为断言新 8 分组结构 |

---

## Task 0: 确认干净基线

**Files:** 无改动

- [ ] **Step 1: 确认 worktree 在正确分支与 HEAD**

Run（在 `hibiki/` 上层仓库根）:
```bash
git -C "D:/APP/vs_claude_code/hibiki/.claude/worktrees/settings-hierarchy-redesign" rev-parse --abbrev-ref HEAD
```
Expected: `worktree-settings-hierarchy-redesign`

- [ ] **Step 2: 基线分析**

Run（在 worktree 的 `hibiki/` 目录）:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
```
Expected: No issues found（若有既有 warning，记录下来作为基线，后续不得新增）

- [ ] **Step 3: 基线测试（settings 相关）**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test --no-pub test/settings/
```
Expected: All tests passed（这是改造前的绿基线；若已失败，先报告再决定是否继续）

---

## Task 1: schema 模型加 ReaderPlacement（纯增量，不破坏任何现有行为）

**Files:**
- Modify: `lib/src/settings/settings_destination.dart`

- [ ] **Step 1: 加 `ReaderGroup` 枚举与 `ReaderPlacement` 类**

在 `settings_destination.dart` 顶部、`SettingsDestinationId` 枚举之后插入：

```dart
/// 书内快捷面板的分组维度，与全局 [SettingsDestinationId] 正交。
/// 一个设置项可以同时出现在全局某 destination 和书内某 [ReaderGroup]。
enum ReaderGroup { appearance, layout, behavior, audiobook }

/// 描述某个 [SettingsItem] 在书内快捷面板里的放置位置。
/// 为 null 表示该项不出现在书内面板（仅全局可见）。
class ReaderPlacement {
  const ReaderPlacement({required this.group, required this.order});

  final ReaderGroup group;
  final int order;
}
```

- [ ] **Step 2: 给 `SettingsItem` 基类加 `reader` 字段**

把 `sealed class SettingsItem` 的构造器与字段改为：

```dart
sealed class SettingsItem {
  const SettingsItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.visible,
    this.reader,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final SettingsVisibility? visible;

  /// 书内快捷面板放置；null = 仅全局可见。
  final ReaderPlacement? reader;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;
}
```

- [ ] **Step 3: 5 个子类透传 `super.reader`**

为 `SettingsNavigationItem` / `SettingsActionItem` / `SettingsSwitchItem` / `SettingsSegmentedItem<T>` / `SettingsSliderItem` / `SettingsStepperItem` / `SettingsCustomItem` 的每个构造器，在参数列表末尾（其它 `super.visible` 旁）加一行：

```dart
    super.reader,
```

例如 `SettingsSwitchItem`：
```dart
  const SettingsSwitchItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
  });
```

（7 个子类逐一加，`SettingsCustomItem` 同样加 `super.reader`。）

- [ ] **Step 4: 分析**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/settings/settings_destination.dart
```
Expected: No issues found（纯增量字段，默认 null，旧代码不受影响）

- [ ] **Step 5: 提交**

```bash
git add lib/src/settings/settings_destination.dart
git commit -m "feat(settings): add ReaderPlacement metadata to SettingsItem"
```

---

## Task 2: 把 DisplaySettingsPage 的 reader 控件迁成 schema item

**目标:** 让 `_readingDisplayDestination()` 直接包含字号/行高/边距/spread/书写方向/视图/振假名/对齐/kerning/VPAL/prioritize 等正式 schema item（此前它们手写在 `DisplaySettingsPage`），并打上 `reader` 放置。此任务仍保留旧 destination 枚举名，先不改名，确保增量可编译。

**Files:**
- Modify: `lib/src/settings/settings_schema.dart`（重写 `_readingDisplayDestination`）

> 注意：这些项的 setter 在 `DisplaySettingsPage` 里是 `ReaderHibikiSource.instance.setTtu*`；在 schema 里用 `settingsContext.readerSource.setTtu*`（同一对象，`SettingsContext.readerSource` 已存在）。改完后必须调 `notifyReaderSettingsChanged(settingsContext)` 让实时预览刷新（与现有 reading_controls 项一致）。

- [ ] **Step 1: 重写 `_readingDisplayDestination()`，加入显示组 stepper 项**

把 `_readingDisplayDestination()`（当前 settings_schema.dart:200-228）的「typography」section 替换为包含真实控件的 section。显示组示例（字号；其余行高/缩进/边距×4/栏数照此模式，参数取自 `display_settings_page.dart:42-117`）：

```dart
SettingsStepperItem(
  id: 'reading_display.font_size',
  title: t.ttu_font_size,
  icon: Icons.format_size,
  min: 8,
  max: 64,
  step: 1,
  reader: const ReaderPlacement(group: ReaderGroup.appearance, order: 0),
  value: (SettingsContext c) => c.readerSource.ttuFontSize,
  format: (double v) => '${v.round()}',
  onChanged: (SettingsContext c, double v) {
    c.readerSource.setTtuFontSize(v);
    notifyReaderSettingsChanged(c);
  },
),
```

逐项迁移（id / title / 取值 / setter / reader.order 对照表）：

| id | title | getter | setter | reader 组/序 |
|----|-------|--------|--------|--------------|
| `reading_display.font_size` | `t.ttu_font_size` | `ttuFontSize` | `setTtuFontSize` | appearance/0 |
| `reading_display.line_height` | `t.ttu_line_height` | `ttuLineHeight` | `setTtuLineHeight((v*100).roundToDouble()/100)` step 0.1 min 1 max 3 format `toStringAsFixed(2)` | appearance/1 |
| `reading_display.text_indentation` | `t.ttu_text_indentation` | `ttuTextIndentation` | `setTtuTextIndentation` min 0 max 10 | appearance/2 |
| `reading_display.margin_top` | `t.margin_top` | `ttuMarginTop` | `setTtuMarginTop` min -5 max 30 | layout/0 |
| `reading_display.margin_bottom` | `t.margin_bottom` | `ttuMarginBottom` | `setTtuMarginBottom` min -5 max 30 | layout/1 |
| `reading_display.margin_left` | `t.margin_left` | `ttuMarginLeft` | `setTtuMarginLeft` min -5 max 30 | layout/2 |
| `reading_display.margin_right` | `t.margin_right` | `ttuMarginRight` | `setTtuMarginRight` min -5 max 30 | layout/3 |
| `reading_display.page_columns` | `t.columns_per_page` | `ttuPageColumns.toDouble()` | `setTtuPageColumns(v.round())` min 0 max 4 format `v.round()==0?t.ttu_page_columns_auto:'${v.round()}'` | layout/4 |

- [ ] **Step 2: 加入布局组 segmented 项**

布局组 segmented（用 `SettingsSegmentedItem<String>`，选项取自 `display_settings_page.dart:122-247`）。spread direction / 竖排朝向 / 竖排 kerning / VPAL 有条件可见，用 `visible:` 谓词复刻 `DisplaySettingsPage` 的 `if` 守卫：

```dart
SettingsSegmentedItem<String>(
  id: 'reading_display.spread_mode',
  title: t.spread_mode,
  reader: const ReaderPlacement(group: ReaderGroup.layout, order: 5),
  options: <SettingsSegmentOption<String>>[
    SettingsSegmentOption<String>(value: 'off', label: t.spread_off, tooltip: t.spread_off),
    SettingsSegmentOption<String>(value: 'on', label: t.spread_on, tooltip: t.spread_on),
    SettingsSegmentOption<String>(value: 'auto', label: t.spread_auto, tooltip: t.spread_auto),
  ],
  selected: (SettingsContext c) => c.readerSource.ttuSpreadMode,
  onChanged: (SettingsContext c, String v) {
    c.readerSource.setTtuSpreadMode(v);
    notifyReaderSettingsChanged(c);
  },
),
SettingsSegmentedItem<String>(
  id: 'reading_display.spread_direction',
  title: t.spread_direction,
  visible: (SettingsContext c) => c.readerSource.ttuSpreadMode != 'off',
  reader: const ReaderPlacement(group: ReaderGroup.layout, order: 6),
  options: <SettingsSegmentOption<String>>[
    SettingsSegmentOption<String>(value: 'rtl', label: 'RTL', tooltip: 'Right to Left'),
    SettingsSegmentOption<String>(value: 'ltr', label: 'LTR', tooltip: 'Left to Right'),
  ],
  selected: (SettingsContext c) => c.readerSource.ttuSpreadDirection,
  onChanged: (SettingsContext c, String v) {
    c.readerSource.setTtuSpreadDirection(v);
    notifyReaderSettingsChanged(c);
  },
),
```

剩余 segmented/switch 项对照（`isVertical` = `c.readerSource.ttuWritingMode.startsWith('vertical')`）：

| id | title | 类型 | getter | setter | visible | reader |
|----|-------|------|--------|--------|---------|--------|
| `reading_display.writing_mode` | `t.ttu_writing_direction` | segmented(horizontal-tb/vertical-rl) | `ttuWritingMode` | `setTtuWritingMode` | 总是 | layout/7 |
| `reading_display.view_mode` | `t.ttu_view_mode_label` | segmented(paginated/continuous) | `ttuViewMode` | `setTtuViewMode` | 总是 | appearance/3 |
| `reading_display.vert_text_orient` | `t.ttu_vert_text_orient` | segmented(mixed/upright) | `ttuVerticalTextOrientation` | `setTtuVerticalTextOrientation` | isVertical | layout/8 |
| `reading_display.furigana_mode` | `t.ttu_furigana_mode` (controlBelow:true) | segmented(show/hide/partial/toggle) | `ttuFuriganaMode` | `setTtuFuriganaMode` | 总是 | layout/9 |
| `reading_display.text_justify` | `t.ttu_text_justify` | switch | `ttuEnableTextJustification` | `setTtuEnableTextJustification` | 总是 | layout/10 |
| `reading_display.vert_kerning` | `t.ttu_vert_kerning` | switch | `ttuEnableVerticalFontKerning` | `setTtuEnableVerticalFontKerning` | isVertical | layout/11 |
| `reading_display.font_vpal` | `t.ttu_font_vpal` | switch | `ttuEnableFontVPAL` | `setTtuEnableFontVPAL` | isVertical | layout/12 |
| `reading_display.prioritize_reader_styles` | `t.ttu_reader_styles` | switch | `ttuPrioritizeReaderStyles` | `setTtuPrioritizeReaderStyles` | 总是 | layout/13 |

把这些按 显示 section（typography）/ 布局 section（layout）/ 高级排版 section（advanced_typography）组织，复用 `display_settings_page.dart` 的三段标题（`t.section_typography` / `t.section_layout` / `t.section_advanced_typography`）。`reading_display.book_css`（visible=false）保留不动。

- [ ] **Step 3: 阅读主题加入显示组（书内/全局共享）**

reader 主题当前在书内 sheet 手写。把它作为 `SettingsCustomItem` 加到显示 section，复用现有 `buildThemeSelector`（appearance 用的同一 builder，若它绑的是 App 主题而非阅读主题，则改用书内 sheet 的主题 chip builder——实现时先确认 `buildThemeSelector` 改的是 `ttu_theme` 还是 App 主题；阅读主题对应 `c.readerSource` 的 `ttuTheme`/`setTtuTheme` + `appModel.setAppThemeKey`）。给它 `reader: ReaderPlacement(group: appearance, order: 4)`。

> 若 App 主题与阅读主题是两套，本步骤只迁阅读主题；App 设计系统/亮暗仍留在 `_appearanceDestination`，不动。

- [ ] **Step 4: 分析**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/settings/settings_schema.dart
```
Expected: No issues found

- [ ] **Step 5: 提交**

```bash
git add lib/src/settings/settings_schema.dart
git commit -m "feat(settings): migrate reader display controls into schema items"
```

---

## Task 3: 给现有 reading_controls / listening / lookup 的阅读项打 reader 标记

**Files:**
- Modify: `lib/src/settings/settings_schema.dart`

- [ ] **Step 1: 给 `_readingControlsDestination()` 的每个 item 加 reader 放置（behavior 组）**

为 settings_schema.dart:240-326 的各项加 `reader:`（键盘快捷键 `reading_controls.keyboard_shortcuts` **不加**，保持仅全局）：

| id | reader 组/序 |
|----|--------------|
| `reading_controls.highlight_on_tap` | behavior/0 |
| `reading_controls.volume_page_turning` | behavior/1 |
| `reading_controls.invert_volume_buttons` | behavior/2 |
| `reading_controls.invert_swipe_direction` | behavior/3 |
| `reading_controls.volume_page_turning_speed` | behavior/4 |
| `reading_controls.dismiss_swipe_sensitivity` | behavior/5 |
| `reading_controls.keep_screen_awake` | behavior/6 |

示例（只加一行 `reader:`，其余不动）：
```dart
SettingsSwitchItem(
  id: 'reading_controls.highlight_on_tap',
  title: t.highlight_on_tap,
  icon: Icons.touch_app_outlined,
  reader: const ReaderPlacement(group: ReaderGroup.behavior, order: 0),
  value: (SettingsContext settingsContext) =>
      settingsContext.readerSource.highlightOnTap,
  onChanged: (SettingsContext settingsContext, bool value) {
    settingsContext.readerSource.toggleHighlightOnTap();
    notifyReaderSettingsChanged(settingsContext);
  },
),
```

- [ ] **Step 2: 给 lookup 的两个阅读行为项加 reader 放置**

`lookup.auto_read_on_lookup` → `reader: ReaderPlacement(group: behavior, order: 7)`；`lookup.pause_on_lookup` → `behavior/8`。其余 lookup 项不加（仅全局）。

- [ ] **Step 3: 给 listening 的项加 reader 放置（audiobook 组）**

`listening.media_notification` → audiobook/0；`listening.floating_lyric` → audiobook/1；`listening.floating_lyric_font_size` → audiobook/2；`listening.volume_key_sentence_nav` → behavior/9（音量键句导航属导航行为）。

- [ ] **Step 4: 新增 `collectReaderItems` 与 `buildReaderGroupDestination`**

在 settings_schema.dart 内（`buildReaderQuickSettingsDestination` 上方）加：

```dart
/// 遍历完整 schema，收集所有带 [ReaderPlacement] 的 item，按 group + order 排序。
Map<ReaderGroup, List<SettingsItem>> collectReaderItems(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      <ReaderGroup, List<SettingsItem>>{};
  for (final SettingsDestination destination in buildSettingsSchema(context)) {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        final ReaderPlacement? placement = item.reader;
        if (placement == null) continue;
        grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
      }
    }
  }
  for (final List<SettingsItem> items in grouped.values) {
    items.sort((SettingsItem a, SettingsItem b) =>
        a.reader!.order.compareTo(b.reader!.order));
  }
  return grouped;
}

/// 把某个 [ReaderGroup] 的 item 包装成一个可被 SettingsRenderer 渲染的 destination。
SettingsDestination buildReaderGroupDestination(
  SettingsContext context,
  ReaderGroup group,
  String title,
) {
  final List<SettingsItem> items =
      collectReaderItems(context)[group] ?? <SettingsItem>[];
  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: title,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[SettingsSection(items: items)],
  );
}
```

- [ ] **Step 5: 重写 `buildReaderQuickSettingsDestination` 用 `collectReaderItems`**

替换 settings_schema.dart:30-73 的实现为：

```dart
SettingsDestination buildReaderQuickSettingsDestination(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      collectReaderItems(context);
  SettingsSection sectionFor(ReaderGroup group, String title) {
    return SettingsSection(
      title: title,
      items: grouped[group] ?? <SettingsItem>[],
    );
  }

  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      sectionFor(ReaderGroup.appearance, t.settings_destination_appearance),
      sectionFor(ReaderGroup.layout, t.section_layout),
      sectionFor(ReaderGroup.behavior, t.section_navigation),
      sectionFor(ReaderGroup.audiobook, t.section_audiobook),
    ].where((SettingsSection s) => s.items.isNotEmpty).toList(growable: false),
  );
}
```

- [ ] **Step 6: 分析 + 运行 dialog widget 测试（若有）**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/settings/settings_schema.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test --no-pub test/settings/
```
Expected: analyze 干净；test/settings 中除 `settings_redesign_static_test.dart` 外应通过（静态测试在 Task 5 改）。若静态测试此时失败，记录哪几条失败，留待 Task 5 修。

- [ ] **Step 7: 提交**

```bash
git add lib/src/settings/settings_schema.dart
git commit -m "feat(settings): project reader items via collectReaderItems"
```

---

## Task 4: 合并 destination 枚举（10→8），重排分组

**Files:**
- Modify: `lib/src/settings/settings_destination.dart`（枚举）
- Modify: `lib/src/settings/settings_schema.dart`（合并函数、`buildSettingsSchema` 列表）
- Modify: 全仓所有引用 `readingDisplay` / `readingControls` / `diagnostics` 处

- [ ] **Step 1: 全仓搜索旧枚举引用，列出受影响点**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run grep -r "readingDisplay\|readingControls\|diagnostics" lib test 2>/dev/null || grep -rn "readingDisplay\|readingControls\|SettingsDestinationId.diagnostics" lib test
```
（用 Grep 工具亦可）Expected: 列出 settings_destination.dart、settings_schema.dart、可能的 settings_home_page.dart 默认选中项、测试。逐一处理。

- [ ] **Step 2: 改枚举**

`settings_destination.dart` 的 `SettingsDestinationId`：把 `readingDisplay,` 与 `readingControls,` 两行替换为单个 `reading,`；删除 `diagnostics,`。保留 `readerQuickSettings`。结果：
```dart
enum SettingsDestinationId {
  appearance,
  profiles,
  reading,
  lookup,
  cardCreation,
  listening,
  syncBackup,
  system,
  readerQuickSettings,
}
```

- [ ] **Step 3: 合并 schema 函数**

在 `settings_schema.dart`：
- 把 `_readingDisplayDestination()` 与 `_readingControlsDestination()` 合并为单个 `_readingDestination()`，`id: SettingsDestinationId.reading`，`title: t.settings_destination_reading`（Task 6 加 key），三个 section 依次为：显示（Task 2 的 typography+layout 显示项）、布局、导航行为（原 reading_controls 各项）。保留各 item 的 `id` 字符串不变（`reading_display.*` / `reading_controls.*` 前缀沿用，避免影响任何按 id 的逻辑）。
- 把 `_diagnosticsDestination()` 的那个 section 整体并入 `_systemDestination()` 作为第三个 section（错误日志 / 调试日志开关 / 调试日志），删除 `_diagnosticsDestination()` 函数。
- `buildSettingsSchema` 列表改为 8 项：
```dart
List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    _appearanceDestination(),
    _profilesDestination(),
    _readingDestination(),
    _lookupDestination(),
    _cardCreationDestination(),
    _listeningDestination(),
    buildSyncBackupDestination(),
    _systemDestination(),
  ];
}
```

- [ ] **Step 4: 修其它引用点**

`settings_home_page.dart` 若有默认 `selectedDestinationId` 用了 `readingDisplay`，改为 `reading`。任何 `switch (destination.id)` 缺失 `reading` 分支的补上、删 `diagnostics`/`readingControls`/`readingDisplay` 分支。

- [ ] **Step 5: 分析**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
```
Expected: No issues found（全仓，确保无遗漏引用）

- [ ] **Step 6: 提交**

```bash
git add lib/src/settings/settings_destination.dart lib/src/settings/settings_schema.dart lib/src/settings/settings_home_page.dart
git commit -m "refactor(settings): merge reading destinations 10->8"
```

---

## Task 5: 重写静态测试断言为新 8 分组结构

**Files:**
- Modify: `test/settings/settings_redesign_static_test.dart`

- [ ] **Step 1: 更新 `settings_destination.dart` 必含 token**

`requiredFiles` 里 `settings_schema.dart` 的 token 列表：删 `SettingsDestinationId.readingDisplay`、`SettingsDestinationId.readingControls`、`SettingsDestinationId.diagnostics`；加 `SettingsDestinationId.reading`。

- [ ] **Step 2: 更新 `'settings schema uses task-oriented destinations'` 测试**

把 token 循环里的 `readingDisplay`/`readingControls`/`diagnostics` 改为单个 `SettingsDestinationId.reading`；保留对 `appearance/profiles/lookup/cardCreation/listening/syncBackup/system` 的断言。`isNot(contains('dictionaryAndCards'))` 等保留。

- [ ] **Step 3: 更新 `'custom fonts are grouped with app appearance typography'` 测试**

该测试用 `_readingDisplayDestination()` / `_readingControlsDestination()` 函数名做 substring 边界，现已不存在。改为用 `_readingDestination()` 与 `_lookupDestination()` 做边界，断言：appearance 段含 `CustomFontsPage` 与 `id: 'appearance.fonts'`；reading 段不含 `CustomFontsPage`。

```dart
final int appearanceStart =
    schemaSource.indexOf('SettingsDestination _appearanceDestination()');
final int profilesStart =
    schemaSource.indexOf('SettingsDestination _profilesDestination()');
final int readingStart =
    schemaSource.indexOf('SettingsDestination _readingDestination()');
final int lookupStart =
    schemaSource.indexOf('SettingsDestination _lookupDestination()');

final String appearanceSource =
    schemaSource.substring(appearanceStart, profilesStart);
final String readingSource =
    schemaSource.substring(readingStart, lookupStart);

expect(appearanceSource, contains('CustomFontsPage'));
expect(appearanceSource, contains("id: 'appearance.fonts'"));
expect(readingSource, isNot(contains('CustomFontsPage')));
```

- [ ] **Step 4: 更新 `'display settings contains reader layout only'` 测试**

`DisplaySettingsPage` 改为 schema 渲染薄页后（Task 7），断言它不再手写 `setTtu`。先放宽为：仍 `isNot(contains('design_system_label'))` 与 `isNot(contains('ProfileSelector'))`。Task 7 改完页面后再回到此步收紧（见 Task 7 Step 3）。

- [ ] **Step 5: 加一条新断言：reader 投影来自 schema**

新增 test：
```dart
test('reader quick settings project from schema reader placements', () {
  final String schemaSource =
      readNormalizedSource('lib/src/settings/settings_schema.dart');
  expect(schemaSource, contains('Map<ReaderGroup, List<SettingsItem>> collectReaderItems'));
  expect(schemaSource, contains('item.reader'));
  // 书内面板不再硬编码 lookup 白名单
  expect(schemaSource,
      isNot(contains("item.id == 'lookup.auto_read_on_lookup' ||")));
});
```

- [ ] **Step 6: 运行 settings 测试**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test --no-pub test/settings/
```
Expected: All tests passed

- [ ] **Step 7: 提交**

```bash
git add test/settings/settings_redesign_static_test.dart
git commit -m "test(settings): assert merged 8-destination structure"
```

---

## Task 6: i18n 新增分组标题 key

**Files:**
- Modify: `lib/i18n/*.i18n.json`（经脚本）+ 重新生成 `strings.g.dart`

- [ ] **Step 1: 确认需要的新 key**

`t.settings_destination_reading`（「阅读」分组标题）。检查 `t.section_navigation` / `t.section_layout` / `t.section_audiobook` / `t.settings_destination_appearance` 是否已存在（schema 现已使用 → 应存在，无需加）。只有 `settings_destination_reading` 是新的。

- [ ] **Step 2: 用脚本加 key（禁止手编 17 文件）**

Run（在 worktree `hibiki/`）:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run tool/i18n_sync.dart --add settings_destination_reading "Reading" "阅读"
```
Expected: 17 个 `*.i18n.json` 更新 + 重新生成 `strings.g.dart`（脚本应自动生成；若没有，手动跑 slang：`D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run slang`）

- [ ] **Step 3: 把 `_readingDestination()` 的 title 指向新 key**

确认 settings_schema.dart 里 `title: t.settings_destination_reading` 编译通过（key 已生成）。

- [ ] **Step 4: 分析 + i18n 测试**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/settings/settings_schema.dart lib/i18n/strings.g.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test --no-pub test/i18n/
```
Expected: 全绿（i18n 完整性测试通过，17 语言无缺 key）

- [ ] **Step 5: 提交**

```bash
git add lib/i18n/ lib/src/settings/settings_schema.dart
git commit -m "i18n: add settings_destination_reading title"
```

---

## Task 7: DisplaySettingsPage 改薄页 + 书内 sheet 投影 + 音频进度

**Files:**
- Modify: `lib/src/pages/implementations/display_settings_page.dart`
- Modify: `lib/src/media/audiobook/reader_quick_settings_sheet.dart`
- Modify: `test/settings/settings_redesign_static_test.dart`（收紧 display 断言）

- [ ] **Step 1: DisplaySettingsPage 改为渲染 reading destination 的「显示+布局」section**

`DisplaySettingsPage` 全文件改为：构造 `SettingsContext` → 取 `_readingDestination()`（通过 `buildSettingsSchema` 取 `id == reading` 的 destination）→ 只保留显示与布局两个 section（排除「导航行为」section，那些归 reading 全局页其它入口）→ 用平台 renderer `buildDetailContent` 渲染。参考 `hibiki_settings_page.dart:66-107` 的 `_buildContent` 写法。删除全部 `_numberStepper` / `setTtu*` 手写代码。

> 实现前先读 `material_settings_renderer.dart` 确认 `buildDetailContent` 对「只含部分 section 的 destination」渲染正常（它已被 dialog 复用，应可直接用）。

- [ ] **Step 2: 书内 sheet 的 4 个设置子页改投影渲染**

先读 `reader_quick_settings_sheet.dart` 的 `_buildSubPage`（~435）与子页分发逻辑（`_subPage` 状态、`appearance`/`layout`/`behavior`/`audiobook` 分支）。把这 4 个分支原本调用 `_buildAppearanceSettingsSection`(~1122) / `_buildLayoutSettingsSection`(~1249) / `_buildBehaviorSettingsSection`(~953)+`_buildReaderSwitches`(~959) / `_buildAudiobookSettingsSection`(~1088) 的设置部分，替换为渲染对应 `ReaderGroup` 的投影：

```dart
Widget _buildReaderGroupContent(ReaderGroup group, String title) {
  final SettingsContext settingsContext = SettingsContext(
    context: context,
    appModel: appModel, // 取本 widget 已有的 appModel/ref 引用
    ref: ref,
    readerSource: ReaderHibikiSource.instance,
    refresh: () {
      if (mounted) setState(() {});
    },
  );
  final SettingsDestination destination =
      buildReaderGroupDestination(settingsContext, group, title);
  final bool cupertino = isCupertinoPlatform(context);
  final SettingsRenderer renderer = cupertino
      ? const CupertinoSettingsRenderer()
      : const MaterialSettingsRenderer();
  return renderer.buildDetailContent(
    settingsContext: settingsContext,
    destination: destination,
    shrinkWrap: true,
  );
}
```

`appearance`→`(ReaderGroup.appearance, t.settings_destination_appearance)`，`layout`→`(layout, t.section_layout)`，`behavior`→`(behavior, t.section_navigation)`，`audiobook`→`(audiobook, t.section_audiobook)`。

删除 `_buildAppearanceSettingsSection` / `_buildLayoutSettingsSection` / `_buildReaderSwitches` / `_buildBehaviorSettingsSection` 中**纯设置**的手写代码（与 schema 重复的部分）。**保留**：`_buildProgressSection`、`_buildQuickControlsSection`（快捷字号/行高 stepper + 主题 chip + 视图——这些可继续手写，但其 onChanged 复用 `ReaderHibikiSource.instance.setTtu*`，与 schema 同源，不另写持久化）、`_buildLocationSection`、听书播放控制（`_buildVolumeSection`/`_buildSpeedSection`/`_buildDelaySection`/`_buildImagePauseSection` 等运行态）、`_buildActionRow`、歌词模式专属 `_buildLyricsDisplaySection`。

> 歌词字号/边距（`lyrics_*`）不进 schema（歌词模式专属、非 ttu 设置），保持手写。

- [ ] **Step 3: `_buildProgressSection` 加音频进度**

先读 `AudiobookPlayerController` 确认进度 API（position / duration 的 getter 或 stream；参考 `_buildSpeedSection`/`_buildVolumeSection` 已如何读 ctrl）。在 `_buildProgressSection(ThemeData theme)` 内，`controller != null` 时追加一行音频播放进度（position / duration 文本或进度条），与现有阅读进度并列。无 controller 时不渲染该行（保持现状）。

```dart
// 在 _buildProgressSection 内，阅读进度行之后：
if (controller != null) _buildAudioProgressRow(theme, controller!),
```
`_buildAudioProgressRow` 用 controller 的 position/duration 流（`StreamBuilder` 或现有 ValueListenable，按 controller 实际 API），显示 `mm:ss / mm:ss`。

- [ ] **Step 4: 收紧 display 静态断言**

回到 `settings_redesign_static_test.dart` 的 `'display settings contains reader layout only'`，加：
```dart
expect(source, isNot(contains('setTtuFontSize')));
expect(source, contains('buildDetailContent'));
```

- [ ] **Step 5: 格式化 + 全量分析**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
```
Expected: No issues found

- [ ] **Step 6: 提交**

```bash
git add lib/src/pages/implementations/display_settings_page.dart lib/src/media/audiobook/reader_quick_settings_sheet.dart test/settings/settings_redesign_static_test.dart
git commit -m "refactor(reader): project quick settings from schema + audio progress"
```

---

## Task 8: 全量验证 + 设备复测原始路径

**Files:** 无改动

- [ ] **Step 1: 全量测试**

Run:
```bash
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test --no-pub
```
Expected: All tests passed（重点关注 test/settings、test/i18n、test/pages、test/goldens；golden 若因设置页结构变化失败，确认是预期变化后用 `--update-goldens` 重生并人工核对截图）

- [ ] **Step 2: 设备复测三条原始路径（按 CLAUDE.md「声明修好前必须验证原始失败路径」）**

在模拟器/真机上：
1. 全局「阅读 → 显示」改字号 → 打开书内 sheet「外观」子页，字号应同步。
2. 书内 sheet「布局」改上边距 → 回全局「阅读 → 显示」，边距应同步。
3. 打开有声书的书 → 书内 sheet 进度区应显示音频播放进度；无音频的纯 EPUB 不显示该行。
4. 书内「行为」子页改音量键翻页开关 → 全局「阅读 → 导航行为」应同步，且音量键拦截实际生效（`VolumeKeyChannel`）。

留存证据（截图/DB 查询）到 `.codex-test/`，在完成说明里引用路径。

- [ ] **Step 3: 提交（如有 golden 更新）**

```bash
git add test/goldens/   # 仅当确认 golden 变化是预期的
git commit -m "test(goldens): update settings golden masters for 8-destination layout"
```

---

## Self-Review 记录

- **Spec 覆盖**: §3.1 模型→Task 1；§3.2 八分组→Task 2/4/6；§3.3 书内投影→Task 3/7；音频进度→Task 7 Step 3；§4 受影响文件全部有对应 Task；§5 风险（控件表达力用 SettingsCustomItem 兜底见 Task 2 Step 3、枚举影响面见 Task 4 Step 1、i18n 走脚本见 Task 6、HBK-AUDIT-131 保留 readerQuickSettings 见 Task 1/3）。
- **类型一致性**: `ReaderGroup` / `ReaderPlacement` / `collectReaderItems` / `buildReaderGroupDestination` 在 Task 1/3 定义，Task 7 一致引用；item id 字符串前缀保持 `reading_display.*` / `reading_controls.*` 不变（不依赖 destination 改名）。
- **待实现时确认的开放点（已在步骤内标注，非占位符）**: (a) `buildThemeSelector` 改的是 App 主题还是阅读主题（Task 2 Step 3）；(b) `AudiobookPlayerController` 的 position/duration API（Task 7 Step 3）；(c) `tool/i18n_sync.dart` 是否自动跑 slang 生成（Task 6 Step 2）。这三点都给了「先读 X 确认」的明确动作。
```

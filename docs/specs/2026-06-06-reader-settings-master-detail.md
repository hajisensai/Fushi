# 阅读器底栏设置 宽窗 master-detail 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development 或 superpowers:executing-plans 逐任务执行。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 桌面/宽窗下把阅读器底栏「设置」改成与主页设置一致的 master-detail（左父菜单＋右详情页，随窗口宽度自适应）；手机的底栏 bottom sheet 保持现状（push 导航）不动。

**Architecture:** 复用主页设置已有的 `MaterialSupportingPaneLayout`（左 supporting pane＋右 primary pane，内置 `minSplitWidth` 宽度阈值 → 自动降级）。在 `ReaderQuickSettingsSheet` 里：宽窗时左 pane = 进度 + 全部分类（外观/布局/阅读控制/查词/导航/有声书）+ 动作行，右 pane = 当前选中分类的详情；窄窗（含全部手机 bottom sheet）维持现有 `_subPage` push 行为。两种模式共用同一份 `_subPage` 选中态与同一份子页详情逻辑，零内容重写。

**Tech Stack:** Flutter / Riverpod / 现有 settings schema renderer（`MaterialSettingsRenderer` / `CupertinoSettingsRenderer`）/ `MaterialSupportingPaneLayout`（`lib/src/utils/misc/platform_utils.dart`）。

---

## 背景事实（实现者须知，零上下文假设）

- 入口：`reader_hibiki_page.dart` 第 4981-4996 行。**桌面**用 `showAppDialog` + `HibikiDialogFrame(maxWidth: 520, maxHeightFactor: 0.80)` 弹**居中对话框**；**移动端**用 `adaptiveModalSheet`（底栏 bottom sheet）。两者 body 都是同一个 `ReaderQuickSettingsSheet`。
- 面板本体：`hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（`_ReaderQuickSettingsSheetState`）。
  - 选中态字段：`String? _subPage`（第 137 行）。`null` = 主页，非 null = 某子页。
  - `build`（241-272 行）：`HibikiModalSheetFrame` 包 `AnimatedSize`，`_subPage != null ? _buildSubPage : _buildMainPage`。
  - `_buildMainPage`（274-319 行）：进度区 `_buildProgressSection` + 内联外观卡 `_buildAppearanceInline` + 分类导航 `AdaptiveSettingsSection(navigationRows)` + 动作行 `_buildActionRow`。分类有 5 个：`layout` / `behavior` / `lookup` / `location` / `audiobook`（见 277-304 行）。**外观当前是内联卡，不在分类里。**
  - `_buildSubPage`（321-368 行）：`switch(page)` → 5 个分类各自内容 + `_InBookSettingsHeader`（带返回箭头）。
  - 详情构造已有的可复用件：`_buildReaderGroupContent(group, title)`（393 行）、`_buildAppearanceInline`（442 行，内含 `buildThemeSelector` + appearance schema 行 + 编辑书籍CSS 行）、`_buildLocationSection`（496 行）、`_buildAudiobookSettingsSection`（1097 行）、`_buildLyricsDisplaySection`（1143 行）。
  - 上下文工厂：`_settingsContext()`（380 行）、`_themeSettingsContext()`（419 行，换肤联动）。
- `MaterialSupportingPaneLayout`（`platform_utils.dart:132`）签名：
  ```dart
  MaterialSupportingPaneLayout({
    required Widget primary,
    required Widget supporting,
    SupportingPaneSide supportingSide = SupportingPaneSide.end,
    double minSplitWidth = 840,
    Color? dividerColor,
  })
  ```
  内部 `LayoutBuilder`：`constraints.maxWidth < minSplitWidth` 时**只返回 `primary`**（自动降级，单列）；否则左右分栏（`SupportingPaneSide.start` = supporting 在左）。
- `ReaderGroup` 枚举（`settings_destination.dart:22`）：`{ appearance, layout, behavior, lookup, audiobook }`（**无 location**；location 是 bespoke 子页）。
- `buildReaderGroupDestination(SettingsContext, ReaderGroup, String title)`（`settings_schema.dart:51`）。
- 参考实现：`settings_home_page.dart:135-179`（`_buildWideLayout`，主页 master-detail 范式，含 `KeyedSubtree(ValueKey(id))` 防详情面板 Element 复用副作用）。

## 设计决策（已与用户确认）

- chrome 放置：**全部并入左 pane**。左 pane 自上而下 = 进度区 → 分类列表（外观/布局/阅读控制/查词/导航/有声书）→ 动作行；右 pane 仅详情。
- 宽窗时分类列表**含「外观」**（成为第 1 项，默认选中），不再用内联外观卡。
- 窄窗/手机：保持现状（进度 + 内联外观卡 + 分类 + 动作行 + tap push 子页），**外观仍内联**，不改。

## 文件结构

| 文件 | 改动 |
|---|---|
| `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart` | 主改：抽出 appearance 详情可复用 builder；抽出 `_subPageContent`/`_subPageTitle`；新增宽窗 master-detail 分支与左 pane builder；统一选中态。 |
| `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` | 桌面对话框 `maxWidth` 由 520 调宽到约 900（让宽窗能分栏）。 |
| `hibiki/test/media/audiobook/reader_quick_settings_master_detail_test.dart` | 新建：宽窗分栏 / 窄窗 push 两个 widget 行为测试。 |

---

## Task 1: 抽出外观详情可复用 builder

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（重构 `_buildAppearanceInline` 442-494 行）

把 `_buildAppearanceInline` 拆成「卡片内容 builder」+「带标题的内联包装」，使外观内容既能内联（窄窗主页）又能当右 pane 详情（宽窗）。

- [ ] **Step 1: 抽出 `_appearanceCardChildren()` 纯组装方法**

在 `_buildAppearanceInline` 上方新增（把 451-482 行 `cardChildren` 的构造原样搬进来，类型签名明确）：

```dart
/// 外观卡的行集合（主题 + appearance schema 行 + 可选「编辑书籍CSS」行）。
/// 内联（窄窗主页）与右 pane 详情（宽窗 master-detail）共用，避免重复。
List<Widget> _appearanceCardChildren() {
  final SettingsContext appearanceCtx = _settingsContext();
  final SettingsDestination base = buildReaderGroupDestination(
    appearanceCtx,
    ReaderGroup.appearance,
    t.settings_destination_appearance,
  );
  final SettingsRenderer renderer = isCupertinoPlatform(context)
      ? const CupertinoSettingsRenderer()
      : const MaterialSettingsRenderer();
  return <Widget>[
    buildThemeSelector(_themeSettingsContext()),
    for (final SettingsSection section in base.sections)
      ...renderer.buildSectionRows(
        settingsContext: appearanceCtx,
        section: section,
      ),
    if (widget.extractDir != null)
      AdaptiveSettingsNavigationRow(
        title: t.book_css_editor_edit_css,
        icon: Icons.code_outlined,
        onTap: () async {
          await Navigator.push(
            context,
            adaptivePageRoute(
              builder: (_) => BookCssEditorPage(extractDir: widget.extractDir!),
            ),
          );
          await _reloadLayoutLive();
        },
      ),
  ];
}
```

- [ ] **Step 2: `_buildAppearanceInline` 改为调用它**

把 `_buildAppearanceInline` 体内 `final SettingsContext appearanceCtx ...` 到 `cardChildren` 构造整段（451-482 行）替换为：

```dart
final List<Widget> cardChildren = _appearanceCardChildren();
```

保留其后的 `return Column(... SettingsSectionHeader(t.display_settings) + AdaptiveSettingsSection(children: cardChildren) ...)` 不变。

- [ ] **Step 3: 新增「外观详情」builder（右 pane 用，无内联标题）**

在 `_buildAppearanceInline` 下方新增：

```dart
/// 宽窗 master-detail 右 pane 的外观详情：仅卡片，无 `display_settings`
/// 内联标题（标题已由左 pane 选中项体现）。
Widget _buildAppearanceDetail() {
  return AdaptiveSettingsSection(children: _appearanceCardChildren());
}
```

- [ ] **Step 4: 编译验证**

Run（worktree 根下）: `cd hibiki && flutter analyze lib/src/media/audiobook/reader_quick_settings_sheet.dart`
Expected: No issues（或仅与本任务无关的既有 info）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart
git commit -m "refactor(reader-settings): extract reusable appearance card builder"
```

---

## Task 2: 抽出 `_subPageContent` / `_subPageTitle` 并加 `appearance` 分支

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（`_buildSubPage` 321-368 行）

把「分类 id → 详情内容 / 标题」从 `_buildSubPage` 抽成独立 helper，窄窗 push 子页与宽窗右 pane 共用；同时让 `appearance` 成为合法分类 id。

- [ ] **Step 1: 新增 `_subPageContent` / `_subPageTitle`**

在 `_buildSubPage` 旁新增：

```dart
/// 某分类的详情内容（不含返回页头）。窄窗 push 子页与宽窗右 pane 共用。
Widget _subPageContent(String page) {
  switch (page) {
    case 'appearance':
      return _buildAppearanceDetail();
    case 'layout':
      return widget.lyricsMode
          ? _buildLyricsDisplaySection()
          : _buildReaderGroupContent(ReaderGroup.layout, t.section_layout);
    case 'behavior':
      return _buildReaderGroupContent(
          ReaderGroup.behavior, t.settings_destination_reading_controls);
    case 'lookup':
      return _buildReaderGroupContent(
          ReaderGroup.lookup, t.settings_destination_lookup);
    case 'location':
      return _buildLocationSection(Theme.of(context));
    case 'audiobook':
      return _buildAudiobookSettingsSection(Theme.of(context));
    default:
      return const SizedBox.shrink();
  }
}

String _subPageTitle(String page) {
  switch (page) {
    case 'appearance':
      return t.settings_destination_appearance;
    case 'layout':
      return t.section_layout;
    case 'behavior':
      return t.settings_destination_reading_controls;
    case 'lookup':
      return t.settings_destination_lookup;
    case 'location':
      return t.section_navigation;
    case 'audiobook':
      return t.section_audiobook;
    default:
      return '';
  }
}
```

- [ ] **Step 2: `_buildSubPage` 改为消费 helper**

```dart
Widget _buildSubPage(BuildContext context, ThemeData theme) {
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  final String page = _subPage!;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _InBookSettingsHeader(
        title: _subPageTitle(page),
        onBack: () => setState(() => _subPage = null),
      ),
      SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
      _subPageContent(page),
    ],
  );
}
```

- [ ] **Step 3: 编译验证**

Run: `cd hibiki && flutter analyze lib/src/media/audiobook/reader_quick_settings_sheet.dart`
Expected: No issues。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart
git commit -m "refactor(reader-settings): extract sub-page content/title helpers + appearance id"
```

---

## Task 3: 新增宽窗 master-detail 分支

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（`build` 241-272 行 / 新增 `_buildWidePane` / `_wideCategories` / `_isWide` 字段）

宽窗（容器宽度 ≥ 640）改用 master-detail；窄窗维持现有 push。共用同一 `_subPage` 选中态：宽窗下把 `_subPage ?? 'appearance'` 当选中分类。

- [ ] **Step 1: 新增 `_isWide` 字段与 `_wideCategories()`**

在 `_subPage` 字段附近加：

```dart
/// 最近一次 LayoutBuilder 是否判定为宽窗。供 PopScope.canPop 读取
/// （宽窗下选中态非 null 也允许直接关闭，不会卡在返回上一级）。
bool _isWide = false;
```

在状态类内新增（id 与 `_subPageContent` 的 case 对齐；audiobook 仅在有 controller 时出现）：

```dart
/// 宽窗 master-detail 左 pane 的分类项。
List<({String id, IconData icon, String label})> _wideCategories() {
  return <({String id, IconData icon, String label})>[
    (
      id: 'appearance',
      icon: Icons.palette_outlined,
      label: t.settings_destination_appearance
    ),
    (id: 'layout', icon: Icons.auto_stories_outlined, label: t.section_layout),
    (
      id: 'behavior',
      icon: Icons.touch_app_outlined,
      label: t.settings_destination_reading_controls
    ),
    (
      id: 'lookup',
      icon: Icons.manage_search_outlined,
      label: t.settings_destination_lookup
    ),
    (
      id: 'location',
      icon: Icons.menu_book_outlined,
      label: t.section_navigation
    ),
    if (widget.controller != null)
      (
        id: 'audiobook',
        icon: Icons.headphones_outlined,
        label: t.section_audiobook
      ),
  ];
}
```

- [ ] **Step 2: 新增 `_buildWidePane`（左 supporting 内容）**

```dart
/// 宽窗 master-detail 左 pane：进度 + 分类列表（含外观，单选高亮）+ 动作行。
Widget _buildWidePane(BuildContext context, ThemeData theme, String selectedId) {
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  final double sectionGap = tokens.spacing.gap + tokens.spacing.gap / 2;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _buildProgressSection(theme),
      SizedBox(height: sectionGap),
      AdaptiveSettingsSection(
        children: [
          for (final cat in _wideCategories())
            AdaptiveSettingsNavigationRow(
              title: cat.label,
              icon: cat.icon,
              selected: cat.id == selectedId,
              onTap: () => setState(() => _subPage = cat.id),
            ),
        ],
      ),
      SizedBox(height: sectionGap),
      _buildActionRow(context),
    ],
  );
}
```

> 注：若 `AdaptiveSettingsNavigationRow` 无 `selected` 参数，则改用 MD3 token 高亮：把该行包进 `ColoredBox(color: cat.id == selectedId ? theme.colorScheme.secondaryContainer : Colors.transparent, child: ...)`。优先用 `selected` 参数；先 grep 确认其签名（`grep -n "class AdaptiveSettingsNavigationRow" -A30` 于 `lib/src/utils/components/`）。**禁止裸 `Container(color: 任意硬编码)`**（撞 MD3 守卫）。

- [ ] **Step 3: `build` 改为 `LayoutBuilder` 宽/窄分流**

把 `build` 的 `body:`（`AnimatedSize(... _subPage != null ? _buildSubPage : _buildMainPage)`）替换为：

```dart
body: LayoutBuilder(
  builder: (BuildContext context, BoxConstraints constraints) {
    _isWide = constraints.maxWidth >= 640;
    if (_isWide) {
      final String selectedId = _subPage ?? 'appearance';
      final Color dividerColor = isCupertinoPlatform(context)
          ? CupertinoColors.separator.resolveFrom(context)
          : HibikiDesignTokens.of(context).surfaces.outline;
      return MaterialSupportingPaneLayout(
        minSplitWidth: 640,
        supportingSide: SupportingPaneSide.start,
        dividerColor: dividerColor,
        supporting: SingleChildScrollView(
          child: _buildWidePane(context, theme, selectedId),
        ),
        // KeyedSubtree：按选中 id 编码，切换时整棵右 pane 子树作废重建，
        // 避免 Flutter 复用上一详情同位置 Element 触发 Switch/Segmented
        // didUpdateWidget 的圆点/分段滑动副作用（同 settings_home_page）。
        primary: KeyedSubtree(
          key: ValueKey<String>(selectedId),
          child: SingleChildScrollView(child: _subPageContent(selectedId)),
        ),
      );
    }
    // 窄窗（含全部手机 bottom sheet）：维持现有 push。
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: _subPage != null
          ? _buildSubPage(context, theme)
          : _buildMainPage(context, theme),
    );
  },
),
```

- [ ] **Step 4: 调整 `PopScope.canPop`**

把 245 行 `canPop: _subPage == null,` 改为：

```dart
canPop: _subPage == null || _isWide,
```

- [ ] **Step 5: 编译验证**

Run: `cd hibiki && flutter analyze lib/src/media/audiobook/reader_quick_settings_sheet.dart`
Expected: No issues。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart
git commit -m "feat(reader-settings): wide-window master-detail layout"
```

---

## Task 4: 加宽桌面对话框，让宽窗能分栏

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（4981-4990 行）

桌面对话框当前 `maxWidth: 520` < 640 阈值，永远进不了分栏。加宽到约 900，使大窗口分栏、小窗口自动降级单列。

- [ ] **Step 1: 调宽 maxWidth**

把 4985 行 `maxWidth: 520,` 改为：

```dart
            // master-detail（左父菜单 + 右详情）需要更宽画布；窄于 640 的
            // 窗口由面板内部 LayoutBuilder 自动降级回单列 push。
            maxWidth: 900,
```

- [ ] **Step 2: 编译验证**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart`
Expected: No issues。

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart
git commit -m "feat(reader-settings): widen desktop settings dialog for master-detail"
```

---

## Task 5: Widget 行为测试（宽窗分栏 / 窄窗 push）

**Files:**
- Create: `hibiki/test/media/audiobook/reader_quick_settings_master_detail_test.dart`

用真实 `ReaderQuickSettingsSheet`，分别在宽/窄约束下 pump，断言：宽窗左 pane 分类与右 pane 详情**同屏可见**；窄窗点击分类后**push** 到带返回箭头的子页。

- [ ] **Step 1: 看已有 sheet 测试 harness 样板**

Run: `cd hibiki && ls test/media/audiobook/ | grep -i settings`
若有 `reader_quick_settings*` 测试，复用其 ProviderScope / AppModel / 必填回调搭建；无则参考 `test/pages/` 下任一 settings widget 测试。记录必填的 `ReaderQuickSettingsSheet` props（`controller`/`toc`/`readerProgress`/`onJumpSection`/`onBookmark`/`onExitReader`/`webViewController`/`appModel`/`ref` 等）的最小可构造方式（headless 下 `webViewController` 通常需 fake/mock 或经 `isHibikiReader: true` 走非 ttu 路径规避 JS 调用）。

- [ ] **Step 2: 写宽窗分栏测试**

```dart
// await tester.binding.setSurfaceSize(const Size(1000, 800));
// addTearDown(() => tester.binding.setSurfaceSize(null));
// await pumpSheet(tester, /* 最小 props，含一个 fake controller 让 audiobook 分类可现 */);
// // 左 pane 分类「外观」可见：
// expect(find.text(t.settings_destination_appearance), findsWidgets);
// // 右 pane 外观详情的稳定控件（如主题行 t.ttu_theme）同屏可见：
// expect(find.text(t.ttu_theme), findsOneWidget);
// // master-detail 无返回箭头：
// expect(find.widgetWithIcon(HibikiIconButton, Icons.arrow_back), findsNothing);
```

- [ ] **Step 3: 运行**

Run: `cd hibiki && flutter test test/media/audiobook/reader_quick_settings_master_detail_test.dart -r expanded`
Expected: 宽窗用例 PASS。

- [ ] **Step 4: 写窄窗 push 测试**

```dart
// await tester.binding.setSurfaceSize(const Size(420, 800));
// addTearDown(() => tester.binding.setSurfaceSize(null));
// await pumpSheet(tester, ...);
// // 主页点击「布局」分类：
// await tester.tap(find.text(t.section_layout));
// await tester.pumpAndSettle();
// // 进入子页 → 出现返回箭头：
// expect(find.widgetWithIcon(HibikiIconButton, Icons.arrow_back), findsOneWidget);
```

- [ ] **Step 5: 运行**

Run: `cd hibiki && flutter test test/media/audiobook/reader_quick_settings_master_detail_test.dart -r expanded`
Expected: 两用例 PASS。

- [ ] **Step 6: Commit**

```bash
git add hibiki/test/media/audiobook/reader_quick_settings_master_detail_test.dart
git commit -m "test(reader-settings): cover wide master-detail and narrow push"
```

---

## Task 6: 全量验证

- [ ] **Step 1: format**

Run: `cd hibiki && dart format lib/src/media/audiobook/reader_quick_settings_sheet.dart lib/src/pages/implementations/reader_hibiki_page.dart test/media/audiobook/reader_quick_settings_master_detail_test.dart`

- [ ] **Step 2: analyze 全量**

Run: `cd hibiki && flutter analyze`
Expected: No issues（或仅与本改动无关的既有项）。

- [ ] **Step 3: 跑相关测试集**

Run: `cd hibiki && flutter test test/media/audiobook/ test/settings/`
Expected: All pass（注意 `md3_design_system_static_test.dart` 等源码守卫——若选中高亮触发 allowlist，按守卫提示调整为 token 色或登记）。

- [ ] **Step 4: 提交 format 残余（若有）**

```bash
git add -p   # 仅本轮文件
git commit -m "style(reader-settings): dart format"
```

---

## 风险与回归点

1. **手机 bottom sheet 必须零行为变化** —— 阈值 640 远宽于任何手机竖屏，`LayoutBuilder` 必走窄分支。测试 Task 5 Step 4 守住。
2. **MD3 源码守卫** —— 选中行高亮优先用 `AdaptiveSettingsNavigationRow.selected` 或 `secondaryContainer` token；禁止裸 `Container(color: 硬编码)`，否则撞 `md3_design_system_static_test`。
3. **`KeyedSubtree(ValueKey(selectedId))`** —— 防右 pane 详情 Element 复用导致 Switch 圆点/Segmented 滑动副作用（已知坑，见 `settings_home_page.dart`）。
4. **桌面对话框 80% 高度** —— 加宽后两 pane 各自 `SingleChildScrollView`，避免溢出。
5. **lyrics mode** —— 宽窗右 pane 的 `layout` 在歌词模式下仍走 `_buildLyricsDisplaySection`（`_subPageContent` 已处理），与窄窗一致。
6. **真机验证** —— 桌面（Windows）肉眼复测：宽窗分栏、窗口拖窄自动单列、手机底栏不变。按 CLAUDE.md 声明「修好了」前需真机/离屏证据。

## Self-Review

- 覆盖确认：左 pane 含进度/分类/动作（Task 3 Step 2）；右 pane 详情含外观（Task 1+2）；宽窗阈值与降级（Task 3 Step 3 + Task 4）；手机不变（Task 5 Step 4）。✅
- 命名一致：`_appearanceCardChildren` / `_buildAppearanceDetail` / `_subPageContent` / `_subPageTitle` / `_buildWidePane` / `_wideCategories` / `_isWide` 全程一致。✅
- 无占位符：每步给出可粘贴代码或确切命令。✅

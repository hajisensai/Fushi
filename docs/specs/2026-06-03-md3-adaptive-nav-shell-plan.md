# MD3 自适应导航外壳 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让顶层导航外壳遵循 MD3 自适应规范——底栏(<600) / 顶对齐 rail(600–1200) / 常驻 NavigationDrawer(≥1200)——消除当前 rail 居中导致的上下大空白，并让平板宽屏左侧用带文字标签的抽屉填满，解决「左右太空、对平板不友好」。

**Architecture:**
- `adaptive_navigation.dart`：① 把 `_MaterialNavCluster` 竖排从 `MainAxisAlignment.center` 改为**顶部对齐**（消除空白）；② 新增 `adaptiveNavDrawer(...)` 与 `_NavDrawerCell`，渲染「图标+文字横排」行（240dp 宽），复用现有 per-item gamepad/keyboard focus 模型（focus id 前缀 `nav-drawer`）。
- `platform_utils.dart`：新增纯函数 `shouldUseNavDrawer(double width) => width >= 1200`（M3 large 窗口宽度类边界）。不改 `WindowSizeClass` 枚举，避免破坏既有 30+ 调用点（铁律：never break userspace）。
- `home_page.dart`：`build` 的 `LayoutBuilder` 增加第三档分支；`_buildDesktopLayout` 增加 `useDrawer` 入参，宽度 ≥1200 时左栏渲染 drawer，否则 rail。`buildBody` / `_selectTab` / `reverseNavigationBar` / 设置全屏分支 / focus·gamepad 经路全部不动。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0；Material 3；项目自研 `HibikiFocus*`（gamepad/键盘焦点）；`flutter_test` widget 测试。

**Scope notes（明确不做，避免 scope creep）：**
- 抽屉是**常驻**的（≥1200 始终显示），不做「≡ 折叠/展开 rail↔drawer 切换」（需要新增 State+持久化+动画，YAGNI）。预览里的 ≡ 仅为示意，本期不渲染非功能性按钮。折叠开关列为后续可选项。
- 不恢复已被移除的宽屏 rail logo（见 memory `project_windows_titlebar_theme`「删宽屏rail logo」）。leading 槽保留但默认只放 12px 顶部留白。
- Cupertino（iPad/桌面 Cupertino）不动——本计划只改 Material 自绘导航。

---

## File Structure

| 文件 | 职责 | 改动 |
|---|---|---|
| `hibiki/lib/src/utils/adaptive/adaptive_navigation.dart` | 自绘 Material 导航（底栏/rail/**新增 drawer**） | 改 `_MaterialNavCluster` 竖排对齐；新增 `adaptiveNavDrawer` + `_NavDrawerCell` |
| `hibiki/lib/src/utils/misc/platform_utils.dart` | 窗口尺寸类/布局度量纯函数 | 新增 `shouldUseNavDrawer` |
| `hibiki/lib/src/pages/implementations/home_page.dart` | 顶层外壳：分尺寸装配导航 | `build` 第三档分支 + `_buildDesktopLayout` 增 `useDrawer` |
| `hibiki/test/widgets/material_nav_focus_test.dart` | rail/底栏焦点行为测试 | 加 rail 顶对齐断言 + drawer 焦点/选择/标签测试 |
| `hibiki/test/utils/misc/platform_layout_test.dart` | 布局度量测试 | 加 `shouldUseNavDrawer` 阈值测试 |

---

## Task 1: rail 顶部对齐（消除上下大空白）

**Files:**
- Modify: `hibiki/lib/src/utils/adaptive/adaptive_navigation.dart:130-156`
- Test: `hibiki/test/widgets/material_nav_focus_test.dart`

- [ ] **Step 1: 写失败测试**（追加到 `material_nav_focus_test.dart` 的 `main()` 末尾）

```dart
  testWidgets('rail top-aligns its destinations instead of centering',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: 0,
          rail: true,
          onTap: (_) {},
        ),
      ),
    ));
    await tester.pump();
    // 在 600px 高的 rail 里，首个目的地必须靠近顶部（< 200），而不是被居中
    // 到 ~250。这是「左右太空」里上下空白的直接守卫。
    final double firstTileTop =
        tester.getTopLeft(find.text('Books')).dy;
    expect(firstTileTop, lessThan(200),
        reason: 'rail destinations must be top-aligned, not vertically centered');
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/widgets/material_nav_focus_test.dart --no-pub`
Expected: 新测试 FAIL（当前居中，`firstTileTop` ≈ 250+，>200）。

- [ ] **Step 3: 改实现为顶部对齐**

把 `adaptive_navigation.dart` 竖排 rail（130-156 行）整段替换为：

```dart
    return Material(
      key: hibikiMaterialNavKey,
      color: colors.surface,
      child: SizedBox(
        width: 80,
        child: SafeArea(
          right: false,
          // MD3 navigation rail 把目的地组顶部对齐（可选先头 menu/FAB）。原先
          // Expanded + MainAxisAlignment.center 在只有 3 个目的地时上下留出巨大
          // 空白（「太空」的主因），改为自然顶排。
          child: Column(
            children: <Widget>[
              if (leading != null) leading! else const SizedBox(height: 12),
              for (final Widget tile in tiles)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: tile,
                ),
            ],
          ),
        ),
      ),
    );
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/widgets/material_nav_focus_test.dart --no-pub`
Expected: 全部 PASS（含既有 rail 焦点测试，未受影响）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/adaptive/adaptive_navigation.dart hibiki/test/widgets/material_nav_focus_test.dart
git commit -m "fix(nav): top-align rail destinations (kill MD3 center void)"
```

---

## Task 2: 新增 `adaptiveNavDrawer` + `_NavDrawerCell`

**Files:**
- Modify: `hibiki/lib/src/utils/adaptive/adaptive_navigation.dart`（在 `adaptiveNavRail` 函数后追加）
- Test: `hibiki/test/widgets/material_nav_focus_test.dart`

- [ ] **Step 1: 扩展测试夹具支持 drawer**

把 `material_nav_focus_test.dart` 顶部的 `contentThenBar` 签名与分支改为同时支持 `drawer`（保持 `rail` 行为不变）：

```dart
  Widget contentThenBar({
    required int index,
    required ValueChanged<int> onTap,
    bool rail = false,
    bool drawer = false,
  }) {
    final Widget nav = Builder(
      builder: (BuildContext context) {
        if (drawer) {
          return adaptiveNavDrawer(
            context: context,
            currentIndex: index,
            onTap: onTap,
            items: items,
          );
        }
        return rail
            ? adaptiveNavRail(
                context: context,
                currentIndex: index,
                onTap: onTap,
                items: items,
              )
            : adaptiveBottomBar(
                context: context,
                currentIndex: index,
                onTap: onTap,
                items: items,
              );
      },
    );
    return HibikiFocusRoot(
      child: SizedBox(
        width: 320,
        height: 600,
        child: Column(
          children: <Widget>[
            const HibikiFocusTarget(
              id: HibikiFocusId('content'),
              child: SizedBox(width: 320, height: 120),
            ),
            if (rail || drawer) Expanded(child: nav) else nav,
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 2: 写失败测试**（追加到 `main()` 末尾）

```dart
  testWidgets('drawer registers one focus target per destination and shows labels',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          drawer: true,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    // 抽屉每行都显示文字标签（这是它区别于 icon-only rail 的关键）。
    expect(find.text('Books'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column).first),
    );
    controller.requestById(const HibikiFocusId('nav-drawer-0'));
    await tester.pump();
    // 竖排：Down 步进到下一行，且不切换 tab。
    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('nav-drawer-1'));
    expect(index, 0, reason: 'stepping focus does not select');
  });

  testWidgets('tapping a drawer row selects that destination',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          drawer: true,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(index, 2);
  });
```

- [ ] **Step 3: 跑测试确认失败**

Run: `flutter test test/widgets/material_nav_focus_test.dart --no-pub`
Expected: FAIL，报 `adaptiveNavDrawer` 未定义。

- [ ] **Step 4: 写实现**（在 `adaptive_navigation.dart` 中 `adaptiveNavRail` 函数闭合 `}` 之后追加）

```dart
/// Self-drawn Material navigation DRAWER (persistent, shown at large widths,
/// see [shouldUseNavDrawer]). Each destination is a full-width icon+label row
/// inside a `secondaryContainer` pill when selected. Mirrors [adaptiveNavRail]'s
/// per-item gamepad/keyboard focus model (`nav-drawer-N` ids) so the app focus
/// ring hugs one row; [items]/[currentIndex] are in visual order and [onTap]
/// receives the visual index (caller keeps its visual->logical mapping).
Widget adaptiveNavDrawer({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
  Widget? leading,
}) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  final List<Widget> rows = <Widget>[
    for (int i = 0; i < items.length; i++)
      _NavDrawerCell(
        id: HibikiFocusId('nav-drawer-$i'),
        item: items[i],
        selected: i == currentIndex,
        onSelect: () => onTap(i),
      ),
  ];
  return Material(
    key: hibikiMaterialNavKey,
    color: colors.surface,
    child: SizedBox(
      width: 240,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (leading != null) leading! else const SizedBox(height: 12),
            for (final Widget row in rows)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                child: row,
              ),
          ],
        ),
      ),
    ),
  );
}

/// One Material drawer destination: an icon+label row in a selectable pill,
/// wrapped as an independent gamepad/keyboard focus target (the ring frames the
/// whole row). A/Enter resolve to [ActivateIntent] (mapped to [onSelect]); a
/// mouse/touch tap calls it directly. The [InkWell] does not request focus.
class _NavDrawerCell extends StatelessWidget {
  const _NavDrawerCell({
    required this.id,
    required this.item,
    required this.selected,
    required this.onSelect,
  });

  final HibikiFocusId id;
  final AdaptiveNavItem item;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onSelect();
            return null;
          },
        ),
      },
      child: InkWell(
        onTap: onSelect,
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(28),
        child: HibikiFocusTarget(
          id: id,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color:
                  selected ? colors.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? (item.selectedIcon ?? item.icon) : item.icon,
                  size: 24,
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelLarge?.copyWith(
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/widgets/material_nav_focus_test.dart --no-pub`
Expected: 全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/utils/adaptive/adaptive_navigation.dart hibiki/test/widgets/material_nav_focus_test.dart
git commit -m "feat(nav): add MD3 persistent navigation drawer (icon+label rows)"
```

---

## Task 3: `shouldUseNavDrawer` 宽度阈值

**Files:**
- Modify: `hibiki/lib/src/utils/misc/platform_utils.dart`（紧接 `windowSizeClassFromContext` 之后，56 行附近）
- Test: `hibiki/test/utils/misc/platform_layout_test.dart`

- [ ] **Step 1: 写失败测试**（追加到 `platform_layout_test.dart` 的 `main()` 内，`windowSizeClassOf` group 之后）

```dart
  group('shouldUseNavDrawer', () {
    test('switches to a persistent drawer at the 1200dp large boundary', () {
      expect(shouldUseNavDrawer(1199), isFalse);
      expect(shouldUseNavDrawer(1200), isTrue);
      expect(shouldUseNavDrawer(1600), isTrue);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/utils/misc/platform_layout_test.dart --no-pub`
Expected: FAIL，报 `shouldUseNavDrawer` 未定义。

- [ ] **Step 3: 写实现**（在 `platform_utils.dart` 的 `windowSizeClassFromContext` 函数闭合 `}` 之后追加，约 56 行后）

```dart
/// At very large widths MD3 recommends a persistent navigation DRAWER (icon +
/// label rows) instead of the icon-only rail. 1200dp is the M3 "large" window
/// width-class boundary; below it the rail (>=600) or bottom bar (<600) applies.
bool shouldUseNavDrawer(double width) => width >= 1200;
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/utils/misc/platform_layout_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/platform_utils.dart hibiki/test/utils/misc/platform_layout_test.dart
git commit -m "feat(nav): add shouldUseNavDrawer 1200dp breakpoint helper"
```

---

## Task 4: home_page 装配 rail↔drawer

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart:292-303`（`build` 的 `LayoutBuilder`）
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart:326-381`（`_buildDesktopLayout`）

> 说明：`_HomePageState` 依赖完整 `appModel` 初始化，widget 测试成本高；本任务的逻辑分支由 Task 3 的 `shouldUseNavDrawer` 单测覆盖，装配正确性在 Step 4 的设备验证里确认。不写 home_page widget 测试（避免引入脆弱的全初始化夹具）。

- [ ] **Step 1: 改 `build` 的 LayoutBuilder 分支**

把 `home_page.dart` 292-301 行的 `LayoutBuilder` body：

```dart
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final sizeClass = windowSizeClassOf(constraints);
                    // compact(<600) → 底栏；medium/expanded(≥600，含竖屏平板) → 侧边布局。
                    if (sizeClass == WindowSizeClass.compact) {
                      return _buildMobileLayout();
                    }
                    return _buildDesktopLayout(sizeClass);
                  },
                ),
```

替换为：

```dart
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final sizeClass = windowSizeClassOf(constraints);
                    // compact(<600) → 底栏；medium/expanded(≥600) → 侧边布局；
                    // large(≥1200) → 侧栏升级为带文字标签的常驻 NavigationDrawer。
                    if (sizeClass == WindowSizeClass.compact) {
                      return _buildMobileLayout();
                    }
                    return _buildDesktopLayout(
                      sizeClass,
                      useDrawer: shouldUseNavDrawer(constraints.maxWidth),
                    );
                  },
                ),
```

- [ ] **Step 2: 改 `_buildDesktopLayout` 签名与左栏装配**

把 `_buildDesktopLayout(WindowSizeClass sizeClass) {` 改为：

```dart
  Widget _buildDesktopLayout(
    WindowSizeClass sizeClass, {
    required bool useDrawer,
  }) {
```

并把该方法里 `Row` 中 `adaptiveNavRail(...)` 调用（368-373 行）那段：

```dart
              child: adaptiveNavRail(
                context: context,
                currentIndex: visualIndex,
                onTap: selectVisual,
                items: displayItems,
              ),
```

替换为：

```dart
              child: useDrawer
                  ? adaptiveNavDrawer(
                      context: context,
                      currentIndex: visualIndex,
                      onTap: selectVisual,
                      items: displayItems,
                    )
                  : adaptiveNavRail(
                      context: context,
                      currentIndex: visualIndex,
                      onTap: selectVisual,
                      items: displayItems,
                    ),
```

> 设置全屏分支（327 行 `if (_currentTab == 2 ...)`）、`reversed`/`visualIndex`/`selectVisual`、`VerticalDivider`、`Expanded(child: buildBody())` 全部保持不变。

- [ ] **Step 3: analyze + 全量测试**

Run:
```bash
cd hibiki
dart format .
flutter analyze
flutter test --no-pub
```
Expected: analyze 无 error；全部测试 PASS（含 Task1-3 新增）。

- [ ] **Step 4: 设备/真窗复测（必做，按 CLAUDE.md「布局问题声明修好前须真机复测」）**

在桌面真窗（Windows）或平板模拟器上验证三档过渡：
1. 窗口拉到 <600：底栏。
2. 600–1199：rail，目的地**顶部对齐**、上方无大空白。
3. ≥1200：左侧变为带「书架/词典管理/设置」文字标签的常驻抽屉，左侧不再「太空」。
4. 在每档下点击切 tab、键盘方向键/手柄 D-pad 上下步进、A/Enter 选择都正常；`reverseNavigationBar` 开启时顺序与高亮正确。

留证据（截图）到 `.codex-test/`（不入库）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/pages/implementations/home_page.dart
git commit -m "feat(nav): use MD3 drawer at >=1200dp, rail at 600-1200dp"
```

---

## Task 5: 按 docs/BUGS.md 记录（若用户把「太空」当 bug 跟踪）

> 本项是 UI 改进而非缺陷；如需登记到 `docs/BUGS.md`，按其流程追加一条，根因记 `adaptive_navigation.dart:141 (MainAxisAlignment.center)` + `home_page.dart` 缺 ≥1200 抽屉档，①修复勾 Task1/4 提交哈希，②自动测试勾 `material_nav_focus_test.dart` / `platform_layout_test.dart`。否则跳过。

---

## Self-Review

**1. Spec coverage：**
- 「rail 上下太空」→ Task 1（顶部对齐）✅
- 「平板宽屏左右太空」→ Task 2+3+4（≥1200 常驻抽屉填满左栏）✅
- 「参考 MD3/谷歌 MD3」→ 窗口尺寸类映射（底栏/rail/drawer）+ rail 顶对齐 + secondaryContainer pill ✅
- 用户选②「完整 MD3 自适应」→ 含 drawer 组件 + home_page 断点装配 ✅
- 向后兼容：不改 `WindowSizeClass` 枚举、不动 Cupertino、不动 focus/gamepad 契约、设置全屏分支不变 ✅

**2. Placeholder scan：** 无 TBD/TODO；每个代码步骤含完整代码与确切命令。✅

**3. Type consistency：**
- focus id 前缀 `nav-drawer-N`（Task 2 实现 = Task 2 测试 = 一致）✅
- `adaptiveNavDrawer(context/currentIndex/onTap/items/leading)` 签名与 `adaptiveNavRail` 对齐，home_page 调用一致 ✅
- `shouldUseNavDrawer(double) -> bool`（Task 3 定义 = Task 4 调用 = Task 3 测试 一致）✅
- `_NavDrawerCell(id/item/selected/onSelect)` 字段在实现内自洽 ✅
- `_buildDesktopLayout(WindowSizeClass, {required bool useDrawer})`（Task 4 Step1 调用 = Step2 定义 一致）✅

无遗漏。

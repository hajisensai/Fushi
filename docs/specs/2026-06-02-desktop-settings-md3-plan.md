# 桌面端设置 MD3 打磨 实现计划（方案 B）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Windows/Linux 桌面 Material 路径的设置页（已是 list-detail 两栏）打磨成地道 MD3：两栏色调区分、选中态圆角胶囊、去误导 chevron、详情区加宽、栏间距对齐。

**Architecture:** 不重写结构（结构已是 MD3 推荐的 Pattern A）。表面级改动分散在 4 个文件，每个任务独立可验证。macOS（Cupertino）与移动端紧凑布局不受影响。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0、Material 3、`HibikiDesignTokens`、Riverpod。

> 设计源文档：`docs/specs/2026-06-02-desktop-settings-md3-design.md`
> 关键约束（来自现有静态测试，违反即红）：
> - `material_settings_renderer.dart` 必须保留 `HibikiListItem`/`AdaptiveSettingsSection`/`HibikiPageScaffold`/`AdaptiveSettingsSwitchRow`/`AdaptiveSettingsSegmentedRow`/`AdaptiveSettingsSliderRow`/`HibikiDesignTokens.of(context)`。
> - 渲染器内**禁止硬编码 `EdgeInsets`**（如 `const EdgeInsets.symmetric(horizontal: 16`、`EdgeInsets.fromLTRB(16, 8, 16, 16)` 等已被 `isNot(contains(...))` 断言禁止）→ 一切间距走 `tokens.spacing.*`。
> - `settings_home_page.dart` 必须保留 `HibikiPageHeader`、`DesktopContentKind.settings`、`master-detail` 字样。

**对 design 的一处刻意细化（②）：** 选中圆角胶囊用**新增 `selectedShape` 参数**（默认 `fill` 保持现状）实现，仅设置导航列表启用 `pill`，而非改 `HibikiListItem` 全局默认。理由：`HibikiListItem` 是全仓共享组件，改默认会波及书架/词典/统计等所有选中列表并冲掉现有 golden；导航选中（胶囊）与平铺列表选中（满宽）本就是 MD3 里两种正当语境。fill 路径保持逐像素不变 → 现有 golden 不动。

---

## 文件结构

| 文件 | 改动 | 任务 |
|---|---|---|
| `hibiki/lib/src/utils/misc/platform_utils.dart` | ④ settings 限宽 760→960 | Task 1 |
| `hibiki/lib/src/settings/material_settings_renderer.dart` | ③ chevron 仅 push 模式；⑤ 详情贴线侧 token 内缩 | Task 2、Task 5 |
| `hibiki/lib/src/utils/components/hibiki_material_components.dart` | ② `HibikiListItem` 新增 `selectedShape` + pill 渲染 | Task 3 |
| `hibiki/lib/src/settings/settings_home_page.dart` | ① 导航窗格 `surfaceContainerLow` 背景（Material 门控）；导航列表传 `selectedShape: pill` | Task 4 |
| `hibiki/test/...` | 新增/更新断言 | 各任务内 |

> 注：导航列表由 `MaterialSettingsRenderer.buildDestinationList` 渲染，但 `selectedShape: pill` 只该在桌面 master-detail（`pushRoutes:false`）时启用。故在 `buildDestinationList` 内用 `pushRoutes` 推导：`pushRoutes ? fill : pill`（窄屏 push 列表保持满宽 fill，宽屏窗格内导航用胶囊）。

---

## Task 1：④ 加宽 settings 详情区（760→960）

**Files:**
- Modify: `hibiki/lib/src/utils/misc/platform_utils.dart:54`
- Test: `hibiki/test/utils/platform_utils_settings_width_test.dart`（若不存在则创建；存在则加用例）

- [ ] **Step 1: 写失败测试**

创建 `hibiki/test/utils/platform_utils_settings_width_test.dart`：

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

void main() {
  test('settings detail pane is widened for desktop balance', () {
    expect(
      desktopContentMaxWidth(
        WindowSizeClass.expanded,
        DesktopContentKind.settings,
      ),
      960,
    );
  });

  test('compact returns null (no cap) for settings', () {
    expect(
      desktopContentMaxWidth(
        WindowSizeClass.compact,
        DesktopContentKind.settings,
      ),
      isNull,
    );
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/utils/platform_utils_settings_width_test.dart --no-pub`
Expected: FAIL（当前返回 760，期望 960）

- [ ] **Step 3: 改实现**

`platform_utils.dart` `desktopContentMaxWidth` 内：

```dart
    DesktopContentKind.settings => 960,
```

（原 `DesktopContentKind.settings => 760,`）

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/utils/platform_utils_settings_width_test.dart --no-pub`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/platform_utils.dart hibiki/test/utils/platform_utils_settings_width_test.dart
git commit -m "feat(settings): widen desktop settings detail pane to 960 (MD3 list-detail)"
```

---

## Task 2：③ 去掉 master-detail 侧栏的误导 chevron

**Files:**
- Modify: `hibiki/lib/src/settings/material_settings_renderer.dart:65`
- Test: `hibiki/test/settings/settings_renderer_test.dart`（加一条 widget 断言；若结构不便，改用静态源断言）

- [ ] **Step 1: 写失败测试**

在 `hibiki/test/settings/settings_renderer_test.dart` 末尾（`main()` 内）追加：

```dart
  testWidgets('master-detail destination list shows no trailing chevron',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: const MaterialSettingsRenderer().buildDestinationList(
                settingsContext: makeTestSettingsContext(context),
                destinations: testDestinations,
                selectedDestinationId: testDestinations.first.id,
                onDestinationSelected: (_) {},
                pushRoutes: false,
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });
```

> 若 `settings_renderer_test.dart` 已有可复用的 `makeTestSettingsContext` / `testDestinations` 辅助，直接复用；没有则改为最简静态断言（更稳，无需构造 SettingsContext）：
>
> ```dart
>   test('destination list gates chevron on pushRoutes', () {
>     final String source =
>         File('lib/src/settings/material_settings_renderer.dart')
>             .readAsStringSync();
>     expect(source, contains('pushRoutes ? const Icon(Icons.chevron_right)'));
>   });
> ```
>
> 二选一即可，优先 widget 断言；若构造成本高则用静态断言。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/settings/settings_renderer_test.dart --no-pub`
Expected: FAIL（当前 chevron 恒显）

- [ ] **Step 3: 改实现**

`material_settings_renderer.dart` `buildDestinationList` 的 `HibikiListItem` 中：

```dart
          trailing:
              pushRoutes ? const Icon(Icons.chevron_right) : null,
```

（原 `trailing: const Icon(Icons.chevron_right),`）

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/settings/settings_renderer_test.dart --no-pub`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/settings/material_settings_renderer.dart hibiki/test/settings/settings_renderer_test.dart
git commit -m "fix(settings): drop misleading chevron in master-detail destination list"
```

---

## Task 3：② `HibikiListItem` 选中圆角胶囊（新增 `selectedShape`，默认不变）

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart:109-248`
- Test: `hibiki/test/widgets/hibiki_list_item_selected_shape_test.dart`（新建）

- [ ] **Step 1: 写失败测试**

新建 `hibiki/test/widgets/hibiki_list_item_selected_shape_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('pill selected shape renders a rounded highlight', (tester) async {
    await tester.pumpWidget(_host(
      HibikiListItem(
        title: const Text('基础'),
        selected: true,
        selectedShape: HibikiListItemSelectedShape.pill,
        onTap: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final BoxDecoration decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, isNotNull);
    expect(container.margin, isNot(EdgeInsets.zero));

    final InkWell ink = tester.widget<InkWell>(find.byType(InkWell));
    expect(ink.borderRadius, isNotNull);
  });

  testWidgets('default fill shape keeps square full-bleed highlight',
      (tester) async {
    await tester.pumpWidget(_host(
      HibikiListItem(
        title: const Text('基础'),
        selected: true,
        onTap: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(container.decoration, isNull); // fill 走 color:，非 decoration
    expect(container.margin, EdgeInsets.zero);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/widgets/hibiki_list_item_selected_shape_test.dart --no-pub`
Expected: FAIL（`selectedShape` 参数与 `HibikiListItemSelectedShape` 尚不存在 → 编译错误）

- [ ] **Step 3: 改实现**

在 `hibiki_material_components.dart` `HibikiListItem` 上方加枚举：

```dart
/// 选中态高亮形状：fill = 满宽方角（平铺列表），pill = 内缩圆角（导航列表）。
enum HibikiListItemSelectedShape { fill, pill }
```

构造函数与字段新增（保持默认 `fill`）：

```dart
    this.selectedShape = HibikiListItemSelectedShape.fill,
```
```dart
  final HibikiListItemSelectedShape selectedShape;
```

`_HibikiListItemState.build` 内，把构造 `material` 的 `AnimatedContainer` 改为按形状分支（其余不变）：

```dart
    final bool pill =
        widget.selectedShape == HibikiListItemSelectedShape.pill;
    final BorderRadius? highlightRadius =
        pill ? tokens.radii.groupRadius : null;
    final Widget material = AnimatedContainer(
      duration: hibikiMd3StateDuration,
      curve: hibikiMd3StateCurve,
      margin: pill
          ? EdgeInsets.symmetric(horizontal: tokens.spacing.gap)
          : EdgeInsets.zero,
      color: pill ? null : color,
      decoration: pill
          ? BoxDecoration(color: color, borderRadius: highlightRadius)
          : null,
      child: Material(
        type: MaterialType.transparency,
        child: widget.onTap == null
            ? content
            : InkWell(
                onTap: widget.onTap,
                borderRadius: highlightRadius,
                child: content,
              ),
      ),
    );
```

> 说明：fill 路径仍用 `color:`（逐像素同旧实现，golden 不变）；pill 路径用 `decoration` 上圆角 + `margin` 内缩 + `InkWell.borderRadius` 裁水波。

- [ ] **Step 4: 跑测试确认通过 + 现有 golden 不回归**

Run: `flutter test test/widgets/hibiki_list_item_selected_shape_test.dart test/goldens/hibiki_list_tile_golden_test.dart test/goldens/hibiki_list_tile_extended_golden_test.dart --no-pub`
Expected: PASS（新测试过；两个 golden 因 fill 路径未变而不回归）

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/components/hibiki_material_components.dart hibiki/test/widgets/hibiki_list_item_selected_shape_test.dart
git commit -m "feat(ui): add pill selected shape to HibikiListItem (MD3 nav highlight)"
```

---

## Task 4：① 两栏色调区分 + 导航列表启用 pill

**Files:**
- Modify: `hibiki/lib/src/settings/settings_home_page.dart:124-145`（窗格背景）
- Modify: `hibiki/lib/src/settings/material_settings_renderer.dart:59`（导航 `HibikiListItem` 传 `selectedShape`）
- Test: `hibiki/test/settings/settings_redesign_static_test.dart`（加断言）

- [ ] **Step 1: 写失败测试**

在 `settings_redesign_static_test.dart` 的 `main()` 内追加：

```dart
  test('wide settings nav pane gets a tonal container background (material only)',
      () {
    final String source =
        readNormalizedSource('lib/src/settings/settings_home_page.dart');
    expect(source, contains('surfaceContainerLow'));
    expect(source, contains('isCupertinoPlatform(context)'));
  });

  test('material destination list uses pill selected shape for master-detail',
      () {
    final String source = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');
    expect(source, contains('HibikiListItemSelectedShape'));
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/settings/settings_redesign_static_test.dart --no-pub`
Expected: FAIL（两个新串都还不存在）

- [ ] **Step 3a: 改 `settings_home_page.dart` `_buildWideLayout`**

把导航窗格的 `SizedBox` 包一层带背景的 `ColoredBox`/`Container`，仅 Material 路径上色（`cupertino` 变量当前函数内已有）：

```dart
    final Color? navPaneColor = cupertino
        ? null
        : Theme.of(context).colorScheme.surfaceContainerLow;
    return Row(
      children: <Widget>[
        Container(
          width: 280,
          color: navPaneColor,
          child: renderer.buildDestinationList(
            settingsContext: settingsContext,
            destinations: destinations,
            selectedDestinationId: _selectedDestinationId,
            onDestinationSelected: _selectDestination,
            pushRoutes: false, // master-detail keeps selection in-pane.
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: dividerColor),
        Expanded(
          child: renderer.buildDetailContent(
            settingsContext: settingsContext,
            destination: selected,
          ),
        ),
      ],
    );
```

（原本是 `SizedBox(width: 280, child: ...)`；替换为上面的 `Container(width: 280, color: navPaneColor, child: ...)`，其余行不变。）

- [ ] **Step 3b: 改 `material_settings_renderer.dart` `buildDestinationList` 的 `HibikiListItem`**

加一行 `selectedShape`：

```dart
        return HibikiListItem(
          selected: selected,
          selectedShape: pushRoutes
              ? HibikiListItemSelectedShape.fill
              : HibikiListItemSelectedShape.pill,
          leading: Icon(destination.icon),
          title: Text(destination.title),
          subtitle:
              destination.summary != null ? Text(destination.summary!) : null,
          trailing:
              pushRoutes ? const Icon(Icons.chevron_right) : null,
          onTap: () {
```

> 需确保 `material_settings_renderer.dart` 顶部已 import `hibiki_material_components.dart`（现有代码已 import，`HibikiListItem` 即来自此文件，枚举同文件，无需新增 import）。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/settings/settings_redesign_static_test.dart test/settings/md3_design_system_static_test.dart --no-pub`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/settings/settings_home_page.dart hibiki/lib/src/settings/material_settings_renderer.dart hibiki/test/settings/settings_redesign_static_test.dart
git commit -m "feat(settings): tonal nav pane + pill selection for desktop list-detail (MD3)"
```

---

## Task 5：⑤ 详情窗格贴线侧内缩（token 化，禁硬编码 EdgeInsets）

**Files:**
- Modify: `hibiki/lib/src/settings/material_settings_renderer.dart:107-115`（`buildDetailContent` 的 `ListView.builder` padding）
- Test: 复用 Task 2 的 `settings_renderer_test.dart`「禁硬编码 EdgeInsets」既有断言 + `flutter analyze`

- [ ] **Step 1: 改实现**

`buildDetailContent` 当前左右 padding 都用 `tokens.spacing.page`(16)；让左侧（贴分隔线一侧）多一个 `tokens.spacing.gap` 的呼吸感，凑近 MD3 expanded 24：

```dart
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page + tokens.spacing.gap,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page + mediaPadding.bottom,
      ),
```

（原左值为 `tokens.spacing.page`；改为 `tokens.spacing.page + tokens.spacing.gap` = 16+8=24。全部走 token，不触发「禁硬编码 EdgeInsets」断言。）

- [ ] **Step 2: 跑相关测试 + 分析**

Run: `flutter test test/settings/ --no-pub && flutter analyze lib/src/settings/material_settings_renderer.dart`
Expected: PASS / No issues

- [ ] **Step 3: 提交**

```bash
git add hibiki/lib/src/settings/material_settings_renderer.dart
git commit -m "style(settings): give detail pane 24dp inset against divider (MD3 spacing)"
```

---

## Task 6：全量验证 + 设备复测

**Files:** 无（仅验证）

- [ ] **Step 1: 格式化**

Run（在 `hibiki/` 下）: `dart format .`
Expected: 仅格式化本轮新增/改动文件，无意外大改

- [ ] **Step 2: 全量单测**

Run（在 `hibiki/` 下）: `flutter test --no-pub`
Expected: 全绿。重点确认 `test/settings/*`、`test/goldens/hibiki_list_tile*`、`test/widgets/hibiki_list_item_selected_shape_test.dart`、`test/pages/*md3*` 通过。

- [ ] **Step 3: 静态分析**

Run（在 `hibiki/` 下）: `flutter analyze`
Expected: No issues found

- [ ] **Step 4: 设备复测（Windows 桌面，真实路径）**

按 [docs/agent/integration-testing.md] 在 Windows 桌面运行，打开设置页（窗口拉宽至 ≥960）核对：
1. 左导航窗格有 `surfaceContainerLow` 底色，与右详情 `surface` 有可见色差；
2. 选中分组是**内缩圆角胶囊**高亮，水波不溢出圆角；
3. 导航项右侧**无 chevron**；
4. 详情区比之前更宽（详情贴分隔线侧有呼吸间距）；
5. 把窗口缩到 <720 → 回到单栏 push 模式，此时 chevron 恢复、选中态为满宽 fill。
留截图证据到 `.codex-test/`。

- [ ] **Step 5: macOS 回归确认（如手头有 Mac）**

macOS 设置页走 Cupertino，应**无任何变化**（无 surfaceContainer 底色、无圆角胶囊）。若无 Mac 设备，至少静态确认 `_buildWideLayout` 的 `navPaneColor` 在 `cupertino==true` 时为 `null`，逻辑上不影响 Cupertino 路径。

- [ ] **Step 6: 终验提交（若 format 产生改动）**

```bash
git add -u hibiki/
git commit -m "chore(settings): dart format after MD3 desktop polish"
```

（仅当 format 改了文件时执行；提交前 `git status --short` 确认只含本轮文件。）

---

## 自检对照（计划 vs 设计）

- ① 两栏色调 → Task 4（Material 门控，Cupertino 不上色）✓
- ② 选中圆角胶囊 → Task 3（新增 `selectedShape`，默认不变）+ Task 4（导航启用 pill）✓
- ③ 去 chevron → Task 2 ✓
- ④ 详情加宽 760→960 → Task 1 ✓
- ⑤ 栏间距 24 → Task 5（token 化）✓
- 明确不做（底部操作栏/右对齐表单/去图标）→ 计划中无对应任务 ✓
- macOS 不动 → Task 4 `cupertino` 门控 + Task 6 Step 5 回归确认 ✓
- 静态测试约束（保留必需串、禁硬编码 EdgeInsets）→ Task 2/4/5 已规避 ✓
- golden 不回归 → Task 3 fill 路径逐像素不变 ✓

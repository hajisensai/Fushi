# 宽屏设置二栏 + 竖屏平板隐藏底栏 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development 或 superpowers:executing-plans 按任务实现。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 宽屏下进入「设置」标签时隐藏 3 图标侧栏、呈现参考图式 `[分类列表][详情]` 2 栏并带返回箭头；同时让宽≥600 的竖屏平板也用侧边布局（不再显示底栏）。

**Architecture:** 改动集中在顶层外壳 `home_page.dart`（移除竖屏底栏特例 + 设置 tab 走「全屏二栏 + 返回」分支 + 提取统一 `_selectTab` 记录来源 tab），并给 `HibikiSettingsContent` / `SettingsHomePage` 增加可选 `onBack` 回调，由 `HibikiPageHeader.leading` 渲染返回箭头。设置内部的二栏（`MaterialSupportingPaneLayout`，断点 720）已存在，复用不动。

**Tech Stack:** Flutter 3.44 / Dart / Riverpod / 现有 `windowSizeClassOf` 断点体系 / Slang i18n（`t.back` 已存在）。

---

## 背景事实（已存在，不重写）

- `home_page.dart:295-308` 用 `windowSizeClassOf(constraints)` 在 compact(<600) / 竖屏特例 → `_buildMobileLayout()`（底栏），否则 `_buildDesktopLayout()`（3 图标侧栏 + body）。
- `home_page.dart:332-372` desktop：`Row[ adaptiveNavRail, VerticalDivider, Expanded(buildBody()) ]`。`buildBody()` tab2 → `const HibikiSettingsContent()`。
- 设置二栏：`settings_home_page.dart:110-147` `_buildWideLayout` → `MaterialSupportingPaneLayout(minSplitWidth:720, supportingSide:start)`，宽<720 走 `renderer.buildHomePage`（单栏列表 push 详情）。
- `HibikiPageHeader`（`hibiki_material_components.dart:1171`）已支持 `leading`/`actions`。
- `HibikiSettingsContent`（`hibiki_settings_page.dart:112-119`）= `SettingsHomePage(embedded:true)`。
- `t.back` = "Back" 已存在，无需新增 i18n。

## 范围外（本次不做）

- 参考图右上的「设置内搜索」功能：独立特性，工作量大，本次不做（不放无效按钮）。
- Cupertino（iOS/macOS）路径：保持现状不动，返回箭头只在 Material 侧栏外壳生效。

---

## Task 1: 提取统一 `_selectTab` 并记录来源 tab

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`

- [ ] **Step 1: 加字段 `_previousTab`**

在 `_currentTab` 字段附近新增：

```dart
/// 进入「设置」标签前的来源 tab，供设置全屏左上返回箭头切回。
int _previousTab = 0;
```

- [ ] **Step 2: 新增统一切换方法**

在 state 内新增（替代 desktop/mobile 各自重复的 setState 逻辑）：

```dart
void _selectTab(int logicalIndex) {
  setState(() {
    if (logicalIndex == 2 && _currentTab != 2) {
      _previousTab = _currentTab;
    }
    _currentTab = logicalIndex;
  });
  if (logicalIndex == 0) _loadIconPreset();
}
```

- [ ] **Step 3: desktop 的 `selectVisual` 改用 `_selectTab`**

`_buildDesktopLayout` 内（约 340-344 行）：

```dart
void selectVisual(int index) {
  final int logicalIndex = reversed ? (items.length - 1 - index) : index;
  _selectTab(logicalIndex);
}
```

- [ ] **Step 4: mobile 的 `onTap` 改用 `_selectTab`**

`_buildMobileLayout` 内（约 388-393 行）：

```dart
onTap: (int index) {
  final int logicalIndex = reversed ? (items.length - 1 - index) : index;
  _selectTab(logicalIndex);
},
```

- [ ] **Step 5: `flutter analyze` 通过，提交**

```bash
cd hibiki && dart format lib/src/pages/implementations/home_page.dart && flutter analyze lib/src/pages/implementations/home_page.dart
git add lib/src/pages/implementations/home_page.dart
git commit -m "refactor(home): unify tab selection + track previous tab"
```

---

## Task 2: 设置标签下隐藏图标侧栏，全屏二栏 + 返回箭头

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/hibiki_settings_page.dart`
- Modify: `hibiki/lib/src/settings/settings_home_page.dart`

- [ ] **Step 1: `SettingsHomePage` 增加 `onBack`**

`settings_home_page.dart` 构造器与字段：

```dart
const SettingsHomePage({
  super.key,
  this.embedded = false,
  this.onBack,
});

final bool embedded;
final VoidCallback? onBack;
```

`_buildEmbeddedMaterialShell` 的 `HibikiPageHeader` 加 leading（约 104 行）：

```dart
HibikiPageHeader(
  title: t.settings,
  leading: widget.onBack != null
      ? IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: t.back,
          onPressed: widget.onBack,
        )
      : null,
),
```

- [ ] **Step 2: `HibikiSettingsContent` 透传 `onBack`**

`hibiki_settings_page.dart:112-119`：

```dart
class HibikiSettingsContent extends StatelessWidget {
  const HibikiSettingsContent({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SettingsHomePage(embedded: true, onBack: onBack);
  }
}
```

- [ ] **Step 3: `_buildDesktopLayout` 在设置 tab 走全屏分支**

`home_page.dart` `_buildDesktopLayout` 开头（`reversed`/`items` 计算之前可提前 return）插入：

```dart
if (_currentTab == 2) {
  // 设置标签：隐藏 3 图标侧栏，全屏二栏（内部 MaterialSupportingPaneLayout），
  // 左上返回箭头切回来源 tab（参考 Mihon 宽屏设置）。
  return Scaffold(
    resizeToAvoidBottomInset: false,
    body: SafeArea(
      child: FocusTraversalGroup(
        child: HibikiSettingsContent(
          onBack: () => _selectTab(_previousTab),
        ),
      ),
    ),
  );
}
```

> 此后原有 `Row[rail, divider, Expanded(buildBody())]` 分支只会处理 tab 0/1，无需改动其余代码。`buildBody()` tab2 分支保留（mobile/compact 底栏模式仍用它，无 onBack → 无返回箭头，靠底栏切换）。

- [ ] **Step 4: `flutter analyze` 通过**

```bash
cd hibiki && dart format lib/src/pages/implementations/home_page.dart lib/src/pages/implementations/hibiki_settings_page.dart lib/src/settings/settings_home_page.dart && flutter analyze lib
```
Expected: No issues。

- [ ] **Step 5: 提交**

```bash
git add lib/src/pages/implementations/home_page.dart lib/src/pages/implementations/hibiki_settings_page.dart lib/src/settings/settings_home_page.dart
git commit -m "feat(home): widescreen settings hides icon rail, two-pane with back"
```

---

## Task 3: 竖屏平板（宽≥600）也隐藏底栏改侧栏

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`

- [ ] **Step 1: 移除竖屏底栏特例**

`home_page.dart` build 的 `LayoutBuilder`（约 295-307）改为：

```dart
child: LayoutBuilder(
  builder: (context, constraints) {
    final sizeClass = windowSizeClassOf(constraints);
    if (sizeClass == WindowSizeClass.compact) {
      return _buildMobileLayout();
    }
    return _buildDesktopLayout(sizeClass);
  },
),
```

> 删除原 `if (!isDesktopPlatform && constraints.maxWidth <= constraints.maxHeight) return _buildMobileLayout();`。效果：宽≥600（medium/expanded）一律侧边布局（含竖屏平板），宽<600 仍底栏。符合 MD3：compact→bottom bar，medium/expanded→rail。

- [ ] **Step 2: `flutter analyze` 通过，提交**

```bash
cd hibiki && dart format lib/src/pages/implementations/home_page.dart && flutter analyze lib/src/pages/implementations/home_page.dart
git add lib/src/pages/implementations/home_page.dart
git commit -m "feat(home): portrait tablets (>=600) use side layout, no bottom bar"
```

---

## Task 4: 测试与验证

**Files:**
- 检查/可能修改: `hibiki/test/settings/settings_redesign_static_test.dart`
- 检查/可能修改: `hibiki/test/utils/misc/platform_layout_test.dart`

- [ ] **Step 1: 跑相关静态/布局测试**

```bash
cd hibiki && flutter test test/settings/ test/utils/misc/platform_layout_test.dart
```
若有断言「竖屏走 mobile」或「设置布局含 rail」之类与新行为冲突，按新行为修正断言（不是绕过——确认新行为是预期后更新期望值）。

- [ ] **Step 2: 全量测试**

```bash
cd hibiki && flutter test
```
Expected: 全绿。

- [ ] **Step 3: 真机/模拟器肉眼复测（reader-debugging 规则：UI 改动声明修好前必须设备复测）**

验证三种形态：
1. 横屏宽屏（expanded ≥840）：设置标签隐藏图标侧栏，左 [分类列表] 右 [详情] 2 栏，左上返回箭头 → 点击回到书架/词典。
2. 竖屏平板（medium 600-840）：无底栏、有图标侧栏；进设置隐藏侧栏，宽<720 时设置为单栏列表 push 详情，header 有返回箭头。
3. 手机竖屏（compact <600）：保持底栏，设置仍是底栏 tab、无返回箭头。

并验证手柄/键盘焦点能到达设置全屏的返回箭头（rail 移除后焦点树变化）。留截图证据到 `.codex-test/`。

---

## 影响范围与风险

- **向后兼容**：横屏宽屏外壳、手机底栏行为不变；仅竖屏平板（600+）和设置标签外观改变，均为用户明确要求。
- **导航可达性**：设置全屏隐藏 rail 后只能靠返回箭头退出 → 必须确保返回箭头在焦点树、手柄可达（Task 4 Step 3 重点验证）。
- **medium 竖屏断点错配**：设置二栏断点 720 > 顶层 medium 起点 600，竖屏平板 600-720 设置为单栏 push（可接受，非两栏）。
- **测试**：`settings_redesign_static_test` / `platform_layout_test` 可能需同步断言。

## Self-Review

- 覆盖：参考图 2 栏 = Task 2；隐藏图标侧栏 = Task 2 Step 3；竖屏平板隐藏底栏 = Task 3；返回入口 = Task 1+2。✓
- 类型一致：`onBack: VoidCallback?` 在 SettingsHomePage / HibikiSettingsContent / home_page 三处签名一致。✓
- 无占位符：所有步骤含确切代码与命令。✓

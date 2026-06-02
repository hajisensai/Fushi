# 长下拉设置项 → 二级整页选择 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"选项很多"的设置下拉（App 界面语言、Anki 牌组/笔记类型、Profile 等）从锚定在触发点旁、会顶出屏幕的浮层（DropdownMenu / MenuAnchor / CupertinoActionSheet），根本性改为一个有界、可滚动的二级整页可勾选列表。

**Architecture:**
- 新增一个**可复用的泛型二级整页单选组件** `HibikiOptionSelectionPage<T>`（基于现成的 `AdaptiveSettingsScaffold`，照搬 `custom_fonts_page.dart` 的 `_SystemFontPickerPage` 模板：选项多时带搜索框；选中项打勾，其余行点击 `Navigator.pop(context, value)` 返回选择），以及一个 `pickOption<T>()` 推页助手。
- 在共享组件 `AdaptiveSettingsPickerRow` 内做**根因修复**：当 `options.length` 超过阈值时，行不再渲染内联浮层下拉，而是渲染一个带 chevron 的导航行，点击推 `HibikiOptionSelectionPage`。短选项集（≤ 阈值）行为完全不变，避免破坏阅读快捷设置等底部 sheet 里的短下拉。
- **语言**项不再用专属弹窗，统一改成一个渲染 `AdaptiveSettingsPickerRow<String>` 的设置项（17 种语言 > 阈值 → 自动走整页），删除 `LanguageDialogPage`。一个机制覆盖全部长下拉，消除特例。

**Tech Stack:** Flutter 3.41.6 / Dart、Riverpod、Slang i18n、项目自有 `Adaptive*` 自适应组件（Material/Cupertino 双端）、`flutter test`。

**根因说明（写进 commit）：** "出屏幕" 的根因是把大选项集渲染成锚定在触发控件旁的浮层；浮层高度/位置受触发点和屏幕边界双重挤压，选项一多必然溢出或贴边滚动体验差。根治手段是：大选项集改走 `AdaptiveSettingsScaffold` 承载的整页 `ListView`——天然有界、整屏可滚、可搜索，不再依赖浮层定位。短选项集不溢出，保持内联下拉。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `hibiki/lib/src/utils/components/hibiki_option_selection_page.dart` | 泛型二级整页单选组件 + `pickOption` 助手 | **新建** |
| `hibiki/lib/utils.dart`（或 components barrel） | 导出新组件 | 修改 |
| `hibiki/lib/src/utils/components/settings_shared.dart` | `AdaptiveSettingsPickerRow` 加阈值路由；新增阈值常量 | 修改 |
| `hibiki/lib/src/settings/settings_actions.dart` | 新增 `buildLanguageSelector`（渲染 `AdaptiveSettingsPickerRow<String>`） | 修改 |
| `hibiki/lib/src/settings/settings_schema.dart` | `appearance.language` 从 `SettingsActionItem`+弹窗改为 `SettingsCustomItem`+`buildLanguageSelector` | 修改 |
| `hibiki/lib/src/pages/implementations/language_dialog_page.dart` | 删除（语言不再用专属弹窗） | **删除** |
| `hibiki/lib/pages.dart` | 移除 `LanguageDialogPage` 导出 | 修改 |
| `hibiki/lib/i18n/*.i18n.json` + `strings.g.dart` | 整页搜索框提示 key（若复用不到现成 key 才新增，用 `i18n_sync.dart`） | 视情况修改 |
| `hibiki/test/widgets/hibiki_option_selection_page_test.dart` | 新组件单测 | **新建** |
| `hibiki/test/widgets/adaptive_settings_picker_row_test.dart` | 阈值路由单测（若已有则追加） | 新建/追加 |

**契约（跨任务一致使用，勿改名）：**

```dart
// hibiki_option_selection_page.dart
class HibikiOptionSelectionOption<T> {
  const HibikiOptionSelectionOption({required this.value, required this.label});
  final T value;
  final String label;
}

class HibikiOptionSelectionPage<T> extends StatefulWidget {
  const HibikiOptionSelectionPage({
    required this.title,
    required this.options,
    required this.selected,
    super.key,
    this.searchable,
  });
  final String title;
  final List<HibikiOptionSelectionOption<T>> options;
  final T? selected;
  /// null → 选项数 > [kOptionSelectionSearchThreshold] 时自动开启搜索。
  final bool? searchable;
}

/// 推 [HibikiOptionSelectionPage] 并返回所选 value；用户返回则为 null。
Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<HibikiOptionSelectionOption<T>> options,
  required T? selected,
  bool? searchable,
});

const int kOptionSelectionSearchThreshold = 12;

// settings_shared.dart
const int kSettingsPickerInlineLimit = 8; // 选项数 > 8 → 整页；否则内联下拉
```

---

## Task 1: 新建泛型二级整页单选组件

**Files:**
- Create: `hibiki/lib/src/utils/components/hibiki_option_selection_page.dart`
- Test: `hibiki/test/widgets/hibiki_option_selection_page_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/widgets/hibiki_option_selection_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_option_selection_page.dart';

void main() {
  List<HibikiOptionSelectionOption<String>> langs() => const [
        HibikiOptionSelectionOption(value: 'en-US', label: 'English'),
        HibikiOptionSelectionOption(value: 'ja', label: '日本語'),
        HibikiOptionSelectionOption(value: 'zh-CN', label: '简体中文'),
      ];

  testWidgets('选中项打勾，点未选项 pop 返回其 value', (tester) async {
    String? popped = 'SENTINEL';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => HibikiOptionSelectionPage<String>(
                    title: 'Language',
                    options: langs(),
                    selected: 'ja',
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 选中项 ja 行有打勾
    expect(find.byIcon(Icons.check), findsOneWidget);
    // 点 English 行
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(popped, 'en-US');
  });

  testWidgets('选项超阈值时显示搜索框并过滤', (tester) async {
    final many = List.generate(
      kOptionSelectionSearchThreshold + 3,
      (i) => HibikiOptionSelectionOption(value: i, label: 'Item $i'),
    );
    await tester.pumpWidget(MaterialApp(
      home: HibikiOptionSelectionPage<int>(
        title: 'Pick', options: many, selected: 0,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Item 1');
    await tester.pumpAndSettle();
    expect(find.text('Item 0'), findsNothing);
    expect(find.text('Item 1'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `hibiki/`）: `flutter test test/widgets/hibiki_option_selection_page_test.dart`
Expected: 编译失败 / "HibikiOptionSelectionPage isn't defined"

- [ ] **Step 3: 实现组件**

`hibiki/lib/src/utils/components/hibiki_option_selection_page.dart`，照搬 `_SystemFontPickerPage`（`custom_fonts_page.dart:284-392`）的结构：`AdaptiveSettingsScaffold` + 可选 `HibikiTextField` 搜索 + `AdaptiveSettingsSection`，选中行用 `AdaptiveSettingsRow`(trailing `Icon(Icons.check)`)，未选行用 `AdaptiveSettingsNavigationRow`(onTap → `Navigator.pop(context, value)`)。

```dart
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_text_field.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

const int kOptionSelectionSearchThreshold = 12;

class HibikiOptionSelectionOption<T> {
  const HibikiOptionSelectionOption({required this.value, required this.label});
  final T value;
  final String label;
}

Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<HibikiOptionSelectionOption<T>> options,
  required T? selected,
  bool? searchable,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => HibikiOptionSelectionPage<T>(
        title: title,
        options: options,
        selected: selected,
        searchable: searchable,
      ),
    ),
  );
}

class HibikiOptionSelectionPage<T> extends StatefulWidget {
  const HibikiOptionSelectionPage({
    required this.title,
    required this.options,
    required this.selected,
    super.key,
    this.searchable,
  });

  final String title;
  final List<HibikiOptionSelectionOption<T>> options;
  final T? selected;
  final bool? searchable;

  @override
  State<HibikiOptionSelectionPage<T>> createState() =>
      _HibikiOptionSelectionPageState<T>();
}

class _HibikiOptionSelectionPageState<T>
    extends State<HibikiOptionSelectionPage<T>> {
  final TextEditingController _searchController = TextEditingController();
  late List<HibikiOptionSelectionOption<T>> _filtered = widget.options;

  bool get _searchable =>
      widget.searchable ??
      widget.options.length > kOptionSelectionSearchThreshold;

  void _onSearch(String query) {
    final String q = query.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? widget.options
          : widget.options
              .where((o) => o.label.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final List<Widget> rows = _filtered.map((o) {
      final bool selected = o.value == widget.selected;
      if (selected) {
        return AdaptiveSettingsRow(
          title: o.label,
          trailing: Icon(Icons.check, color: scheme.primary),
        );
      }
      return AdaptiveSettingsNavigationRow(
        title: o.label,
        onTap: () => Navigator.pop(context, o.value),
      );
    }).toList();

    return AdaptiveSettingsScaffold(
      title: Text(widget.title),
      children: <Widget>[
        if (_searchable)
          AdaptiveSettingsSection(
            children: <Widget>[
              AdaptiveSettingsRow(
                title: '',
                controlBelow: true,
                trailing: SizedBox(
                  width: double.infinity,
                  child: HibikiTextField(
                    controller: _searchController,
                    onChanged: _onSearch,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: tokens.spacing.rowHorizontal,
                      vertical: tokens.spacing.rowVertical,
                    ),
                  ),
                ),
              ),
            ],
          ),
        AdaptiveSettingsSection(children: rows),
      ],
    );
  }
}
```

> 执行时注意：核对 `HibikiTextField` 实际构造参数（`hintText`/`controller`/`onChanged`/`contentPadding`）与 `custom_fonts_page.dart` 用法一致；`AdaptiveSettingsRow` 的 `title` 是否允许空串，若不允许则搜索行改用其它现成行组件或给个搜索提示文案（见 Task 5 i18n）。导入路径以实际文件为准（可改为经 `package:hibiki/utils.dart` barrel 导入）。

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/widgets/hibiki_option_selection_page_test.dart`
Expected: PASS（2 测试）

- [ ] **Step 5: 导出 + 格式化**

在 `hibiki/lib/utils.dart`（或 components 的 barrel）加：
```dart
export 'src/utils/components/hibiki_option_selection_page.dart';
```
Run: `dart format hibiki/lib/src/utils/components/hibiki_option_selection_page.dart hibiki/test/widgets/hibiki_option_selection_page_test.dart`

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/utils/components/hibiki_option_selection_page.dart hibiki/lib/utils.dart hibiki/test/widgets/hibiki_option_selection_page_test.dart
git commit -m "feat(settings): add reusable full-page single-choice selector"
```

---

## Task 2: AdaptiveSettingsPickerRow 长选项集走整页（根因修复）

**Files:**
- Modify: `hibiki/lib/src/utils/components/settings_shared.dart:544-616`（`AdaptiveSettingsPickerRow.build` / `_buildMaterialDropdown`）
- Test: `hibiki/test/widgets/adaptive_settings_picker_row_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/widgets/adaptive_settings_picker_row_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

void main() {
  AdaptiveSettingsPickerRow<int> row(int count, {required int selected}) =>
      AdaptiveSettingsPickerRow<int>(
        title: 'Pick',
        selected: selected,
        options: [
          for (int i = 0; i < count; i++)
            AdaptiveSettingsPickerOption<int>(value: i, label: 'Opt $i'),
        ],
        onChanged: (_) {},
      );

  testWidgets('短选项集仍内联渲染（无 chevron 导航行）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: row(3, selected: 0)),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('长选项集渲染为导航行（chevron），点击推整页', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: row(kSettingsPickerInlineLimit + 1, selected: 0)),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    // 推到整页：出现选项的整页列表（多个选项可见）
    expect(find.text('Opt 1'), findsWidgets);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/widgets/adaptive_settings_picker_row_test.dart`
Expected: 第二个测试 FAIL（长列表当前仍是内联下拉，无 chevron）

- [ ] **Step 3: 实现阈值路由**

在 `settings_shared.dart` 顶部（其它常量旁）加：
```dart
/// 选项数超过此值的 [AdaptiveSettingsPickerRow] 改走二级整页，
/// 避免内联浮层下拉顶出屏幕。
const int kSettingsPickerInlineLimit = 8;
```

修改 `AdaptiveSettingsPickerRow.build`，在 cupertino/material 分支前先判断长列表：

```dart
@override
Widget build(BuildContext context) {
  if (options.length > kSettingsPickerInlineLimit) {
    return _buildFullPageRow(context);
  }
  final bool cupertino = isCupertinoPlatform(context);
  return AdaptiveSettingsRow(
    title: title,
    subtitle: subtitle,
    icon: icon,
    controlBelow: cupertino ? false : controlBelow,
    trailing: cupertino
        ? _buildCupertinoTrailing(context)
        : _buildMaterialDropdown(context),
    onTap: cupertino ? () => _showCupertinoPicker(context) : null,
  );
}

Widget _buildFullPageRow(BuildContext context) {
  return AdaptiveSettingsNavigationRow(
    title: title,
    subtitle: _selectedLabel ?? placeholder,
    icon: icon,
    showIcon: icon != null,
    onTap: () async {
      final int? index = await pickOption<int>(
        context,
        title: title,
        selected: _selectedIndex,
        options: <HibikiOptionSelectionOption<int>>[
          for (int i = 0; i < options.length; i++)
            HibikiOptionSelectionOption<int>(value: i, label: options[i].label),
        ],
      );
      if (index != null) onChanged(options[index].value);
    },
  );
}
```

并在文件顶部 import：
```dart
import 'package:hibiki/src/utils/components/hibiki_option_selection_page.dart';
```
（用 index 作 value 复用既有 `_selectedIndex`/`_selectedLabel`，避免对 `T` 加 `==`/hash 约束。）

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/widgets/adaptive_settings_picker_row_test.dart`
Expected: PASS（2 测试）

- [ ] **Step 5: 跑相邻测试 + 格式化**

Run: `flutter test test/widgets/`
Expected: 全绿（若有既有 picker/golden 测试因长列表改版而失败，按新行为更新断言/golden 并在 commit 说明）。
Run: `dart format hibiki/lib/src/utils/components/settings_shared.dart hibiki/test/widgets/adaptive_settings_picker_row_test.dart`

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/utils/components/settings_shared.dart hibiki/test/widgets/adaptive_settings_picker_row_test.dart
git commit -m "fix(settings): route long option pickers to bounded full-page list"
```

---

## Task 3: 语言项改用统一 picker，删除专属弹窗

**Files:**
- Modify: `hibiki/lib/src/settings/settings_actions.dart`（新增 `buildLanguageSelector`）
- Modify: `hibiki/lib/src/settings/settings_schema.dart:1144-1154`（`appearance.language`）
- Delete: `hibiki/lib/src/pages/implementations/language_dialog_page.dart`
- Modify: `hibiki/lib/pages.dart`（移除 `LanguageDialogPage` 导出）

- [ ] **Step 1: 新增 `buildLanguageSelector`**

在 `settings_actions.dart`（与 `buildThemeSelector` 等并列）加：

```dart
Widget buildLanguageSelector(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  final String current = appModel.appLocale.toLanguageTag();
  return AdaptiveSettingsPickerRow<String>(
    title: t.options_language,
    icon: Icons.translate_outlined,
    selected: current,
    options: <AdaptiveSettingsPickerOption<String>>[
      for (final MapEntry<String, String> e
          in HibikiLocalisations.localeNames.entries)
        AdaptiveSettingsPickerOption<String>(value: e.key, label: e.value),
    ],
    onChanged: (String tag) {
      appModel.setAppLocale(tag);
      settingsContext.refresh();
    },
  );
}
```

> 17 种语言 > `kSettingsPickerInlineLimit(8)` → 自动走整页；> `kOptionSelectionSearchThreshold(12)` → 整页自动带搜索。核对 `settings_actions.dart` 已 import `HibikiLocalisations`（语言名表）与 `AppModel`；缺则补 import。

- [ ] **Step 2: 改 `appearance.language` 设置项**

`settings_schema.dart` 把：
```dart
SettingsActionItem(
  id: 'appearance.language',
  title: t.options_language,
  icon: Icons.translate_outlined,
  onTap: (SettingsContext settingsContext) {
    return showSettingsDialog(
      settingsContext,
      (_) => const LanguageDialogPage(),
    );
  },
),
```
改为：
```dart
SettingsCustomItem(
  id: 'appearance.language',
  icon: Icons.translate_outlined,
  builder: buildLanguageSelector,
),
```

- [ ] **Step 3: 删除弹窗 + 清理导出**

```bash
git rm hibiki/lib/src/pages/implementations/language_dialog_page.dart
```
在 `hibiki/lib/pages.dart` 移除该文件的 `export`（grep `language_dialog_page` 定位）。

- [ ] **Step 4: 静态检查 + 全量测试**

Run（在 `hibiki/`）:
```bash
flutter analyze
flutter test
```
Expected: analyze 无新错误（`LanguageDialogPage` 已无引用）；测试全绿。
- 若有引用 `LanguageDialogPage` 的残留（grep 全仓 `LanguageDialogPage` 应只剩 0 处），逐一清理。

- [ ] **Step 5: 格式化 + 提交**

```bash
dart format hibiki/lib/src/settings/settings_actions.dart hibiki/lib/src/settings/settings_schema.dart hibiki/lib/pages.dart
git add hibiki/lib/src/settings/settings_actions.dart hibiki/lib/src/settings/settings_schema.dart hibiki/lib/pages.dart hibiki/lib/src/pages/implementations/language_dialog_page.dart
git commit -m "feat(settings): unify app language into full-page picker, drop language dialog"
```

---

## Task 4: 搜索框提示文案（i18n，按需）

**仅当** Task 1 的搜索行需要一个提示文案 key（`HibikiTextField` 的 `hintText`）且复用不到现成 key 时执行。先 grep 现有：`search`、`custom_fonts_search_hint`，能复用就复用，**不新增**。

**Files:**
- Modify（仅当新增）: `hibiki/lib/i18n/*.i18n.json`（17 文件，**只能用脚本**）+ `strings.g.dart`

- [ ] **Step 1: 加 key（如确需）**

```bash
cd hibiki
dart run tool/i18n_sync.dart --add option_search_hint "Search" "搜索"
```

- [ ] **Step 2: 重新生成 + 格式化生成文件**

```bash
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 3: 在组件里引用 `t.option_search_hint`，补 import `t`**

把 Task 1 搜索行的 `HibikiTextField` 加 `hintText: t.option_search_hint`，并在组件顶部 `import 'package:hibiki/utils.dart';`（或 i18n barrel）取得 `t`。

- [ ] **Step 4: 测试 + 提交**

```bash
flutter test test/i18n/ test/widgets/hibiki_option_selection_page_test.dart
git add hibiki/lib/i18n hibiki/lib/src/utils/components/hibiki_option_selection_page.dart
git commit -m "i18n(settings): add option picker search hint"
```

---

## Task 5: 全量验证 + 设备复测原始失败路径

**Files:** 无（验证）

- [ ] **Step 1: 静态 + 单测全量**

Run（在 `hibiki/`）:
```bash
dart format .
flutter analyze
flutter test
```
Expected: 全绿。

- [ ] **Step 2: 设备复测（声明"修好了"前必须）**

按 `docs/agent/integration-testing.md` 在真机/模拟器：
1. 设置 → 系统 → 语言：点开 → 应是**整页**带搜索的语言列表，当前语言打勾；选另一语言 → 返回 → 语言生效。**列表不再顶出屏幕。**
2. Anki 设置 → 牌组/笔记类型（账户里有多个时）：点开为整页列表，可选、可搜。
3. 短下拉回归：阅读快捷设置（跳转秒数/图片暂停秒数 ≤5 项）仍是内联下拉，行为不变。
4. iOS/桌面任一端各复测语言项一次（Cupertino / Material 双路径）。
留证据（截图）到 `.codex-test/`。

- [ ] **Step 3: 代码审查**

调用 `superpowers:requesting-code-review` 启动 code-reviewer agent（**显式 `model: "opus"`**），审查：整页组件的泛型/类型签名、阈值路由是否漏改/误伤短下拉、删除弹窗后无残留引用、向后兼容（既有 picker 调用点行为）。

---

## Self-Review

**Spec coverage：**
- "语言改二级页面" → Task 3（+ Task 1 组件、Task 2 路由）。
- "其他长下拉一起改" → Task 2（Anki 牌组/笔记类型、Profile 等所有 `AdaptiveSettingsPickerRow` 长列表自动走整页）。
- "整页可勾选列表" → Task 1（选中打勾 + 整页 `AdaptiveSettingsScaffold`）。
- "出屏幕 / 根本性修复" → Task 2 根因修复 + Architecture 根因说明；短下拉不受影响（阈值）。

**Placeholder scan：** 无 TBD/TODO；每个写码步骤含完整代码或明确"以现成模板/实际签名为准"的核对指令。

**Type consistency：** `HibikiOptionSelectionOption<T>` / `HibikiOptionSelectionPage<T>` / `pickOption<T>` / `kOptionSelectionSearchThreshold` / `kSettingsPickerInlineLimit` 在 Task 1/2/3 中名称一致；`AdaptiveSettingsPickerRow` 复用既有 `_selectedIndex` / `_selectedLabel`（已存在于 settings_shared.dart:678-690），整页路由用 index 作 value 规避 `T` 的相等约束。

**风险点：**
- 既有 widget/golden 测试若假设长 picker 是内联下拉，会因 Task 2 改版失败 → Task 2 Step 5 已要求跑 `test/widgets/` 并按新行为更新。
- `AdaptiveSettingsRow(title: '')` 空标题搜索行是否合法 → Task 1 Step 3 已标注核对，必要时走 i18n 提示文案（Task 4）。
- `HibikiTextField` 构造参数以实际为准 → Task 1 已标注核对。

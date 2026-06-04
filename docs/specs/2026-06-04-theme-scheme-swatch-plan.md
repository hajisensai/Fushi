# 主题选择器四分割方案预览 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设置页主题选择器的每个圆，从「单色显示 seed 种子色」改为「四分割显示 ColorScheme.fromSeed 生成的真实方案色（primary/secondary/tertiary/surface）」，让圆准确预示主题实际观感，并让同种子色的明暗预设可区分。

**Architecture:** 新建专用组件 `HibikiSchemeSwatch`（四分割），只用在主题选择器；旧的单色 `HibikiColorSwatch` 对外行为零变更（tag 颜色、自定义色继续用）。两组件共用一个顶层私有 helper `_buildSwatchInteractive`（InkWell ripple + 手柄/键盘焦点停靠 + 选中环 + 语义 + 可选 label），把旧组件那段带注释的焦点逻辑抽出来共享，避免复制漂移导致「到不了主题位置」回归。

**Tech Stack:** Flutter / Material 3 / `material_color_utilities` / `ColorScheme.fromSeed`（经 `buildHibikiColorScheme`）/ CustomPaint。

---

## 根因（已确认）

- `settings_actions.dart:345` 主题圆 `color: entry.value.seed` 直接画 **seed 种子色**单色。
- app 真实主题走 `ColorScheme.fromSeed`（`theme_notifier.dart:35`）把 seed 色调映射后才用 → 圆色 ≠ 实际观感（「感觉怪怪的」根因）。
- `light-theme` 与 `dark-theme` 种子色完全相同（`0xFF1F4959`），单色圆只差明暗、几乎分不清。

## 文件结构

| 文件 | 责任 | 改动 |
|---|---|---|
| `hibiki/lib/src/utils/components/hibiki_material_components.dart` | swatch 组件 | 抽 `_buildSwatchInteractive` 共享 helper；`HibikiColorSwatch.build` 改为调它（行为不变）；新增 `HibikiSchemeSwatch` + `_SchemeQuadrantPainter` + 公开纯函数 `hibikiSchemeSwatchColors` |
| `hibiki/lib/src/settings/settings_actions.dart` | 主题选择器 UI | `buildThemeSelector` 三处 swatch（system / presets / custom）改用 `HibikiSchemeSwatch` |
| `hibiki/test/widgets/hibiki_scheme_swatch_test.dart` | 测试 | 新增：方案色区分性单测 + 点击回调 widget 测试 |

无 i18n 改动。无 DB 改动。

---

### Task 1: 抽取共享交互 helper（旧组件行为不变）

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart:1019-1110`（`HibikiColorSwatch.build`）

- [ ] **Step 1: 在 `HibikiColorSwatch` 类之后、`HibikiActivatableFocusTarget` 之前，新增顶层私有 helper**

```dart
/// Shared interactive wrapper for swatch widgets: InkWell ripple + a single
/// gamepad/keyboard focus stop + selection semantics + optional caption label.
///
/// [visual] is the bare painted swatch (it owns its own size/shape/border).
/// [inkRadius] clips the ripple. Factored out of [HibikiColorSwatch] so
/// [HibikiSchemeSwatch] inherits the EXACT focus-stop behaviour: under a
/// [HibikiFocusRoot] a bare InkWell makes its own unregistered Focus node and
/// the directional controller skips the whole swatch row (the theme picker was
/// unreachable — "到不了主题的位置"). We register one [HibikiActivatableFocusTarget]
/// per swatch and keep the InkWell with `canRequestFocus: false`. Off-root
/// (mobile touch) the InkWell is unchanged.
Widget _buildSwatchInteractive(
  BuildContext context, {
  required Widget visual,
  required BorderRadius inkRadius,
  required bool selected,
  required VoidCallback? onTap,
  String? label,
  Color? textColor,
}) {
  final Widget interactiveSwatch;
  if (onTap == null) {
    interactiveSwatch = visual;
  } else {
    final bool underFocusRoot =
        HibikiFocusRoot.maybeControllerOf(context) != null;
    final Widget inkSwatch = Material(
      color: Colors.transparent,
      borderRadius: inkRadius,
      child: InkWell(
        borderRadius: inkRadius,
        onTap: onTap,
        canRequestFocus: !underFocusRoot,
        child: visual,
      ),
    );
    interactiveSwatch = underFocusRoot
        ? HibikiActivatableFocusTarget(
            focusIdPrefix: 'color-swatch',
            onTap: onTap,
            child: inkSwatch,
          )
        : inkSwatch;
  }
  final Widget semanticSwatch = Semantics(
    button: onTap != null,
    selected: selected,
    child: interactiveSwatch,
  );
  if (label == null) return semanticSwatch;
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      semanticSwatch,
      SizedBox(height: tokens.spacing.gap / 2),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.metadata.copyWith(
          color: textColor ?? tokens.surfaces.onSurface,
        ),
      ),
    ],
  );
}
```

- [ ] **Step 2: 把 `HibikiColorSwatch.build` 末段（从 `final Widget interactiveSwatch;` 到 `return Column(...)` 结束，约 1058-1109 行）替换为调用 helper**

把原来构建 `interactiveSwatch` / `semanticSwatch` / label `Column` 的整段，替换为：

```dart
    return _buildSwatchInteractive(
      context,
      visual: swatch,
      inkRadius: inkRadius,
      selected: selected,
      onTap: onTap,
      label: label,
      textColor: textColor,
    );
```

保留前面 `swatch` 这个 `SizedBox(... AnimatedContainer ...)` 的构建不动。

- [ ] **Step 3: 静态分析**

Run: `cd hibiki && dart format lib/src/utils/components/hibiki_material_components.dart && flutter analyze lib/src/utils/components/hibiki_material_components.dart`
Expected: No issues.

- [ ] **Step 4: 跑既有 swatch 相关 widget 测试确认旧组件零回归**

Run: `cd hibiki && flutter test test/widgets/ --no-pub`
Expected: 全绿（tag 颜色选择器、自定义色 swatch 行为不变）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/utils/components/hibiki_material_components.dart
git commit -m "refactor(swatch): extract shared interactive wrapper for swatches"
```

---

### Task 2: 新增 `HibikiSchemeSwatch` 四分割组件 + 纯函数

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart`（在 `_swatchForegroundFor` 之后追加）

- [ ] **Step 1: 追加纯函数 + 组件 + 画笔**

```dart
/// The four quadrant colours (top-left, top-right, bottom-left, bottom-right)
/// previewed by a [HibikiSchemeSwatch] for a generated [ColorScheme]: primary,
/// secondary, tertiary, surface. Surface sits bottom-right so light vs dark
/// presets sharing one seed stay visually distinct (their surfaces differ).
List<Color> hibikiSchemeSwatchColors(ColorScheme scheme) => <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.surface,
    ];

/// A circular swatch split into four quadrants previewing the real generated
/// scheme colours, instead of a single seed colour. Used by the theme picker so
/// each circle accurately predicts the applied theme. Single-colour swatches
/// (tag colour, custom-colour preview) keep using [HibikiColorSwatch].
class HibikiSchemeSwatch extends StatelessWidget {
  const HibikiSchemeSwatch({
    required this.colors,
    super.key,
    this.size = 48,
    this.selected = false,
    this.onTap,
    this.overlay,
    this.label,
    this.textColor,
    this.borderColor,
  }) : assert(colors.length == 4, 'scheme swatch needs exactly 4 colours');

  /// [primary, secondary, tertiary, surface] — see [hibikiSchemeSwatchColors].
  final List<Color> colors;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  /// Centred badge icon for non-preset swatches (system = auto, custom = palette).
  final Widget? overlay;
  final String? label;
  final Color? textColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BorderSide borderSide = BorderSide(
      color: selected ? cs.primary : borderColor ?? cs.outlineVariant,
      width: selected ? 3 : 1,
    );
    final Widget? badgeChild =
        selected ? const Icon(Icons.check, size: 18) : overlay;
    final Widget? badge = badgeChild == null
        ? null
        : Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: cs.surface,
              shape: BoxShape.circle,
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: cs.onSurface, size: 18),
              child: badgeChild,
            ),
          );
    final Widget visual = AnimatedContainer(
      duration: hibikiMd3StateDuration,
      curve: hibikiMd3StateCurve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.fromBorderSide(borderSide),
      ),
      child: ClipOval(
        child: CustomPaint(
          painter: _SchemeQuadrantPainter(colors),
          child: badge == null ? null : Center(child: badge),
        ),
      ),
    );
    return _buildSwatchInteractive(
      context,
      visual: visual,
      inkRadius: BorderRadius.circular(size / 2),
      selected: selected,
      onTap: onTap,
      label: label,
      textColor: textColor,
    );
  }
}

class _SchemeQuadrantPainter extends CustomPainter {
  const _SchemeQuadrantPainter(this.colors);

  /// [topLeft, topRight, bottomLeft, bottomRight].
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final double mx = size.width / 2;
    final double my = size.height / 2;
    final Paint paint = Paint()..style = PaintingStyle.fill;
    paint.color = colors[0];
    canvas.drawRect(Rect.fromLTRB(0, 0, mx, my), paint);
    paint.color = colors[1];
    canvas.drawRect(Rect.fromLTRB(mx, 0, size.width, my), paint);
    paint.color = colors[2];
    canvas.drawRect(Rect.fromLTRB(0, my, mx, size.height), paint);
    paint.color = colors[3];
    canvas.drawRect(Rect.fromLTRB(mx, my, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_SchemeQuadrantPainter oldDelegate) =>
      !listEquals(oldDelegate.colors, colors);
}
```

- [ ] **Step 2: 确认 `listEquals` 可用**

`listEquals` 来自 `package:flutter/foundation.dart`。文件顶部若未导入 `flutter/material.dart`（已 re-export foundation）则无需新增 import。

Run: `cd hibiki && flutter analyze lib/src/utils/components/hibiki_material_components.dart`
Expected: No issues（若报 `listEquals` 未定义，在文件顶部补 `import 'package:flutter/foundation.dart';`）。

- [ ] **Step 3: 格式化**

Run: `cd hibiki && dart format lib/src/utils/components/hibiki_material_components.dart`

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/utils/components/hibiki_material_components.dart
git commit -m "feat(swatch): add HibikiSchemeSwatch four-quadrant scheme preview"
```

---

### Task 3: 测试 —— 方案色区分性 + 点击回调

**Files:**
- Create: `hibiki/test/widgets/hibiki_scheme_swatch_test.dart`

- [ ] **Step 1: 写测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  test('same-seed light/dark presets yield distinguishable swatch colours', () {
    // light-theme 与 dark-theme 共用 seed 0xFF1F4959，旧单色圆只差明暗几乎分不清。
    final ColorScheme light = buildHibikiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.light,
    );
    final ColorScheme dark = buildHibikiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.dark,
    );
    final List<Color> lightColors = hibikiSchemeSwatchColors(light);
    final List<Color> darkColors = hibikiSchemeSwatchColors(dark);
    expect(lightColors, isNot(equals(darkColors)));
    // surface（背景）必然不同，正是区分明暗预设的关键。
    expect(lightColors[3], isNot(equals(darkColors[3])));
  });

  test('swatch colours preview the generated scheme, not the raw seed', () {
    const Color seed = Color(0xFF1F4959);
    final ColorScheme scheme = buildHibikiColorScheme(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final List<Color> colors = hibikiSchemeSwatchColors(scheme);
    // primary 是色调映射后的结果，不应等于原始 seed（否则就退回旧的“怪”行为）。
    expect(colors[0], isNot(equals(seed)));
    expect(colors, <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.surface,
    ]);
  });

  testWidgets('HibikiSchemeSwatch fires onTap and paints four quadrants',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HibikiSchemeSwatch(
              colors: const <Color>[
                Color(0xFF112233),
                Color(0xFF445566),
                Color(0xFF778899),
                Color(0xFFAABBCC),
              ],
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tap(find.byType(HibikiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
```

- [ ] **Step 2: 跑测试**

Run: `cd hibiki && flutter test test/widgets/hibiki_scheme_swatch_test.dart --no-pub`
Expected: 3 个测试全绿。

- [ ] **Step 3: Commit**

```bash
git add hibiki/test/widgets/hibiki_scheme_swatch_test.dart
git commit -m "test(swatch): guard scheme-swatch colour distinctness + tap"
```

---

### Task 4: 主题选择器接入四分割

**Files:**
- Modify: `hibiki/lib/src/settings/settings_actions.dart:313-376`（`buildThemeSelector`）

- [ ] **Step 1: 确认 import**

`settings_actions.dart` 已使用 `AppModel`，确认顶部已 import app_model.dart（`buildHibikiColorScheme` 顶层函数即从该文件导出）。`HibikiColorSwatch` 已在用 → `HibikiSchemeSwatch` 同文件可见。

- [ ] **Step 2: 改写三处 swatch（全部换成 `HibikiSchemeSwatch`）**

system（动态）——系统主色作 seed、当前亮度生成：

```dart
        HibikiSchemeSwatch(
          colors: hibikiSchemeSwatchColors(
            buildHibikiColorScheme(
              seedColor: systemColor,
              brightness: Theme.of(settingsContext.context).brightness,
            ),
          ),
          size: _swatchSize,
          selected: appModel.appThemeKey == 'system-theme',
          overlay: const Icon(Icons.auto_awesome_outlined, size: 18),
          onTap: () async {
            await appModel.setAppThemeKey('system-theme');
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
```

presets——各自 seed+brightness 生成真实方案：

```dart
        ...AppModel.themePresets.entries.map(
          (MapEntry<String, ({Color seed, Brightness brightness})> entry) {
            return HibikiSchemeSwatch(
              colors: hibikiSchemeSwatchColors(
                buildHibikiColorScheme(
                  seedColor: entry.value.seed,
                  brightness: entry.value.brightness,
                ),
              ),
              size: _swatchSize,
              selected: appModel.appThemeKey == entry.key,
              onTap: () async {
                await appModel.setAppThemeKey(entry.key);
                notifyReaderSettingsChanged(settingsContext);
              },
            );
          },
        ),
```

custom——自定义 seed + 当前亮度生成：

```dart
        HibikiSchemeSwatch(
          colors: hibikiSchemeSwatchColors(
            buildHibikiColorScheme(
              seedColor: appModel.customThemeSeed,
              brightness: Theme.of(settingsContext.context).brightness,
            ),
          ),
          size: _swatchSize,
          selected: appModel.appThemeKey == 'custom-theme',
          overlay: const Icon(Icons.palette_outlined, size: 18),
          onTap: () async {
            await pushSettingsPage(
              settingsContext,
              (_) => const CustomThemePage(),
            );
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
```

- [ ] **Step 3: 分析 + 格式化**

Run: `cd hibiki && dart format lib/src/settings/settings_actions.dart && flutter analyze lib/src/settings/settings_actions.dart`
Expected: No issues.

- [ ] **Step 4: 跑全量测试**

Run: `cd hibiki && flutter test --no-pub`
Expected: 全绿（含新增 swatch 测试）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/settings/settings_actions.dart
git commit -m "feat(theme): preview real scheme colours as four-quadrant swatches"
```

---

### Task 5: 设备复测（声明修好前必做）

阅读器/设置 UI 改动，CLAUDE.md 要求真机/模拟器复测原始失败路径并留证据。

- [ ] **Step 1:** 真实模拟器/用户指定设备打开 设置 → 界面 → 主题，确认：每个圆四分割显示、`light-theme` 与 `dark-theme` 肉眼可区分、点击切换生效、手柄/键盘能聚焦到主题行（无「到不了主题位置」回归）。
- [ ] **Step 2:** 截图留证据（见 docs/agent/integration-testing.md）。

---

## Self-Review

1. **Spec 覆盖**：根因（seed≠实际色、同种子分不清）→ Task 2 纯函数取生成方案色 + Task 4 接入；可选模式被否决 → Task 2 独立组件、Task 1 仅内部抽 helper 不改对外行为。✅
2. **Placeholder 扫描**：无 TBD/TODO，所有代码段完整。✅
3. **类型一致**：`hibikiSchemeSwatchColors(ColorScheme)→List<Color>`、`HibikiSchemeSwatch.colors`、`_SchemeQuadrantPainter(List<Color>)` 三处签名一致；`buildHibikiColorScheme` 命名与 app_model.dart:135 导出一致。✅
4. **焦点回归**：共享 helper 保留 `HibikiActivatableFocusTarget` + `canRequestFocus:!underFocusRoot`，新组件天然继承。✅

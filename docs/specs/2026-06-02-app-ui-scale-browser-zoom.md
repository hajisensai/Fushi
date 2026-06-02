# 界面大小改为「浏览器式整体缩放」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「界面大小」(`app_ui_scale`) 从「只缩放文字+间距」改成浏览器式整体缩放——文字/图标/控件/图片一起按比例放大缩小；阅读器 WebView 单独反向补偿，保持原生清晰渲染。

**Architecture:** 在 `main.dart` 的 `MaterialApp.builder`（唯一注入点）用 `Transform.scale` + `MediaQuery.size/insets` 反算实现整体视觉缩放（同时让布局按缩小后的逻辑画布回流填满屏幕）。新增一个 InheritedWidget 暴露当前缩放系数；新增 `HibikiNativeScale` 宿主，对其子树做 `1/scale` 反向缩放，使内部平台视图（阅读器 WebView）净变换为单位阵、按原生分辨率渲染、命中测试 1:1。阅读器正文字号本来就由阅读器自身设置控制，不归 `app_ui_scale` 管，所以排除它正确。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0；Riverpod；`flutter_inappwebview`（reader 平台视图）；Slang i18n；`spaces` 包（`Spacing`）。

**已知权衡（必须在文案里说明）：** Flutter 没有引擎级 UI 缩放，整体缩放靠 `Transform.scale` 栅格放大，非整数倍下文字会有轻微软化（类似浏览器缩放观感）。这是 Flutter 平台限制，不是 bug。阅读器 WebView 因为做了反向补偿不受此影响。

---

## File Structure

| 文件 | 角色 | 改动 |
|---|---|---|
| `hibiki/lib/src/utils/app_ui_scale.dart` | 全局缩放组件 + 缩放系数 InheritedWidget + `HibikiNativeScale` 宿主 | 重写 |
| `hibiki/test/widgets/app_ui_scale_test.dart` | 缩放组件单测 | 重写 |
| `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` | 用 `HibikiNativeScale` 包裹 `InAppWebView` | 改 1 处（`_buildWebView` 返回值） |
| `hibiki/lib/i18n/strings.i18n.json` + `strings_zh-CN.i18n.json` | 更新 `app_ui_scale_hint` 文案（不再说"文字和间距"） | 改值 + `dart run slang` 重生成 |
| `hibiki/lib/main.dart` / `hibiki/lib/popup_main.dart` | 调用点 | 无需改（接口保持 `HibikiAppUiScale(scale:, child:)`） |

> 接口保持向后兼容：`HibikiAppUiScale` 的构造签名、`minScale/maxScale/defaultScale/normalize` 静态成员全部保留，`main.dart`/`popup_main.dart` 调用点零改动（铁律：Never break userspace）。

---

## Task 1: 重写 HibikiAppUiScale 为浏览器式整体缩放

**Files:**
- Modify: `hibiki/lib/src/utils/app_ui_scale.dart`（整文件重写）
- Test: `hibiki/test/widgets/app_ui_scale_test.dart`（整文件重写）

- [ ] **Step 1: 重写单测（先红）**

替换 `hibiki/test/widgets/app_ui_scale_test.dart` 全文：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/spacing.dart';

void main() {
  testWidgets('整体缩放：固定尺寸子节点视觉尺寸按 scale 放大', (
    WidgetTester tester,
  ) async {
    const Key boxKey = Key('scaled-box');
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            HibikiAppUiScale(scale: 2.0, child: child ?? const SizedBox.shrink()),
        home: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: boxKey,
            width: 100,
            height: 100,
            child: ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      ),
    );

    // RenderBox 逻辑尺寸仍是 100（未改控件本身），但全局（变换后）矩形是 200。
    final Size logical = tester.getSize(find.byKey(boxKey));
    final Rect visual = tester.getRect(find.byKey(boxKey));
    expect(logical.width, 100);
    expect(visual.width, 200);
    expect(visual.height, 200);
  });

  testWidgets('整体缩放：间距基数保持 10（视觉由 Transform 放大，不再二次乘 scale）', (
    WidgetTester tester,
  ) async {
    late double normalSpacing;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            HibikiAppUiScale(scale: 3.0, child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (BuildContext context) {
            normalSpacing = Spacing.of(context).spaces.normal;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(normalSpacing, 10.0);
  });

  testWidgets('整体缩放：不再改写 textScaler（系统字号缩放原样透传）', (
    WidgetTester tester,
  ) async {
    late double textScale;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.2)),
          child: HibikiAppUiScale(scale: 2.0, child: child ?? const SizedBox.shrink()),
        ),
        home: Builder(
          builder: (BuildContext context) {
            textScale = MediaQuery.textScalerOf(context).scale(1);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // textScaler 不被本组件触碰：系统 1.2 原样保留。
    expect(textScale, closeTo(1.2, 0.001));
  });

  testWidgets('scale==1.0 走快路径：不插入 Transform，无额外变换', (
    WidgetTester tester,
  ) async {
    const Key boxKey = Key('unscaled-box');
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            HibikiAppUiScale(scale: 1.0, child: child ?? const SizedBox.shrink()),
        home: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: boxKey,
            width: 100,
            height: 100,
            child: ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      ),
    );
    final Rect visual = tester.getRect(find.byKey(boxKey));
    expect(visual.width, 100);
  });

  testWidgets('HibikiNativeScale：缩放 2.0 下宿主子节点净变换为单位阵（按原生逻辑分辨率布局、填满区域）', (
    WidgetTester tester,
  ) async {
    const Key hostChildKey = Key('native-child');
    late Size childLogicalSize;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            HibikiAppUiScale(scale: 2.0, child: child ?? const SizedBox.shrink()),
        home: HibikiNativeScale(
          child: Builder(
            builder: (BuildContext context) {
              childLogicalSize = MediaQuery.of(context).size;
              return const ColoredBox(
                key: hostChildKey,
                color: Color(0xFF112233),
                child: SizedBox.expand(),
              );
            },
          ),
        ),
      ),
    );

    // 外层屏幕逻辑尺寸（test 默认 800x600）。
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    // 子节点按原生逻辑分辨率布局：= 缩放空间区域(screen/2) * 2 = 整屏。
    expect(childLogicalSize.width, closeTo(screen.width, 0.5));
    expect(childLogicalSize.height, closeTo(screen.height, 0.5));
    // 净变换为单位阵：宿主子节点视觉矩形 == 整屏。
    final Rect visual = tester.getRect(find.byKey(hostChildKey));
    expect(visual.width, closeTo(screen.width, 0.5));
    expect(visual.height, closeTo(screen.height, 0.5));
  });
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd hibiki && flutter test test/widgets/app_ui_scale_test.dart --no-pub`
Expected: 编译失败/断言失败（`HibikiNativeScale` 未定义；旧实现 textScaler 行为不符）。

- [ ] **Step 3: 重写 `app_ui_scale.dart`**

替换 `hibiki/lib/src/utils/app_ui_scale.dart` 全文：

```dart
import 'package:flutter/widgets.dart';
import 'package:hibiki/src/utils/spacing.dart';

/// 浏览器式整体界面缩放。
///
/// 与早期实现不同：不再仅改写 [MediaQuery.textScaler] / [Spacing]（那样只会放大
/// 文字和间距，图标、控件、图片纹丝不动）。这里用 [Transform.scale] 对整棵子树做
/// 视觉缩放，同时把 [MediaQuery] 的 size / inset 反算成「缩小后的逻辑画布」，让布局
/// 回流填满整屏——效果等同浏览器缩放：所有东西按同一比例一起放大缩小。
///
/// 平台视图（如阅读器 WebView）若要保持原生清晰渲染，用 [HibikiNativeScale] 包裹，
/// 它会对该子树做 1/scale 反向缩放，使净变换回到单位阵。
class HibikiAppUiScale extends StatelessWidget {
  const HibikiAppUiScale({
    required this.scale,
    required this.child,
    super.key,
  });

  static const double minScale = 0.3;
  static const double defaultScale = 1.0;
  static const double maxScale = 3.0;

  final double scale;
  final Widget child;

  static double normalize(double value) {
    if (value.isNaN || !value.isFinite) return defaultScale;
    return value.clamp(minScale, maxScale).toDouble();
  }

  /// 读取最近一层祖先注入的有效缩放系数；无祖先时返回 [defaultScale]。
  static double of(BuildContext context) {
    final _AppUiScaleScope? scope =
        context.dependOnInheritedWidgetOfExactType<_AppUiScaleScope>();
    return scope?.scale ?? defaultScale;
  }

  @override
  Widget build(BuildContext context) {
    final double s = normalize(scale);

    // 间距基数始终为 10：视觉放大交给 Transform，避免二次缩放。
    final Widget scoped = _AppUiScaleScope(
      scale: s,
      child: Spacing(
        dataBuilder: (_) => SpacingData.generate(10),
        child: child,
      ),
    );

    if (s == defaultScale) return scoped;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          // 无界约束下无法反算画布，退化为不缩放（不应发生在 MaterialApp.builder）。
          return scoped;
        }
        final Size view = constraints.biggest;
        final Size canvas = view / s;
        final MediaQueryData mq = MediaQuery.of(context);
        return Transform.scale(
          scale: s,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: canvas.width,
            maxWidth: canvas.width,
            minHeight: canvas.height,
            maxHeight: canvas.height,
            child: SizedBox.fromSize(
              size: canvas,
              child: MediaQuery(
                data: _scaleMediaQuery(mq, 1 / s),
                child: scoped,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 把 [MediaQueryData] 的几何量按 [factor] 缩放，使 SafeArea / 键盘避让在缩小后的
/// 逻辑画布里仍然正确。
MediaQueryData _scaleMediaQuery(MediaQueryData mq, double factor) {
  return mq.copyWith(
    size: mq.size * factor,
    padding: mq.padding * factor,
    viewPadding: mq.viewPadding * factor,
    viewInsets: mq.viewInsets * factor,
    systemGestureInsets: mq.systemGestureInsets * factor,
  );
}

/// 对子树做 1/scale 反向缩放，使其内部平台视图按原生分辨率渲染、命中测试 1:1。
///
/// 用于阅读器 WebView：外层 [HibikiAppUiScale] 把整屏放大了 s 倍，这里再缩 1/s，
/// 净变换为单位阵——WebView 拿到的逻辑视口 = 真实屏幕逻辑尺寸，EPUB 原生清晰。
/// 必须放在有界约束下（如 [Positioned.fill] 内）。
class HibikiNativeScale extends StatelessWidget {
  const HibikiNativeScale({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double s = HibikiAppUiScale.of(context);
    if (s == HibikiAppUiScale.defaultScale) return child;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final Size region = constraints.biggest; // 缩放空间里的区域尺寸
        final Size native = region * s; // 还原到真实逻辑分辨率
        final MediaQueryData mq = MediaQuery.of(context);
        return Transform.scale(
          scale: 1 / s,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: native.width,
            maxWidth: native.width,
            minHeight: native.height,
            maxHeight: native.height,
            child: SizedBox.fromSize(
              size: native,
              child: MediaQuery(
                data: _scaleMediaQuery(mq, s),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 向后代暴露当前有效缩放系数。
class _AppUiScaleScope extends InheritedWidget {
  const _AppUiScaleScope({
    required this.scale,
    required super.child,
  });

  final double scale;

  @override
  bool updateShouldNotify(_AppUiScaleScope oldWidget) =>
      oldWidget.scale != scale;
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `cd hibiki && flutter test test/widgets/app_ui_scale_test.dart --no-pub`
Expected: 全部 PASS（5 个 test）。

- [ ] **Step 5: analyze + format**

Run: `cd hibiki && dart format lib/src/utils/app_ui_scale.dart test/widgets/app_ui_scale_test.dart && flutter analyze lib/src/utils/app_ui_scale.dart`
Expected: No issues。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/utils/app_ui_scale.dart hibiki/test/widgets/app_ui_scale_test.dart
git commit -m "feat(ui-scale): browser-style whole-UI zoom (text+icons+controls)"
```

---

## Task 1.5: 修复 HibikiFocusRing 对界面缩放的感知（向后兼容回归）

**根因**：`hibiki_focus_ring.dart` 旧逻辑靠监听 `MediaQuery.textScalerOf(context)` 的变化感知「界面大小」改变（旧实现把 scale 折进 textScaler），据此重算焦点环几何并把焦点控件滚动到可见。Task 1 改成 Transform 缩放后不再写 textScaler；更关键的是 `MediaQuery.textScalerOf` 注册的是 **textScaler aspect** 依赖，而新实现改 scale 只变 **size aspect**——`didChangeDependencies` 不再被触发，焦点环既不重定位也不滚动到可见。必须改为依赖真正的缩放信号 `HibikiAppUiScale.of(context)`（依赖 `_AppUiScaleScope`，scale 变化必触发 dependency 通知）。

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_focus_ring.dart`（`_lastTextScaler`/`didChangeDependencies` 里的 textScaler 读取改成 UI scale 读取 + 注释更新）
- Modify: `hibiki/test/widgets/hibiki_focus_ring_test.dart`（更新两处描述 textScaler 机制的注释，确保两个 scale 相关 testWidgets 在新实现下仍绿）

- [ ] **Step 1**：把字段 `TextScaler? _lastTextScaler;` 改为 `double? _lastUiScale;`，注释从「folded into MediaQuery.textScaler」改为「exposed by HibikiAppUiScale via _AppUiScaleScope」。

- [ ] **Step 2**：`didChangeDependencies` 里把
  ```dart
  final TextScaler textScaler = MediaQuery.textScalerOf(context);
  final bool scaleChanged = _lastTextScaler != null && textScaler != _lastTextScaler;
  _lastTextScaler = textScaler;
  if (scaleChanged) _scheduleEnsureVisible();
  ```
  改为
  ```dart
  // Depend on the actual in-app UI scale (HibikiAppUiScale exposes it via an
  // InheritedWidget; a scale change always notifies, unlike the old
  // MediaQuery.textScaler aspect which the Transform-based scale no longer
  // touches). A scale reflow moves the focused control without any
  // window-metrics/focus/scroll/highlight change, so detect it here and reveal.
  final double uiScale = HibikiAppUiScale.of(context);
  final bool scaleChanged = _lastUiScale != null && uiScale != _lastUiScale;
  _lastUiScale = uiScale;
  if (scaleChanged) _scheduleEnsureVisible();
  ```
  并 `import 'package:hibiki/src/utils/app_ui_scale.dart';`。

- [ ] **Step 3**：更新 `hibiki_focus_ring_test.dart` 中两处注释（line ~133 的「via MediaQuery.textScaler / Spacing」、line ~224 的「Only a real UI-scale (textScaler) change may scroll」）为新机制描述；不改测试断言逻辑。

- [ ] **Step 4**：`cd hibiki && flutter test test/widgets/hibiki_focus_ring_test.dart --no-pub` → 全绿（重点是「ring follows … UI scale changes」和「theme change does not yank」两个 test）。

- [ ] **Step 5**：format + analyze 该两文件，No issues。

- [ ] **Step 6**：提交
  ```bash
  git add hibiki/lib/src/utils/components/hibiki_focus_ring.dart hibiki/test/widgets/hibiki_focus_ring_test.dart
  git commit -m "fix(focus-ring): track UI scale via HibikiAppUiScale.of (Transform zoom)"
  ```

---

## Task 2: 阅读器 WebView 反向补偿，保持原生清晰

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（`_buildWebView()` 返回的 `InAppWebView` 外包一层 `HibikiNativeScale`，约 `:1602`）

- [ ] **Step 1: 用 `HibikiNativeScale` 包裹 `InAppWebView`**

定位 `_buildWebView()`（约 `reader_hibiki_page.dart:1587`）。Linux 分支保持不变；把 `return InAppWebView(...)` 改为返回包裹后的版本。具体改法——把：

```dart
    return InAppWebView(
      key: const ValueKey<String>('hoshi_webview'),
```

改为：

```dart
    return HibikiNativeScale(
      child: InAppWebView(
        key: const ValueKey<String>('hoshi_webview'),
```

并在 `InAppWebView(...)` 的收尾 `)` 后补一个闭合 `)`（即 `HibikiNativeScale(child: ...)` 的右括号）。确认 `package:hibiki/utils.dart` 或 `app_ui_scale.dart` 已在该文件的 import 中可见（`utils.dart` barrel 已 `export 'src/utils/app_ui_scale.dart'`）；若 reader 页未导入 `utils.dart`，加 `import 'package:hibiki/src/utils/app_ui_scale.dart';`。

- [ ] **Step 2: analyze + format**

Run: `cd hibiki && dart format lib/src/pages/implementations/reader_hibiki_page.dart && flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart`
Expected: No issues（重点确认括号配平、无未用 import 警告）。

- [ ] **Step 3: 跑阅读器相关单测确保未回归**

Run: `cd hibiki && flutter test test/reader --no-pub`
Expected: 全绿（这些是 JS/CSS/分页/选区逻辑测试，不依赖真实 WebView；只验证包裹未破坏页面构建路径）。

- [ ] **Step 4: 提交**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart
git commit -m "fix(reader): render WebView at native resolution under UI zoom"
```

---

## Task 3: 更新「界面大小」说明文案

**Files:**
- Modify: `hibiki/lib/i18n/strings.i18n.json`（base/en `app_ui_scale_hint` 值）
- Modify: `hibiki/lib/i18n/strings_zh-CN.i18n.json`（zh `app_ui_scale_hint` 值）
- Regenerate: `hibiki/lib/i18n/strings.g.dart`

> 这是**改已有 key 的值**，不是增删 key，所以不走 `i18n_sync.dart`（它只做 add/remove/补缺）。只手改 en + zh-CN 两个语言的值，其余语言保留旧译文（key 仍齐全，Slang 不会报错），留待后续翻译轮统一更新。

- [ ] **Step 1: 改 zh-CN 文案**

`hibiki/lib/i18n/strings_zh-CN.i18n.json` 里 `"app_ui_scale_hint"` 的值改为：
`"整体缩放应用界面（文字、图标、控件一起放大缩小），范围 30% 到 300%。大屏设备上界面偏小可调高。"`

- [ ] **Step 2: 改 en 文案**

`hibiki/lib/i18n/strings.i18n.json` 里 `"app_ui_scale_hint"` 的值改为：
`"Scales the whole interface — text, icons and controls together — from 30% to 300%. Increase it if the UI looks small on large screens."`

- [ ] **Step 3: 重新生成并格式化**

Run: `cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart`
Expected: `strings.g.dart` 内对应 getter 更新；format 无大规模 churn（遵循 i18n 纪律：生成后立刻 format）。

- [ ] **Step 4: i18n 完整性测试**

Run: `cd hibiki && flutter test test/i18n --no-pub`
Expected: 全绿（key 完整性不变）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/i18n/strings.i18n.json hibiki/lib/i18n/strings_zh-CN.i18n.json hibiki/lib/i18n/strings.g.dart
git commit -m "docs(i18n): app_ui_scale hint now describes whole-UI zoom (en/zh)"
```

---

## Task 4: 全量验证 + 设备复测（阅读器铁律）

**Files:** 无（验证）

- [ ] **Step 1: 全量单测**

Run: `cd hibiki && flutter test --no-pub`
Expected: 全绿。若有快照/golden 因整体缩放路径变化而抖动，检查是否 `scale==1.0` 快路径未命中（默认应为 1.0，不插 Transform，理论上 golden 不应变）。

- [ ] **Step 2: 设备复测原始失败路径（CLAUDE.md 强制）**

在真机/模拟器上：
1. 设置页把「界面大小」拉到 ~150%/200%；
2. **确认图标、按钮、控件随文字一起变大**（原始投诉点）；
3. 打开一本分页 EPUB：**确认 EPUB 正文清晰不糊、翻页/划词命中正常**（WebView 反向补偿生效）；
4. 拉到 30% 确认整体缩小且可用；回到 100% 确认无残留。
留证据（截图）到 `.codex-test/`。参考 [docs/agent/integration-testing.md](../agent/integration-testing.md)。

- [ ] **Step 3: 弹窗/悬浮词典抽查（次要平台视图）**

确认 `popup_main.dart` 的弹窗词典在非 1.0 缩放下显示正常；若弹窗内含平台视图(WebView)出现糊化/错位，同样用 `HibikiNativeScale` 包裹（本计划默认弹窗为纯 Flutter 内容，无需改；此步为抽查兜底）。

- [ ] **Step 4: 代码审查（CLAUDE.md 强制，model: opus）**

调用 `superpowers:requesting-code-review`，spawn code-reviewer subagent 且显式 `model: "opus"`，审查 Task 1–3 实现是否符合计划、括号配平、向后兼容、平台视图变换正确性。

---

## Self-Review

- **Spec 覆盖**：① 图标/控件随文字一起缩放 → Task 1（Transform 整体缩放）；② 阅读器不糊 → Task 2（反向补偿）；③ 文案准确 → Task 3；④ 阅读器铁律验证 → Task 4。覆盖完整。
- **Placeholder 扫描**：无 TODO/TBD；所有代码步给出完整代码。
- **类型/命名一致**：`HibikiAppUiScale.of` / `HibikiNativeScale` / `_AppUiScaleScope` / `_scaleMediaQuery` 在 Task 1 定义，Task 2 仅用 `HibikiNativeScale`，一致；构造签名 `HibikiAppUiScale({scale, child})` 与 `main.dart:467` / `popup_main.dart:166` 现有调用一致，零破坏。
- **向后兼容**：静态成员 `minScale/maxScale/defaultScale/normalize` 全保留，settings_schema.dart `:122-123` 引用不变。

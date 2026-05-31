# 手柄导航 期1（滚动通道 + 焦点默认可达）实施计划

> **For agentic workers:** 逐 Task 实现，TDD（写失败测试→跑失败→最小实现→跑通过→commit）。步骤用 `- [ ]`。计划依据：[2026-05-31-gamepad-navigation-comprehensive-design.md](2026-05-31-gamepad-navigation-comprehensive-design.md) §3.2 §3.3，及 develop 逐文件核对的实现地图。

**Goal:** 给手柄三条独立能力——(A) D-pad 在有焦点列表走到边缘时自动接管滚动；(B) LB/RB 在任意非阅读器页整页翻屏（含纯展示零焦点页）；(3) `HibikiIconButton`/`HibikiTagChip` 在 `HibikiFocusRoot` 下默认可被手柄聚焦。

**Architecture:** 所有滚动逻辑集中在 `HibikiFocusScroll`（满足 focus 包集中化静态约束）。A 注入 `gamepadMoveFocusInDirection` 的 root 分支失败出口；B 做成 `ShortcutScope.global` 的 `ShortcutAction`，执行体放 `wrapWithGlobalNavigation`（在 Navigator 之上、用 `navigatorKey.currentContext` 命中当前路由主 `PrimaryScrollController`）；(3) 反转默认注册，用 `identityHashCode` 派生稳定 fallback focusId（与 `HibikiCard`/`HibikiListItem` 现状一致）。

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4；`HibikiFocusController`/`HibikiFocusTarget`/`HibikiFocusRoot`；`ShortcutRegistry`/`ShortcutAction`/`GamepadButton`；`Scrollable.maybeOf` + `ScrollPosition.animateTo` + `PrimaryScrollController.maybeOf`。

**验证命令（每 Task）:** `cd /d/APP/vs_claude_code/hibiki/hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test <path> -p vm`，全量 `flutter test`，`dart format .`，`flutter analyze`。

---

## 文件清单

| 文件 | 动作 | 职责 |
|------|------|------|
| `hibiki/lib/src/focus/hibiki_focus_scroll.dart` | modify | 新增 `scrollByViewportFraction` + `signedFractionFor`（A/B 共享） |
| `hibiki/lib/src/shortcuts/gamepad_service.dart` | modify | 件A：root 分支边缘接管滚动 |
| `hibiki/lib/src/shortcuts/shortcut_action.dart` | modify | 件B：新增 `globalScrollPageDown/Up`（global） |
| `hibiki/lib/src/shortcuts/shortcut_defaults.dart` | modify | 件B：配 LB/RB 默认绑定 |
| `hibiki/lib/src/shortcuts/global_navigation.dart` | modify | 件B：执行体（registry 入参 + PrimaryScrollController 翻屏） |
| `hibiki/lib/src/pages/implementations/home_page.dart` | modify | 件B：home 对 globalScroll 不拦截、冒泡到全局层 |
| `hibiki/lib/src/utils/components/hibiki_icon_button.dart` | modify | 件3：默认注册焦点 |
| `hibiki/lib/src/utils/components/hibiki_material_components.dart` | modify | 件3：`HibikiTagChip` 升 Stateful + 默认注册 |
| `hibiki/lib/i18n/*.i18n.json`（经 `tool/i18n_sync.dart --add`） | modify | 件B：两个 action 的设置页 label |

---

## Task 1：HibikiFocusScroll 共享滚动基建

**Files:** Modify `hibiki/lib/src/focus/hibiki_focus_scroll.dart`；Test `hibiki/test/focus/hibiki_focus_scroll_test.dart`（新建）

- [ ] **Step 1: 读现状** — 读 `hibiki_focus_scroll.dart` 全文，确认现有 static 方法风格（120ms easeOutCubic）。
- [ ] **Step 2: 写失败测试**（纯函数 + 行为）

```dart
// hibiki/test/focus/hibiki_focus_scroll_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';

void main() {
  test('signedFractionFor: down/right 正、up/left 负', () {
    expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.down, 0.8), 0.8);
    expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.right, 0.8), 0.8);
    expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.up, 0.8), -0.8);
    expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.left, 0.8), -0.8);
  });

  testWidgets('scrollByViewportFraction 无 Scrollable 返回 false', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (c) { ctx = c; return const SizedBox(); })));
    expect(HibikiFocusScroll.scrollByViewportFraction(ctx, null, 0.8), isFalse);
  });

  testWidgets('scrollByViewportFraction 有 Scrollable 时滚动并返回 true；到底返回 false', (t) async {
    final ScrollController c = ScrollController();
    late BuildContext itemCtx;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ListView(controller: c, children: [
      for (int i = 0; i < 60; i++)
        SizedBox(height: 100, child: i == 0 ? Builder(builder: (x) { itemCtx = x; return const Text('first'); }) : Text('$i')),
    ]))));
    final double vp = c.position.viewportDimension;
    expect(HibikiFocusScroll.scrollByViewportFraction(itemCtx, AxisDirection.down, 0.8), isTrue);
    await t.pumpAndSettle();
    expect(c.offset, closeTo(vp * 0.8, 1.0));
    c.jumpTo(c.position.maxScrollExtent);
    await t.pump();
    expect(HibikiFocusScroll.scrollByViewportFraction(itemCtx, AxisDirection.down, 0.8), isFalse);
  });

  testWidgets('wantAxis 不匹配返回 false（垂直页 left/right 不误翻）', (t) async {
    final ScrollController c = ScrollController();
    late BuildContext itemCtx;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ListView(controller: c, children: [
      for (int i = 0; i < 60; i++)
        SizedBox(height: 100, child: i == 0 ? Builder(builder: (x) { itemCtx = x; return const Text('first'); }) : Text('$i')),
    ]))));
    // 垂直列表，水平方向请求 -> 轴不匹配
    expect(HibikiFocusScroll.scrollByViewportFraction(itemCtx, AxisDirection.right, 0.8), isFalse);
  });
}
```

- [ ] **Step 3: 跑测试，预期 FAIL**（方法未定义）。
- [ ] **Step 4: 实现** — 在 `HibikiFocusScroll` 类加：

```dart
  /// 把 [context] 最近的可滚动祖先按 viewport 的 [signedFraction] 比例滚动一段。
  /// 命中且仍能滚返回 true；无 Scrollable / 已到边界 / 轴不匹配返回 false。
  static bool scrollByViewportFraction(
    BuildContext context,
    AxisDirection? wantAxis,
    double signedFraction,
  ) {
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return false;
    final ScrollPosition position = scrollable.position;
    if (wantAxis != null && axisDirectionToAxis(wantAxis) != position.axis) {
      return false;
    }
    final double target = (position.pixels + position.viewportDimension * signedFraction)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return false;
    position.animateTo(target,
        duration: const Duration(milliseconds: 120), curve: Curves.easeOutCubic);
    return true;
  }

  /// 方向 → viewport 比例正负号：down/right 为正，up/left 为负。
  static double signedFractionFor(TraversalDirection direction, double fraction) {
    switch (direction) {
      case TraversalDirection.down:
      case TraversalDirection.right:
        return fraction;
      case TraversalDirection.up:
      case TraversalDirection.left:
        return -fraction;
    }
  }
```

- [ ] **Step 5: 跑测试，预期 PASS**。
- [ ] **Step 6: `dart format .` + commit** `feat(focus): add HibikiFocusScroll.scrollByViewportFraction for gamepad scroll channel`

---

## Task 2：件A — D-pad 边缘接管滚动

**Files:** Modify `hibiki/lib/src/shortcuts/gamepad_service.dart`（`gamepadMoveFocusInDirection` ~294-316）；Test `hibiki/test/shortcuts/gamepad_focus_nav_test.dart`（扩展）

- [ ] **Step 1: 读现状** — 读 `gamepad_service.dart:294-344` 与 `hibiki_focus_controller.dart:75-79`(`activeContext`) 确认锚点。
- [ ] **Step 2: 写失败测试** — 在 `gamepad_focus_nav_test.dart` 加：构造 `HibikiFocusRoot` 内一个长 `ListView` + 外部 `ScrollController`，只放**一个**靠顶部的 `HibikiFocusTarget`（使某方向 `controller.move` 无几何目标→失败）。聚焦它后 `gamepadMoveFocusInDirection(ctx, TraversalDirection.down)`，断言返回 `true` 且 `controller.offset` 增加 ≈ `0.8*viewport`（`closeTo`，`pumpAndSettle` 后）。再 `controller.jumpTo(maxScrollExtent)` 后 down，断言返回 `false` 且 offset 不变。
- [ ] **Step 3: 跑测试，预期 FAIL**（当前 move 失败即 return false，不滚）。
- [ ] **Step 4: 实现** — 在 `gamepadMoveFocusInDirection` 有 root 分支，`controller.move(...)` 返回 false 后、`return _movePrimaryFocusInDirection(...false)` 之前插入：

```dart
    final BuildContext? focusCtx =
        controller.activeContext ?? FocusManager.instance.primaryFocus?.context;
    if (focusCtx != null &&
        HibikiFocusScroll.scrollByViewportFraction(
          focusCtx,
          axisDirectionFromTraversal(direction), // 见下；垂直页 left/right 不误翻
          HibikiFocusScroll.signedFractionFor(direction, 0.8),
        )) {
      return true;
    }
```

并加 `import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';`。若无现成 `TraversalDirection→AxisDirection` helper，在本文件加纯函数：

```dart
AxisDirection axisDirectionFromTraversal(TraversalDirection d) {
  switch (d) {
    case TraversalDirection.up: return AxisDirection.up;
    case TraversalDirection.down: return AxisDirection.down;
    case TraversalDirection.left: return AxisDirection.left;
    case TraversalDirection.right: return AxisDirection.right;
  }
}
```

- [ ] **Step 5: 跑测试，预期 PASS**；跑 `gamepad_focus_nav_test.dart` 全部确认无回归。
- [ ] **Step 6: commit** `feat(gamepad): D-pad edge takeover scrolls focused list when no target in direction`

---

## Task 3：件B-1 — 新增 globalScrollPageDown/Up action + 默认绑定 + i18n

**Files:** Modify `shortcut_action.dart`、`shortcut_defaults.dart`；i18n 经 `tool/i18n_sync.dart --add`；Test `shortcut_defaults_test.dart`（扩展）

- [ ] **Step 1: 读现状** — 读 `shortcut_action.dart`（枚举 + scope + coactiveScopes）、`shortcut_defaults.dart`（`_desktop` map 结构、`_gLB/_gRB` 常量名、reader page-turn 绑定写法）、`shortcut_defaults_test.dart:11-25`（每平台覆盖断言）。
- [ ] **Step 2: 写失败测试** — `shortcut_defaults_test.dart` 加：`globalScrollPageDown` 的 gamepad 绑定含 RB、`globalScrollPageUp` 含 LB；`hasGamepadConflict` 对 global 这两键不报冲突（与 reader page-turn 跨组）。
- [ ] **Step 3: 跑测试，预期 FAIL**（枚举值不存在 → 编译失败即视为 FAIL）。
- [ ] **Step 4: 实现**
  - `shortcut_action.dart` Global 段新增：`globalScrollPageDown(ShortcutScope.global, 'global_scroll_page_down')`、`globalScrollPageUp(ShortcutScope.global, 'global_scroll_page_up')`。
  - `shortcut_defaults.dart` `_desktop` 给两者配 `gamepadBindings`：down=`[_gRB]`、up=`[_gLB]`（键盘留空或 PageDown/PageUp）。`_macOS/_mobile` 自动继承。
  - i18n label：`cd hibiki && D:/flutter_sdk/.../dart.bat tool/i18n_sync.dart --add shortcut_action_global_scroll_page_down "Scroll page down" "向下翻一屏"`，up 同理。**禁手改 17 语言文件。** 跑 slang 生成。
- [ ] **Step 5: 跑测试，预期 PASS**；`flutter analyze`。
- [ ] **Step 6: commit** `feat(shortcuts): add global scroll-page actions bound to LB/RB`

---

## Task 4：件B-2 — wrapWithGlobalNavigation 执行体 + home 冒泡

**Files:** Modify `global_navigation.dart`、`home_page.dart`、其调用处（`main.dart`/app builder 传 registry）；Test `gamepad_navigation_flow_test.dart`（扩展）

- [ ] **Step 1: 读现状** — 读 `global_navigation.dart` 全文（已知 71-94）、`wrapWithGlobalNavigation` 调用方、`home_page.dart:204-251`（`_handleGamepadButton`/`_executeShortcutAction`）、`ShortcutRegistry.resolveGamepad` 签名。
- [ ] **Step 2: 写失败测试** — `gamepad_navigation_flow_test.dart` 加端到端：外壳含可滚动 primary `CustomScrollView`，经 `Actions.invoke<GamepadButtonIntent>(rb)` 后断言 `PrimaryScrollController.position.pixels` 增加约一屏；同样验 push 出去的路由（模拟 ReadingStatisticsPage）。
- [ ] **Step 3: 跑测试，预期 FAIL**。
- [ ] **Step 4: 实现**
  - `wrapWithGlobalNavigation` 新增 `required ShortcutRegistry registry` 入参；在其 `Actions` map 加 `GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(onInvoke: ...)`：`final action = registry.resolveGamepad(intent.button, ShortcutScope.global);` 命中 `globalScrollPageDown/Up` 时，`final ctx = navigatorKey.currentContext;` → `PrimaryScrollController.maybeOf(ctx)` 取主滚动 → `position.animateTo((pixels ± viewport).clamp(...), 120ms, easeOutCubic)`（复用 `HibikiFocusScroll` 同参或直接 `scrollByViewportFraction` with 1.0）。未命中 return null（不吞）。
  - 调用处把 `appModel.shortcutRegistry` 传入。
  - `home_page.dart _handleGamepadButton`：命中 `globalScrollPageDown/Up` 时 `return false`（让 `GamepadButtonIntent` 继续冒泡到全局层）；确保 `_executeShortcutAction` 对其 `default→ignored`。
- [ ] **Step 5: 跑测试，预期 PASS**；`flutter analyze`。
- [ ] **Step 6: commit** `feat(gamepad): LB/RB page-scroll any non-reader route via global layer`

---

## Task 5：件3-1 — HibikiIconButton 默认注册焦点

**Files:** Modify `hibiki_icon_button.dart`；Test `hibiki/test/widgets/hibiki_icon_button_focus_test.dart`（新建）、`hibiki_icon_button_test.dart`（回归）

- [ ] **Step 1: 读现状** — 读 `hibiki_icon_button.dart` 全文（重点 `_focusable` 188-206、State 结构、`HibikiFocusTarget` 用法），及 `hibiki_card_focus_test.dart` 骨架。
- [ ] **Step 2: 写失败测试** — `hibiki_icon_button_focus_test.dart`：`HibikiFocusRoot(Column)` 内放两个**不传 focusId**、`onTap:++` 的 `HibikiIconButton`；`controller.move(down)` 从首到次，断言 `activeId != null` 且变化、`Actions.maybeInvoke<ActivateIntent>(controller.activeContext!, ...)` 触发 onTap。反例：`enabled:false` 不进 move 序列；`onTap==null` 装饰图标不注册（`activeId` 仍 null / 不在序列）。
- [ ] **Step 3: 跑测试，预期 FAIL**（当前 focusId==null 退化裸 InkWell，move 落不到）。
- [ ] **Step 4: 实现**
  - State 顶加 `late final HibikiFocusId _fallbackFocusId = HibikiFocusId('hibiki-icon-button-${identityHashCode(this)}');`
  - `_focusable` 顶部加 `if (widget.onTap == null) return button;`（装饰图标不注册）。
  - 删行 189 `if (widget.focusId == null) return button;`；保留行 190 `maybeControllerOf(context)==null` 守卫。
  - 行 201 `id: widget.focusId!` → `id: widget.focusId ?? _fallbackFocusId`；`enabled`/`ActivateIntent` 原样。
- [ ] **Step 5: 跑测试，预期 PASS**；跑 `hibiki_icon_button_test.dart` 确认无 root 用例（裸 button 兜底）与显式 focusId 用例无回归。
- [ ] **Step 6: commit** `feat(focus): HibikiIconButton registers focus by default under HibikiFocusRoot`

---

## Task 6：件3-2 — HibikiTagChip 默认注册焦点（升 Stateful）

**Files:** Modify `hibiki_material_components.dart`（`HibikiTagChip` 529-631）；Test `hibiki/test/widgets/hibiki_tag_chip_focus_test.dart`（新建）

- [ ] **Step 1: 读现状** — 读 `HibikiTagChip`（529-631）、范本 `HibikiActionChip`(473-525)/`HibikiSelectableChip`(403-471)/`HibikiCard`(7-91)。
- [ ] **Step 2: 写失败测试** — `hibiki_tag_chip_focus_test.dart`：root 内 `HibikiTagChip(onTap:++, 不传 focusId)` 默认可达（`controller.move` 命中 + `ActivateIntent` 触发 onTap）；`onTap==null` 不注册。
- [ ] **Step 3: 跑测试，预期 FAIL**（当前 onTap 分支裸 InkWell）。
- [ ] **Step 4: 实现**
  - `HibikiTagChip` 升级为 `StatefulWidget`；加 `final HibikiFocusId? focusId;` 字段（构造器可选）。
  - State `late final HibikiFocusId _fallbackFocusId = HibikiFocusId('hibiki-tag-chip-${identityHashCode(this)}');`
  - `onTap != null` 分支：`maybeControllerOf(context) != null` 时把现有 `InkWell` 外包 `Actions{ActivateIntent: CallbackAction(onInvoke: (_) { widget.onTap!(); return null; })}` + `HibikiFocusTarget(id: widget.focusId ?? _fallbackFocusId, enabled: true, ...)`，照抄 `HibikiActionChip` 写法；`onTap == null` 仍返回裸 chip。
- [ ] **Step 5: 跑测试，预期 PASS**；全量 `flutter test` 确认 `HibikiTagChip` 各调用点（书架标签条 `reader_hibiki_history_page.dart:1484`）无回归。
- [ ] **Step 6: commit** `feat(focus): HibikiTagChip registers focus by default under HibikiFocusRoot`

---

## 收尾验证（期1 全部完成后）

- [ ] `cd hibiki && dart format .`
- [ ] `flutter analyze`（0 error）
- [ ] `flutter test`（全绿）
- [ ] 真机/模拟器（Windows 优先）实测原始失败路径：进**阅读统计页** LB/RB 翻到「按书」列表底；进**设置长列表**用 D-pad 走到底自动滚；工具栏图标键 D-pad 可聚焦 + A 触发。证据存 `.codex-test/`。
- [ ] code-review（subagent，`model: opus`）→ 修复 → 复审。

## 风险

- `wrapWithGlobalNavigation` 需 registry 入参——改签名，更新所有调用处。
- home Actions 比全局层近，必须 `return false` 让冒泡，否则 home 吞掉且无主滚动可翻。
- `HibikiTagChip` Stateless→Stateful 是破坏性结构改动，需确认所有调用点构造不依赖 const。
- 新增 2 action 触发 `shortcut_defaults_test` 每平台覆盖断言——必须配 `_desktop`。
- i18n 必须走 `tool/i18n_sync.dart --add`，禁手改。

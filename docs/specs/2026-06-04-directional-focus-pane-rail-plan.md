# 方向焦点「面板」身份修复（Down 误入侧栏/底栏）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans 逐任务执行；步骤用 `- [ ]`。

**Goal:** 书架页头三个图标按钮按方向键 Down 不再跳到左侧导航 rail，而是进入下方内容（这一类「chrome/内容纵向移动误入导航簇」问题一并根治）。

**Architecture:** `HibikiFocusController._geometricTarget` 当前用「最近 Scrollable」当「面板」代理，并把 `samePane` 排在 `along`（纵向距离）之上。把面板身份升级为「**最近 FocusTraversalGroup**，再按**非空 Scrollable** 细分」：app 已用 FTG 精确分隔了 rail / body / 设置三区，而设置两栏共用一个 FTG 但各是独立 ListView——两条信号组合后既能把 rail 与 body chrome 判为异面板，又能保持设置两栏异面板。仅改 `_geometricTarget` 内的 samePane 计算，排序档次与其它逻辑不动。

**Tech Stack:** Flutter / Dart，`flutter test`（项目 3.44.0 工具链）。

---

## 根因（已沿真实路径定位）

- 书架 body = `Column[页头(3×HibikiIconButton,无Scrollable→null) / 标签栏(横向ListView) / Expanded(CustomScrollView 书格)]`（`reader_hibiki_history_page.dart:141-147,193-214`）。
- rail = `_MaterialNavCluster` 垂直、非滚动 `Column`（`adaptive_navigation.dart:130-157`）→ rail 项 `Scrollable.maybeOf==null`。
- home 桌面布局把 rail 与 body 各包一个 `FocusTraversalGroup`（`home_page.dart:370,382`）；设置标签是单个 FTG 包两栏（`home_page.dart:341`），两栏各是独立 `ListView`（`material_settings_renderer.dart:46,114`）。
- `_geometricTarget`（`hibiki_focus_controller.dart:303-431`）里 `samePane = identical(Scrollable.maybeOf(target), activeScrollable)`，null==null 视为同面板。于是头部按钮(null) 与 rail(null) 判**同面板**、与真正内容(在 Scrollable 里)判**异面板**；samePane 档(tier 1)高于 along(tier 2)，Down 时 rail 击败内容；短窗口里 rail 项纵向还更近，along 也帮 rail。

## 不变式（必须保持，已有测试钉住）

- `focus_geometry_test`：无 FTG 无 Scrollable，Down 走「下一行」(mid-left)。
- `focus_pane_locality_test`：两 ListView，Down 留在同栏(detail-theme)，不跳更近的异栏 nav。
- `focus_left_escapes_pane_test`(BUG-015)：整宽行 Left 逃到 nav 栏。

新 samePane 规则在以上三场景结果不变（推演见任务 2）。

---

## Task 1: 失败测试 —— Down 从页头按钮不得进入 rail（FTG 分隔的两栏）

**Files:**
- Create/Test: `hibiki/test/focus/focus_nav_pane_not_entered_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

// 复现书架 bug：左 rail 与右 body 各一个 FocusTraversalGroup。右 body 顶部是
// 无 Scrollable 的「页头按钮」，下方是一个 ListView 内容。按 Down 必须落到同
// body 组的内容，而不是另一组（rail）的导航项——即便某个 rail 项纵向更近。
Widget _shell({required GlobalKey rootKey}) {
  Widget t(String id, {required double w, required double h}) =>
      HibikiFocusTarget(id: HibikiFocusId(id), child: SizedBox(width: w, height: h));
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: Row(
          key: rootKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 左：rail（独立组，非滚动 Column，垂直居中 → 项落在中段，纵向接近顶部按钮）
            FocusTraversalGroup(
              child: SizedBox(
                width: 80,
                height: 400,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    t('nav-0', w: 80, h: 56),
                    t('nav-1', w: 80, h: 56),
                    t('nav-2', w: 80, h: 56),
                  ],
                ),
              ),
            ),
            // 右：body（独立组）：顶部无 Scrollable 的页头按钮 + 下方 ListView 内容
            Expanded(
              child: FocusTraversalGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerRight,
                      child: t('header-btn', w: 48, h: 48),
                    ),
                    Expanded(
                      child: ListView(
                        children: <Widget>[
                          t('content-0', w: 400, h: 56),
                          t('content-1', w: 400, h: 56),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Down from a header button stays in the body pane, never enters '
      'the rail group', (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_shell(rootKey: rootKey));
    await tester.pump();
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('header-btn')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('content-'),
      isTrue,
      reason: 'Down from header must reach the body content, not the rail',
    );
  });

  testWidgets('Left from body content still escapes into the rail group',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_shell(rootKey: rootKey));
    await tester.pump();
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('content-0')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.left), isTrue);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('nav-'),
      isTrue,
      reason: 'Left must still cross panes into the rail',
    );
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/focus/focus_nav_pane_not_entered_test.dart --no-pub`
Expected: 第一个用例 FAIL（`activeId` 落到 `nav-*`，因旧 samePane 把 rail 判同面板）。第二个应已 PASS。

---

## Task 2: 根因修复 —— 面板身份 = 最近 FocusTraversalGroup + 非空 Scrollable 细分

**Files:**
- Modify: `hibiki/lib/src/focus/hibiki_focus_controller.dart`（`_geometricTarget` 内 samePane 计算 + 新增私有 helper）

- [ ] **Step 1: 新增 helper（放在 `_GeometricMoveResult` 之后或 controller 私有方法区）**

```dart
/// 方向导航「面板」身份的主边界：最近的 [FocusTraversalGroup]。home 外壳把侧栏
/// rail、正文 body、设置各包进**独立** FocusTraversalGroup（home_page.dart），所以
/// rail 与 body 的页头按钮属于不同面板——即便两者都没有 Scrollable 祖先。
Element? _nearestTraversalGroup(BuildContext context) {
  if (!context.mounted) return null;
  Element? group;
  context.visitAncestorElements((Element element) {
    if (element.widget is FocusTraversalGroup) {
      group = element;
      return false;
    }
    return true;
  });
  return group;
}
```

- [ ] **Step 2: 在 `_geometricTarget` 里把 activeScrollable 旁补算 activeGroup**

把（约 313-314 行）：
```dart
    final ScrollableState? activeScrollable =
        Scrollable.maybeOf(active.context);
```
改为：
```dart
    final ScrollableState? activeScrollable =
        Scrollable.maybeOf(active.context);
    // 面板身份：先看最近 FocusTraversalGroup（rail/body/设置各一组），同组内再用
    // 非空 Scrollable 细分（设置两栏共用一组、各是独立 ListView）。
    final Element? activeGroup = _nearestTraversalGroup(active.context);
```

- [ ] **Step 3: 替换 per-target 的 samePane 计算**

把（约 330-333 行）：
```dart
      final bool samePane = identical(
        Scrollable.maybeOf(target.context),
        activeScrollable,
      );
```
改为：
```dart
      final bool samePane = _isSamePane(
        target.context,
        activeGroup: activeGroup,
        activeScrollable: activeScrollable,
      );
```

并新增私有方法（与 `_geometricTarget` 同类内）：
```dart
  /// 是否与当前项同面板：① 必须同一最近 FocusTraversalGroup（不同组=异面板，
  /// 例如侧栏 rail vs 正文）；② 同组内若两者都在非空 Scrollable 且不同，则异面板
  /// （设置 list-detail 两栏）；任一方无 Scrollable（页头 chrome）则只看组——
  /// 让无滚动的 chrome 与同组的内容算同面板。两者皆无 FTG、皆无 Scrollable 时退化
  /// 为旧行为（恒同面板，纯展示页/无分栏页不受影响）。
  bool _isSamePane(
    BuildContext targetContext, {
    required Element? activeGroup,
    required ScrollableState? activeScrollable,
  }) {
    if (!identical(_nearestTraversalGroup(targetContext), activeGroup)) {
      return false;
    }
    final ScrollableState? targetScrollable = Scrollable.maybeOf(targetContext);
    if (activeScrollable == null || targetScrollable == null) return true;
    return identical(targetScrollable, activeScrollable);
  }
```

- [ ] **Step 4: 更新 311-312 行的中文注释**为「优先 FocusTraversalGroup 面板、再按非空 Scrollable 细分」，避免注释与实现脱节。

- [ ] **Step 5: 跑新测试确认通过**

Run: `flutter test test/focus/focus_nav_pane_not_entered_test.dart --no-pub`
Expected: 两个用例 PASS。

---

## Task 3: 回归 + 格式

- [ ] **Step 1: 跑全部焦点/快捷键/相关 widget 测试**

Run: `flutter test test/focus test/shortcuts test/widgets test/settings --no-pub`
Expected: 全绿（尤其 `focus_geometry_test` / `focus_pane_locality_test` / `focus_left_escapes_pane_test` 不破）。

> 推演不变式：
> - geometry_test：无 FTG、无 Scrollable → `_nearestTraversalGroup` 全 null（identical(null,null)=同组），scrollable 皆 null → 走 waiver → samePane 全 TRUE（与旧 null==null 全 TRUE 一致）→ along 决定 → mid-left 仍胜。
> - pane_locality：无 FTG（全 null 同组）；detail-seg vs detail-theme 同 ListView → TRUE；vs nav 异 ListView → FALSE → Down 仍留 detail。
> - left_escapes(BUG-015)：无 FTG（同组）；switch vs nav 异 ListView → FALSE，clears 档（高于 samePane）仍让 nav 胜 → Left 仍逃到 nav。

- [ ] **Step 2: 格式**

Run: `dart format lib/src/focus/hibiki_focus_controller.dart test/focus/focus_nav_pane_not_entered_test.dart`

---

## Task 4: BUG 台账 + 提交

- [ ] **Step 1: 在 `docs/BUGS.md` 顶部追加 BUG-033 条目**（号若被并发 agent 抢占则顺延），含报告/真实性(根因 file:line)/① 修复(提交哈希)/② 测试(文件)/备注(设备复测待用户)。两勾选框打勾。

- [ ] **Step 2: 只 stage 本轮文件并提交**

```bash
git status --short
git add lib/src/focus/hibiki_focus_controller.dart \
        test/focus/focus_nav_pane_not_entered_test.dart \
        ../docs/BUGS.md
git diff --cached --check
git commit -m "fix(focus): treat nav rail as a distinct pane so Down/Up never leaves content for the rail (BUG-033)"
```

- [ ] **Step 3: 提交后 `git status --short`**，回复给出哈希与残留的无关未提交改动。

---

## Task 5: 代码审查（强制，opus 子代理）

- [ ] 用 superpowers:requesting-code-review 派 **model: opus** 子代理审查：面板新规是否在三条不变式下行为不变、是否引入新特殊情况、`visitAncestorElements` 在未挂载/无 FTG 页的安全性。发现问题修复后复审。

---

## 设备复测（待用户）

桌面（rail 布局）/手机（底栏）真机：焦点停在书架右上任一图标按钮 → 按 Down → 落到下方标签栏/书格而非侧栏/底栏；按 Left（桌面）仍能进侧栏；侧栏内 Up/Down 仍切目的地。

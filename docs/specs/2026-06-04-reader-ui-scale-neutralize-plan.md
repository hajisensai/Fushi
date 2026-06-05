# 阅读器界面缩放中和（正文统一走字号）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让阅读器（正文 WebView + 划词弹窗 + 高亮 + 铬层）不再被全局「界面大小」光栅放大而发糊；进入阅读器后整页净缩放回到 1.0、按原生像素密度渲染，正文大小统一由阅读器自带字号控制。

**Architecture:** 新增 `HibikiAppUiScaleNeutralizer`，镜像 `HibikiAppUiScale` 自身结构的逆变换：`FittedBox(BoxFit.fill) + SizedBox(真实视口) + 真实 MediaQuery + 子树缩放标记=1.0`。整棵阅读器子树**一起**中和（处于同一坐标空间，所以 `selectionRect` 定位不错位）——这正是与被撤销的 `HibikiNativeScale`（只反缩放 WebView 致弹窗错位）的本质区别。中和器从**路由层**包在 `ReaderHibikiPage` 外，保证 `State.context` 也落在其下、辅助方法读到真实 MediaQuery。

**Tech Stack:** Flutter / Dart 3.12，Riverpod，flutter_test（widget 测试 + 源码守卫）。

---

## 背景与根因（已在代码层验真）

- 全局界面缩放 `HibikiAppUiScale`（`hibiki/lib/src/utils/app_ui_scale.dart`）用 `FittedBox(BoxFit.fill)` 把整棵 app 渲染进 `canvas = view/s` 的逻辑画布再拉满屏（单坐标系，焦点/命中正确）。
- 阅读器正文（`reader_hibiki_page.dart:1704` `InAppWebView`）、查词弹窗（`base_source_page.dart:276` `buildDictionary()` → `DictionaryPopupWebView`，作为阅读器 Stack 直接子节点挂在 `reader_hibiki_page.dart:1186`）、高亮（正文 WebView 内 CSS）**全是 WebView 纹理**：按 `逻辑尺寸 × dpi` 渲染成纹理后被 `FittedBox` 拉大 `s` → 放大必糊。原生绘制（按钮/列表/图标）放大不糊（Skia 按最终变换重栅格化）。
- 移动端（Android HC 真 WebView、iOS/macOS 真 WKWebView 平台视图）无离屏过采样旋钮，只有 `zoomBy`/`pageZoom`（内容重排，会移动划词坐标系=错位陷阱）。故跨平台统一解法 = 阅读器整页中和缩放 + 正文走字号。

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `hibiki/lib/src/utils/app_ui_scale.dart` | 新增 `HibikiAppUiScaleNeutralizer`（逆变换中和器），复用同文件私有 `_AppUiScaleScope` / `_scaleMediaQuery` | Modify |
| `hibiki/lib/src/media/sources/reader_hibiki_source.dart:112` | 构造阅读器页处用中和器包裹 | Modify |
| `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:754` | 书架 push 阅读器路由处用中和器包裹 | Modify |
| `hibiki/test/utils/app_ui_scale_neutralizer_test.dart` | 中和器几何/MediaQuery/缩放标记不变式 + 焦点几何基线一致 widget 测试 | Create |
| `hibiki/test/pages/reader_neutralizer_wired_test.dart` | 源码守卫：两处构造点都包了中和器 | Create |

---

## Task 1: 实现 `HibikiAppUiScaleNeutralizer`

**Files:**
- Modify: `hibiki/lib/src/utils/app_ui_scale.dart`（在 `HibikiAppUiScale` 类之后、`_scaleMediaQuery` 之前插入新类）
- Test: `hibiki/test/utils/app_ui_scale_neutralizer_test.dart`

- [ ] **Step 1: 写失败测试**

创建 `hibiki/test/utils/app_ui_scale_neutralizer_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

void main() {
  const Size physicalView = Size(1000, 800);

  // 驱动「真实」HibikiAppUiScale（它自己装 FittedBox + 缩放 MediaQuery +
  // _AppUiScaleScope）罩在固定 1000x800 画布上，再把中和器放进去——完全复刻
  // 生产嵌套：HibikiAppUiScale → … → 中和器 → 阅读器。视口尺寸用 tester.view 控制，
  // 让 HibikiAppUiScale 的 LayoutBuilder 拿到 1000x800 根约束、内部缩到 view/s。
  Widget appScaled({required double scale, required Widget child}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: HibikiAppUiScale(scale: scale, child: child),
      );

  testWidgets('neutralizer restores real view size, MQ and reports scale 1.0',
      (WidgetTester tester) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size gotConstraintBiggest;
    late Size gotMqSize;
    late double gotScale;

    await tester.pumpWidget(appScaled(
      scale: 2.0,
      child: HibikiAppUiScaleNeutralizer(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            gotConstraintBiggest = c.biggest;
            gotMqSize = MediaQuery.of(context).size;
            gotScale = HibikiAppUiScale.of(context);
            return const SizedBox.expand();
          },
        ),
      ),
    ));

    expect(gotConstraintBiggest, physicalView); // 真实视口布局,不是 500x400
    expect(gotMqSize, physicalView); // MediaQuery 还原真实几何
    expect(gotScale, 1.0); // 子树视角净缩放=1(focus ring/reorderable 不反补偿)
  });

  testWidgets('neutralizer is identity passthrough at scale 1.0',
      (WidgetTester tester) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size gotConstraintBiggest;
    await tester.pumpWidget(appScaled(
      scale: 1.0,
      child: HibikiAppUiScaleNeutralizer(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            gotConstraintBiggest = c.biggest;
            return const SizedBox.expand();
          },
        ),
      ),
    ));
    expect(gotConstraintBiggest, physicalView);
  });

  // 焦点几何守卫：globalRectOfBox 走真实变换链(localToGlobal)。中和器抵消全局缩放
  // (净=1)后,可聚焦控件的屏幕矩形必须等于「无全局缩放」基线 → 焦点导航几何与不缩放
  // 时完全一致。这同时间接证明焦点环(app 级单例,用同一 localToGlobal)不会错位。
  testWidgets('focus geometry under neutralizer == unscaled baseline',
      (WidgetTester tester) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget probe(GlobalKey key) => Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 120, top: 90),
            child: SizedBox(key: key, width: 200, height: 60),
          ),
        );

    final GlobalKey k1 = GlobalKey();
    await tester.pumpWidget(appScaled(
      scale: 1.0,
      child: HibikiAppUiScaleNeutralizer(child: probe(k1)),
    ));
    final Rect baseline =
        globalRectOfBox(k1.currentContext!.findRenderObject()! as RenderBox);

    final GlobalKey k2 = GlobalKey();
    await tester.pumpWidget(appScaled(
      scale: 2.0,
      child: HibikiAppUiScaleNeutralizer(child: probe(k2)),
    ));
    final Rect scaled =
        globalRectOfBox(k2.currentContext!.findRenderObject()! as RenderBox);

    // 净缩放=1 → 与基线逐项一致(允许 0.5px 量化误差)。
    expect(scaled.left, closeTo(baseline.left, 0.5));
    expect(scaled.top, closeTo(baseline.top, 0.5));
    expect(scaled.width, closeTo(baseline.width, 0.5));
    expect(scaled.height, closeTo(baseline.height, 0.5));
  });
}
```

> 注：`globalRectOfBox` 是 `hibiki/lib/src/focus/focus_geometry.dart` 的顶层函数（`Rect globalRectOfBox(RenderBox box)`），焦点导航据此计算方向距离。

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/utils/app_ui_scale_neutralizer_test.dart`
Expected: 编译失败 `HibikiAppUiScaleNeutralizer isn't defined`。

- [ ] **Step 3: 实现中和器**

在 `hibiki/lib/src/utils/app_ui_scale.dart` 的 `HibikiAppUiScale` 类闭合 `}`（第 84 行）之后、`MediaQueryData _scaleMediaQuery(...)`（第 88 行）之前，插入：

```dart
/// 在阅读器等需要原生清晰度的全屏子树里「中和」祖先 [HibikiAppUiScale] 的整体缩放。
///
/// 逆变换：把子树重新按**真实视口尺寸**布局、净缩放回到 1.0，使其中的 WebView 平台
/// 视图按原生像素密度渲染（放大不再栅格软化）。正文大小改由阅读器自带字号控制。
///
/// **关键**：必须整棵子树（WebView + 划词弹窗 + 高亮 + 铬层）一起中和——它们处于
/// 同一坐标空间，所以 JS 报的 selectionRect 定位不会错位。**不要**只中和 WebView：
/// 那正是被撤销的 [HibikiNativeScale] 老坑（只反缩放 WebView、弹窗没跟上 → 错位）。
///
/// 必须从**路由层**包在页面外，使页面 State.context 也落在本中和器之下，辅助方法
/// 经 State.context 读到的 MediaQuery 才是真实几何。
class HibikiAppUiScaleNeutralizer extends StatelessWidget {
  const HibikiAppUiScaleNeutralizer({required this.child, super.key});

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
        final Size canvas = constraints.biggest; // 祖先给的缩放画布 (view/s)
        final Size view = canvas * s; // 还原真实视口
        final MediaQueryData mq = MediaQuery.of(context);
        // 镜像 HibikiAppUiScale：用 FittedBox(BoxFit.fill) 把「真实尺寸子树」装回
        // 「画布尺寸盒」里 → 本地缩放 1/s；叠加祖先的 ×s 后净缩放 = 1。box 尺寸恒为
        // canvas（=入参约束），绝不溢出，hitTest 不丢命中（同 BUG-022 的 FittedBox 取舍）。
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: view,
            child: MediaQuery(
              data: _scaleMediaQuery(mq, s), // ×s 还原真实 size/inset
              child: _AppUiScaleScope(
                scale: HibikiAppUiScale.defaultScale, // 子树视角:净缩放=1
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/utils/app_ui_scale_neutralizer_test.dart`
Expected: PASS（3 个用例：尺寸/MQ/缩放标记 + scale1 直通 + 焦点几何基线一致）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/app_ui_scale.dart hibiki/test/utils/app_ui_scale_neutralizer_test.dart
git commit -m "feat(reader): add HibikiAppUiScaleNeutralizer to render scaled subtrees at native density"
```

---

## Task 2: 在两处阅读器构造点接线中和器

**Files:**
- Modify: `hibiki/lib/src/media/sources/reader_hibiki_source.dart:112`
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:754`
- Test: `hibiki/test/pages/reader_neutralizer_wired_test.dart`

- [ ] **Step 1: 写源码守卫失败测试**

创建 `hibiki/test/pages/reader_neutralizer_wired_test.dart`：

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 守卫：两处构造 ReaderHibikiPage 的地方都必须用 HibikiAppUiScaleNeutralizer 包裹，
/// 否则全局界面缩放会把阅读器 WebView 正文/弹窗光栅放大致糊（统一走字号方案）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('reader_hibiki_source wraps ReaderHibikiPage with neutralizer', () {
    final String src = read('lib/src/media/sources/reader_hibiki_source.dart');
    expect(src.contains('HibikiAppUiScaleNeutralizer'), isTrue,
        reason: 'reader_hibiki_source.dart 必须用中和器包裹 ReaderHibikiPage');
  });

  test('history page wraps pushed ReaderHibikiPage with neutralizer', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_history_page.dart');
    expect(src.contains('HibikiAppUiScaleNeutralizer'), isTrue,
        reason: '书架 push 阅读器路由必须用中和器包裹 ReaderHibikiPage');
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/pages/reader_neutralizer_wired_test.dart`
Expected: FAIL（两处尚未包裹，`contains` 为 false）。

- [ ] **Step 3a: 接线 reader_hibiki_source.dart**

先在文件顶部 import 区加入（若尚无）：

```dart
import 'package:hibiki/src/utils/app_ui_scale.dart';
```

把 `reader_hibiki_source.dart:112` 的：

```dart
    return ReaderHibikiPage(
      item: item,
      bookId: bookId,
      initialBookmarkJump: initialBookmarkJump,
```

改为（注意保留原有其余命名参数与闭合括号，只在外层包一层）：

```dart
    return HibikiAppUiScaleNeutralizer(
      child: ReaderHibikiPage(
        item: item,
        bookId: bookId,
        initialBookmarkJump: initialBookmarkJump,
```

并在该 `ReaderHibikiPage(...)` 原闭合 `)` 后补上中和器的闭合 `)`（即多一层括号）。实现时按文件实际参数列表对齐缩进。

- [ ] **Step 3b: 接线 reader_hibiki_history_page.dart**

先确认顶部已 import `package:hibiki/src/utils/app_ui_scale.dart`（无则补）。

把 `reader_hibiki_history_page.dart:754` 的：

```dart
        builder: (_) => ReaderHibikiPage(
          bookId: book.ttuBookId,
          item: _srtBookMediaItem(book),
        ),
```

改为：

```dart
        builder: (_) => HibikiAppUiScaleNeutralizer(
          child: ReaderHibikiPage(
            bookId: book.ttuBookId,
            item: _srtBookMediaItem(book),
          ),
        ),
```

- [ ] **Step 4: 运行守卫 + analyze**

Run: `flutter test test/pages/reader_neutralizer_wired_test.dart`
Expected: PASS（两处都含中和器）。

Run: `flutter analyze lib/src/media/sources/reader_hibiki_source.dart lib/src/pages/implementations/reader_hibiki_history_page.dart lib/src/utils/app_ui_scale.dart`
Expected: No issues。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/media/sources/reader_hibiki_source.dart hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart hibiki/test/pages/reader_neutralizer_wired_test.dart
git commit -m "feat(reader): neutralize global UI scale at reader route so body renders at native density"
```

---

## Task 3: 全量验证 + 文档

**Files:**
- Modify: `docs/BUGS.md`（追加一条 BUG-NNN）

- [ ] **Step 1: 格式化 + 相关测试**

Run: `cd hibiki && dart format lib/src/utils/app_ui_scale.dart test/utils/app_ui_scale_neutralizer_test.dart test/pages/reader_neutralizer_wired_test.dart`

Run: `cd hibiki && flutter test test/utils/ test/pages/ test/widgets/`
Expected: 全绿（含新增 5 用例：中和器 3 + 接线守卫 2；且既有 app_ui_scale / focus_ring 不回归）。

- [ ] **Step 2: 全量回归**

Run: `cd hibiki && flutter test`
Expected: 全绿。若出现与本改动无关的并发 agent 失败，按 `CLAUDE.md` 只 stage 本轮文件。

- [ ] **Step 3: 记录 BUG**

在 `docs/BUGS.md` 追加（编号取当前最大 +1，避免与并发 agent 冲突）：

```markdown
## BUG-NNN：放大界面后阅读器正文/划词弹窗/高亮发糊

- 现象：调大「界面大小」后，阅读器书内正文、划词弹窗、选区高亮变模糊（放大时；缩小未报）。
- 根因：全局 `HibikiAppUiScale` 用 `FittedBox` 把整树渲染进 `view/s` 画布再拉大；正文/弹窗/高亮均为 WebView 纹理，按 `逻辑尺寸×dpi` 渲染后被拉大 `s` 倍 → 丢分辨率。`reader_hibiki_page.dart:1704`（正文 WebView）、`base_source_page.dart:276`（弹窗）。
- [x] ① 根因修复：新增 `HibikiAppUiScaleNeutralizer`，阅读器整页中和全局缩放、净缩放=1、按原生密度渲染；正文统一走阅读器字号。提交：<commit>
- [x] ② 自动测试：`test/utils/app_ui_scale_neutralizer_test.dart`（几何/MQ/缩放标记不变式）+ `test/pages/reader_neutralizer_wired_test.dart`（两构造点接线守卫）。
- 设备复测（放大界面后正文/弹窗/高亮清晰、划词弹窗不错位）：待用户。
```

- [ ] **Step 4: 提交**

```bash
git add docs/BUGS.md
git commit -m "docs(bugs): record reader UI-scale blur root-cause fix (neutralizer)"
```

---

## 设备复测（用户执行，代码改动无法自证清晰度）

1. 设「界面大小」> 100%（如 150%），进入一本书：正文应**清晰**（不再栅格软化）。
2. 划词：弹窗内容清晰，且弹窗**定位准确贴住选中文字**（验证未重蹈坐标错位）。
3. 选区高亮：颜色块**贴合文字**、清晰。
4. 阅读器铬层（底栏/设置）按真实尺寸显示（不随界面大小变化——这是「统一成字号」的预期语义）。
5. 退出阅读器回书架：书架/设置等原生 UI 仍按界面大小整体缩放（中和只作用于阅读器）。

---

## Self-Review

- **Spec 覆盖**：正文(WebView 原生密度)=Task1+2；弹窗/高亮(同子树一起中和)=Task1+2（已验 `buildDictionary` 在阅读器 Stack 内，非 Overlay）；focus ring/reorderable 不反补偿=Task1 的 `_AppUiScaleScope(scale: 1.0)` 覆写；真实 MediaQuery 覆盖辅助方法=路由层包裹使 State.context 在中和器下。
- **Placeholder 扫描**：无 TBD/TODO；测试与实现代码均完整给出。
- **类型一致**：`HibikiAppUiScaleNeutralizer({required Widget child})`、`HibikiAppUiScale.of/defaultScale`、`_scaleMediaQuery(mq, s)`、`_AppUiScaleScope({scale, child})` 在各 Task 中名称一致，且 `_scaleMediaQuery`/`_AppUiScaleScope` 为 `app_ui_scale.dart` 既有私有符号、同文件可用。
- **风险**：① 第三方/某些 route 若另有阅读器入口未包中和器→守卫只覆盖已知两点，新增入口需补包（注释提醒）。② 中和器依赖 `constraints` 有界；非全屏嵌入场景退化为 passthrough（不糊修但不崩）。③ standalone 词典页 WebView 同病未在本计划范围（如需，后续同样 `HibikiAppUiScaleNeutralizer` 包裹）。

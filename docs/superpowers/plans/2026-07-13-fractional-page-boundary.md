# 亚像素页边界提前停翻 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复真实 macOS WKWebView 在 `pitch=564.490967` 时于第 31 页误判 `limit`，并保持 BUG-169 的单页步进与首末页边界语义。

**Architecture:** 在 JavaScript `paginate()` 与其 Dart 纯函数影子中，把距整数页号不超过 1px 的浮点商规范化为整数，再沿用原 forward floor+1 / backward ceil-1 算法。用真机精确值先写红测，源码守卫锁定两侧同源公式，最后在真实 macOS WKWebView 复跑全章扫描。

**Tech Stack:** Dart 3.12、Flutter 3.44、注入式 JavaScript、flutter_test、macOS WKWebView integration_test。

## Global Constraints

- 只修改 `reader_pagination_scripts.dart`、`reader_paginate_step_test.dart`、`reader_paginate_js_guard_static_test.dart` 与 BUG-783 完成记录。
- 页边界容差固定为现有语义的 1px；不得随页数累计或扩大。
- 不修改分页 CSS、`getScrollContext()`、pagination metrics、章节切换或 BUG-782 harness。
- 不纳入任何旧分支的其它 57 个文件。
- 严格 TDD：先用精确真机数值证明旧实现红，再写最小实现。

---

### Task 1: 用 1px 商容差修复 forward/backward 边界

**Files:**
- Modify: `hibiki/lib/src/reader/reader_pagination_scripts.dart:123-151,2164-2205`
- Test: `hibiki/test/reader/reader_paginate_step_test.dart`
- Test: `hibiki/test/reader/reader_paginate_js_guard_static_test.dart`

**Interfaces:**
- Consumes: `resolvePaginateStepForTesting(...)`、JS `pageStepPosition(currentScroll, pitch)`，以及现有 `ReaderPageStep` 返回契约。
- Produces: forward/backward 共用的规范化页号商；距整数页边界 ≤1px 时精确视为该整数，>1px 时保持原 floor/ceil 行为。

- [ ] **Step 1: 先加入精确数值红测**

在 `reader_paginate_step_test.dart` 的 `sub-pixel page-boundary drift` group 中加入：

```dart
test('forward crosses fractional page 31 instead of returning limit', () {
  const double fractionalPitch = 564.490967;
  final ReaderPageStep step =
      ReaderPaginationScripts.resolvePaginateStepForTesting(
    direction: ReaderNavigationDirection.forward,
    currentScroll: 17499,
    columnPitch: fractionalPitch,
    minAlignedScroll: 0,
    maxAlignedScroll: 40 * fractionalPitch,
  );

  expect(step.scrolled, isTrue);
  expect(step.targetScroll, closeTo(32 * fractionalPitch, 1e-9));
});

test('backward crosses an N-plus-epsilon quotient instead of returning limit',
    () {
  const double fractionalPitch = 564.490967;
  final ReaderPageStep step =
      ReaderPaginationScripts.resolvePaginateStepForTesting(
    direction: ReaderNavigationDirection.backward,
    currentScroll: 33305,
    columnPitch: fractionalPitch,
    minAlignedScroll: 0,
    maxAlignedScroll: 80 * fractionalPitch,
  );

  expect(step.scrolled, isTrue);
  expect(step.targetScroll, closeTo(58 * fractionalPitch, 1e-9));
});
```

在 `reader_paginate_js_guard_static_test.dart` 中把只锁 literal floor/ceil 的前两个测试替换为：

```dart
test('normalizes near-integer page quotient with the existing 1px contract',
    () {
  expect(paginate, contains('var pageCoordinate = stepScroll / pitch;'));
  expect(paginate, contains('var nearestPage = Math.round(pageCoordinate);'));
  expect(
    paginate,
    contains('Math.abs(pageCoordinate - nearestPage) * pitch <= 1'),
  );
  expect(paginate, contains('pageCoordinate = nearestPage;'));
});

test('forward and backward consume the normalized page coordinate', () {
  expect(paginate, contains('Math.floor(pageCoordinate) + 1'));
  expect(paginate, contains('Math.ceil(pageCoordinate) - 1'));
});
```

- [ ] **Step 2: 运行红测并确认失败原因**

```bash
cd hibiki
flutter test \
  test/reader/reader_paginate_step_test.dart \
  test/reader/reader_paginate_js_guard_static_test.dart
```

Expected: FAIL。forward exact-value 测试应显示 `scrolled=false` 或 target 仍为
`31 * pitch`；backward 对称测试应显示 target 仍为 `59 * pitch`；源码守卫应找不到
`pageCoordinate` 容差代码。若精确数值没有触发这些失败，停止实现并重新核对真机日志，不改生产代码。

- [ ] **Step 3: 在 Dart 影子中加入最小规范化**

在 `_pageStepPosition` 得到 `stepScroll` 后、forward/backward 分支前加入：

```dart
final double rawPageCoordinate = stepScroll / columnPitch;
final int nearestPage = rawPageCoordinate.round();
final double pageCoordinate =
    (rawPageCoordinate - nearestPage).abs() * columnPitch <= 1
        ? nearestPage.toDouble()
        : rawPageCoordinate;
```

并只替换两处分支的 basePage 来源：

```dart
final int basePage = pageCoordinate.floor(); // forward
final int basePage = pageCoordinate.ceil(); // backward
```

不得改变 clamp、`target > stepScroll + 1` / `target < stepScroll - 1` 或
`ReaderPageStep` 接口。

- [ ] **Step 4: 在 JavaScript paginate 中加入同源规范化**

在 `var stepScroll = this.pageStepPosition(currentScroll, pitch);` 后加入：

```javascript
var pageCoordinate = stepScroll / pitch;
var nearestPage = Math.round(pageCoordinate);
if (Math.abs(pageCoordinate - nearestPage) * pitch <= 1) {
  pageCoordinate = nearestPage;
}
```

只把目标公式改成：

```javascript
var targetForward = (Math.floor(pageCoordinate) + 1) * pitch;
var targetBack = (Math.ceil(pageCoordinate) - 1) * pitch;
```

max/min clamp、1px limit guard、`setPagePosition` 与 `_diagTurn` 保持原样。

- [ ] **Step 5: 格式化并运行聚焦回归**

```bash
cd hibiki
dart format \
  lib/src/reader/reader_pagination_scripts.dart \
  test/reader/reader_paginate_step_test.dart \
  test/reader/reader_paginate_js_guard_static_test.dart
flutter test \
  test/reader/reader_paginate_step_test.dart \
  test/reader/reader_paginate_js_guard_static_test.dart \
  test/reader/paged_cross_chapter_limit_test.dart
```

Expected: PASS。精确 forward target 为 `18063.710944`，backward target 为
`32740.476086`；现有 aligned、mid-page、首末页 clamp、跨章 limit 与 BUG-169 用例均保持绿色。

- [ ] **Step 6: 只提交 3 个实现文件**

```bash
git add \
  hibiki/lib/src/reader/reader_pagination_scripts.dart \
  hibiki/test/reader/reader_paginate_step_test.dart \
  hibiki/test/reader/reader_paginate_js_guard_static_test.dart
git diff --cached --check
git commit -m "fix(reader): tolerate fractional page boundary quotients"
```

Expected: commit 只含上述 3 个文件，不含 `hibiki/macos/Podfile.lock`、BUG-782 harness 或旧分支文件。

---

### Task 2: 在真实 macOS WKWebView 复验并完成 BUG-783

**Files:**
- Verify: `hibiki/integration_test/reader_pagination_test.dart`
- Modify: `docs/bugs/BUG-783-fractional-page-boundary-premature-limit.md`
- Modify generated index: `docs/BUGS.md`

**Interfaces:**
- Consumes: Task 1 的 JS/Dart 同源修复和 `a6c9904d0` 的 raw-double harness。
- Produces: page 31 不再提前 `limit` 的真实引擎证据，以及带实现哈希/测试路径的完成记录。

- [ ] **Step 1: 复跑真实 macOS 全章分页扫描**

```bash
cd hibiki
flutter test integration_test/reader_pagination_test.dart -d macos --no-pub
```

Expected: `pitch` 保持 raw 小数；page 31 forward 继续到 page 32，不再同步返回 `limit`；
扫描走到真实章末，I1/I2/I3/I4/I5/I6 全部通过，命令 exit 0。

- [ ] **Step 2: 更新 BUG-783 完成证据**

在 `docs/bugs/BUG-783-fractional-page-boundary-premature-limit.md` 中：

- 将 `[ ] ①` 改为 `[x] ①`，记录 Task 1 的真实提交哈希及 JS/Dart 修改位置。
- 将 `[ ] ②` 改为 `[x] ②`，记录两个精确 TDD 用例、JS 源码守卫、聚焦测试结果和 macOS
  WKWebView 全章扫描结果。
- 保留 BUG-782 为「探针假阳性」，不得把本 bug 改名为累计漂移。

- [ ] **Step 3: 重建索引并提交文档**

```bash
dart run tool/bug.dart reindex
git add \
  docs/BUGS.md \
  docs/bugs/BUG-783-fractional-page-boundary-premature-limit.md
git diff --cached --check
git commit -m "docs(bug): close fractional page boundary limit"
```

Expected: docs commit 只含 BUG-783 与自动索引；`hibiki/macos/Podfile.lock` 仍未暂存。

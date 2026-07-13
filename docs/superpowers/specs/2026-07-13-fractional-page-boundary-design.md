# 亚像素分页边界提前 `limit` 修复设计

- 日期：2026-07-13
- 分支：`codex/md3-pagination-drift-20260713`
- reader 基线：`develop@b177f858b`
- 关联缺陷：BUG-786

## 背景与验真结论

旧分页集成探针把 WebView 的 `scroll` 与 `pageSize` 分别取整，导致正确亚像素页网格被 I1
误报为累计漂移。`a6c9904d0` 保留原始 `double` 后，真实 macOS WKWebView 报告
`pitch=564.490967`，I1/I2/I3/I4/I6 全部通过，因此 BUG-785 的产品累计漂移未复现。

同一次全章扫描暴露出另一条真实故障：page 31 的 `scroll=17499`，距离理论页边界
`31 × 564.490967 = 17499.219977` 仅 0.22px；内容仍有 17426px，但同步
`paginate('forward')` 返回 `limit`，使 `fullChapterScan()` 提前结束并触发 I5。

## 根因候选

`pageStepPosition()` 已把距页边界 1px 内的 readback 归一为 `N × pitch`，但 `paginate()`
紧接着又做一次除法来恢复页号：

```javascript
var targetForward = (Math.floor(stepScroll / pitch) + 1) * pitch;
var targetBack = (Math.ceil(stepScroll / pitch) - 1) * pitch;
```

对当前精确输入，JavaScript 实际得到：

```text
pitch        = 564.490967
stepScroll   = 17499.219976999997
step/pitch   = 30.999999999999996
floor(商)    = 30
forward目标  = 31 * pitch = stepScroll
```

target 没有前进，随后 `targetForward <= stepScroll + 1` 把它误判为末页。反向路径在二进制商
落到 `N + ε` 时会被 `ceil` 推到下一整数，存在对称的原地 `limit` 风险。纯 Dart 影子复刻了
相同 floor/ceil 算法，必须同改以保持测试与 JS 同源。

## 设计

### 复用现有 1px 页边界语义

在 JS `paginate()` 和 Dart `resolvePaginateStepForTesting()` 中，先计算页号商及最近整数页号；
若两者在像素空间的差不超过 1px，就把商规范化为该整数，否则保留原商：

```text
pageCoordinate = stepScroll / pitch
nearestPage    = round(pageCoordinate)
if abs(pageCoordinate - nearestPage) * pitch <= 1px:
    pageCoordinate = nearestPage
```

forward 继续使用 `floor(pageCoordinate)+1`，backward 继续使用
`ceil(pageCoordinate)-1`。这不是新增任意 epsilon，而是把 `pageStepPosition()` 已声明的
「1px 内视为同一页边界」契约延续到页号商；距边界超过 1px 的真正页内错位仍走原 floor/ceil，
不会复活 BUG-169 的跳两页问题。

### 修改边界

只修改以下生产/测试文件：

1. `hibiki/lib/src/reader/reader_pagination_scripts.dart`
   - Dart 影子：在 forward/backward 分支前计算带 1px 容差的页号商。
   - JS `paginate()`：用同一公式规范化页号商，再分别 floor/ceil。
2. `hibiki/test/reader/reader_paginate_step_test.dart`
   - 用本次真机精确值增加 page 31 forward 红测。
   - 用同一 pitch 构造 `N+ε` 的 backward 对称红测。
3. `hibiki/test/reader/reader_paginate_js_guard_static_test.dart`
   - 锁定 JS 存在像素化的 1px 商容差，且 forward/backward 都消费规范化后的页号商。

实现完成后只更新 BUG-786 状态并重建 bug 索引。不得修改分页 CSS、`getScrollContext()`、
pagination metrics、章节切换、BUG-785 harness，也不得带入任何旧分支的其它 57 个文件。

## TDD 验证

### 精确数值红测

- forward：`pitch=564.490967`、`currentScroll=17499`、max 足够大；期望
  `scrolled=true`，target 为 `32 × pitch = 18063.710944`。旧实现错误返回原页/`limit`。
- backward：同一 pitch，取 `currentScroll=33305`；归一页边界为
  `59 × pitch = 33304.967053`，二进制商为 `59.00000000000001`；期望
  `scrolled=true`，target 为 `58 × pitch = 32740.476086`。旧 `ceil` 会落回原页。
- 保留现有 aligned、mid-page、首末页 clamp 和 BUG-169 测试，证明容差不改变 >1px 的页内语义。

### 真实引擎门禁

修复后在 macOS WKWebView 复跑
`integration_test/reader_pagination_test.dart`。验收必须同时满足：

- raw pitch 仍保留小数精度；
- page 31 forward 不再同步返回 `limit`，扫描能继续到真实章末；
- I1/I2/I3/I4/I5/I6 全部通过；
- 不出现一次翻两页、倒退或超过 maxScroll。

## 风险与控制

1. **容差过宽吞掉真实页内位置**：固定复用现有 1px，而不是按页数放大；>1px 时保持原商。
2. **只修 forward 留下对称回归**：forward 与 backward 共用同一规范化页号商，并各有精确红测。
3. **Dart 影子与 JS 漂移**：两侧使用同一公式，源码守卫锁定 JS，纯函数测试锁定数值行为。
4. **误把 BUG-785 探针修复混入产品修复**：`a6c9904d0` 保持独立；本实现不再改 harness。
5. **范围膨胀**：不碰 CSS、metrics、章节逻辑或旧分支其它 57 文件；若精确红测不能复现，
   停止实施并重新取证，不扩大修改面。

## 验收标准

- 精确 forward/backward 测试先红后绿。
- JS 守卫、Dart 影子及现有跨章边界回归测试全部通过。
- 真实 macOS WKWebView 全章扫描不在 page 31 提前停止，I5 通过。
- 最终产品提交只含上述 3 个代码/测试文件；BUG-786 文档完成另作 docs 提交。

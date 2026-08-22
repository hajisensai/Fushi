## BUG-1743 · VN 缺 scrollToSearchMatch 且调用点无存在性守卫
- **报告**：2026-08-19（用户：）
- **真实性**：✅ 真 bug。

  **缺实现**：`scrollToSearchMatch` 只定义在分页/连续共享的 `window.fushiReader` 上
  （`fushi/lib/src/reader/reader_pagination_scripts.dart:1599-1662`，同族 `clearSearchHighlight`
  在 `:1663`）。`reader_visual_novel_scripts.dart` 全文**零命中**
  `scrollToSearchMatch` / `clearSearchHighlight` / `scrollToRange` / `scrollToTarget`。
  VN 的 host-compat shim 块（`:2990-3049`）当时只补了 4 个方法
  （`updatePageSize` / `getFirstVisibleCharOffset` / `setChromeInsets` / `restoreToCharOffset`）。

  **调用点裸调**：`reader_pagination_scripts.dart:729-730`
  `'window.fushiReader.scrollToSearchMatch(...)'` —— 对比同族收藏路径用的是带守卫写法
  `'window.fushiReader && window.fushiReader.restoreToCharOffset(...)'`，search 这条是裸调。
  全部 Dart 调用点均无模式检查：
  `reader_fushi/chrome.part.dart:1620-1623`（`onSearchJump` 构造）、`:1656`（同章直接 evaluate，
  **无 try-catch**）、`:2227`/`:2245`（收藏跳转 by-text 回退，BUG-876）、
  `reader_fushi/navigation.part.dart:599-612`（队列消费端，有 try/catch 但无函数存在性检查）。
  队列在 VN 下确实会被触发：`navigation.part.dart:190-197` 的注释直接点名 VN。
  搜索入口在 VN 下也没被禁用（`reader_quick_settings_sheet.dart:695` 只判 epubBook / onSearchJump）。

  **实际后果**：JS 抛 `TypeError: ...scrollToSearchMatch is not a function`。但
  `evaluateJavascript` 的 JS 运行时异常在移动端通道上一般**不回传成 Dart 异常**（返回 null），
  所以队列消费端的 try/catch + ErrorLogService 抓不到，1c/2b 更是连 catch 都没有。
  用户可见症状：VN 下**搜索结果点了没反应**（同章）/ **只跳到目标章第一屏**（跨章，章节导航本身
  成功、只有章内定位失败）；缺 offset 的收藏跳转同理停在章首。同一次 evaluate 里 TypeError 之后的
  语句也会被一并中断。

- **[x] ① 已修复** — 提交见本分支。
  - `reader_visual_novel_scripts.dart` shim 块新增 `vn.scrollToSearchMatch(query, hintOffset)`：
    **不能沿用分页版**（那版 `createWalker()` 只走当前屏、且靠 VN 没有的 `scrollToRange` 滚动）。
    VN 版在整章 `contentStream.textEntries` 上拼全文匹配，就近策略与分页版一致（取离 `hintOffset`
    最近的一处命中），再走「字符偏移 → 屏索引 → `renderScreen`」链路，返回 `calculateProgress()`
    与分页版契约一致（调用方靠它落库）。
    **关键换算**：命中下标是「拼接后的原始文本」坐标，而屏索引吃的是**可匹配字符**坐标
    （`countChars` 跳过空白/不可匹配字符）。直接拿命中下标当 charOffset 用会在任何含空白的章节上
    系统性偏移，故必须经命中所在 entry 的前缀 `countChars(prefix)` 换算。
  - 同时补 `vn.clearSearchHighlight()`（`CSS.highlights.delete`，带 try）。
  - `reader_pagination_scripts.dart` 的 `scrollToSearchMatchInvocation` /
    `clearSearchHighlightInvocation` 加**存在性守卫**（第二层防线，与 `pageInfoInvocation` 同款写法）：
    即便某个 shell 未实现也只是 no-op，不再抛 TypeError 污染控制台 / 中断同一次 evaluate 的后续语句。

- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/vn_shell_smoke_test.dart`：VN 宿主接口清单守卫（见 [[BUG-1742]]）+
    「VN 搜索在整章 contentStream 上匹配并做坐标换算」——断言**不得**出现 `createWalker(`
    （照搬分页版只会在当前屏内找，跨屏命中永远找不到）、必须有 `countChars(prefix)` 换算、
    必须走 `screenIndexForCharOffset`、必须返回 `calculateProgress()`。
  - `fushi/test/reader/reader_pagination_scripts_test.dart`：两条逐字符串断言改为 `contains`
    并新增守卫断言（转义意图保留：`a"b` / CJK / 反斜杠换行三条原有覆盖不变）。
  - 验证：`flutter test test/reader/ test/pages/ test/media/ --no-pub` → 8961 passed。

- **备注**：headless 跑不到真 WebView，**VN 下的搜索跳转须真机复验**。
  shim 块现在是「VN 必须实现的宿主接口清单」的唯一真相点，新增接口请一并更新
  `vn_shell_smoke_test.dart` 的清单断言。与 [[BUG-1742]] 同一批落地。

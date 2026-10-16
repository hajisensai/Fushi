## BUG-3419 · 在线漫画失败页吞掉点击翻页，读者卡在失败页翻不走
- **报告**：2026-10-15（审查已合入 PR #2196「在线直读失败页可重取」时发现）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/manga/manga_overlay_html.dart`：`_onTap` 首行 `if (_retryFailedPageAt(x, y)) return;` 排在 `_tapZoneTurn` 之前，且 `_retryFailedPageAt` 按失败页**整页矩形**命中——修复前 :2001 / :1621-1629，引入提交 c96ade20c5）
- **[x] ① 已修复** — `_retryFailedPageAt` 只认失败页中心的重试符号命中区（`RETRY_HIT_PX = 72` 的方块，≥48dp）；`_onTap` 里重取挪到 OCR 选字与翻页热区之后（修复后 `manga_overlay_html.dart:1621-1637` / `:2016`）。提交：待提交
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reader_transforms_js_test.dart`「失败页上左右翻页热区照常翻页，只有中央重试符号触发重取」（node 跑注入的 `_onTap` + 热区 + 重取真实切片）；既有重取用例补「失败页上离开图标的点击不重取」。变异实测：恢复整页命中 + 重取前置 → 两条用例红（`left zone must turn on a failed page: []`）；还原后 7/7 绿。
- **备注**：重取的其它触发路径不变：翻到含失败页的跨页（`__mangaApplyTranslate`）、长条模式失败页新进入视口时各重取一次。

### 根因

PR #2196 给取页失败的页打 `data-load-failed`，并在 `_onTap` 最前面调用 `_retryFailedPageAt(x, y)`：
只要点击坐标落在任一失败页的 `getBoundingClientRect()` 内就重取并 `return`。单页模式下失败页铺满视口，
所以**任何**点击（包括左右翻页热区）都被当成重试吞掉，`_tapZoneTurn` 永远走不到。源还挂着时重取很快又
失败、标记又回来，下一次点击再被吞——读者只能靠滑动翻走，点击翻页完全失效。

### 修复

- 重试命中区收窄到失败页中央的重试符号（CSS `::before` 画在页面中心）周围 72px 方块；页面其它位置不再触发重取。
- 判定顺序改为 OCR 选字 → 翻页热区（复用 `_tapZoneTurn`，不另写测宽）→ 重试符号 → 双击 / 空白单击。
  热区在失败页上照常翻页；符号若恰好落在热区内（如 kindle 布局中央、双页的页中心落进边缘热区），
  热区优先，重取由翻页进出该跨页触发。

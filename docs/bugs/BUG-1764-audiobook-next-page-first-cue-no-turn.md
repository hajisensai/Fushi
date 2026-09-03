## BUG-1764 · 有声书跟随：下一页第一句不自动翻页

- **报告**：2026-08-21（用户反馈：有声书读到下一页的第一句话时不会自动翻页）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_pagination_scripts.dart:2193`（修复前的
  `if (startEdge >= 0 && startEdge < context.viewportExtent) return false;`），更深一层在
  `alignToPage`（同文件 `:2151`）缺分页网格相位。

### 症状

有声书跟随播放（`followAudio` 开）时，音频推进到下一页的第一句，页面不翻；要等到第二句
（或更靠后的句子）才翻过去。翻过去之后落页位置是对的，所以表现为「下一页开头那一两句被跳过」。

### 根因

分页 cue 跟随的唯一落页路径是 `scrollToRange`：取句首起始边（竖排 `rect.top` / 横排 `rect.left`）
加当前滚动量得到 anchor，再 `alignToPage`(floor) 落页。

**滚动坐标的原点是 body 的 padding box 起始边，而列内容从 content box 起始边开始**，两者恰差一个
turn 轴起始 padding。所以列 j 的起始滚动坐标是 `contentStart + j*pageStep`，不是 `j*pageStep`。
旧 `alignToPage` 用裸 `floor(anchor/pageStep)`，等于把整个列网格平移了 `contentStart`，两个方向
各错一次：

1. `contentStart > column-gap` 时，每列末尾 `contentStart − gap` 那段被判进下一列 → 有声书读到
   「句首是行尾单字」的 cue 时凭空前翻一页、下一句又翻回 = 抖动。这就是 **BUG-875**。
2. BUG-875 当时的修法不是补相位，而是在 `scrollToRange` 加一条
   `startEdge < context.viewportExtent` 的「已可见即不翻」短路。而 client 视口
   （`body.clientWidth/Height`，body 是 `border-box`、margin/border 皆 0）比一页真正的内容宽出
   turn 轴**两侧** padding：

   ```
   viewportExtent − pageStep = (contentStart + contentBox + contentEnd) − (contentBox + gap)
                             = contentStart + contentEnd − gap
   ```

   下一页第一句的起始边恰好是 `contentStart + pageStep`，于是短路命中的充要条件塌成
   **`contentEnd > column-gap`**（turn 轴结束边 padding 大于列间距，`column-gap` 恒 22px）：

   - 横排：`contentEnd = padding-right = margin-right vw = 0.02·W` → **窗口宽 > 1100px 必现**
     （1280px → 25.6 > 22；1920px → 38.4 > 22）。桌面默认横排就中招。
   - 竖排：`contentEnd = padding-bottom = margin-bottom vh + fontSize + --chrome-bottom-inset`
     → 字号 > 22、或底栏「挤压」模式占位（+56·scale）、或移动端系统底部 inset > 0 时必现。

   命中即 `return false` → 该翻不翻。

两个场景的 `startEdge` 与 `targetScroll` 取值**完全相同**，单一阈值结构上区分不了它们——说明判据
维度本身就错了，可见性短路只是用一条带宽把相位误差盖住，代价是把下一页开头等宽的一段一起吞掉。

### 修复

- `getScrollContext` 暴露 `contentStart`（turn 轴起始 padding：竖排 `paddingTop`＝含
  `--chrome-top-inset`，横排 `paddingLeft`），与落页锚的取轴严格同源。
- `alignToPage` 改为 `floor((offset − contentStart)/pageSize)*pageSize`，成为精确的列号函数。
  返回值仍落在 `j*pageSize` 的滚动网格上，**网格本身零变化**（`paginate` / `pageStepPosition` /
  `minScroll` 不受影响）。
- 删掉 `scrollToRange` 里的 `viewportExtent` 可见性短路：补相位后
  `targetScroll === currentScroll` 已经精确表达「句首就在本页」，BUG-875 与本 bug 同时消失，
  不再需要任何特例分支。

顺带修正的同源错判：跳到下一页**后半段**的句子，旧裸网格会翻过头整整一页（`scrollToProgressPaged`
/ `alignToFragmentTarget` / `scrollToCharOffset` 共用 `alignToPage`，一并变正确）。

- **[x] ① 已修复** — `fushi/lib/src/reader/reader_pagination_scripts.dart`：`getScrollContext`
  增 `contentStart`、`alignToPage` 减相位、`scrollToRange` 删可见性短路；Dart 影子
  `revealAnchorTargetScrollForTesting` / `revealScrollTargetForTesting` 同步。提交见分支
  `worktree-fix-audiobook-next-page-first-cue`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reveal_viewport_visible_no_flip_test.dart`
  重写为「reveal 落页网格相位」契约：BUG-1764 组（下一页首句必须翻、翻一页不翻两页）+ BUG-875 组
  （行尾单字不得前翻，双向锁）+ 边界回归 + 源码守卫（`getScrollContext` 必须暴露 `contentStart`、
  `alignToPage` 必须减相位、`scrollToRange` 不得复活 `viewportExtent` 短路）。两轮变异实测：移除
  JS 相位 → 守卫红；移除 Dart 影子相位 → 3 条行为用例红。
- **备注**：本 bug 是 BUG-875 修法引入的回归，两者共享同一根因，故合并在同一份契约测试里守，
  避免未来两处几何漂移。未做真机复测（无对应设备取证），相位关系由 CSS 生成器
  `reader_content_styles.dart` 的 body 规则代数推导 + 纯函数影子锁定。

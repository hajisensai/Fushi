## BUG-661 · 从目录往前翻落到封面而非封面章节最后部分（图片章章末落点塌缩）
- **报告**：2026-07-09（用户：）— 「安達としまむら2 从目录，往前翻，会去到封面，而不是封面章节的最后部分」
- **真实性**：✅ 真 bug — 根因两处（图片章「章末」落点塌缩到章首）：
  - `hibiki/lib/src/reader/reader_pagination_scripts.dart` 连续模式 `restoreProgress`（原 `scrollToProgressContinuous(0.99)`）：只走文本节点 `findNodeAtProgress`，纯图片章无文本 → 返 null → 不滚动 → 停章首（封面）。
  - `hibiki/lib/src/reader/reader_pagination_scripts.dart` `_sharedInitImages`（`:1571` 附近 `img.forEach` 的 `setAttribute('loading','lazy')`）：纯图片章的图也无条件 `loading="lazy"` → 离屏图永不进视口 margin → 永不 load → 0 尺寸被 `buildPaginationMetrics`（`:1948/:1967`）的 first/lastContentEdge 排除 → 分页版 `scrollToProgressPaged(0.99)` 的 `contentLastPageScroll`(maxScroll) 塌缩到章首。
- **[x] ① 已修复** — 提交 本提交（分支 `todo1349-prev-chapter-landing`，见 `git log --grep TODO-1349`）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/prev_chapter_landing_guard_test.dart`（源码/生成产物扫描守卫，CI 可跑）+ `tool/reader_pitch_headless/prev_chapter_landing_probe.mjs`（headless Chrome 注入**真 shell** 行为断言，本机已验），提交 本提交
- **备注**：

### 复现路径（真实代码路径）
往前翻章 `reader_hibiki/navigation.part.dart _handlePageTurnLimit` backward →
`_navigateToVirtualPage(currentVirtual-1, progress:0.99)` → `_navigateToChapter(prev, progress:0.99)`
→ `_beginNavigation(progress:0.99)` → shell `restoreProgress(0.99)`（章尾语义，与手动后退跳章一致）。
上一章是「封面章节」（纯图片/整页插图章，或章尾附插图）时，章末落点塌缩到章首（封面图）。
基于最新 develop（含 TODO-1229 章切第二跳 / TODO-1339 合并图 eager）复现，非回退。

### 根因（章末落点，两墙互补）
1. **连续模式**：`restoreProgress(progress)` 对 `progress>0` 一律走 `scrollToProgressContinuous`
   → `findNodeAtProgress`（`createWalker` = SHOW_TEXT，只走文本节点）。纯图片章 `totalChars<=0`
   → 返 null → 不滚动 → `scrollTop` 停 0 = 封面。分页版早有 `progress>=0.99 → contentLastPageScroll`
   （章末=maxScroll，含 media），连续版缺对称的章末分支。
2. **分页模式**：`contentLastPageScroll`=maxScroll 由 `buildPaginationMetrics` 的 lastContentEdge 算，
   只计入**有非零尺寸**的媒体。纯图片章的图被 `_sharedInitImages` 挂 `loading="lazy"`，离屏图（远列）
   永不进视口 margin → 永不 load → 0 尺寸 → 被排除 → maxScroll 塌缩到章首。`__imgReanchorProgress`
   重锚也救不了：落点卡在封面 → 远列图永不进视口 → 永不 load → 重锚永不触发（鸡生蛋）。

### 修复
1. 连续 `restoreProgress`：新增对称的 `progress>=0.99` 分支 → 新 helper `scrollToChapterEnd()`：
   取正文最后一个可见内容元素 `scrollIntoView({block:'end', inline:'nearest'})`。block/inline 轴由
   writing-mode 自动映射（横排 block=竖直落到内容底；竖排 vertical-rl block=横向 RTL 落到最左列 = 章末），
   横竖排统一，天然含尾部插图；且 scrollIntoView 把末尾懒图带进视口触发 load（懒加载几何自愈）。
   无可见内容元素时兜底滚到滚动轴物理末端。
2. `_sharedInitImages`：纯图片章（`__hoshiImageOnlyChapter = !ttuRegex.test(document.body.textContent)`，
   即正文无任何可匹配文本）的所有 `<img>` 保持 **eager**（与 gaiji / 合并前导插图 `.hoshi-merged-image`
   同理），无条件 load、真实撑开尺寸 → metrics 计入全部图 → 分页 maxScroll 不塌缩。图文混排章
   仍 lazy（不回退 TODO-1074），非图片章完全 no-op（向后兼容）。ttuRegex 单字符匹配无 /g、首个
   可匹配字符即短路 → 文本章几乎零开销。

### 测试
- `hibiki/test/reader/prev_chapter_landing_guard_test.dart`（CI 可跑）：连续 `scrollToChapterEnd` 在场
  且用 `scrollIntoView(block:'end')`；连续 `restoreProgress` 把 `progress>=0.99` 路由到它；分页+连续 shell
  纯图片章检测 `__hoshiImageOnlyChapter` 放行 lazy；普通文本章仍 lazy（不回退 TODO-1074）。
- `tool/reader_pitch_headless/prev_chapter_landing_probe.mjs`（headless Chrome 真 shell，本机跑）：
  三几何（纯图片 imageOnly3 / 尾部插图 textThenImages / 图文混排 imagesThenText）× 分页/连续两 shell，
  断言 `restoreProgress(0.99)` 落点 >= 0.5 页/屏（离开封面）。修前 continuous/imageOnly3 = p0.00（STUCK），
  修后全 END-OK；懒加载延迟到位变体分页/连续均 p2.00（末图）。回归：`flutter test test/reader/ test/epub/`
  全绿。

### 真机验收步骤（用户）
1. 一本含「封面章节」为纯整页插图（封面/口绘，单章多图或图片章不后跟文本）、其后有目录/正文的 EPUB（如 安達としまむら2）。
2. 打开该书，从目录（或往后翻到目录所在章）**往前翻**（向上一章方向翻页）。
3. 期望：落到上一章（封面章节）的**最后部分**（最后一张插图 / 章尾），而非整本书封面（第一张图）。
4. 分页模式与连续模式（设置里「阅读模式」）都需验证；修复前分页/连续均可能停在封面。

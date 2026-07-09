## BUG-666 · 文字少+图片封面章往前翻仍落章首（BUG-661 续）
- **报告**：2026-07-09（用户：）— 「安達としまむら2 从目录往前翻，还是会去到最开头，因为文字少的问题？」（BUG-661 修后复诉）
- **真实性**：✅ 真 bug — 根因：BUG-661 只对**纯图片章**（`__hoshiImageOnlyChapter = !ttuRegex.test(document.body.textContent)`，即正文零可匹配字符）让 `<img>` 保持 eager。封面章含少量文字（题名/版权/页码，ttuRegex 匹配 `0-9A-Za-z`+CJK/kana，一个字符即命中）→ `__hoshiImageOnlyChapter=false` → 整页插图仍 `loading="lazy"`。真机 WebView 离屏懒图不发请求 → 0 尺寸 → 往前翻 `restoreProgress(0.99)`（章尾语义）章末落点两墙均塌缩到章首：
  - 分页：`hibiki/lib/src/reader/reader_pagination_scripts.dart` `buildPaginationMetrics`（`:1798` 附近 media 循环 `if (mediaRect.width<=0||mediaRect.height<=0) continue`）跳过 0 尺寸尾图 → `lastContentEdge` 只到少量文字 → `contentLastPageScroll`(maxScroll) 塌缩 → `scrollToProgressPaged(0.99)` 落章首。
  - 连续：`scrollToChapterEnd`（`:2655`）可见性判据 `rect.width>0||rect.height>0` 跳过 0 尺寸尾图 → 落到少量文字（章首附近）。
  - 且 `__imgReanchorProgress` 懒图 load 后重锚永不触发（尾图离屏永不进视口=鸡生蛋；连续模式当年根本没有 load 后重锚分支）。
- **[x] ① 已修复** — 提交 本提交（分支 `todo1349-sparse-landing-v2`）。新增 `forceLoadPendingImages`（章末恢复时把仍 lazy 的图强制 eager 触发 load，打破鸡生蛋），分页/连续 `restoreProgress(>=0.99)` 均调用；`_sharedInitImages` 的 img `load` 回调补连续重锚分支（判别用连续独有的 `scrollToChapterEnd`——`scrollToProgressPaged` 在 `_sharedJs` 两 shell 都有不能判别）；连续 `restoreProgress`/`paginate` 维护 `__imgReanchorProgress`。仅往前翻到章末触发，正向阅读/精确 char 锚不动 → 不回退 TODO-1074 懒加载、不回退 BUG-661/1339/纯图片章 eager。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/sparse_chapter_landing_guard_test.dart`（源码/生成产物扫描守卫，CI 可跑）+ `tool/reader_pitch_headless/sparse_chapter_landing_probe.mjs`（headless Chrome 真 shell + 扣响应忠实复现 0 尺寸态；分页/连续两 shell 断言塌缩复现 → forceLoadPendingImages 强制 eager → load 后重锚收敛真章末，本机已验），提交 本提交
- **备注**：headless Chrome **不延迟离屏懒图**（实测立即请求并加载全部图），真机 0 尺寸态需在拦截器扣住尾图响应模拟；真机复现的分页/连续两模式最终仍需真实设备验收（步骤见下）。

### 复现路径（真实代码路径）
往前翻章 `reader_hibiki/navigation.part.dart _handlePageTurnLimit` backward →
`_navigateToVirtualPage(currentVirtual-1, progress:0.99)` → `_navigateToChapter(prev, progress:0.99)` →
shell `restoreProgress(0.99)`。上一章是「文字少+图片」封面章（少量题名/版权文字 + 整页封面/口绘插图）时，
尾部整页插图仍 `loading="lazy"`（非纯图片章不走 BUG-661 eager 分支），离屏 0 尺寸 → 章末落点塌缩到章首。

### 修复（章末落点，两墙互补 + 打破鸡生蛋）
1. `_sharedJs` 新增 `forceLoadPendingImages()`：`querySelectorAll('img[loading="lazy"]')` 全部改 `loading="eager"`
   触发 load。分页/连续 `restoreProgress(progress>=0.99)` 均先调它——尾图离屏永不 load 的鸡生蛋由此打破，
   图尺寸解析后走既有 load 回调重锚。仅章末恢复触发（幂等，无 lazy 则 no-op），正向阅读不动。
2. `_sharedInitImages` 的未完成图 `load` 回调补连续重锚分支：`__imgReanchorProgress>=0.99` 时调
   `scrollToChapterEnd()`（连续）；分页仍走 `scrollToProgressPaged`。判别用连续独有的 `scrollToChapterEnd`
   （`scrollToProgressPaged` 在 `_sharedJs` 两 shell 都定义，不能作判别，否则连续误走分页分支不重锚）。
3. 连续 `restoreProgress`：`>=0.99` 分支置 `__imgReanchorProgress=progress`、其余分支清 null；连续 `paginate`
   清 `__imgReanchorProgress`（镜像分页 paginate，避免尾图 late-load 把用户已翻走的位置拽回章末）。

### 测试
- `hibiki/test/reader/sparse_chapter_landing_guard_test.dart`（CI 可跑）：`forceLoadPendingImages` 在场且把
  lazy 改 eager；分页+连续 shell `restoreProgress(>=0.99)` 均调 `forceLoadPendingImages`；load 回调含连续
  `scrollToChapterEnd` 重锚分支且判别不误用 `scrollToProgressPaged`；连续 `paginate` 清 `__imgReanchorProgress`；
  普通文本章仍 lazy（不回退 TODO-1074）。
- `tool/reader_pitch_headless/sparse_chapter_landing_probe.mjs`（headless 真 shell，本机跑）：扣尾图响应复现
  0 尺寸塌缩（分页释放前 p1.00 / 连续 p0.03），释放后重锚收敛真章末（分页 p5.00 / 连续 p3.83），
  两模式 collapse=YES + recover=END-OK。

### 真机验收步骤（用户）
1. 一本封面章为「少量文字（题名/版权）+ 整页封面/口绘插图」的 EPUB（如 安達としまむら2）。
2. 打开该书，从目录（或往后翻到目录所在章）**往前翻**（向上一章方向翻页）。
3. 期望：落到上一章（封面章节）的**最后部分**（最后一张插图 / 章尾），而非整本书封面（最开头）。
4. 分页模式与连续模式（设置里「阅读模式」）都需验证；修复前两模式均可能停在最开头。

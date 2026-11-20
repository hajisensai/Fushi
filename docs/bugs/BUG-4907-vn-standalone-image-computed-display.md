## BUG-4907 · VN 独立插图归类读脱离文档的 computed display，该分支恒不生效且随挂载状态翻转
- **报告**：2026-11-20（路线图 #3722 c06 遗留 gap-readerjs2-10 余项「`isStandaloneImageNode` 用 computedDisplay，另开 bug」，代码审读 + 真 Chrome 实测，无用户报告）
- **真实性**：✅ 潜在缺陷（结构问题，生产当前无可见症状）。`fushi/lib/src/reader/reader_visual_novel_scripts.dart`
  `isStandaloneImageNode` 的最后一条判据是 `isBlockDisplay(computedDisplay(node))`（`getComputedStyle(node).display`）。
  VN 的所有归类调用（切屏 `containsStandaloneMedia`、内容流 `mediaUnits`、`watchLateImages` 复核）对象都是
  `detachChapterSource` 搬进一个**不挂在文档上**的 div 的源树；真 Chrome 实测：同一张 `style="display:block"` 的图，
  挂在文档上 `getComputedStyle(img).display === 'block'`，摘下后为 `''`（Blink / WebKit 对脱离文档的元素给空声明）。
  因此这条判据在生产里恒为 false，是死代码；而同一个函数一旦被用在挂着的节点上（或换成为脱离文档元素计算样式的
  引擎），书本样式、阅读器自己的 `p > img:only-child { display:block }`（`reader_content_styles.dart`）都会把文字中间的
  小图翻成「独立插图」、独占一屏——归类随挂载状态变，切屏结果不确定。每次归类还白调一次 `getComputedStyle`。
- **[x] ① 已修复** — 删掉 `computedDisplay` / `isBlockDisplay` 与这条判据，归类只看节点自身携带的信号（无文字上下文、
  真实尺寸 / 未加载完时的声明尺寸、`block-img` 类）。生产行为不变（那条判据本来就恒为 false）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_refit_late_image_test.dart` 新用例 + 跑手
  `vn_standalone_image_classification_harness.mjs`（真 Chrome 跑生产 VN shell：行内样式 block、阅读器 `:only-child`
  规则、书本类名 block 三种小图挂着 / 摘下归类相同且都是行内；纯图段与 `block-img` 两种状态都是独立插图）。修复前
  `inlineStyleBlock` 挂着为 true、摘下为 false，用例红。
- **备注**：「是否应该按书本 CSS 的 `display:block` 把文字中间的小图拆成独立一屏」是功能取舍，不在本修复里做（要做得在
  `detachChapterSource` 之前按挂载状态记一次归类），已列入待拍板。设备复测未做：本修复不改变生产行为。

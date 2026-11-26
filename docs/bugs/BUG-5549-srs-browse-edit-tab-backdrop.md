## BUG-5549 · 复习浏览页检查器「编辑」页签的字段直接压在自定义背景图上，字看不清
- **报告**：2026-11-26（用户截图：宽屏浏览页右侧检查器切到「编辑」，樱花 / 动画背景图透过字段名、提示小字与输入框，文字和背景糊在一起）
- **真实性**：✅ 真 bug。检查器的「预览」页签是卡面、「历史」页签是 `FushiCard`，完整编辑页的字段也在 `FushiCard` 里；唯独内嵌「编辑」页签 `_EditTabState.build`（`fushi/lib/src/pages/implementations/srs/srs_browse_inspector.dart:680`）把字段 `ListView` 直接放在页底上。页底被 `FushiPageBackdrop` 换成透明画背景图，字段名 / 「点一个词改读音」/「词典排版」提示是直接压在图上的小字，输入框与排版预览底是 `surfaces.card`（玻璃下半透明），图片的明暗花纹整片透上来。
- **[x] ① 已修复** — 「编辑」页签的字段列表放进一张 `FushiCard`（`srs-browse-edit-panel`，`padding: zero`、不按压缩放，内边距给 `ListView`，滚动内容裁在卡的圆角里），与完整编辑页、另两个页签同一层级。MD3 是分组色卡底，Apple 走 Apple 分组面（`FushiCard` 自带两套分支）；字段输入框（`surfaces.card`）坐在分组色（`surfaces.group`）上差一级，没有背景图时也照常分层。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_browse_page_test.dart`「[MD3]/[Apple] BUG-5549」：宽屏检查器切到「编辑」，字段列表与字段编辑器都在 `FushiCard` 卡里，卡完整包住字段列表。
- **备注**：检查器底部一排（回到出处 / 暂停 / 旗标 / 更多）仍直接坐在页底上，是按钮自带底色 / 图标，截图里可读，未动。

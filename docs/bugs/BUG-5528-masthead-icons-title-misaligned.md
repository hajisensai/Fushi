## BUG-5528 · 页头大字顶栏的返回键、动作图标和页名上下没对齐（二级页收缩后返回键高出一截，库页动作组和页名错开）
- **报告**：2026-11-26（用户：手机字幕工作台页滚动后「←」比「Subtitles」高一截；书架宽窗 / 窄窗页名与右侧图标不在一条线上，要求所有模块都对齐、宽窄屏都查）
- **真实性**：✅ 真 bug。两套页头都按「行底边 + 固定下边距」摆图标，没有任何一处以页名的字面位置为参照：
  - 二级页 `FushiMastheadHeader`（`fushi/lib/src/utils/components/fushi_masthead_scaffold.dart`，原 `Row(crossAxisAlignment: end)`）：返回键与动作和页名盒**底边**对齐。页名随滚动在绘制层缩小（46→28）后盒高不到 48，返回键的上半截就高出页名；有副标题时对齐的还是副标题的底边。
  - 库页 / 模块页 `_RenderMastheadLayout`（`fushi_floating_chrome.dart` `_transformsAt`）+ `FushiMastheadGeometry`（`fushi_page_masthead.dart`）：前导 / 动作组 / 主按钮按 `actionLift` 固定下边距**底边**对齐，页名按基线贴底，两者中线差多少全看字号碰巧；收起过程里页名的抬升按盒中心算（又不是字面中心），一级切换也没跟着页名抬，基线在收缩中途错开。
- **[x] ① 已修复** — 新增 `FushiPageTitleMetrics.inkCenterEm`（字面中心 = 基线上 0.37em）作为两套页头唯一的竖向参照线：
  - `FushiMastheadGeometry.actionCenterLiftAt` / `actionCenterAt`：图标中线 = 主标题（页名或顶替页名的一级切换）字面中心，字面中心太低时把页名抬起而不是把图标压过下边距；前导 / 动作组 / 主按钮 / 徽标都按各自高度以这条线居中，一级切换随页名抬升保持同一基线。
  - `FushiMastheadHeader`：返回键、动作组以页名首行字面中心居中（`_centerOnLine`），页名盒按缩放后的字面中心补上边距；`titleInBody` 裸图标行里页名字面中心落在行中线上。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_masthead_icon_alignment_test.dart`：二级页 402 / 1400 宽 × 进度 0 / 0.5 / 1（带副标题）返回键与动作中线 = 页名字面中心；裸图标行同；库页几何宽窄 × 三档进度图标 / 徽标中线 = 字面中心、图标不越行；窄窗一级切换顶替页名同样成立。
- **备注**：字面中心常量 0.37em 取汉字（≈0.38em）与拉丁大写（≈0.36em）之间，46 号字两者误差都不到 1 px。

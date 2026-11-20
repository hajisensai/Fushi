## BUG-4900 · 拼贴视频块背景剧照被两侧裁掉、悬停放大后右列块被内容区裁切
- **报告**：2026-11-15（用户：拼贴审查设计稿 #video V1「海报右侧被截断了」「明明海报左右其实还有东西」，悬停抬起后）
- **真实性**：✅ 真 bug，两处根因：
  1. 背景图槽几何写死块宽 64%：`fushi/lib/src/utils/components/fushi_cover_block.dart:1029`
     （`_BlockGeometry.backdropPoster` 的 `Rect.fromLTWH(w * 0.36, 0, w * 0.64, h)`，横版摆法同款在 `:900`）。
     16:9 剧照用 `BoxFit.cover` 塞进约 1.2:1 的槽，两侧各裁掉约 1/4；悬停姿态 `dx: -14, scale: 1.06` 以右缘为轴，
     右缘被拉进来 14px。
  2. 布局不给悬停放大留余量：`fushi/lib/src/utils/components/fushi_cover_block_layout.dart:487`
     （`SliverFushiCoverBlocks` 把块铺满整个 `crossAxisExtent`）。库页卡壳的 `FushiHoverLift` 以格子中心放大 1.05，
     贴行尾的宽块单侧溢出 `宽 × 0.025`（600 宽 = 15px、拼贴首块 830 宽 = 21px），而页面 `CustomScrollView`
     视口左右只有页边距 12，放大后的块被视口矩形裁掉一条。
- **[x] ① 已修复** — ① 背景槽宽 = 块高 × 图片真实宽高比（`backdropAspectRatio` 参数优先，否则从背景图
  `Image` / `FadeInImage` 解码取，取不到按 16:9），靠右对齐、不裁；槽比块宽时左段落在块外、渐隐从露出来的起始缘
  算起；悬停只以右缘为轴放大 1.06，不横移（`_BlockGeometry._backdropSlot`）。② 新增
  `computeFushiCoverBlockPlacement`：按贴边块的放大溢出量（`kFushiHoverLiftOverflow`）在两侧留边再排，块间距不变；
  `SliverFushiCoverBlocks` / `FushiCoverBlocks` / `fushiCoverBlockFirstRowHeight` 都走它。提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_cover_block_polish_test.dart` 「V1 背景剧照」组：
  槽宽 = 高 × 16/9 且右对齐、悬停后右缘不内收；无比例时按 16:9；多宽度 × 拼贴 / 等尺寸下贴边块放大后整块留在
  布局宽度内。
- **备注**：像素观感需在 Windows / Mac 真机视频库「系列」页悬停复测（收尾阶段）。音乐推荐页
  `musicCoverBlockRowCapacity` 仍直接调 `computeFushiCoverBlockPlan` 算容量，需改调 `computeFushiCoverBlockPlacement`
  才与实际摆法逐格一致（已列跨线请求）。

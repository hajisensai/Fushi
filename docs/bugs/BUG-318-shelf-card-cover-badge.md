## BUG-318 · TODO-552 书架卡片封面变形+有声书徽章过小
- **报告**：2026-06-19（用户验收 B01 批次）
- **真实性**：✅ 真 bug（来自书架卡片重设计 TODO-355/284/293/361/362/480 的回归）

### 子问题 A：封面图被压缩变形
- **根因**：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:88` 的 `_bookCardCoverFit` 被 TODO-480（commit `f845ab564 fix(reader): fill bookshelf covers`）从 `BoxFit.fitHeight` 改成 `BoxFit.cover`。叠加 TODO-455（commit `60988a797 fix(reader): move shelf titles below covers`）把书名移到封面下方 40px footer（`kShelfTitleFooterHeight`）后，封面区（`Expanded` = 卡片高 − 40px）的宽高比不再等于封面图比例，`cover` 放大裁切，封面构图上/下被截，肉眼读作「被压缩变形」。
- **修复**：改回 `BoxFit.fitHeight`（回归前行为），按封面区高度等比缩放、保持封面原始比例，两侧溢出由外层 `ClipRect` 裁掉，封面竖向全貌完整不变形。

### 子问题 B：有声书/类型徽章太小（约 16px）
- **根因**：`reader_hibiki_history_page.dart:78` 常量 `kShelfCoverBadgeDimension` 被 TODO-361（commit `187582f08 fix(shelf): restore audiobook badge size`）设为 `8.0 * 2`（16px），配合徽章 overlay 的 `BoxFit.contain`（line ~1554），把内在 22px 的 `HibikiBadge`（icon 14 + padding gap 8）硬缩到 16px。历史上徽章移到封面后长期用 `gap*5=40 + BoxFit.scaleDown` 按 22px 满尺寸渲染——22px 才是「正常大小」。
- **修复**：把 `kShelfCoverBadgeDimension` 设为 `22.0`（徽章内在尺寸），保留 `BoxFit.contain` 既不放大也不缩小，徽章按 22px 满尺寸（正常大小）渲染。

- **[x] ① 已修复** — `reader_hibiki_history_page.dart:88`（fit → fitHeight）、`:78`（徽章常量 16 → 22）；commit 见 claim。
- **[x] ② 已加自动化测试** — 更新源码扫描守卫 `test/pages/reader_bookshelf_card_layout_static_test.dart`（断言 fit=fitHeight、徽章常量=22.0）+ widget 视觉守卫 `test/pages/reader_bookshelf_badge_size_test.dart`（断言徽章视觉绘制 22px）。
- **备注**：封面观感（按比例正常、不变形）与徽章大小为肉眼项，需真机/模拟器复测确认。`fitHeight` 会在封面区比封面图更宽时左右留白——这是用「比例正确」换「占满」的取舍，符合用户「按比例正常显示·像旧版」诉求。

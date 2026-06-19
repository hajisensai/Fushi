## BUG-319 · TODO-557 长按书卡对话框封面消失
- **报告**：2026-06-19（用户验收 B01 批次，TODO-552 里一并报）
- **真实性**：✅ 真 bug（来自书架卡片重设计的回归，与 BUG-318 同区）

- **根因**：`hibiki/lib/src/pages/implementations/media_item_dialog_page.dart` 的 `MediaItemDialogFrame.build`。TODO-455（commit `60988a797 fix(reader): move shelf titles below covers`）把长按对话框的封面从「顶部完整可见封面块」（`ConstrainedBox(maxHeight: screenHeight*0.34) + ColoredBox + cover!`）重写成「背景层 `Opacity(0.34/0.24)` + 前置 `_readabilityScrim`（surface 渐变 alpha 0.72~0.94）」；TODO-464（commit `efb7c35ce polish book and video long-press UI`）又把 opacity 降到 0.24。封面有效可见度只剩约 7%（中段）/1.4%（顶底），肉眼基本看不见 → 用户看到「没封面」。封面数据链路完好（`cover` 非空、传参正确），只是被遮罩吃掉。
- **修复**：把 `build` 从 `Stack(背景封面+scrim)` 改回 `Column`，顶部加回可见封面块 `if (cover != null) ConstrainedBox(maxHeight: screenHeight * _coverHeightFactor=0.34) → ColoredBox → cover!`（`_buildCover` 用 `BoxFit.contain`，封面完整不裁切）；删除 `_coverBackground` / `_readabilityScrim` 两个 helper、`coverBackgroundFit` / `coverBackgroundOpacity` 参数及 `kBookDialogCoverBackgroundOpacity` 常量。保留 TODO-455 之后引入的有用改动（`showLaunchAction` 可选、launchLabel/onLaunch 可空，供视频长按菜单只管理）。书/视频/SRT 三调用方传参无需改。

- **[x] ① 已修复** — `media_item_dialog_page.dart` `MediaItemDialogFrame.build`（封面恢复为顶部可见块）；commit 见 claim。
- **[x] ② 已加自动化测试** — `test/pages/media_item_dialog_page_test.dart`：源码守卫断言封面是「height-capped 顶部块」且不含 `_readabilityScrim` / `coverBackgroundOpacity`；widget 守卫断言封面不在 `Opacity` 包裹内、在 `ConstrainedBox` 内（可见、不被压暗）。
- **备注**：封面是否清晰可见为肉眼项，需真机/模拟器长按书卡复测确认。

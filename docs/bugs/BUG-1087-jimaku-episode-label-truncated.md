## BUG-1087 · 番剧下载确认页集号输入框在界面缩放下 label 截断成「集…」
- **报告**：2026-07-25（用户截图：4K 下确认推送阶段，字幕手动搜索行右侧集号框只显示「集…」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart` `_buildJimakuManualSearch` 里集号 `TextField` 外层 `SizedBox(width: 72)`：72 逻辑像素减去 `InputDecoration` 内边距后，「集号」两个 CJK 字符在界面缩放（浏览器式缩放）>1 时装不下，resting label 被省略号截断。
- **[x] ① 已修复** — 宽度 72 → 96（同一提交顺带：字幕搜索词默认预填罗马字并提供 罗马字/日文原名/英文名 下拉切换，与 Nyaa 查询词同口径——用户同轮要求）。提交 a940dcf23。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart`：断言集号输入框渲染宽度 96、字幕搜索词预填罗马字、下拉切换日文原名生效。
- **备注**：更彻底的做法是让 label 自适应宽度（IntrinsicWidth），但集号本就是 1–4 位数字输入，固定 96 已给缩放留足余量，不引入布局复杂度。

## BUG-5560 · 反馈处理台看截图没有关闭键、列表只有「下一页」
- **报告**：2026-11-26（应用内反馈 vh4K5khfVr）
- **真实性**：✅ 真问题，网页处理台与 App 内处理台两处都有。
  - 网页（rank.fushi.moe/dev）：详情页截图是 `<a href="/dev/f/:id/a/:slot"><img></a>`（`services/leaderboard/src/devconsole.js` detailPage 的 `shots`），点开后同一标签页整页跳成裸图片，没有任何关闭入口，只能按浏览器返回。拍板台（`src/decisions.js` 的 `filesHtml` / `originalHtml`）是另一套写法（新标签页打开）。列表（`listPage`）是游标分页，「下一页」整页换成下一批，没有上一页，所以才会有人要页码和「上一页」。
  - App：处理台与反馈人详情的 `_viewImage`（`fushi/lib/src/pages/implementations/feedback/feedback_dev_page.dart:574`、`feedback_detail_page.dart:479`）都是 `showAppDialog` + `FushiDialog` 包一个 `InteractiveViewer`，没有关闭键；复习卡面的 `showSrsCardImageViewer`（`srs_fushi_card_view.dart:2405`）又是第三套。阅读器早有带 × 的共用查看器 `IllustrationZoomViewer`，但只收磁盘文件。
- **[x] ① 已修复** — 拍板（用户 2026-11-27）：加关闭键、统一成一个共用的全屏看图组件；不做页码，改成「已加载 N 条」+ 回到顶部。
  - 网页：新增 `services/leaderboard/src/lightbox.js`。处理台页面不跑脚本（CSP `script-src 'none'`），所以用 CSS `:target` 做全屏遮罩：右上角 ×、点空白处、浏览器返回都能关闭，「原图」在新标签页打开。反馈截图、拍板台图片附件、拍板台原文图片三处都走它。列表改成累计加载：`?n=<条数>` 由服务端按游标分批取齐（上限 1000），「加载更多」把 n 加一页并跳到新加载的第一条；底部显示「已加载 N 条」和「回到顶部」，另有一个浮动的回到顶部按钮。
  - App：`IllustrationZoomViewer` 的画面拆出通用的 `ImageZoomFrame`（缩放拖动、点图 / 遮罩 / × / Esc / 返回关闭），加 `showImageZoomViewer(context, picture)`。处理台、反馈人详情、复习卡面三处都换成它，删掉 `showSrsCardImageViewer`。处理台列表底部显示「已加载 N 条」+「加载更多」+「回到顶部」。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/feedback.test.js`「网页处理台：看图与列表」两条：改前的 devconsole.js 上两条都红。`test/decisions.test.js` 跟着改成按缩略图计数。`fushi/test/feedback/feedback_pages_test.dart`：反馈人详情点开截图后有 `ImageZoomFrame` 和 × 键，点 × 关闭、Esc 关闭；处理台列表显示「已加载 2 条」与回到顶部。
- **备注**：没做真机验证。

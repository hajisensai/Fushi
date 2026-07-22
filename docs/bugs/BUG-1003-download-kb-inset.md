## BUG-1003 · 下载页输入apikey时软键盘顶掉贴底下载任务区
- **报告**：2026-07-22（用户：下载里面输入apikey的时候下载任务会进入到输入栏位置，被输入框挤上去）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/downloads_page.dart:23`（`Scaffold` 未设 `resizeToAvoidBottomInset`，默认 `true`）+ `anime_download_dialog.dart:1092-1105`（内联布局：顶部输入框 + 中段唯一 `Expanded(stage)` + 贴底 `_buildTasksSection`）。
  - 数据流：手机点顶部 apikey 输入框 → 软键盘弹出 → `MediaQuery.viewInsets.bottom` 增大 → `resizeToAvoidBottomInset:true` 把 `Scaffold` body 高度压掉键盘高度 → Column 里唯一弹性的 `Expanded(stage)` 被压扁 → 贴底的「下载任务」折叠区被顶到键盘上方；在被键盘缩短的视口里正好升到顶部 apikey 输入框边上，表现为「下载任务爬进输入栏位置、被输入框挤上去」。
  - 桌面端无软键盘，`viewInsets.bottom` 恒为 0，不复现（纯移动端布局问题）。
- **[x] ① 已修复** — `downloads_page.dart` 的 `Scaffold` 加 `resizeToAvoidBottomInset: false`。所有真正的输入框（apikey / 搜番 / Nyaa 查询 / 通用磁力）都在页面上半部，结果列表与下载任务在下半部；关掉 inset 后键盘只覆盖下半部（打字时本就不看），顶部输入框保持可见、布局不再反流。符合「消除特殊情况而非加补丁」——不再让贴底任务区随键盘反流。提交：<待填>e
- **[x] ② 已加自动化测试** — 源码扫描守卫 `hibiki/test/pages/downloads_page_resize_inset_guard_test.dart`：断言 `downloads_page.dart` 的 `Scaffold` 显式设 `resizeToAvoidBottomInset: false`，防回归（widget 层无法稳定断言「键盘弹出后贴底区不上移」，最强可落地层是源码守卫）。提交：<待填>e
- **备注**：下载页（`DownloadsPage` / `AnimeDownloadDialog(embedded:true)`）由 PR#300（`feat-general-download-upload-toggle`）引入，已在 develop。本修复原在 PR#324（stack 于 #300），现单独 cherry-pick 补合进 develop；因 develop 上 BUG-897 号已被占，改号为 BUG-1003。

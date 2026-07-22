## BUG-1006 · 下载页内嵌推送成功后误 pop 宿主路由
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：✅ 真 bug（代码路径已验真）。根因 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:469`：`_push()` 推送成功尾部无条件 `Navigator.pop(context)`，无 `widget.embedded` 分支。而 `downloads_page.dart:46` 以 `AnimeDownloadDialog(embedded: true)` 内嵌进 home 顶层 tab（`home_page.dart:965`）——embedded 下这个 pop 作用在宿主路由上：下载 tab 场景等于 pop home 根路由（Android 上表现为退出/黑屏），从设置入口 push 进来时会把整个下载页弹掉。对照 `_pushGeneric()`（`anime_download_dialog.dart:690-707`）就没有 pop。
- **[ ] ① 未修复** — 修法：`if (!widget.embedded) Navigator.pop(context);`，embedded 下推送成功后重置回搜番阶段并刷新任务区。
- **[ ] ② 未加自动化测试** — 建议 widget 测试：embedded 模式下 `_push` 成功后断言 Navigator 栈深不变、任务区出现新 plan。
- **备注**：巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 下载模块；计划随下载模块 UI 重构 PR 一并根因修复。

## BUG-3239 · 反馈详情页截图下载失败后本次打开期间不再重试
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2021）。根因 `fushi/lib/src/pages/implementations/feedback/feedback_detail_page.dart` `_image`（原 :97-101）：`_images[slot] ??= screenshot(...)` 把失败的 Future 也一直缓存着，缩略图与大图都只会拿到同一个错误，本次打开期间这张图永远是坏图（服务端 503 / 网络抖动一次即中）。
- **[x] ① 已修复** — 提交「fix(feedback): retry a failed screenshot download on tap」：下载失败时把该槽位从缓存摘掉并记进 `_failedShots`；点坏图的缩略图重取（重建新 Future），成功后再点才看大图、复用这次下载。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_pages_test.dart`「BUG-3239 反馈人详情：截图下载失败显示坏图，点一下重取…」（未修复时红）。
- **备注**：

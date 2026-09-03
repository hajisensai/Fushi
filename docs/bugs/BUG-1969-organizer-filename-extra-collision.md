## BUG-1969 · 剧集整理把平铺 NCED 文件当正片，与同集正片撞号
- **报告**：2026-08-30（用户截图：Windows 下载中心）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/download/video_download_organizer.dart` 的剧集排布只在解析集号前调用 `_isInExtraDirectory()`；BUG-1865 修复了特典目录，却明确不检查文件名。截图中的正片 `... - 24 END ...mkv` 与 `... - 24 NCED Version ...mkv` 平铺在种子根目录，因此都被解析为第 24 集并映射到同一个 `S01E24.mkv`，触发 `organization target collision`。
- **[x] ① 已修复** — `43d66f64a5`：整理器新增 `_isExplicitExtra()`；目录仍走既有宽词表，文件名复用元数据链路的 `classifyLocalVideoExtra()` 严格 token 判据，在解析集号前排除 `NCOP` / `NCED` / `creditless OP|ED` / `PV` 等明确附件。真正的同集 v1/v2 仍保留冲突失败；纯特典种子的二次旧口径回退契约不变。
- **[x] ② 已加自动化测试** — `43d66f64a5`：`fushi/test/media/video/download/video_download_organizer_test.dart` 新增用户截图同形用例：平铺的 `24 END` 进入 `Season 01/S01E24`，`24 NCED Version` 进入 `Extras` 且不携带集号。
- **备注**：
  - 存量失败任务需在下载页点一次“重试”，重新规划后才能按新规则整理。

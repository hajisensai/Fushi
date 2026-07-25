## BUG-1081 · 海报匹配弹窗点使用没反应无进度反馈
- **报告**：2026-07-25（用户）
- **真实性**：✅ 真 bug（UX/健壮性）。用户在「在线匹配海报」弹窗点「使用」没反应。弹窗缩略图能加载（URL 可达），桌面 toast 经根 navigator overlay 置顶（不会被弹窗盖住）——排除「toast 隐藏」。
- **根因**：`poster_match_dialog.dart:_use` 是异步（`applyCandidateToBooks` 内含最长 30s 的海报下载 `poster_downloader.dart:31 _timeout`），但「使用」按钮**无任何加载态**——点下去只是静默 `onPressed:null` 禁用，标签不变、无转圈。用户看不到任何「进行中」反馈 → 误判「没反应」。次要成因：`onApplied()`（=`home_video_page._refresh`）在 `_use` 的 try 之外调用，一旦它异常，`Navigator.pop()` 不执行且 `_applying` 永不复位 → 按钮永久禁用，坐实「没反应」。
- **[x] ① 已修复** — commit（见末）。`poster_match_dialog.dart`：
  - 新增 `_applyingCandidate` 状态，进行中的候选「使用」按钮显示 `CircularProgressIndicator`（明确「正在应用」反馈）。
  - `_use` 重构为成功/失败分支：失败必复位 `_applying` + 弹可见失败 toast（绝不吞成静默）、弹窗保留让用户改选；成功才刷新+关弹窗+成功 toast。`onApplied()` 单独 try 包裹，其异常不得阻断关闭弹窗（杜绝 `_applying` 卡死）。
- **[x] ② 已加自动化测试** — `test/media/video/scraper/poster_match_dialog_test.dart` 既有冒烟「候选渲染 + 使用按钮回调应用封面」覆盖成功路径（重构后仍绿）；进度转圈/失败复位为纯 UI 反馈增强，逻辑不变。
- **备注**：属「统一各媒体页服务」P1 刮削域。若用户实测仍下载失败，现在会弹明确失败 toast（不再静默），便于进一步定位下载侧问题（如运行进程无代理时某些 CDN 不可达）。

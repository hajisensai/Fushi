## BUG-2833 · 漫画默认缩放存量坏值与改缩放方式不重置会话缩放
- **报告**：2026-10-01（用户复报：16:10 笔记本看漫画显示不全，「缩放修了吗」；与 BUG-2782 同一录屏 `2026-09-28 19-32-05.mp4`）
- **真实性**：✅ 真 bug（BUG-2782 的遗留面）。BUG-2782 只删掉了捏合 / 滚轮 / 右键 ± 回写 `manga_zoom_percent` 的写入方，备注明说不回滚已写坏的存量值；中招用户升级后 `fushi/lib/src/models/preferences_repository.dart` `mangaZoomPercent` 照旧读出 108% 之类的值，经 `mangaReaderPreferences.zoomStart` → `fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `_zoomPercent = readerPreferences.zoomStart` 进 `#manga-canvas` 的 `scale(ZOOM)`，「适应屏幕」仍上下被裁。同时设置面板里改缩放方式不重置会话缩放（`manga_fushi_page.dart` 应用阅读设置处只在 `zoomStart` 变化时重置），录屏里「选适应屏幕无变化」也是这条。
- **[x] ① 已修复** — `fushi/lib/src/media/manga/manga_view_prefs.dart` 新增 `normalizeStoredMangaZoomPercent`：设置滑块自建立起就是 50–400、步长 10，非 10 倍数的存量值只可能来自旧回写，读取端按未设置回到 100%（读取端修，备份恢复 / Profile 快照带回的旧值同样覆盖）；`mangaZoomPercent` 经它读出。阅读设置变化时 `resetSessionZoom` 也包含缩放方式变化。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_polluted_default_zoom_test.dart`（纯函数 + 内存库读写往返）；`fushi/test/media/manga/manga_default_zoom_single_writer_guard_test.dart` 加钉 `resetSessionZoom` 包含 `scaleType`。
- **备注**：10 的倍数（例如右键 + 按出来的 110%）与设置里有意选的值无法区分，保留不动；这类用户仍需去 设置 › 漫画 › 默认缩放 拉回 100%。未在用户 16:10 真机复测（拿不到用户机上的偏好值）。

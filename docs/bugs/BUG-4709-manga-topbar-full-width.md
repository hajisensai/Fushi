## BUG-4709 · 漫画阅读器顶栏在桌面宽屏限宽 1080 居中，与小说全宽顶栏不一致
- **报告**：2026-11-16（用户：维护者应用内反馈 se4AshgQ7s「漫画阅读器顶栏限宽 1080 居中，改成与小说一致的全宽」）
- **真实性**：✅ 真 bug。#3240（反馈 -JpWlEuH5N「漫画与小说阅读器顶栏统一」）把漫画顶栏换成了小说同款 `FushiFloatingTopBar`，但外框仍套着 `Align(topCenter)` + `ConstrainedBox(maxWidth: kMangaChromeTopMaxWidth = 1080)`（`fushi/lib/src/media/manga/reader/manga_reader_chrome.dart:86`、`:688-693`）。小说顶栏是 `Positioned(left/right = 边距)` 铺满全宽（`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:3475-3479`）。逻辑宽度超过 1104 时（如 2560 屏 1.5 倍缩放 ≈ 1707）漫画顶栏只占中间 1080，返回键和动作胶囊离两边都远，跟小说不一致。
- **[x] ① 已修复** — 去掉 `MangaReaderTopBar` 外框的 1080 限宽，删除常量 `kMangaChromeTopMaxWidth`，只留左右 `kMangaChromeEdgeInset`，和小说顶栏用同一种全宽布局；动作放不下时照旧由 `FushiFloatingTopBar` 自己测宽收进「⋯」。底部胶囊的 720 限宽不在本条范围内。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reader_chrome_test.dart`「桌面宽屏：顶栏与小说一样铺满全宽，只留左右边距（反馈 se4AshgQ7s）」：宽 1707 时断言顶栏左右各只留 `kMangaChromeEdgeInset`，返回键贴左，动作胶囊贴右。修复前这条是红的（left 实测 313.5，期望 12）。
- **备注**：没用真机或模拟器复测。

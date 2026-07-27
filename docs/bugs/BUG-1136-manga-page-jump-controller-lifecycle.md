## BUG-1136 · 漫画页码跳转关闭弹窗后红屏
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart`
  在 `showAppDialog` Future 返回后立刻 dispose `TextEditingController`，但弹窗反向
  动画中的 `TextField` 仍会重建并监听它，先抛 “used after being disposed”，继而
  触发 Overlay `_dependents.isEmpty` 红屏。
- **[x] ① 已修复** — 页码弹窗改用 `TextFormField.initialValue` 与局部字符串，
  不再跨 Route 退出动画手工管理 controller；弹窗提成可独立验证的
  `showMangaPageJumpDialog`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/manga_hibiki_page_test.dart` 完整打开、输入、确认并等待弹窗退出
  动画，断言返回页码且 Flutter 无异常。
- **备注**：Windows 真应用复测从第 16–17 页跳到第 1 页，页面正常加载且无红屏。

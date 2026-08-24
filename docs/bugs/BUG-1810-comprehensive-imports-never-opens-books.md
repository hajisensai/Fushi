## BUG-1810 · 综合导入实测未打开书架导致已导入图书不可见
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/comprehensive_imports_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。`fushi/integration_test/helpers/library_fixture.dart:99-130` 的 `seedReaderBook` 自己承诺轮询书卡可见，却没有自行满足书架“未访问就不构建”的惰性 tab 前置，而是把 `showBooksTab` 要求留在注释里甩给每个调用者。综合导入与 Reader Computer Use 两个实机用例都在 `EpubImporter.import` 返回有效 book key 后轮询 20 秒为 0；`seedAudiobook` 有同一缺口。
- **[x] ① 已修复** — reader/audiobook seed helper 自行打开书架；提交 `bb1f2ddf7`。
- **[x] ② 已加自动化测试** — 综合导入与 Reader Computer Use 物理 GREEN；RED 在第 46 行、已导入图书不可见、exit 1。
- **备注**：根本修复收进共享 fixture：`seedReaderBook` / `seedAudiobook` 在可见性轮询前自行走生产 `HomePage.debugSelectTab(HomeTab.books)` 钩子；调用用例不再各自记忆前置，不放宽书卡断言，也不绕过真实 provider。

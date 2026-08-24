## BUG-1823 · 综合导入实测按固定索引误把书架当查词
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/comprehensive_imports_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。综合导入把 `navTargets[1]` 硬当查词；Reader Computer Use 与歌词模式入口又把 `navTargets.first` 硬当书架。当前动态 `homeActiveTabs` 的 index 0 是 Dashboard、index 1 才是书架，且模块可插入/隐藏。物理证据已证明这些位置假设会把真实查词/书卡路径切错；生产真值 helper `findNavTargetForTab(HomeTab.*)` 已存在。
- **[x] ① 已修复** — 三处改按 `HomeTab` 身份定位；提交 `bb1f2ddf7`。
- **[x] ② 已加自动化测试** — 综合导入、Reader Computer Use、歌词模式物理路径均越过正确 tab 并 GREEN；RED 曾分别表现为词典结果 0、已可见书卡被藏回 Dashboard。
- **备注**：顶层 tab 会按模块偏好和平台插入/隐藏，测试不得再把位置索引编码成业务身份。

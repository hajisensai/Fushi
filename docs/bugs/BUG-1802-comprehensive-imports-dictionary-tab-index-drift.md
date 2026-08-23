## BUG-1802 · 综合导入实测按固定索引误把书架当查词
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/comprehensive_imports_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。综合导入把 `navTargets[1]` 硬当查词；Reader Computer Use 与歌词模式入口又把 `navTargets.first` 硬当书架。当前动态 `homeActiveTabs` 的 index 0 是 Dashboard、index 1 才是书架，且模块可插入/隐藏。物理证据已证明这些位置假设会把真实查词/书卡路径切错；生产真值 helper `findNavTargetForTab(HomeTab.*)` 已存在。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED①：综合导入实机用例已通过字典、EPUB、字体阶段，最终在词典结果断言失败；RED②：Reader Computer Use 日志先显示书卡 500ms 可见，随后 `_openSeededBook` 激活 index 0 后精确书卡 key 为 0。两个物理机用例共同验证按 tab 身份切换。
- **备注**：顶层 tab 会按模块偏好和平台插入/隐藏，测试不得再把位置索引编码成业务身份。

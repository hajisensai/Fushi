## BUG-480 · 查词窗白色无内容
- **报告**：2026-07-01（用户：`查词窗是白色的，没内容`）
- **真实性**：❌ 当前未复现/未定位新根因。修复 macOS file picker entitlement 后，用 Computer Use 复测首页查词页：搜索框、空状态“请先导入词典以便使用”和“导入词典”按钮均正常显示；进入词典管理页后，顶部导入/下载按钮、分类 tabs 和空状态也正常显示。既有查词弹窗防白屏路径（空结果仍注入 `renderPopup`、搜索中遮罩、global-lookup 样式作用域）自动化守卫均通过。
- **[ ] ① 未修复** — 当前没有复现到独立查词窗白屏缺陷；本轮实际修复的是导致词典导入 picker 不弹出的 macOS sandbox entitlement 问题（见 BUG-478）。
- **[ ] ② 未加自动化测试** — 未新增测试；已回跑既有查词弹窗守卫：`flutter test test/pages/dictionary_popup_webview_test.dart test/pages/popup_layer_loading_cover_guard_test.dart test/lookup/global_lookup_popup_style_guard_test.dart --reporter expanded`。
- **备注**：如再次出现，需要补充具体入口（首页查词、阅读器划词弹窗、全局查词悬浮窗或视频字幕查词）和触发词/页面状态；旧的同类真 bug 记录见 `docs/bugs/BUG-312-todo-520-lookup-window-no-text.md`。

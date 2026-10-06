## BUG-3010 · 标签管理重排使用SDK浮层导致非默认界面缩放下拖拽错位
- **报告**：2026-10-06（Codex 目录守卫复核）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/tag_management_page.dart:493` 重新使用 SDK `ReorderableListView.builder`，其 Overlay 拖拽代理不继承页面的界面缩放，重现 BUG-778 的坐标边界；原第 259 行还使用 SDK 插入槽下标协议。
- **[x] ① 已修复** — `98b42edb5f1`：标签页迁到 `FushiReorderableColumn`，共享组件新增默认关闭的把手模式，仅把手接管拖动，行体保留长按菜单和横滑删除；页面回调使用最终下标。
- **[x] ② 已增加自动化测试** — `fushi_reorderable_column_test.dart` 覆盖 0.5/0.8/1.5 倍缩放、触摸把手不误触菜单、行体长按/横滑不重排；`tag_management_reorder_wiring_guard_test.dart` 钉住页面接线，整批 `reorderable_scale_safety_guard_test.dart` 禁 SDK 组件回流。
- **备注**：设备端原始视觉路径尚未复测，当前交付为代码修复与自动化验证；未操作用户正在运行的 Fushi Dev。本轮执行结果待定向验证，不继承 verify-1006 分支结论。

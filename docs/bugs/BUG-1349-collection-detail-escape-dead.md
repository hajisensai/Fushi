## BUG-1349 · 合集详情页按Esc不退出（焦点导航开启时全局Esc解析不到路由被吞）
- **报告**：2026-08-02（用户：合集详情页现在按 Esc 不退出）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/shortcuts/global_navigation.dart:52-56`（修复前）：`_handleGlobalEscape` 用 `controller?.activeContext ?? primaryFocus?.context` 取「聚焦上下文」，但 `HibikiFocusController.activeContext`（`hibiki/lib/src/focus/hibiki_focus_controller.dart:100-104`）在当前页**零受管焦点目标**时回落 `fallbackNode.context ?? _rootContext`——两者都挂在 `HibikiFocusRoot`（main.dart:1639，Navigator **之上**），`ModalRoute.of` 恒为 null，被 `route == null → ignored` 当成「无路由」吞掉。合集详情页默认态恰好零受管目标（剧集轨卡非受管、管理列表默认折叠不建 `HibikiFocusTarget`，路由切换又清 activeId），焦点导航开启的安装上必现；Esc 的三处默认绑定全是页面 scope（reader/manga/video），globalBack 默认键是 Alt+Left，没有第二条路兜底。
- **[x] ① 已修复** — `_handleGlobalEscape` 改为候选（controller.activeContext → primaryFocus.context）逐个解析路由，取第一个**能解析出**的路由；只有确证 `PopupRoute` 才让路给框架（弹窗持焦点时 Esc 根本冒泡不到这里），解析不出路由（焦点停在 Navigator 之上的兜底节点）不再视作弹窗、照常 `maybePop`。提交 <landing commit 见 PR>。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/media_collection_detail_escape_test.dart`：①注册表接线下详情页 Esc 退层；②焦点导航开启（HibikiFocusRoot enabled + 零受管目标）下 Esc 仍退层（修复前红）。
- **备注**：与 docs/agent/focus-ownership.md 的焦点所有权模型一致：兜底节点不属于任何路由，任何「按聚焦上下文判路由」的消费方都不得把它当权威。

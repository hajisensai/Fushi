## BUG-1349 · 合集详情页按Esc不退出（焦点导航开启时全局Esc解析不到路由被吞）
- **报告**：2026-08-02（用户：合集详情页现在按 Esc 不退出）
- **真实性**：✅ 真 bug，根因有**两处**（叠加成用户症状，各自独立可触发）：
  1. **Esc 解析遮蔽**（`hibiki/lib/src/shortcuts/global_navigation.dart:52-56` 修复前）：`_handleGlobalEscape` 用 `controller?.activeContext ?? primaryFocus?.context` 取聚焦上下文，而 `HibikiFocusController.activeContext`（`hibiki/lib/src/focus/hibiki_focus_controller.dart:100-104`）在当前页无已聚焦受管目标时回落 `fallbackNode.context ?? _rootContext`——挂在 Navigator **之上**、`ModalRoute.of` 恒 null，被 `route == null → ignored` 当成「无路由/弹窗」吞掉；明明能解析出路由的 `primaryFocus` 被 `??` 遮蔽。
  2. **焦点层挂载顺序**（`hibiki/lib/main.dart` 修复前 1600-1606）：`_wrapFocusNavigation`（HibikiFocusRoot，挂 fallbackNode）包在 `wrapWithGlobalNavigation` **外**。键事件沿焦点树只向祖先冒泡：零受管目标页（如空合集详情/旧版折叠列表详情页）把焦点回收到 fallbackNode 后，Esc 与**所有全局快捷键**根本到不了全局处理器。
  旧详情页默认态零受管目标（管理列表折叠不建 `HibikiFocusTarget`），两处根因在焦点导航开启的安装上叠加必现；Esc 三处默认绑定全是页面 scope、globalBack 默认 Alt+Left，没有第二条兜底路径。
- **[x] ① 已修复** —
  1. `_handleGlobalEscape` 改为候选（activeContext → primaryFocus）逐个解析路由，取第一个**能解析出**的；只有确证 `PopupRoute` 才让路（弹窗持焦点时 Esc 冒泡不到这里）；两候选都解析不出（焦点停在 Navigator 之上的兜底节点）不再视作弹窗、照常 `maybePop` 顶层。
  2. `main.dart`：`_wrapFocusNavigation` 挪进 `wrapWithGlobalNavigation` 的 child——fallbackNode 的键事件必经全局处理器。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/media_collection_detail_escape_test.dart`（6 用例）：
  - 注册表接线基线：详情页 Esc 退层；
  - **遮蔽态**（根因1）：零目标页进页未聚焦，前置断言 `activeContext` 解析不出路由而 `primaryFocus` 能解析（护栏：故障态不成立先红，防假防护）→ Esc 退页；
  - **双失效态**（根因1+2）：零目标页 `ensureFocus` 真实回收链路 park 到 fallbackNode（前置断言 `primaryFocus == fallbackNode`）→ Esc 退页；
  - 负向：弹窗持焦点 Esc 只关弹窗不退页；
  - 负向翻转面：弹窗开着且焦点 park 兜底，「解析不出→maybePop」只弹顶层（弹窗）不越级退页；
  - 源码守卫（根因2，widget 测试不加载 main.dart）：`wrapWithGlobalNavigation` 实参段内必须含 `_wrapFocusNavigation(`。
  变异证据：还原 origin/develop 版 `global_navigation.dart` → 三故障态用例红（+2 -3）；还原旧 `main.dart` 接线 → 源码守卫红（+0 -1）；均复原后 6/6 绿。
- **备注**：与 docs/agent/focus-ownership.md 的焦点所有权模型一致：兜底节点不属于任何路由，「按聚焦上下文判路由」的消费方不得把它当权威；且一切全局键处理层必须在焦点树上位于兜底节点之上。

## BUG-422 · 平板宽屏 rail 焦点右键应进内容区（TODO-814）

- **报告**：2026-06-25
- **真实性**：❓ 当前 develop 下**未复现**（widget 层沿真实代码路径穷尽验证，方向几何与框架回退均行为正确；疑似已被 BUG-033/011/015 一系列「面板感知方向导航」修复覆盖，或需真机/特定运行时态才触发）。

### 真实代码路径（已逐层追踪）
- 输入分发：键盘方向键经 `home_page.dart:280` 的 `_handleKeyEvent` → `gamepadMoveFocusInDirection`（手柄 D-pad/摇杆同一入口，`gamepad_service.dart:340/380`）。三种输入收敛到同一焦点引擎。
- 受管几何引擎：`gamepad_service.dart:646` → `HibikiFocusController.move` → `_geometricTarget`（`hibiki_focus_controller.dart:370`）。
  - 宽屏布局 `home_page.dart:549-563`：左 rail 与右 body 各自独立 `FocusTraversalGroup`（两面板），rail 用 `adaptiveNavRail` → `_MaterialNavCluster`（竖向，每项独立 `HibikiFocusTarget`，居中同一列）。
  - 对「右」按压：候选须 `dx > epsilon`（`hibiki_focus_controller.dart:446-452`）。rail 内其它项与当前项同列 `dx≈0` → **永远不满足 ahead → 不可能被选为右向目标**；内容卡片 `dx>0` → 命中。故几何引擎对 rail 上的「右」**只会进内容，不可能在 rail 内纵向移动**。
- 框架回退：`move()` 找不到受管目标时回退 `gamepad_service.dart:696` 的 `primary.focusInDirection(direction)`（Flutter `DirectionalFocusTraversalPolicyMixin`）。实测探针证明：Flutter 该遍历**方向严格**，单列 group 内对「右」无横向邻居时返回 false 原地不动，**不会反向/垂直弹跳**。
- 唯一方向无关的回退 `_moveByReadingOrder`（`hibiki_focus_controller.dart:537`）仅在 `activeRect==null`（当前项无布局）时触发，且其「右」是注册序 `+1`=视觉下方，亦非「上」。

### 结论
- 文字描述的「rail 上按右焦点往上跳」在当前 develop 的 widget 测试中无法复现：几何引擎正确把右向路由进内容，框架回退方向严格不反弹。
- 推测：该现象由 `714b1af45`(BUG-033 面板隔离)/`c8017ad8c`(BUG-011)/`84e13f2e8`(BUG-015) 系列修复后已消除；或依赖真机特定运行时态（内容懒加载注册时序、空内容 tab 等）才偶发。
- 已补**回归守卫测试**锁定正确行为，防止未来回归。真机最终验收待用户在平板/宽屏真实设备上复测原始失败路径。

- **[x] ① 根因修复** — 当前 develop 未复现，无需改动 dispatch/geometry；方向几何已正确（`hibiki_focus_controller.dart:370-501`，rail 同列项对「右」恒不满足 ahead），框架回退方向严格（`gamepad_service.dart:696`）。
- **[x] ② 自动化测试** — `hibiki/test/focus/rail_right_enters_content_test.dart`：真实 `adaptiveNavRail` + 内容网格，走真实 `gamepadMoveFocusInDirection` 分发，断言 rail 上按右进内容（不在 rail 内纵向）、Down 仍在 rail 内步进（无回归）。
- **备注**：若用户在真机仍能复现，需带真机焦点几何证据（`flutter run` 日志打 rail 项/内容首项 globalRect + 按右后 activeId）重开调查，重点查内容目标注册时序与是否存在非 `HibikiFocusTarget` 的内容可聚焦节点。

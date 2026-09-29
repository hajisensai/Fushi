## BUG-2749 · 手柄方向导航看不见原生控件、对话框里焦点被拽走
- **报告**：2026-09-28（用户：「重写一下手柄的焦点，现在好多地方焦点都不对」）
- **真实性**：✅ 真 bug（前提：「键盘/手柄焦点导航」开关打开、`FushiFocusRoot` 控制器接管）。根因在 `fushi/lib/src/focus/fushi_focus_controller.dart`：方向引擎 `move()` 的候选集只有 `FushiFocusTarget` 登记目标（`_focusableEntries()`），`_currentEntry()` 在主焦点落到未登记控件时无条件回退陈旧 `_activeId`，零 active 时 `_moveByReadingOrder(currentIndex: -1)` 取**插入顺序**首项；`ensureFocus()` 在主焦点是对话框路由 scope 时落到 `fallbackNode.requestFocus()`；`_FushiFocusRootState.build` 把 `_FushiFocusScope` 放在兜底 `Focus` 里面，兜底节点上 `maybeControllerOf` 恒 null。
- **[x] ① 已修复** — 分支 `gamepad-focus`（见 git log）
- **[x] ② 已加自动化测试** — `fushi/test/focus/mixed_page_directional_focus_test.dart`、`fushi/test/focus/dialog_menu_gamepad_focus_test.dart`（旧实现下 3 条红、新实现全绿）；`fushi/test/widgets/fushi_material_components_test.dart` 紧凑搜索行改为断言 D-pad 能落到搜索框
- **备注**：不是从零重写——几何排序（clears / samePane / along / beam / cross）、方向锚点、autoHome、后台闸门（BUG-1619）、边缘滚动接管全部原样保留，只换了「在谁身上排序」和「从哪儿出发」。

### 根因（审计量化）

`lib/` 下未经 `FushiFocusTarget` 包裹的原生可聚焦控件约 1000 处（TextButton 287、IconButton 174、FilledButton 168、`adaptiveDialogAction` 225……），受管目标只覆盖共享组件。于是：

1. **混排页跳过原生控件**：受管行之间夹着原生按钮时，D-pad 直接越过它们（复现：受管→↓ 落到下一个受管目标而不是中间的 TextButton）。
2. **从陈旧位置出发**：焦点移到原生控件后，方向键仍从上一个受管目标计算（按 ↑ 跳到倒数第二行；下拉菜单打开时 D-pad 跳到菜单背后的页面行）。
3. **插入顺序 bootstrap**：无 active 时任意方向都去登记表插入顺序首项（首页上是侧栏 rail 第一项），不看方向也不看阅读顺序。
4. **对话框焦点被拽走**：只有原生按钮的对话框（`showAppDialog` 258 处）弹出后，被动修复 / 第一次 D-pad 把焦点从对话框路由 scope 拽到 Navigator 之上的兜底节点；此后 A 键 `ActivateIntent` 无人处理、D-pad 从根 scope 盲跳。
5. **兜底节点上看不到控制器**：`maybeControllerOf(fallbackNode.context)` 为 null，D-pad 走「无控制器」分支 `FocusScope.nextFocus()`，绕过当前路由过滤。
6. **两套引擎**：控制器找不到目标后再跑一遍框架 `focusInDirection`，同一次按键两套结论。

### 修复

- 候选集 = 当前焦点作用域（主焦点最近的 `FocusScopeNode`：页面路由 / 对话框 / 菜单 / 页内面板；主焦点无可用节点时取最顶层当前路由 scope）里所有可聚焦叶子；受管目标带登记信息（id / 锚点 / autoHome / 几何锚点），原生节点用自身 context。受管复合控件内部的原生节点、包着其它候选的原生容器（整页 key sink）不当落点。
- 当前位置 = 真实主焦点；陈旧 `_activeId` 只在主焦点不在任何可用节点上时兜底。
- bootstrap 按阅读顺序落首个 autoHome 目标。
- 被动修复不再把焦点从有落点的路由 / 菜单 scope 拽到兜底节点（也不替用户挑对话框按钮，避免 Enter 误触）。
- `_FushiFocusScope` 挪到兜底 `Focus` 外面。
- 控制器是唯一引擎：去掉控制器失败后的第二遍框架 `focusInDirection`；键盘方向键门控 `primaryFocusIsManagedTarget` → `primaryFocusIsNavigable`，与 D-pad 同一候选集。
- 顺带修正 `FushiIconButton` 装饰图标（`onTap == null`）仍给底层 InkWell / IconButton 挂空转回调、因而原生可聚焦的问题（旧引擎看不见原生节点把它掩盖了）。

### 待验证（真机）

- 打开焦点导航，手柄走一遍：首页 dashboard（继续阅读卡 / 每日目标行等裸 InkWell）、书架搜索框、设置搜索框、任一 `showAppDialog` 确认框（D-pad 进按钮、A 确认、B 关闭）、下拉菜单、视频页侧面板。

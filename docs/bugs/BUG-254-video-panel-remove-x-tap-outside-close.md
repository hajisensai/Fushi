## BUG-254 · 视频侧栏面板删右上角 X、改点左侧 / 空白关闭

- **报告**：2026-06-14（TODO-303：「视频那些界面右上角的 X 删掉，改成点击左边或者空白会取消右边这些界面」）。
- **真实性**：✅ 真功能需求（交互改造）。
  - 现状：侧栏面板（`VideoSubtitleJumpPanel` 自带 header 有 close 按钮；`VideoTranslucentSidePanel` 也有 close 按钮）只能靠右上角 X 关闭，没有点外关闭；点面板外的空白还会冒泡到控制条 `Listener` 误触发暂停 / 全屏（与 BUG-246 同源）。

### 根因（file:line）

- `hibiki/lib/src/media/video/video_side_panel.dart`：`VideoTranslucentSidePanel` header（旧 :63-69）渲染右上角 `IconButton(Icons.close)`。
- `hibiki/lib/src/media/video/video_subtitle_jump_panel.dart`：`_buildHeader`（旧 :282-288）渲染右上角 `IconButton(Icons.close)`，onPressed `_handleClose`。
- `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` `_buildVideoSidePanelOverlay`（旧 :3975）只渲染面板本体，**没有**面板外的 barrier，点空白不关面板（且冒泡到控制条）。

### [x] ① 根因修复

- **删 X 关闭按钮**：`VideoTranslucentSidePanel` header 去掉 `IconButton(Icons.close)`（标题独占一行，padding 收尾改 16）；`VideoSubtitleJumpPanel._buildHeader` 去掉 close `IconButton`，并删掉随之失去调用方的 `_handleClose` 方法。两处 `onClose` 字段保留（供 barrier / 调用方复用、保持构造契约）。字幕列表关闭时的 `onClearCueSelection` 副作用由页面层 `_hideVideoSidePanel`（字幕列表分支 `_clearSelectedMiningCues`）统一承载，删按钮不丢该副作用。
- **加点外关闭 barrier**：`_buildVideoSidePanelOverlay` 把面板内容抽成 `_buildVideoSidePanelContent(kind, controller)`，外层包 `Stack(fit: expand, children: [全屏 GestureDetector(behavior: opaque, onTap: _hideVideoSidePanel), panelContent])`。barrier 在面板**后面**铺满全屏、`HitTestBehavior.opaque` 吃掉点击 → 点空白 / 左侧只关面板、**不**冒泡到下方控制条 `Listener`（不触发暂停 / 全屏，与 `_handleVideoPointerUp` 的侧栏早返回门控一致）。面板本体是不透明 Material、在 Stack 上层，点面板内部命中面板自身、到不了 barrier，故只有点外部才关闭。

提交：见本轮 `fix(video): suppress background controls + tap-outside-to-close side panels`。

### [x] ② 自动化测试

- `hibiki/test/pages/video_side_panel_tap_outside_guard_test.dart`（源码守卫）：`_buildVideoSidePanelOverlay` 含全屏 `GestureDetector` barrier（`HitTestBehavior.opaque` + `onTap: _hideVideoSidePanel`）包在 `Stack` 里、面板内容在 barrier 之后（上层）。
- `hibiki/test/media/video/video_side_panel_test.dart` / `video_subtitle_jump_panel_test.dart`（widget 行为）：扩展为「header 不再渲染 `Icons.close` 关闭按钮」。

### 不回归

- 面板内部所有交互（字号步进 / 自动滚动 / 筛选 / 行点击跳转 / 收藏 / 挖词选择 / 设置项）不变。
- 字幕列表关闭清挖词选择（`_clearSelectedMiningCues`）经 `_hideVideoSidePanel` 仍执行。
- `onClose` 字段保留，调用方 `onClose: _hideVideoSidePanel` 不变（barrier 直接调 `_hideVideoSidePanel`）。

### 残留风险

- **真机待验**：host 跑不了 media_kit 渲染，需桌面 / 移动真机打开各侧栏面板，点左侧空白确认关闭、点面板内部确认不关闭、点空白不触发暂停 / 全屏。
- 与 BUG-246（`_handleVideoPointerUp` 侧栏早返回）协调：barrier 现在先吃掉面板外点击，`_handleVideoPointerUp` 的侧栏早返回成为第二道保险（barrier 已拦住、不再冒泡进控制条 Listener），两者不冲突。

### 后续（TODO-637 / BUG-356：字幕列表部分被反转）

- 2026-06-20 TODO-637：用户针对**字幕列表**改主意——`VideoSubtitleJumpPanel`（push-aside 侧栏）改回「带 × 的非阻塞侧栏」。原因：BUG-256 为字幕列表在画面区叠的 opaque barrier 罩在画面字幕查词手势上，列表开着时画面字幕查不了词（BUG-356 / TODO-636）。
- 反转范围**仅限字幕列表**：`VideoSubtitleJumpPanel._buildHeader` 带回右上角 `IconButton(Icons.close)`（onPressed `widget.onClose`），并删除字幕列表的 opaque barrier + 列表锁定（TODO-611/634）。
- **overlay 面板体系不反转**：`VideoTranslucentSidePanel`（倍速/设置/收藏句子/字幕源/音轨/章节）保持本 BUG-254 现状——无 X、点面板外 barrier 关闭、收藏列表可锁定（`_sidePanelLocked`）。
- 影响：字幕列表关闭路径现为 × / Esc / 控制条字幕按钮三选一（各含 `_clearSelectedMiningCues`）；不再依赖「点画面关列表」。详见 BUG-356 与分支 `todo-637-subtitle-sidebar-x`。

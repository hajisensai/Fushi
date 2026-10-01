## BUG-2832 · 视频控制条空间不够时按钮被等比缩小或裁成半个图标
- **报告**：2026-10-01（用户：截图——开字幕列表后播放区变窄，返回键后面多出一个小「▸」，底栏时间后面一排 −10s / 上一句 / 播放 / 下一句 / +10s 缩成米粒大，旁边音量 / 倍速 / + 却是原尺寸；画面中央同时出现小窗档才有的大三键）
- **真实性**：✅ 真 bug，三处根因：
  1. **media_kit fork 的 theme `updateShouldNotify` 写反**（`third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material.dart:637`、`material_desktop.dart:479`）：`identical(normal, old.normal) && identical(fullscreen, old.fullscreen)` 在 theme **换了**新实例时返回 false，依赖方不重建。控制条主体是 `const _MaterialVideoControls()`，父级重建会被跳过，只能靠这条通知。开字幕列表 → 播放区落进 mini 档 → 本仓按新密度画出中央大三键，media_kit 却仍拿旧 theme 画完整顶/底栏，直到它内部下一次 setState。截图里大三键与顶/底栏并存就是这个。
  2. **底栏放不下靠等比缩小**（`fushi/lib/src/media/video/video_bottom_bar_slots.dart:56-101`）：左右两簇先按原尺寸拿宽，中间传输簇只拿剩下的缝，`FittedBox(scaleDown)` 把整排缩到 ~40%——点击区远小于 48dp，同一条栏两种尺寸。±10s 带不带文字按整条底栏 `>= 600` 判（`video_fushi_page.dart` `_hasRoomyVideoBottomBar`），不看中簇实际放不放得下，768 宽时仍带文字，缩得更狠。
  3. **顶栏按钮组放不下靠横滚裁切**（`video_fushi_page.dart` `_topBarSlotGroup` 的 `reverse` 横向 `ListView`）：topRight 组从左边裁掉，「剧集列表」（`Icons.playlist_play`）只露出右下角三角，紧贴在返回键后面——那个「▸」。
- **修复计划**：
  - fork 两处 `updateShouldNotify` 改成「任一实例变了才通知」；两个 State 的 `didChangeDependencies` 都由 `subscriptions.isEmpty` / `??=` 守着，重复调用幂等。记入 `third_party/media_kit_video/PATCHES.md`。
  - 新增 `VideoControlBar`（`fushi/lib/src/media/video/video_control_bar.dart`）：自定义 RenderBox，所有按钮按原尺寸量宽，纯函数 `planVideoControlBar` 决定 ①先全部原样 ②放不下先把带文字的按钮（±10s）换成纯图标 ③还放不下就按优先级从低到高（成对按钮一起）收进末尾的「⋯」按钮，点开菜单就地执行。按钮永不缩放、永不裁切；返回 / 播放暂停 / 时间钉死不收。被收起的按钮不绘制、不参与命中、不进语义树，并经 `ExcludeFocus` 退出 Tab / 手柄遍历。
  - 底栏三簇（左 / 中 / 右）与顶栏左右按钮组都换成 `VideoControlBar`，删掉 `VideoBottomBarSlots` 与 `_hasRoomyVideoBottomBar`。
- **[x] ① 已修复** — `676812cbd5`：fork 两处 `updateShouldNotify` 改正（记入 `third_party/media_kit_video/PATCHES.md`），mini 档不再与完整顶/底栏并存；新增 `VideoControlBar` + `planVideoControlBar`，底栏三簇与顶栏左右组统一走它（原样 → ±10s 换纯图标 → 按优先级收进「⋯」），删除 `VideoBottomBarSlots`、`_hasRoomyVideoBottomBar` 与死字段 `VideoControlsDensitySpec.showSeekLabels`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_control_bar_test.dart`（planner 三档 / 成对收起 / 钉死项 / 同优先级先收靠后的 + 真布局：居中、紧凑、收进「⋯」后不绘制不命中且退出焦点、菜单顺序与执行、`fill: false` 收缩）；`fushi/test/pages/video_controls_theme_notify_guard_test.dart`（真实 fork 部件的 `updateShouldNotify`）；源码守卫 `video_topbar_guards_test` / `video_mobile_controls_guard_test` / `video_play_center_seek_labels_guard_test` 改钉 `VideoControlBar`，禁止回退到 `FittedBox` / 横滚 `ListView`。
- **备注**：代码审查追加三处修复（同一轮）：
  1. 顶栏 `VideoTopBarSlots` 原按「左组先拿完剩余宽」分宽，左组按钮多时右组只剩不到一个「⋯」宽，仍会被裁成半个甚至整组消失。改为 `allocateVideoTopBarButtonWidths`：先按各组最小固有宽（钉死项 + 「⋯」）保底，再按优先级补足；`VideoControlBar.computeMinIntrinsicWidth` 补算「⋯」。测试 `fushi/test/pages/video_top_bar_slots_test.dart`。
  2. 移动端全屏按钮原是画成零宽的条目，会被收进「⋯」，菜单里多出一行无效的「全屏」。改在 `_shouldRenderControlItem` 门上按 `isMobilePlatform` 排除。守卫 `video_mobile_controls_guard_test.dart`。
  3. 音量 / 倍速浮层开着时锚点按钮被收起，浮层（`showWhenUnlinked: false`）隐身但遮罩仍吞点击。新增 `VideoBarEntry.onFolded`，页面在锚点被收起时 `_hideControlPopover()`。测试 `video_control_bar_test.dart`「onFolded 只对刚被收起的条目调一次」。

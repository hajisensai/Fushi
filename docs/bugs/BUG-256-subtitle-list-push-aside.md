## BUG-256 · 字幕列表应挤画面到左（非浮层遮挡）
- **报告**：2026-06-14（用户：TODO-314 字幕列表浮在画面上遮挡，应像 asbplayer 那样把画面挤到左边）
- **真实性**：✅ 真 bug。`_toggleSubtitleJumpList`（`hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1541`）被错误统一进浮层 side-panel 系统——它走 `_showVideoSidePanel(_VideoSidePanelKind.subtitleList)`（:3903），而 `_showVideoSidePanel` 无条件 `_subtitleListVisible.value = false`（:3909）→ 真正的 push-aside 布局 `_videoWithSubtitlePanel`（:5273，`Row[Expanded(video), _subtitleJumpSidePanel]`，窗口/全屏两处都已包）成死代码，改由 overlay `_buildVideoSidePanelOverlay`（:3988，`Align centerRight` 浮在画面上）遮挡。另：从收藏句进入的内联 push-aside 面板（`_subtitleJumpSidePanel`，`initialSubtitleListVisible`）删 X 后（BUG-254 给 overlay 加了点外关闭）只能靠控制条字幕按钮切换，点外不关。
- **[x] ① 已修复** — `_toggleSubtitleJumpList` 改驱动 `_subtitleListVisible`（push-aside 路径），不再调 `_showVideoSidePanel` 开 subtitleList overlay；开 push-aside 列表时关其它浮层、开其它浮层时 `_subtitleListVisible.value = false`（`_showVideoSidePanel` 对其它 kind 仍设 false）。从 `_VideoSidePanelKind` 删除 subtitleList 枚举值及其 title/width/child/content 死分支，删 `_buildSubtitleListSidePanel`（overlay 版）。给 push-aside 面板补点外关闭：`_videoWithSubtitlePanel` 在 video 区叠一层 barrier（仅 visible 时），点视频/外部 → `_subtitleListVisible.value = false`，保证除控制条字幕按钮外仍有明确关闭入口。提交哈希见末行。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_subtitle_list_push_aside_guard_test.dart` 源码守卫：subtitleList 走 `_subtitleListVisible` 而非 overlay（`_VideoSidePanelKind` 不再含 subtitleList、`_toggleSubtitleJumpList` 不调 `_showVideoSidePanel`）；push-aside 面板有点外关闭途径。
- **备注**：与 integration/wave-1 ff 基线对照零新增回归。真机验证待用户。

### 后续（TODO-637 / BUG-356：barrier 被移除）

- 2026-06-20 TODO-637：本 BUG-256 当初给 push-aside 字幕列表加的「点画面/外部关闭」barrier（`_videoWithSubtitlePanel` 里 video 区叠的 `Positioned.fill(GestureDetector(behavior: opaque, onTap: 关列表))`）**已删除**。
- 原因：该 opaque barrier 罩在画面字幕 overlay（`VideoSubtitleOverlay`）的查词手势之上，列表开着时画面字幕查不了词（BUG-356 / TODO-636）。
- 现状：字幕列表是「带 × 的非阻塞侧栏」，画面区是裸 `video`（画面字幕可查词），关列表走面板头部 × / Esc / 控制条字幕按钮（各含 `_clearSelectedMiningCues`）。随 barrier 失去意义的列表锁定（TODO-611）一并移除（TODO-634）。
- 守卫同步反转：`video_subtitle_list_push_aside_guard_test.dart` 原断言「应有 opaque barrier」改为「画面区不应再有 opaque barrier」。详见 BUG-356 与分支 `todo-637-subtitle-sidebar-x`。

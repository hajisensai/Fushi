## BUG-371 · 打开字幕列表侧边栏时左侧控制按钮全部消失
- **报告**：2026-06-21（用户：字幕列表出现时左边按钮全消失；字幕列表只是侧边栏，左边的按钮应该还可以换出）
- **真实性**：✅ 真 bug。根因=`_subtitleListVisible` 被写进三处控制条/rail 抑制门控，但字幕跳转列表早已（TODO-314）从 overlay 改成 **push-aside** 布局（`_videoWithSubtitlePanel` 的 `Row[Expanded(video), 面板列]`，`video_hibiki_page.dart:6202`），把画面挤窄到左侧、**不遮挡**叠在画面上的控制层/rail。门控陈腐：
  - rail 强压制 getter `_videoSideActionRailStronglySuppressed`（`video_hibiki_page.dart:2019`）含 `_subtitleListVisible.value` → `_buildVideoSideActionRail` 直接 `SizedBox.shrink()`（`video_hibiki_page.dart:6091`）。
  - 控制条可见性派生 `_applyControlsVisibilityFromMediaKit` 的 `gated`（`hibiki/lib/src/pages/implementations/video_hibiki/controls_visibility.part.dart:87-93`）含 `_subtitleListVisible.value` → `_videoControlsVisible` 强制 false。
  - media_kit controls 的 `IgnorePointer`（`video_hibiki_page.dart:5875`）含 `_subtitleListVisible.value` → 顶/底栏按钮不可点。
  - `_toggleSubtitleJumpList`（`video_hibiki/subtitle.part.dart:34`）打开分支还主动 `_markControlsVisible(false)`。
- **[x] ① 已修复** — 从上述三处抑制门控移除 `_subtitleListVisible`（保留 `_videoSidePanel` 真 overlay 门控），`_toggleSubtitleJumpList` 打开分支删 `_markControlsVisible(false)`。字幕列表 push-aside 时控制条/rail 留在被挤窄的画面上继续可见可用。光标在字幕列表打开时仍保活（靠 `_hasVideoOverlay` 含 `_subtitleListVisible` + 前置胜出层光标覆盖，未改）。提交：<PENDING>
- **[x] ② 已加自动化测试** — 更新陈腐守卫 `hibiki/test/pages/video_side_panel_suppress_controls_guard_test.dart`（反向断言三门控不含 `_subtitleListVisible`）+ `video_immersive_cursor_hide_guard_test.dart` + `video_subtitle_push_up_guard_test.dart`（同步去除字幕列表门控断言、改断言光标仍由 `_hasVideoOverlay` 保活）；新增 `video_subtitle_list_keeps_controls_guard_test.dart`（断言打开分支不再 `_markControlsVisible(false)`）。
- **备注**：剧集列表（`_episodeListVisible`，TODO-638）也是 push-aside，仍在门控里——本轮只修用户报的字幕列表，剧集列表是否同改属 PM 决策（同一根因，建议一并改）。需**真机复测**：打开字幕列表后左右按钮可见且可点。

## BUG-248 · 桌面音量按钮挤走全屏键 + 顶栏设置入口与右栏重复 (TODO-283)
- **报告**：2026-06-14（用户：）
- **真实性**：✅ 真 bug（两子项）。
  - 子A（音量挤按钮）：桌面 `_buildVolumeButton`（`hibiki/lib/src/pages/implementations/video_hibiki_page.dart`）用 media_kit 的 `MaterialDesktopVolumeButton`，hover 时其内部 `AnimatedContainer` 把宽度从 12 撑到 82px、实时挤走右邻的全屏键。
  - 子B（设置入口重复）：桌面 / 移动 `topButtonBar` 各写死一枚 `Icons.tune` → `onPressed: _showPlayerSettings`，与右侧 rail 的可配置 settings 按钮（`VideoControlCustomization.defaults` 默认 `settings: rightRail`，`hibiki/lib/src/media/video/video_control_customization.dart:50` → `_buildVideoSideActionRail` → `_activateVideoControlButton(settings)` → 同一个 `_showPlayerSettings`）功能完全重复。
- **[x] ① 已修复** —
  - 子A：`_buildVolumeButton` 桌面分支改用固定宽度的 `MaterialDesktopCustomButton`（图标 `_volumeIconFor(controller.volume)` + `onPressed: _showVolumeMenu(controller)`），复用移动端已验证的弹出滑块菜单路径，放弃 hover 展开条 → 按钮宽度恒定，不再挤全屏键；顺带给音量按钮包 `Tooltip(message: t.audio_volume)`。
  - 子B：删掉桌面 + 移动 `topButtonBar` 写死的 `tune` 入口，统一由可配置 rightRail settings 按钮负责（默认就在 rightRail）。删后设置仍可从 rightRail 打开（`_activateVideoControlButton(VideoControlButton.settings) → _showPlayerSettings()`，方法未删）。提交哈希：见本轮提交。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_volume_and_settings_dedupe_guard_test.dart`：源码守卫断言 ①桌面 `_buildVolumeButton` 不再用 `MaterialDesktopVolumeButton`、改用 `MaterialDesktopCustomButton` + `_showVolumeMenu`；②两套 `topButtonBar` 内不再出现 `onPressed: _showPlayerSettings`（去重）；③`_showPlayerSettings` 方法与 `_activateVideoControlButton` 的 settings 分支保留（rightRail 仍可打开设置）。
- **备注**：子B 删顶栏 tune 与 TODO-274（控制条自定义）关系——settings 仍是可配置按钮，默认在 rightRail；若用户经自定义把它改成 settingsOnly，则播放器上没有设置入口（与原本任何按钮设 settingsOnly 一致，符合 TODO-274 语义）。真机看音量按钮不挤全屏键、设置仍可从右栏打开，待用户。

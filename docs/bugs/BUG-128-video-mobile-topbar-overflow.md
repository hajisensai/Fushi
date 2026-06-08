## BUG-128 · 手机视频顶栏按钮溢出点不到
- **报告**：2026-06-08（用户：手机视频里好多按钮打不开，完全没反应；控制条出现了但点图标没反应；操作太难受，请按正常手机操作方式来）
- **真实性**：✅ 真 bug（移动端顶栏图标过多在窄屏溢出/挤压），根因 `video_hibiki_page.dart:1327 _mobileControlsTheme topButtonBar`。

### 根因（真实代码路径取证 + 用户真机现象）
用户真机确认：控制条**会出现**、图标**看得到**，但点图标「完全没反应」，播放本身正常。
`_mobileControlsTheme` 的 `topButtonBar` 是一个 `Row(mainAxisSize: max)`，硬塞：返回 + `Expanded(标题)` +（播放列表时）上一集/下一集/剧集列表 + 截图 + 字幕 + 音轨 + 倍速 + 设置 —— **5~8 个固定宽图标**。手机窄屏（~360dp）下固定图标总宽超出可用宽度：`Expanded(标题)` 被压成 0，图标溢出到屏幕右侧被裁剪（release 静默 clip），右侧图标在屏外点不到、其余挤在一起命中区不可靠 → 表现为「图标看得到但点了没反应」。这也是用户说「操作太难受」的根因：违反手机播放器「顶栏少量按钮 + ⋮ 更多」的标准交互。
（media_kit 移动 `MaterialVideoControls` 的 topButtonBar 渲染见 `material.dart:982/995-1004` 的 `Row(mainAxisSize.max, children: topButtonBar)`，不自动换行/折叠。）

### 修复（按标准手机交互重排）
移动端顶栏只留：返回 + `Expanded(标题)` +（播放列表时）剧集列表 + **「⋮ 更多」**。把截图/字幕/音轨/倍速/剧集/设置全部收进 ⋮ 打开的底部 `showModalBottomSheet`（一项一行、触控目标大，`_showMobileMoreMenu` + `_VideoMoreAction` 枚举）。每项 `Navigator.pop(ctx, action)` 返回选择，**等 sheet 完全关闭后再派发**到既有 handler，避开与各 handler 共享的 `_videoSheetOpen` 守卫竞争。桌面 `_desktopControlsTheme` 顶栏不动（桌面有横向空间、用户未报桌面按钮问题）。

- **[x] ① 已修复** — `video_hibiki_page.dart _mobileControlsTheme` 顶栏尾部图标从 6~8 个收为「剧集列表(播放列表时) + ⋮」；新增 `_showMobileMoreMenu`/`_moreTile`/`_VideoMoreAction` 底部 sheet 派发到 `_saveScreenshot`/`_showSubtitleSourceMenu`/`_showAudioTrackMenu`/`_showSpeedMenu`/`_showEpisodeList`/`_showPlayerSettings`；i18n 加 `video_audio_track`/`video_more`。
- **[x] ② 已加自动化测试** — `test/pages/video_mobile_controls_guard_test.dart`（移动顶栏含 `more_vert` + `_showMobileMoreMenu`、不再在移动顶栏直接放截图/字幕/音轨/倍速/设置图标按钮、`_showMobileMoreMenu` 派发到 6 个 handler）。
- **备注**：media_kit 无 headless，真机复验：手机顶栏点 ⋮ 弹出菜单、各项可正常打开；桌面顶栏不变。原「完全没反应」应消失（图标不再溢出屏外）。

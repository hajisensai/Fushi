## BUG-134 · 手机视频顶栏竖屏溢出（自适应布局）
- **报告**：2026-06-08（用户：手机视频里好多按钮打不开；操作太难受，请按正常手机操作方式来）
- **真实性**：✅ 真 bug（竖屏窄屏顶栏图标溢出），但**「点了没反应」的真因是 BUG-135**（热 WebView 吞触摸），本条只解决竖屏布局溢出。用户后续澄清横屏全展开也点不动 → 点不动非溢出所致，见 [BUG-135](BUG-135-video-warm-popup-eats-touches.md)。根因 `video_hibiki_page.dart:1352 _mobileControlsTheme topButtonBar`。

### 根因（真实代码路径取证 + 用户真机现象）
用户真机确认：控制条**会出现**、图标**看得到**，但点图标「完全没反应」，播放本身正常。
`_mobileControlsTheme` 的 `topButtonBar` 是一个 `Row(mainAxisSize: max)`，硬塞：返回 + `Expanded(标题)` +（播放列表时）上一集/下一集/剧集列表 + 截图 + 字幕 + 音轨 + 倍速 + 设置 —— **5~8 个固定宽图标**。手机窄屏（~360dp）下固定图标总宽超出可用宽度：`Expanded(标题)` 被压成 0，图标溢出到屏幕右侧被裁剪（release 静默 clip），右侧图标在屏外点不到、其余挤在一起命中区不可靠 → 表现为「图标看得到但点了没反应」。这也是用户说「操作太难受」的根因：违反手机播放器「顶栏少量按钮 + ⋮ 更多」的标准交互。
（media_kit 移动 `MaterialVideoControls` 的 topButtonBar 渲染见 `material.dart:982/995-1004` 的 `Row(mainAxisSize.max, children: topButtonBar)`，不自动换行/折叠。）

### 修复（按标准手机交互重排）
移动端顶栏只留：返回 + `Expanded(标题)` +（播放列表时）剧集列表 + **「⋮ 更多」**。把截图/字幕/音轨/倍速/剧集/设置全部收进 ⋮ 打开的底部 `showModalBottomSheet`（一项一行、触控目标大，`_showMobileMoreMenu` + `_VideoMoreAction` 枚举）。每项 `Navigator.pop(ctx, action)` 返回选择，**等 sheet 完全关闭后再派发**到既有 handler，避开与各 handler 共享的 `_videoSheetOpen` 守卫竞争。桌面 `_desktopControlsTheme` 顶栏不动（桌面有横向空间、用户未报桌面按钮问题）。

- **[x] ① 已修复** — `video_hibiki_page.dart _mobileControlsTheme` 顶栏**按宽度自适应**：`roomy = MediaQuery.width >= 600`，横屏/平板平铺全部 截图/字幕/音轨/倍速/设置（用户要求横屏能全展开），竖屏窄屏收进新增 `_showMobileMoreMenu`/`_moreTile`/`_VideoMoreAction` 底部 sheet（派发到 6 个既有 handler）；i18n 加 `video_audio_track`/`video_more`。
- **[x] ② 已加自动化测试** — `test/pages/video_mobile_controls_guard_test.dart`（顶栏自适应 `roomy`/宽度阈值、窄屏 `more_vert`+`_showMobileMoreMenu`、宽屏分支平铺图标、`_showMobileMoreMenu` 派发到 6 个 handler）。
- **备注**：media_kit 无 headless，真机复验：竖屏顶栏不溢出（点 ⋮ 展开）、横屏全展开。**点不动的真修复是 BUG-135**（本条只管布局）。

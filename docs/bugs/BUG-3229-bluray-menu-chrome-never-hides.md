## BUG-3229 · 原盘菜单左上角退出不自动隐藏且菜单栏不符合 M3E / Apple 规范
- **报告**：2026-10-10（用户：「原盘菜单的左上角的退出不会自动隐藏。原盘菜单做的时候不符合m3e和苹果标准，重新做一下」）
- **真实性**：✅ 真 bug。`BlurayDiscMenuBar`（`fushi/lib/src/media/video/bluray_disc_menu_bar.dart`，首版 fbeb260d78）是一条自绘的 `Colors.black87` 方角条，被两处无条件挂上：菜单态替换控制条时（`video_fushi/layout.part.dart:435`），以及**正片播放态**叠在常规控制条之上（`layout.part.dart:781` `if (controller.isBlurayNavigationSession) _buildDiscMenuBar(...)`）。两处都不订阅任何显隐源——media_kit 的自动隐藏只管它自己的控制条——所以左上角的退出键永不淡出；正片时还与常规顶栏的返回 + 标题胶囊重叠。外观是 `FushiTextButton` + 黑底方块，不是播放器顶栏的 MD3 Expressive 浮动胶囊 / Apple 玻璃钮。
- **[x] ① 已修复**（ce3747a4b4）— 正片态：删掉常驻条，「主菜单 / 弹出菜单」改为常规顶栏右上按钮组头部的两个条目（`_discNavigationBarEntries` → `_topBarSlotGroup`），与其它顶栏按钮同一外观、随控制条一起显隐、窄屏收进「⋯」。菜单态：`BlurayDiscMenuChrome` 只负责显隐（淡入淡出 + M3E 弹簧位移，隐藏时 `IgnorePointer` 点穿给原盘），内容由播放器同一套顶栏部件拼成（`VideoTopBarSlots` + MD3 下返回键并进标题浮动胶囊 / Apple 玻璃圆钮 + 标题，右侧 `VideoControlBar` 按钮组）；显隐源 `_discMenuChromeVisible` 由指针活动唤起、静置 `_videoControlsHoverDuration`（2 s，与控制条同源）淡出，指针悬停或焦点在顶栏上时顶住，进菜单时引导性亮一次。
- **[x] ② 已加自动化测试**（ce3747a4b4）— `fushi/test/media/video/bluray_disc_menu_bar_test.dart`（显示时按钮可点；隐藏后透明度归零且点击落到下层原盘画面；悬停 / 焦点回报给页面用于顶住）。
- **备注**：触屏 / 手柄 / 全屏下的实机验收未做（本轮无真盘真机会话）。

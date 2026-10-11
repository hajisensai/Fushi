## BUG-3230 · 原盘菜单鼠标点击展开后移开鼠标菜单收起
- **报告**：2026-10-10（用户：「在原盘里面使用鼠标点击bd里面的菜单鼠标移开后菜单会取消展开」）
- **真实性**：✅ 真 bug。`_buildDiscMenuSurface` 的 `MouseRegion.onHover`（`video_fushi/disc_menu.part.dart`，首版 fbeb260d78）把**每一次**指针移动都发成 `discnav mouse-move` → mpv `bd_mouse_select`。libbluray 的 `_mouse_move`（`src/libbluray/decoders/graphics_controller.c:1788`）把指针下的按钮**选中**，而盘上带 `auto_action_flag` 的按钮一被选中就执行它的导航命令（同文件 `_render_page` :1469 的 auto-activate）。点开子菜单后鼠标移开，必然掠过页签 / 父项等别的按钮 → 被选中 / 自动激活 → 页面切回，菜单收起。BD-J 同理（`BDJ_EVENT_MOUSE` → `MOUSE_MOVED` 改焦点）。原盘菜单按遥控器设计，悬停没有「只高亮不改状态」的语义。
- **[x] ① 已修复**（ce3747a4b4）— 指针移动不再发给原盘，只用来唤出顶栏；只有点击（`clickDiscMenu` = `mouse-click`，一步选中 + 激活）进原盘，与触屏同一语义。`videoDiscNavigationCommand` 白名单删掉 `mouse-move`，从契约上关死这条路。
- **[x] ② 已加自动化测试**（ce3747a4b4）— `fushi/test/media/video/video_disc_menu_test.dart`「pointer hover never reaches the disc」（`mouse-move` 必须被拒）。
- **备注**：代价是悬停不再预高亮原盘按钮。真盘真机复测未做。

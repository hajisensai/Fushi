## BUG-2111 · 右键菜单硬绑鼠标次按钮，把动作绑到右键会双触发
- **报告**：2026-09-04（用户：把快捷键绑到鼠标右键上，按一下在跑那个动作的同时还会唤出右键菜单）
- **真实性**：✅ 真 bug。根因不在某一个页面，而在「右键这个物理按钮没有唯一的归属仲裁者」：
  鼠标绑定通道走 `lib/src/shortcuts/mouse_binding_dispatch.dart:33`（页面根 / app 根的
  `Listener.onPointerDown` → 解析阶梯 → `dispatchClaimedMouseAction` 单槽认领），而上下文菜单
  走的是各表面**各自硬编码**的 `GestureDetector.onSecondaryTap*`（改造前 lib/ 下 23 处，例如
  `video_fushi/layout.part.dart:340`、`reader_fushi/webview.part.dart:2617`、
  `fushi_material_components.dart:111`）。两条路互不知情，也不共享那个单槽仲裁，所以同一次
  右键按下会被两边各消费一次。
- **[x] ① 已修复** — 把菜单本身纳入绑定表：新增 `ShortcutAction.globalContextMenu`
  （`global` scope，三平台默认 `MouseBinding(2)` = 右键，与改造前逐字一致），新增
  `lib/src/shortcuts/context_menu_trigger.dart` 作为菜单的唯一触发口（`ContextMenuTrigger`
  用 `Listener` 按绑定表判据触发，并复用 `dispatchClaimedMouseAction` 的单槽认领），把 23 处
  硬绑入口全部改接它；`wrapWithGlobalNavigation` 增挂 `ShortcutBindingScope` 把注册表递进子树。
  于是让位由**解析阶梯**决定：页面 scope 先命中别的动作 → 菜单自动让位，用户不必先解绑菜单。
  顺带补了 `kVideoMouseLadder` 缺失的 `global` 尾段（reader/manga/home 三条早就有），否则
  视频页解析不到住在 global 的新动作。
  设置页的撞键流程同时从「替换 / 取消」二选一改成三态（新增「两者都保留」），因为撞键并不
  蕴含其中一个必须让出——同一个键完全可以同时留在两个动作上，按下时由阶梯仲裁。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/context_menu_binding_test.dart`（15 条）：
  默认表三平台都绑右键且无页面动作默认占用右键；判据的四种形态（没改键 / 右键被页面动作占用
  时**只在那条阶梯上**让位、其它表面照常 / 菜单改绑中键 / 绑定清空）；`ContextMenuTrigger` 的
  widget 行为（右键触发并带坐标、左键零影响、onInvoke 为 null 时不挂 Listener、无
  `ShortcutBindingScope` 时回退硬绑右键）；以及「同一次按下只被认领一次」——内层菜单弹出后
  外层鼠标绑定不再派发，这条就是本 bug 症状的直接回归门。另加两条源码守卫（`lib/` 不得再出现
  `onSecondaryTapDown` / `onSecondaryTapUp`；三个共享卡片组件的 `onSecondaryTap` 参数只能经
  `ContextMenuTrigger` 落地），两条都做过变异实测（注入后确实转红）。
- **备注**：行为上唯一的可感差异是视频画面的菜单从「右键抬起」变成「右键按下」触发——
  改造前 app 内四个媒体表面里已有三个（阅读器 / 漫画 / 字幕）用的就是 `onSecondaryTapDown`，
  这一步把剩下那个不一致也抹平了。移动端默认表原先对 `global` scope 丢弃鼠标绑定，一并补回
  （Android 接鼠标时右键菜单否则会整个消失）。

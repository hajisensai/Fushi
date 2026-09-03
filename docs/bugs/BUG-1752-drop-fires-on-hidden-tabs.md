## BUG-1752 · 拖放同时命中隐藏 tab：视频页拖文件夹弹出「导入漫画」
- **报告**：2026-08-20（用户带截图：停在**视频页**，拖入视频文件夹 `[VCB-Studio] Yuru Yuri [Ma10p_1080p]`，结果弹出「导入漫画」对话框 + 橙色 toast「拖入的文件里没有新的游戏 .exe」，而视频页本身毫无反应。用户：「反正就没正确显示过」「这些具体地方以打开的页面为准」）
- **真实性**：✅ 真 bug。一次拖放**同时**触发了三个页面的处理器，根因链三层：
  1. `third_party/desktop_drop/lib/src/drop_target.dart` — `DropTarget` 把自己加进**进程级全局监听器列表**，每次 OS drop 事件所有监听者都被调用，唯一过滤是各自 `renderBox.paintBounds.contains(position)`。上游注释自陈：「把新页面推到 drop target 前面时你必须自己禁用它」。
  2. `fushi/lib/src/pages/implementations/home_page.dart` — 书/漫画/视频/游戏四个 tab 是 `Offstage` 保活的。Flutter 的 `RenderOffstage.performLayout` 在 offstage 时**仍以完整约束给子树布局**（`Stack(fit: StackFit.expand)` 给的是全屏紧约束），只关掉 Flutter 自己的 `hitTest`。desktop_drop 不走 Flutter hitTest → **每个访问过的 tab 的 drop target 都是全屏大小、全部命中**。
  3. `fushi/lib/src/media/drag_drop/fushi_file_drop_target.dart` — 唯一的门 `_routeVisible` 判的是 `ModalRoute.isCurrent`，而四个 tab **同在 HomePage 这一条路由上**，对它们同时为 true。业务层重复的同款检查（`home_video_page.dart` / `reader_history/books.part.dart`）同样无效。
  实际链路：书架表面注入了 `isDirectory` 判据 → 目录归 `mangas` → `importNewManga` → 弹「导入漫画」；游戏库不分类直接 `filterOutDuplicateGameExes` → 无 exe → toast；视频页当时**没传** `isDirectory` → 目录落 `unknown` → `ignore` → 静默（后者单独立项 BUG-1754）。
  「以前显示导入书籍、现在显示导入漫画」也解释了：`948190783a` 起目录就被判成漫画（那时仍复用 `BookImportDialog`，标题「导入书籍」），`9fd958bd0e` 漫画导入分家后落到 `MangaImportDialog`，标题才变「导入漫画」——从头到尾都是同一个错误路由。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/drag_drop/drop_surface_scope.dart`：`DropSurfaceScope` 声明「这棵子树属于哪个可见表面」，`activeFor(context)` 用 `visitAncestorElements` 逐层 AND（嵌套可组合）。`FushiFileDropTarget` 的判定加上 `DropSurfaceScope.activeFor(context)`。作用域由 `home_page.dart` 在**构建 tab 内容的那一处**统一提供，判据与 `Offstage` 用同一个 `_visibleTab`，保证「看得见的那个」与「接拖放的那个」永远同一个。
  刻意**不是**给 11 个注册点各加一个 `enabled` 参数：那样等于「要写守卫检查每个调用点有没有传对」，而调用点漏传就是 bug 本身。现在 11 个注册点一行未改，以后新增的入口天生带上。
- **[x] ② 已加自动化测试** — `fushi/test/media/drag_drop/drop_surface_routing_test.dart` 的 `DropSurfaceScope 决定谁接这次拖放` 三条：无作用域时放行（对话框/播放页各自独占路由，行为不变）；`Offstage(offstage: true)` 包住的子树被判不活跃、可见子树放行（直接钉住本 bug 的形状——Offstage 挡不住 desktop_drop，只有作用域能挡）；嵌套逐层 AND。
- **备注**：
  - 只挡「谁接」，不改任何一个表面接到之后**做什么**——分类/决策纯函数一行未动。
  - 未做（更彻底的架构，单独立项）：把 11 个 `DropTarget` 收敛成 app 根部**唯一**一个真 `DropTarget` + 一个 registry 裁决。当前作用域方案已让「多个表面同时响应」在结构上不可能，但每个 widget 仍各自向 desktop_drop 注册。
  - 未做：库页**内部**子视图（视频页的 首页/发现/系列/全部视频/导入/设置）没有全局真值可读（`_VideoLibraryShellState._section` 是私有字段），所以「在发现子页拖入」仍会被本地库表面接走。`DropSurfaceScope` 的嵌套语义已经为它留好口子，补一层即可。

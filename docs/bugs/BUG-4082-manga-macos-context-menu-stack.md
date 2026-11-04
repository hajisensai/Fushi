## BUG-4082 · macOS 漫画阅读器右键菜单不消失、重复叠加
- **报告**：2026-11-04（用户：应用内反馈 U_8sCB0h_f，macOS，截图同时叠着 6 个菜单；同族 BUG-967）
- **真实性**：✅ 真 bug（代码路径坐实；macOS 实机未复测）。`fushi/lib/src/media/manga/reader/manga_fushi_page.dart` 的 JS 桥 `onMangaContextMenu`（修复前 `:7845`）fire-and-forget 调 `_showReaderContextMenu`（修复前 `:6302`），后者每次都直接 `showFushiMenu` push 一个新菜单路由，既无单飞门控、也不先关旧菜单；漫画页整页是 WKWebView 平台视图，macOS 上点击交给原生视图、到不了菜单路由的 ModalBarrier，点页面别处关不掉，再右键 JS 又发一次 contextmenu，再叠一层。
- **[x] ① 已修复** — 新增 `fushi/lib/src/utils/components/fushi_single_menu_gate.dart`（`FushiSingleMenuGate`：一块表面至多一个菜单，开新菜单前先 `popUntil` 关掉同名菜单路由，首个 await 前登记在场，代数防旧菜单的 finally 清掉新状态；`dismiss()` 只弹本句柄的路由）。漫画页右键菜单经 gate 打开并带 gate 的 `RouteSettings`；gate 在场状态经 `window.__fushiMangaMenuOpen` 同步给页内 JS，`manga_overlay_html.dart` 在菜单在场时把 WebView 里的鼠标 pointerdown 经 `onMangaDismissMenu` 回报，Dart 侧 `dismiss()` 关菜单。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_single_menu_gate_test.dart`：连开两次只剩后一个菜单、旧 future 回 null；`dismiss()` 关掉菜单且不弹页面路由；node 跑生成文档里真实的 pointerdown 监听（无菜单 / 触摸不回报，菜单在场鼠标按下只回报一次）；源码守卫漫画页经 gate 打开、带 routeSettings、注册 onMangaDismissMenu。
- **备注**：macOS 实机未复测（本轮不做）。其它盖在 WebView 上的菜单（小说阅读器等）未统一接 gate。

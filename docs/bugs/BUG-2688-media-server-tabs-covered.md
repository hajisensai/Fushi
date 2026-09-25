## BUG-2688 · 媒体服务器点开后整页覆盖顶部分区导航
- **报告**：2026-09-26（用户：「媒体服务器不要点开后就占满整个页面，要保持顶部导航栏完整」）
- **真实性**：✅ 真 bug。分区页签只作为 `MediaServerListView` 的页头传进嵌套 Navigator 的**栈底**路由（`fushi/lib/src/pages/implementations/media_server/media_server_browse_page.dart` 原 `onGenerateRoute` → `MediaServerListView(navigation: ...)`，`media_server_server_list_view.dart` 原 `FushiPageHeader.customTitle(title: widget.navigation)`）；首页 / 网格 / 详情都是 push 到同一嵌套栈里的整页路由，一压上去就把页签盖掉。单台服务器时 `_maybeAutoEnter` 一进分区就自动 push 首页，所以用户点开「媒体服务器」的第一帧后顶部导航就没了，只能靠返回键退回列表才看得到。
- **[x] ① 已修复** — 页签挪到嵌套 Navigator 之外：`MediaServerBrowsePage` 自己画 `FushiPageHeader.customTitle(title: navigation)`，下面 `Expanded(Navigator)`；各层路由只在页签下方叠自己的紧凑页头，服务器列表层改为「选择服务器」紧凑页头 + 刷新（原列表内嵌标题去掉），`MediaServerListView` 不再接 `navigation`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_server/media_server_browse_page_test.dart`「分区页签在嵌套栈之上：进首页、钻进网格都不被路由盖住」（`hitTestable` 断言，路由盖住即红）。
- **备注**：同批修 BUG-2689（切分区指示条不滑动）。

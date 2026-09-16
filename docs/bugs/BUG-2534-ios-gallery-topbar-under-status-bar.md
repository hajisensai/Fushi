## BUG-2534 · iOS 插图册顶栏被状态栏 / 灵动岛压住，过滤 / 定位 / 关闭点不到
- **报告**：2026-09-14（用户：iOS 上「画廊这块顶部会顶到系统任务栏导致不能操作」）
- **真实性**：✅ 真 bug —— `fushi/lib/src/reader/reader_gallery_page.dart:build`
  返回的是**裸 `Scaffold`**，body 直接是 `Focus > Column > _buildHeader(...)`。
  裸 Scaffold 在没有 `AppBar` 时不会替 body 让开系统 inset，页面又是从阅读器
  `Navigator.push` 出去的全页路由（不经 `FushiPageScaffold` / `FushiToolScaffold`
  ——那两个脚手架自己套了 `SafeArea`，所以书架端插图库没这个毛病）。于是
  `[已解锁 | 全部]` 分段、定位、关闭三个控件整条画在状态栏 / 灵动岛底下：
  像素上被系统 UI 盖住，指针事件也先被系统条吃掉，表现就是「看得见、点不动」。
  页内全屏单图查看器是 `Positioned.fill` 的第二层整页 UI，外层就算加了 SafeArea
  也管不到它，它的「跳转 / 关闭」两个按钮同因同症。
  桌面 / Android 手势条设备上 `viewPadding.top` 为 0 或很小，所以只在 iOS 显形。
- **[x] ① 已修复** — `99d408459b`：主体 `Column` 外包 `SafeArea(bottom: false)`，
  页内查看器在自己的 `ColoredBox` 之内再包一层 `SafeArea`（背景仍铺满整屏，
  只有内容让开）；底部沿用页面通行口径，网格末尾补一条
  `bottomSafeInsetOf(context)` 高的 sliver 让开 home indicator。
- **[x] ② 已加自动化测试** — 两层：
  - `fushi/test/reader/reader_gallery_page_test.dart`「iOS 刘海 / 灵动岛：顶栏整条
    让开状态栏，按钮可点」——用 `FakeViewPadding(top: 59)` 造出刘海，断言关闭 /
    定位 / 过滤三个控件的 `top` 都不小于状态栏高度。确定性、进 CI。
  - `fushi/integration_test/reader_gallery_safe_area_itest.dart` ——真机层：走原始
    失败路径（真开书 → 按 G 唤出插图册），`viewPadding.top` 取设备真值，再在每个
    按钮中心做一次真实 hit test 证明「画出来了」同时「点得到」。iOS 上取不到非零
    状态栏高度即判失败（设备选错了，不算通过）。
- **备注**：同一 PR 还改了两处用户同时报的画廊问题（未解锁卡改回高斯模糊、卡片
  长按 / 右键补跳转与恢复遮罩），那两条是视觉回退与功能缺口，不单独立档。

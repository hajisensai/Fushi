## BUG-4511 · 首次同步确认后页面已卸载：No ProviderScope，首次同步不执行
- **报告**：2026-11-15（应用内反馈 nxR7tmcOjw，错误日志 `SrsDeckList.firstSync`：`No ProviderScope found`）
- **真实性**：✅ 真 bug。牌组列表首帧问「首次 v2 同步」，确认框经 `showAppDialog` 挂在根导航上，不随牌组列表卸载；
  用户切走首页 tab / 换页之后再点「开始」，确认已记下，但随后的那一轮同步不跑。
  - 根因：`fushi/lib/src/pages/implementations/srs/srs_deck_list_page.dart:214-216`（修前）`_confirmFirstSync` 在
    `await ensureSrsFirstSyncConfirmed(...)` 之后才 `ref.read(srsAppRuntimeProvider)`：页面已卸载时 `ref` 不可用、抛
    「No ProviderScope」，被 `srsRunLogged` 记下吞掉。确认之后的首次同步本该归 app 级的 `SrsAppRuntime`，却挂在了发起
    确认的页面的生命周期上。
  - 次要：页面在确认框弹出之前就卸载（`ensureSrsFirstSyncConfirmed` 的 `context.mounted` 检查返回 false）时，静态的
    「本次启动已问过」标记已经置位，本次启动再也不问。
- **[x] ① 已修复** — 运行时在第一个 await 之前、页面还挂着时解析好（app 级对象），确认后直接在它上面跑同步，不再经页面
  的 `ref`；确认框根本没弹出就卸载时撤回「已问过」标记，下次进复习页再问。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_deck_list_first_sync_test.dart`：真牌组列表 + 有笔记的内存库弹出确认框，
  确认框开着时把牌组列表从树上摘掉，Enter 确认（确认按钮自动持焦），断言确认已记下、运行时的「立即同步」恰好跑了一轮、
  没有异常。
- **备注**：

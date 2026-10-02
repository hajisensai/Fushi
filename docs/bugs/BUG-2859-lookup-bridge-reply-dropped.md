## BUG-2859 · 查词卡路由作废后丢弃晚到的 bridge 应答，该词条整个会话无法制卡
- **报告**：2026-10-02（agent 在 ceshi 样本 ATRI -My Dear Moments-（KiriKiri）游戏内查词真机验收中发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/lookup/overlay_window_channel.dart:122`（修复前的 `_invoke`）：路由（`routeIsValid()`）作废后，`_invoke` 一律丢弃调用。这本是为了防止作废路由排队的 Timer/Future 把旧卡面复活，但 `resolveBridge` 也走 `_invoke`，于是**页面还在 await 的应答**也被一起丢了。
  - 触发路径：popup.js 的 `scheduleEntryStateCheck`（`fushi/assets/popup/popup.js:314`）按词条 key 缓存在途的查重 promise（`entryStateCheckPromises`）。制卡按钮的 onclick（约 :4000）先 `await runEntryStateCheckNow`。
  - 后果：查重比关卡慢时（AnkiConnect 不在线，`duplicateCheck` 挂约 4 秒连接超时），应答在关卡之后才到，被丢弃 → 该 key 的 promise 永不 settle → 之后同一个词重新查出来，制卡按钮永远卡在 `mining=1/disabled`，`fushiPopupMineFirstEntry`（:4355）返回 false，`mineEntry` 根本发不出去。
  - 现场日志（隔离根 `hibiki_glookup.log`）：12:37:05 查「ヒト」，12:37:07 关卡；bridge id 4–7 均无应答；此后整个会话再没有 `duplicateCheck` 或 `mineEntry`。
  - 晚到应答是安全的：native 的 `ResolveBridge`（`flutter_window.cpp:3246` / `global_lookup_window.cpp:3519`）和 JS 宿主 `installBridgeRouter`（`global_lookup_host.js:3538`）都按发起 frame 投递，接受晚到应答；不会因此复活卡面。
- **[x] ① 已修复** — 本提交 `fix(lookup): deliver bridge replies after the card route is invalidated`：拆出不判路由的 `_send<T>`；`_invoke` = 路由作废则丢弃，否则 `_send`；`resolveBridge` 直接走 `_send`。前向调用（show/hide/render…）仍照旧丢弃。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/overlay_window_channel_test.dart`「BUG-2859：route 作废后前向调用照旧丢弃，但 bridge 应答必须送达」。变异实测：换回修复前的文件后该用例红（`Expected ['resolveBridge'] Actual []`），恢复后 10/10 通过。
- **备注**：真机复现修复后的完整路径（Anki 不在线时查词 → 快速关卡 → 接上 Anki → 制同一个词）尚未做，需要重编宿主；本条的证据是单测 + 上述日志的时序分析。

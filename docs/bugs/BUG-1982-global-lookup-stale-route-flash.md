## BUG-1982 · 全局查词旧尺寸消息冒充新查询导致首次闪跳
- **报告**：2026-08-31（用户：「全局查词弹窗会先出现一下，然后再闪到对应位置」）
- **真实性**：⚠️ 用户现象（弹窗先出现一下再闪到对应位置）尚未复现定性，**初版记录的根因经复核不成立**：`global_lookup_host.js:280` 的 `postToHost` 对每条消息都无条件 `stampRoute`（`:268`）写全 `__source/__routeEpoch/__lookupEpoch`，而 native `GlobalLookupWindow::RouteForMessage`（`global_lookup_window.cpp:951`）正是逐字段优先采用这三个内嵌值、只在缺字段时才回退 `route_context_`。也就是说 envelope 的 epoch **本来就等于**消息自带的 epoch，"envelope 盖成新 epoch"这条因果链不存在。真正的闪跳根因待定位（候选：Reveal 时序、shellRects/overlaySize 的 HRGN 应用顺序、DPI 换算），需要 Windows WebView2 真实像素复测。
- **[ ] ① 未修复（已做一处加固）** — `ad52944d70`：Dart 侧改成「三字段齐全才整体采用内嵌三元组，否则整体回退 envelope」。这堵住的是 native `RouteForMessage` 逐字段回退**理论上**能拼出 old/new 混合三元组的口子；对 `postToHost` 产出的正常消息是等价变换，**不改变现网行为，不构成对用户所报闪跳的修复**。真正修复需先定位根因。
- **[x] ② 已加自动化测试（覆盖的是上面那处加固，不是闪跳）** — `fushi/test/lookup/overlay_window_channel_test.dart` 构造“消息 epoch=2/3、native envelope epoch=9/10”的延迟 `overlaySize`，断言按内嵌的 2/3 派发。注意这个信封形状**生产路径产不出来**（见「真实性」），它钉的是"混字段不得发生"这条不变式。
- **备注**：未做 Windows WebView2 真实像素复测，闪跳是否消失无证据。定位根因前不得把本条记为已修复。

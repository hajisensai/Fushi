## BUG-1982 · 全局查词旧尺寸消息冒充新查询导致首次闪跳
- **报告**：2026-08-31（用户：「全局查词弹窗会先出现一下，然后再闪到对应位置」）
- **真实性**：✅ 真 bug。`global_lookup_host.js` 的 `postToHost` 已在事件生成时写入不可变 `__source/__routeEpoch/__lookupEpoch`，但 `fushi/lib/src/lookup/overlay_window_channel.dart:331` 解包时反而优先采用 native envelope。`FlutterWindow::BindRouteContext` 会在新 `showAt` 到来时立刻改写同一 HWND 的当前路由；旧页面此前排队的 `overlaySize` 随后被 envelope 盖成新 epoch，绕过 `_acceptsRoute` 后提前 Reveal 旧几何，新页面的正确尺寸再到时二次移动，形成可见闪跳。
- **[x] ① 已修复** — `ad52944d70`：反向 JS 消息优先采用事件发生时内嵌的完整路由三元组；只有三字段不完整的旧 host 才回退 mutable native envelope，且不允许两套时钟混字段。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/overlay_window_channel_test.dart` 构造“消息 epoch=2/3、native HWND 已改绑 epoch=9/10”的延迟 `overlaySize`，断言事件仍按 2/3 派发并会被当前路由门拒绝。
- **备注**：聚焦 Flutter 测试在执行任何 case 前被 `pdfium_dart` 原生资产下载超时阻塞；未做 Windows WebView2 真实像素复测。

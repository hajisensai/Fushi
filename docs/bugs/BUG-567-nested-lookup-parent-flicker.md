## BUG-567 · Windows app 外查词嵌套时父弹窗闪烁

- **报告**：2026-07-06（用户：TODO-1231）
- **真实性**：✅ 真 bug（双根因叠加，均沿真实代码路径定位）
  - 根因 A（内容闪烁 · 每次嵌套开/关都闪）：`hibiki/lib/src/lookup/global_lookup_render.dart:77`（旧）把 `window.__hasChildPopup = $hasChildPopup;` 烘进每帧 settingsJs body，body 以 `renderPopup()` 结尾。子弹窗开/关时父帧 `hasChildPopup` 翻转 → 父帧 settingsJs 串变化 → `hibiki/assets/popup/global_lookup_host.js` 的 `renderPayload`（旧 :712-716）对已加载帧无条件 `injectContent`（`win.eval(settingsJs)`）→ 整卡 DOM 清空重建（滚动丢失 + favorite/duplicate/音频探测全重发），仅为更新一个布尔。
  - 根因 B（几何跳动 · 竖排/屏幕边缘级联 dx/dy≠0 才闪）：`global_lookup_host.js` 的 `measureAndReport`（旧 :860-864）同步平移 `layer` 元素（`layerEl.style.left = -minLeft`），而对应窗口 `SetWindowPos` 要等一整个 bridge 往返（overlaySize → Dart `_applyOverlayBox` → revealStack channel → `windows/runner/global_lookup_window.cpp` `RevealStack`）才发生。WebView2 合成器与 DWM 各自 vsync，两笔互相抵消的位移落在不同帧 → 父卡先可见位移再拉回。

- **[x] ① 已修复** — commit `<pending>`
  - 根因 A（P1 结构性根治）：把 `__hasChildPopup` 从 settingsJs body 抽到独立 per-frame descriptor 通道。`global_lookup_render.dart` `buildStackRenderScript` 改为 `map['hasChildPopup'] = i < payloads.length - 1`（body 不再含该布尔，跨嵌套开/关字节不变）；`global_lookup_host.js` 新增 `applyHasChildPopup(record)`（仅 eval 一行 `window.__hasChildPopup=<bool>`，按上次值守卫），`renderPayload` 仅当 `record.injectedSettingsJs !== descriptor.settingsJs` 时才重跑 body（`injectContent` 记录已注入 body）。父卡滚动位置/收藏态天然保留；BUG-434 行为（点父卡关子窗）保留（popup.js 点击时实时读 flag）。
  - 根因 B（P2 缓解，非原子根治）：`measureAndReport` 不再同步平移 layer / 设 layerOffset；新增 `commitLayerShift(bboxLeft, bboxTop)` 由 C++ `RevealStack` 在 `SetWindowPos` 之后经 `ExecuteScript` 调用，令「窗口先移动、内容平移 ~1 帧后跟上」因果有序，替代旧的「层先移、窗口一个 Dart 往返后才移」的跨 vsync 竞态。channel `revealStack` 新增 `left/top`（CSS px bbox 原点）传给 native；`_applyOverlayBox` 去重条件加 dx/dy（原点变但尺寸不变时窗口仍需移动，否则 commitLayerShift 不触发）。残留 ~1 帧位移（DWM 窗口与 WebView2 表面无法同帧跨边界原子提交），仅 dx/dy≠0（左/上级联）时出现，down-right 级联恒为 0 无位移。真机验证是最终验收门（Windows-only 子系统，C++ 不经 flutter test 编译）。

- **[x] ② 已加自动化测试** —
  - node harness `hibiki/test/lookup/global_lookup_host_test.mjs` #36（已加载帧 body 不变则不重渲染，变了才重渲染）、#37（`__hasChildPopup` 走独立通道翻转、body 不含该布尔）；#11/#34/#35 更新为 `commitLayerShift` 契约（measureAndReport 不再同步平移，hit-test 用 commit 后的 layerOffset）。
  - 源码扫描守卫 `hibiki/test/lookup/global_lookup_inapp_isolation_guard_test.dart`：P1（has-child 独立通道 + renderPayload 变更门控）、P2（measureAndReport 不平移 layer + RevealStack SetWindowPos 后调 commitLayerShift + channel 传 bbox 原点）。
  - `hibiki/test/lookup/global_lookup_popup_style_guard_test.dart` 子4 更新为新架构断言。

- **备注**：P2 为 mitigation：真正原子根治需首次 reveal 预留潜在 bbox 窗口使嵌套期零 SetWindowPos，但会改变「窗口外空隙点击」的穿透语义（大透明窗拦截底层 app 点击）且多屏/任务栏 clamp 复杂，故取缓解。真机验收口径：竖排书 → app 外划词弹窗 → 卡内嵌套查词 → 反复开/关子窗，父卡不整卡重绘/不丢滚动位置（P1）；左/上级联时父卡位移显著减轻（P2，允许 ~1 帧残留）。

## BUG-1982 · 全局查词首帧落在工作区角上再闪回光标处
- **报告**：2026-08-31（用户：「全局查词弹窗会先出现一下，然后再闪到对应位置」）
- **真实性**：✅ 机制级根因已沿真实代码路径定位（证据见下），❌ 尚未做 Windows/WebView2 真机像素复测，故仍记未修复。**初版记录的根因（envelope epoch 冒充）经复核不成立**：`global_lookup_host.js` 的 `postToHost` 对每条消息无条件 `stampRoute` 写全 `__source/__routeEpoch/__lookupEpoch`，而 native `GlobalLookupWindow::RouteForMessage`（`fushi/windows/runner/global_lookup_window.cpp:951`）正是逐字段优先采用这三个内嵌值，envelope 的 epoch **本来就等于**消息自带的 epoch，那条因果链不存在。

### 真正的根因：首帧「窗口已上屏 + 内容层未补偿」
桌面查词的首帧窗口在**内容层平移尚未生效**时就带着 `SWP_SHOWWINDOW` 上屏，而此刻根卡画在窗口本地 (0,0)，窗口原点又被地板顶到工作区角上 —— 用户看到的「先出现一下」就是那一帧的卡片出现在**工作区左上角**，「再闪到对应位置」是一个 `ExecuteScript` 往返后 `commitLayerShift` 把内容层推到光标处。

1. **每次新查词都把内容层位移清零** — `fushi/assets/popup/global_lookup_host.js:2532` `beginLookup()`：`layerOffsetLeft/Top = 0`、`layer.style.left/top = '0px'`、`originFloorLeft/Top = 0`（:2546-2566）。
2. **根卡不等几何提交就 revealReady** — `global_lookup_host.js:1573-1578` `maybeFlipRevealReady()`：`geometryCommitted = !isNested || (...)`，根卡 `parentIndex = -1` → `isNested=false` → **无条件**置位。只有嵌套子卡才等 `committedGeometryEpoch`。
3. **首帧 bbox 原点被地板拉到工作区角** — Dart `global_lookup_layout.dart:318-346` `computeCascadeHeadroomSeed()` → `left: -_cascadeHeadroom(cursorWorkX, screenWorkW)`，而 `_cascadeHeadroom` 自 TODO-1231（BUG-670）起返回**光标到工作区该侧边的整段距离**（reserve-to-edge）。于是 `bbox.left = -cursorWorkX`、`bbox.top = -cursorWorkY`，**首帧就非 0**。
4. **窗口先上屏、内容层后补偿** — `global_lookup_window.cpp:1300` `int x = pending_x_ + dx;`（= `光标x+8 − cursorWorkX` ≈ `rcWork.left`），`:1321` `SetWindowPos(..., SWP_SHOWWINDOW)` 让窗口**此刻上屏**，`:1328` `ShowWindow(SW_SHOWNOACTIVATE)`；直到 `:1358` 才 `ExecuteScript(... commitLayerShift ...)`。该处注释自陈这是有意的因果序：「window first, content ~1 frame later」。
5. **被打破的不变式** — 同一段注释（`:1338-1341`）写的前提是「a ~1 frame residual remains … **and only for a left/up cascade (dx/dy != 0; down-right stays 0)**」。第 3 条的 reserve-to-edge 地板落地后，「down-right stays 0」**已不成立**：桌面 route 的首帧 `dx/dy` 必然等于光标到工作区左/上边的整段距离。「罕见的 1 帧残留」就是在这一步退化成「每次查词首帧一次全屏级位移」。

**加重因素（非主因，同一帧发生）**：`Hide()` 在上一轮结束时 `shell_rects_css_.clear()`（`:1698`）+ `SetWindowRgn(hwnd_, nullptr, FALSE)`（`:1710`），新一轮的 `shellRects` 只进 `pending_shell_rects_css_`（`:3282`），真正装 HRGN 的 `FinalizePendingShellGeometry` 挂在 `commitLayerShift` 的完成回调里（`:1367-1373`）。所以闪跳那一帧窗口**没有任何裁剪区域**：一个近整工作区大小的窗口整块上屏并吞点击。它让闪跳更显眼，但即使区域正确，第 4 条的错位仍会发生。

**仍属推断的一环**：没有真机像素证据证明「那一帧确实被 DWM present 出去」。按 DComp 语义与上述顺序推断应当会；闪跳幅度应为 `(cursorWorkX, cursorWorkY)` 物理 px，即「卡片先出现在工作区左上角，再跳到光标处」——可直接对着用户描述核。

### 排查过并排除的路径
| 候选 | 依据 | 结论 |
|---|---|---|
| envelope / 内嵌 epoch 混淆（初版记录） | `postToHost` 无条件 stampRoute；`RouteForMessage` 逐字段优先内嵌值 | 排除：两者恒等，因果链不存在 |
| Reveal 先用上一次几何显示 | `global_lookup_window.cpp:1091-1157` `ShowAt`、`:1159-1197` `PrewarmWebView`、`:1008` `OffscreenX()` | 排除：建窗/复用窗一律先停靠屏外（`visible_=false`），只有 `Reveal`/`RevealStack` 才带 `SWP_SHOWWINDOW` |
| shellRects / HRGN 应用顺序 | `:1698`、`:1710`、`:3097-3174`、`:1367-1373` | 成立但只是**加重因素**：区域缺失不改变卡片位置，只是不裁 |
| DPI 换算 | Dart `global_lookup_controller.dart:800-806`；native `flutter_window.cpp:2227`、`global_lookup_window.cpp:1355` | 排除：`GetDpiForWindow` 在 `SetWindowPos` 之后取目标显示器 DPI，正常路径 `clamp_dx_css=0`。DPI 错算会是**持续错位**，不是「闪一下再归位」 |
| showAt 与首个 overlaySize 之间的空窗 | `global_lookup_controller.dart:767-789`、`:835`；host `:2716`、`:2951` | 排除：这段时间窗口在 `OffscreenX()`，用户看不见 |
| WebView2 首帧未渲染（白/旧内容） | host `:1601` `markContentReady` → `scheduleMeasure` → `overlaySize` 才触发 reveal | 排除：reveal 由内容就绪驱动；正因为卡片**已经画好**才会在错位置被看见 |
| ready-safety 兜底 reveal | `global_lookup_controller.dart:874-915` → native `Reveal`（`:1199`） | 该路径用 `pending_x_` 且不调 `commitLayerShift`，几何自洽无闪跳 —— 反证问题只出在 `RevealStack` 的「地板原点 + 后补偿」组合上 |

- **[ ] ① 未修复（本 PR 只做了一处等价加固）** — `ad52944d70`：Dart 侧改成「三字段齐全才整体采用内嵌三元组，否则整体回退 envelope」。它堵的是 native `RouteForMessage` 逐字段回退**理论上**能拼出 old/new 混合三元组的口子；对 `postToHost` 产出的正常消息是等价变换，**不改变现网行为，不构成对闪跳的修复**。
  真正的根因修法（未实施，需真机验证后再落）：`RevealStack` 只对**首帧**（`!revealed_`）分叉 —— 先在 `OffscreenX()` 处按**最终 bbox 尺寸**定型（不带 `SWP_SHOWWINDOW`），照旧下发 `commitLayerShift`，把「真正上屏」（`SetWindowPos(..., SWP_SHOWWINDOW)` + `ShowWindow` + `revealed_/visible_` + `StartTopmostGuard` + 装 hook + `SyncShadow`）整体搬进 `ExecuteScript` 的完成回调、排在 `FinalizePendingShellGeometry` 之后；`revealed_ == true` 的后续 resize 保持现状（活卡片不能先变黑）。代价是首帧多约一帧显示延迟，收益是消掉全屏级错位闪跳并顺带消掉「整窗吞点击」的空窗。**未实施的原因**：这条路径本机编不了也测不了像素，把上屏搬进异步回调一旦回调不触发就是「查词窗永不出现」的整功能故障，风险与本 PR（另三条回归）不成比例。
- **[x] ② 已加自动化测试（覆盖的是上面那处加固，不是闪跳）** — `fushi/test/lookup/overlay_window_channel_test.dart` 构造「消息 epoch=2/3、native envelope epoch=9/10」的延迟 `overlaySize`，断言按内嵌的 2/3 派发。这个信封形状**生产路径产不出来**（见上），它钉的是「混字段不得发生」这条不变式。修根因时应另加：host harness（`global_lookup_host_test.mjs`）钉「首帧 `overlaySize` 之后必须先 `commitLayerShift` 再上屏」，以及 `global_lookup_window.cpp` `RevealStack` 的顺序源码守卫。
- **备注**：未做 Windows/WebView2 真实像素复测，闪跳是否消失无证据。上述根因修法落地前不得把本条记为已修复；复测按 `docs/agent/computer-use-testing.md` 连拍 reveal 前后 5 帧，验证「卡片从不出现在工作区左上角」。

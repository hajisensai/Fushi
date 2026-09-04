## BUG-2123 · app 外全局查词弹窗首帧先闪在屏幕左上角再飞到光标
- **报告**：2026-09-04（用户：「global lookup seems to have a bug this version where for a millisecond it appears in the top left of your display before moving to the cursor position」）
- **真实性**：✅ **真 bug（首帧窗口位置与图层补偿平移跨 DWM/WebView2 边界不同帧）**。三处代码合起来必然产出这一帧：
  1. `fushi/lib/src/lookup/global_lookup_layout.dart:346` `computeCascadeHeadroomSeed` / `_cascadeHeadroom` —— BUG-670 的 reserve-to-edge 地板把预留量从「一张卡」改成「光标到工作区该侧边的整段距离」，于是 **每一次** 查词（不只是有子卡的）的 union bbox 原点都被拉到 `(-cursorWorkX, -cursorWorkY)`，即工作区左上角。
  2. `fushi/assets/popup/global_lookup_host.js` `measureAndReport` —— TODO-1231 P2 明确**不在这里**平移图层，只上报 bbox；`beginLookup` 每次查词把 `layer.style.left/top` 归零。
  3. `fushi/windows/runner/global_lookup_window.cpp:1276` `GlobalLookupWindow::RevealStack` —— 先 `SetWindowPos(..., SWP_SHOWWINDOW)` 把窗口挪到 bbox 原点**并让它可见**，之后才用 `ExecuteScript` 发 `commitLayerShift(bbox.left, bbox.top, epoch)`（同文件 1310 行附近的注释自陈「window first, content ~1 frame later」）。

  屏幕位置 = `窗口原点 + 图层平移 + 壳本地坐标`。首帧那一刻窗口原点已经是工作区左上角、图层平移还是 0、根卡壳本地坐标是 0 → 根卡就画在**工作区左上角**；一帧（一次 ExecuteScript + 合成）之后平移生效才跳到光标。

  「窗口先动、内容后跟」这个次序**只**为保护**已经画在屏幕上**的父卡（嵌套子卡展开时的 BUG-583「几何跳动」）。首帧窗口还停在 `OffscreenX()` 之外、对用户不可见，被保护的对象根本不存在，代价却照收——reserve-to-edge 落地后这一帧从「只有向左/上级联才出现」变成**每次查词必现**，即用户说的「this version」。
- **[x] ① 已修复** — 根因修：把补偿平移的时机按「窗口此刻可不可见」分两态，而不是一刀切地永远后置。
  - `fushi/assets/popup/global_lookup_host.js`：新增**唯一写入口** `applyLayerOffset(l, t)`（DOM 平移与 `layerOffsetLeft/Top` 锁步——分开写过一次就是 BUG-859），`commitLayerShift` / `beginLookup` 都改走它；`measureAndReport` 在 `postToHost('overlaySize')` **之前**加一条门：`route.source !== 'galCard' && committedGeometryEpoch === 0` 时立刻 `applyLayerOffset(minLeft, minTop)`。
  - 为什么安全：`committedGeometryEpoch === 0` 精确等价于「本次查词还没提交过任何几何」＝窗口仍在屏外。窗口要等这条 `overlaySize` 走完一整趟 Dart 往返（`overlaySize` → `_applyOverlayBox` → `revealStack` → `SetWindowPos`）才第一次可见，内容早已合成到位，**首帧即正确**。随后 C++ 那次 `commitLayerShift` 带着同样的 `(minLeft, minTop)` 到达，DOM 写入是幂等 no-op，只剩「提交 bounds + 翻 reveal 门」的职责。
  - 未动的部分：窗口已可见后的每一次几何事务仍严格保持 TODO-1231 P2 的「窗口先动、内容后跟」（嵌套展开零位移不回退）；galCard 路由的窗口永远在屏外、靠截图贴进游戏画面，没有可闪的首帧，保持原样以免动到 `captureReady` 的两帧握手。
  - 提交：见本分支 `worktree-lookup-first-reveal-topleft-flash`。
- **[x] ② 已加自动化测试** —
  - `fushi/test/lookup/global_lookup_host_test.mjs` 新增用例 11c（BUG-2123），在**与 C++ 窗口同一套坐标算术**（`screen = windowOrigin + layerOffset + shellLocal`）上锁死两条不变式：(A) 带 `originFloor:{left:-300,top:-200}` 的首次事务，`overlaySize` 发出时图层已补偿到 `300px/200px`，根卡窗口本地位置＝光标偏移而**不是** (0,0)；(B) 窗口可见后再来一次事务（子卡把原点推到 -420/-260），`measureAndReport` **不得**动图层，只有 `commitLayerShift` 能动。用例 11 的图层断言同步改成新的两阶段语义。
  - **变异实测**：把修复那一条 `if` 改成 `if (false)` → 用例 11 红（`actual '0' !== expected '40px'`）；恢复后绿。
  - `fushi/test/lookup/global_lookup_inapp_isolation_guard_test.dart` 的两条源码守卫跟上实现：原来只查 `beginBody.contains('layerOffsetLeft = 0')` 这类字面量（重构后会变**假红**），也查 `measureBody.contains('layerEl.style.left') == false`（重构后会变**空壳恒真**）。改为断言 ①`applyLayerOffset` 是 `layerOffsetLeft` 的唯一写者（排除 `var` 声明后计数为 1）、②`measureAndReport` 里 `applyLayerOffset(` 只出现一次且必须被 `committedGeometryEpoch === 0` 那道门包住、③C++ `RevealStack` 里 `SetWindowPos` 仍排在 `commitLayerShift` 之前。
- **备注**：验证 `test/lookup` 744 条全绿 + `test/dictionary` / `test/pages` / `test/utils` 相邻 4 个守卫 18 条全绿 + 三个 node 宿主 `.mjs` 套件全绿（node 测试不在 CI 真单测门内，必须本地跑）。**真机肉眼复测待用户**：Windows 上按全局查词热键，弹窗应直接出现在光标处，屏幕左上角不再有一帧闪现。

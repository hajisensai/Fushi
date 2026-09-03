## BUG-1857 · 查词浮窗拖右下角调大小时卡片不跟手，松手才跳到位
- **报告**：2026-08-25（用户：gal 查词弹窗调整大小的时候不会跟随鼠标显示，有点异常；但确实调完是到鼠标那）
- **真实性**：✅ 真 bug。拖拽期间整条「可见像素」链路没有任何环节被驱动：
  - grip mousedown → host `postToHost('beginWindowResize')` → C++ `PostMessage(WM_NCLBUTTONDOWN, HTBOTTOMRIGHT)`
    进 native 模态 size 循环；循环里 `WM_SIZE` 只做 `put_Bounds`（composition 再 `Commit`），
    **不通知 Dart**；唯一回报点是 `WM_EXITSIZEMOVE` → `windowMoved [l,t,w,h,startW,startH]`。
  - root 卡宽高是 Dart 钉死的 `descriptor.frame` 固定 CSS px（`global_lookup_host.js` `applyShellStyle`），
    host 没有任何 `resize` / `ResizeObserver` 监听；iframe 100% 铺满 shell，shell 不动 → 里面
    popup.js 的两个 resize 监听全程不触发。
  - 于是窗口随光标长大、卡片一个像素不动、新增区域是全透明底；松手后 Dart `_onOverlayResized`
    用「结束−起始」增量折算 → `_renderStack` → 卡片一步跳到位。gal 直贴模式（BUG-1835，composition
    HWND 直接贴在游戏上）与桌面浮窗症状同源。
- **[x] ① 已修复** — host.js 本地「live-fit」，不改 native 循环、不改 Dart 折算：
  - grip mousedown 先 `beginLiveResize()`：记 root 卡当前 CSS 尺寸（优先 `shell.style`，其次
    `descriptor.frame`）与 viewport 尺寸；再 `postToHost('beginWindowResize')`。
  - `window.resize`（`WM_SIZE → put_Bounds → Chromium viewport 变化`）→ `handleWindowResize()`：
    root 尺寸 = 按下时尺寸 + viewport 增量（下限 80px），并置 `contentMeasureDirty`——松手后 Dart
    重排时 `shell.style.width` 已等于新宽度，`applyShellStyle` 那条「宽度变了才置脏」判不到，不置脏
    会拿旧宽度下量出的内容高度封顶新卡。子卡锚在父卡词上，不动；面板模式 root 本就 100%，不武装。
  - 与 Dart 松手折算同口径（`resolveOverlayResizeFromDelta`：当前 + 物理增量/dpr，CSS 增量 ==
    物理增量/dpr），所以权威重排只是把同一尺寸再写一遍（高度封顶到内容那一步除外）。拖拽期间
    不发 overlaySize → 没有第二个 `SetWindowPos` 和模态循环打架。
  - C++ `WM_EXITSIZEMOVE` 先 `ExecuteScript(__globalLookupHost.endLiveResize())` 再回报 `windowMoved`；
    `renderStack` 开头也解除（Dart 接管 + 清「grip 按下但循环没起来」的悬空武装）。
  - gal **位图回退**模式（direct composition 不可用、离屏 CapturePreview 逐帧 blit）下 blit 尺寸
    仍由 `captureReady` 后的 `_onOverlayRevealed` 决定，拖拽期间看不到跟随——该模式已是回退路径，
    本轮不动。
- **[x] ② 已加自动化测试**：
  - `fushi/test/lookup/global_lookup_host_test.mjs` BUG-1857 段（node harness 行为级）：武装 / 未武装
    no-op / 增量相对按下时 viewport / 下限 / 子卡不动 / 置脏 / endLiveResize 后停跟 / renderStack 接管
    并解除 / 面板模式与无 viewport 不武装。
  - `fushi/test/lookup/global_lookup_live_resize_guard_test.dart`（JS↔C++ 接线）：grip 先武装再进循环、
    resize 监听挂上、`WM_EXITSIZEMOVE` 先解除后回报、`renderStack` 自解除。
- **备注**：⚠️ **真机未复验**（本轮真机验证已取消）。复验点：① 桌面浮窗拖 grip，卡片随光标同帧长大 /
  缩小，松手不跳；② gal 直贴模式同上；③ 有嵌套子卡时拖 root grip 子卡不乱跑，松手后级联重排正常；
  ④ 面板模式不受影响。另观察到但**未改**：composition 实例在 `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` /
  `SetShellRectsFromCsv` 三处被无条件 `ApplyRoundedRegion`，与 `WM_SIZE` 自己写的「composition 不设
  region」不变量矛盾——但 direct 模式当前的点击路由正依赖 shellRects region，无真机证据不动。
  （2026-08-25 审查复核：`git diff` 确认这三处 `ApplyRoundedRegion` 在 merge-base 上就已是
  无条件调用，本 PR 对 `global_lookup_window.cpp` 的全部改动只有 +9 行 `endLiveResize`，
  既未引入也未加剧该矛盾。）
- **已知缺口（审查发现，本轮未修）**：
  - **gal direct（贴游戏）模式下 live-fit 只跟「变大」不跟「变小」。**
    `global_lookup_window.cpp` 的 `WM_SIZE` 在 `direct_process_client_active_ && visible_ &&
    revealed_` 时对 WebView Bounds 取**高水位**（`rc.right = max(rc.right, current.right)`），
    随后 `EqualRect` 相等就不调 `put_Bounds`。于是拖 grip 缩小时 Chromium viewport 不变 →
    `window.innerWidth` 不变 → `handleWindowResize()` 什么也不做 → **缩小方向仍然是「松手才
    跳」**。用户报的正是 gal 查词弹窗，所以这条症状只修好了一半。可行修法：`resizing_` 期间
    豁免高水位分支。⚠️ 代码推断，未真机复验。
  - **live-fit 的夹取区间与 Dart 权威折算不同源。** host 只有 `LIVE_RESIZE_MIN_PX = 80`
    下限、**无上限**；Dart `resolveOverlayResizeFromDelta` 夹到 `[250,2000]×[200,1600]`；
    窗口侧又没有 `WM_GETMINMAXINFO`，可以被拖到任意小。拖到极端时卡片先跟到 80px、松手
    再跳回 250px —— 正是本条要消灭的那个跳，只是退到了边界上。可行修法：把 min/max 随
    descriptor 下发给 host。

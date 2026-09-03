## BUG-1609 · app 外全局查词卡片右上/右下圆角变方角

- **报告**：2026-08-14（用户：截图 —— QQ 上查「现在」，浮窗左上/左下圆角正常，右上/右下是方角）
- **真实性**：✅ 真 bug。最终根因是可滚动 iframe 的 `body` 同时承担内容与可见卡片 chrome；占位式滚动条把它的右边缘内缩，而长内容时 body 底部圆角又落在视口之外。原生 HRGN 圆在更外侧，裁不到这个仍位于 region 内部的方形可见边缘。

### 现象与取证

用户截图逐像素量（浮窗 233..992 × 189..828，DPI 150%）：

- 左边界在上下两端各内缩约 14px（左上/左下圆角完好），圆角外是**真透明**（透出下层 QQ 窗口的蓝色/深灰）。
- 右边界 **y=189..828 共 640 行恒为 x=992，一个像素都不内缩**。卡片自己的 1px 圆角边框其实**画出来了**（右上角弧线从 (978,189) 弯到 (991,210)），但弧线**外侧**被不透明主题色 `#fff8f4` 填满 → 视觉上就是方角。

排除 native：运行中的 `FushiGlobalLookupWindow`（1180×321 @144dpi）用 `GetRegionData` 导出 `SetWindowRgn` 扫描线，region **左右完全对称**（顶行 `x=6..1174`，即两侧各内缩 6px），四角都圆。`ApplyRoundedRegion`（`fushi/windows/runner/global_lookup_window.cpp:2068`）不是根因。

同引擎离屏复现（Edge headless，与 WebView2 同 Chromium，`--force-device-scale-factor=1.5`，`--default-background-color=00000000` 看 alpha），复刻 host → shell → iframe 三层：

| 场景 | 结果 |
|---|---|
| 占位式滚动条 | **完全复现**：右上/右下 alpha=255 不透明方角，左侧圆角正常，右侧 13px 是滚动条 gutter |
| overlay 滚动条 | 四角 alpha=0，完全对称正常 |
| 占位滚动条 + 本次修复 | 四角 alpha=0，正常 |

### 第一轮根因与不完整修复

`html.global-lookup { background: transparent }` 让 documentElement 成为「无背景」，CSS 背景传播规则（css-backgrounds-3 §2.11.2）随即把 `body` 的背景**提升为画布背景**：画布背景铺满整个视口、**永远方角**，而 `body` 自身不再绘制该背景 —— 它的 `border-radius: 10px` 从此只管得到那 1px 边框线，管不到填充色。

于是卡片的圆角外观**完全寄生**在外层 shell（`global_lookup_host.js` 的 `.global-lookup-frame-shell`，`overflow:hidden + border-radius:10px`）的裁剪上，成立条件是「卡片内容区右缘与 shell 右缘恰好重合」。文档一旦出现占位式垂直滚动条（`popup.css` 的 `html { scrollbar-width: thin }` 使 WebView2 用非 overlay 滚动条），gutter 把内容区右缘从 shell 右缘推开约 9 CSS px，右侧那两刀就裁在空处 → 右上/右下露出方角画布底色。左缘永远重合，所以左边两个角一直是好的 —— 症状严格左右不对称，正是这个原因。

第一轮把 `html.global-lookup` 改成“存在但完全透明”的渐变背景，确实阻止了 CSS body-background propagation，也消除了方形 document canvas；但它仍让**可滚动 body 自己**负责背景、边框和圆角。短内容/overlay scrollbar 对照能变绿，不等于长内容 + classic scrollbar 的真实 viewport 已经稳定：body 的右边缘仍停在 gutter 左侧，body 的底部圆角仍可能位于当前滚动视口之外。

### 第一轮修复记录

- **[x] ① 已保留** — `fushi/assets/popup/popup.css`：`html.global-lookup` 声明一个**存在但完全透明**的背景层（`linear-gradient(rgba(0,0,0,0), rgba(0,0,0,0))`），阻止 body 背景传播成方形 document canvas。它是必要的 canvas guard，但不是最终 viewport 圆角修复。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/global_lookup_card_radius_guard_test.dart`（三镜像 × 3 用例 = 9 条）：锁 ①`html.global-lookup` 必须声明真实背景层（不得退回裸 `transparent`/`none`），②该层所有 rgba 停靠点 alpha 必须为 0（防白框回归），③`html.global-lookup body` 仍有 border-radius + border。断言前先剥 CSS 注释，避免注释里的字面量造成假阳/假阴。变异实测：改回 `background: transparent` → 红（用例①）；改成不透明渐变 → 红（用例②）；反向替换还原后复绿。

### 2026-08-23 桌面浮窗再现与最终根修

最新截图对应普通 `FushiGlobalLookupWindow` 的 `desktop` route，不是 `galCard`。逐像素与 live region 对照给出关键证据：

- @192 DPI，截图中可见 body 外宽约 1233 物理 px；同一次“同様”查词的 native region bbox 宽约 1253 px，正好多 20 物理 px，即 10 CSS px classic scrollbar gutter。
- body 的右边框停在 region 右缘内侧约 20px；原生圆角发生在更外侧的透明 gutter 上，所以 HRGN 即使左右对称，也不会切掉 body 的方形右边缘。
- 长内容时，body 底部在当前 iframe viewport 下面；截图最后一条可见横线是 viewport 截断，不是 body 自己的底部圆角。

最终修复位于 `global_lookup_host.js`，不改变查词组件、滚动容器或量测契约：

- `settingsJs` 注入主题后读取 body 的 computed background / border / radius；固定、与 viewport 同尺寸的 `.global-lookup-frame-shell` 接管背景和圆角。
- 可见边框由 shell 的绝对定位 `::after` 绘制，不参与布局；body 只把 background 和 border-color 变透明，保留原 border 宽度、padding、min-height 与滚动语义，因此正文宽高及 `measureContentHeight()` 不发生 2px 漂移。
- border/radius 按 iframe `documentElement.zoom` 换算到 host CSS px；light/dark/e-ink、MD3 动态色和卡片透明度仍只以 popup.css/settings 为真值源。
- 复用 frame 若样式读取失败，会清除旧 shell chrome 并恢复 body 自绘，不能把上一次主题叠在当前卡上。

这样滚动条 gutter 显示的是 shell 的连续背景，四角也由固定 viewport shell 统一裁剪；滚动正文不再承担窗口外轮廓。

### 备注

滚动条 gutter 仍存在，这是 WebView2 classic scrollbar 的布局结果；但它现在位于固定 shell 的连续背景上，不再决定卡片外轮廓。对游戏内 `CapturePreview` 位图，仍保留下述最终像素 alpha mask 作为独立的输出边界兜底。

验证状态：按用户要求未跑单测/analyze；Windows Debug 真构建成功，构建内 host asset 与源码 SHA-256 一致并已从工作区产物启动。尚缺一次新进程里的同类长词条视觉回看。

### 2026-08-23 游戏内附着捕获的独立像素兜底

用户明确使用“附着并捕获”，在游戏画面里的查词卡再次截到右下角方形。它和桌面全局查词共用 `global_lookup_host.js + popup.html` 组件，但输出路径不同：`EnsureGalLookupCardWindow()` 创建第三个离屏 `GlobalLookupWindow`（route=`galCard`、composition controller），`CaptureBgraAsync()` 用 WebView2 `CapturePreview` 抓 PNG、WIC 解为直通 alpha BGRA，再经共享内存注入游戏。

运行中的桌面 `FushiGlobalLookupWindow` 用 `GetRegionData` 检查时，四角 HRGN 已经左右对称；这不能约束 galCard：`SetWindowRgn` 是 HWND 绘制/命中区域，而 `CapturePreview` 的 PNG 契约并不包含该 HRGN。iframe 提升为独立合成面或右侧滚动条 gutter 时，PNG 仍可带出 region 外本应透明的方形画布像素。此前 `html` 透明渐变及 host document-start inline guard 都保留，它们减少 CSS 背景传播，但不足以成为游戏最终位图的硬保证。

最终修复位于 `global_lookup_window.cpp` 的像素发布边界：

- host 继续把每个卡片的 window-relative CSS rect 通过 `shellRects` 上报；C++ 按当前 HWND DPI 折算到 CapturePreview 物理像素。
- `CaptureBgraAsync()` 发起异步捕获时按值快照 rects + DPR；WIC 解码成功后、回调写共享内存前，对每个 shell 计算 10 CSS px 圆角 coverage，并以 `max` 合成并集。并集外 BGRA 全清零，抗锯齿带只乘 alpha、不乘 RGB，保持 v14 的直通 alpha 契约。
- 只对 route=`galCard` 应用像素 mask；桌面窗口仍走既有 HRGN，不把“游戏截图兜底”变成另一套查词 UI。
- `shellRects` 消息增加 route/routeEpoch/lookupEpoch 一致性门控，迟到的旧 lookup 几何不能裁当前帧。

这样最外层圆角不再依赖 Chromium 是否执行父 shell clip、iframe 是否是 promoted surface、滚动条是否占 gutter 或 WebView2 profile 是否复用了旧样式；所有进入游戏的查词位图都在最后一跳满足同一个 per-shell 圆角轮廓。

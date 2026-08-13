## BUG-1609 · app 外全局查词卡片右上/右下圆角变方角

- **报告**：2026-08-14（用户：截图 —— QQ 上查「现在」，浮窗左上/左下圆角正常，右上/右下是方角）
- **真实性**：✅ 真 bug，根因 `fushi/assets/popup/popup.css:83`（原 `html.global-lookup { background: transparent }`）

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

### 根因

`html.global-lookup { background: transparent }` 让 documentElement 成为「无背景」，CSS 背景传播规则（css-backgrounds-3 §2.11.2）随即把 `body` 的背景**提升为画布背景**：画布背景铺满整个视口、**永远方角**，而 `body` 自身不再绘制该背景 —— 它的 `border-radius: 10px` 从此只管得到那 1px 边框线，管不到填充色。

于是卡片的圆角外观**完全寄生**在外层 shell（`global_lookup_host.js` 的 `.global-lookup-frame-shell`，`overflow:hidden + border-radius:10px`）的裁剪上，成立条件是「卡片内容区右缘与 shell 右缘恰好重合」。文档一旦出现占位式垂直滚动条（`popup.css` 的 `html { scrollbar-width: thin }` 使 WebView2 用非 overlay 滚动条），gutter 把内容区右缘从 shell 右缘推开约 9 CSS px，右侧那两刀就裁在空处 → 右上/右下露出方角画布底色。左缘永远重合，所以左边两个角一直是好的 —— 症状严格左右不对称，正是这个原因。

### 修复

- **[x] ① 已修复** — `fushi/assets/popup/popup.css`：`html.global-lookup` 改为声明一个**存在但完全透明**的背景层（`linear-gradient(rgba(0,0,0,0), rgba(0,0,0,0))`）。documentElement 不再是「无背景」，传播不发生，body 的填充留在 body 自己身上、被它自己的 `border-radius` 裁剪 —— 卡片四角**自足**地圆，不再依赖「外层裁剪 + 边缘恰好重合」这个脆弱前提。视觉仍全透明，TODO-893 症状 2（不透明主题色填满方形 iframe、被 shell 裁成一圈「白框」）不会回归。三镜像（`assets/popup` / `assets/browser_extension/vendor` / `tools/browser-extension/vendor`）同步，`content.css` 经生成器重跑（该规则是文档级、被重根时剥离，两份 content.css 内容不变）。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/global_lookup_card_radius_guard_test.dart`（三镜像 × 3 用例 = 9 条）：锁 ①`html.global-lookup` 必须声明真实背景层（不得退回裸 `transparent`/`none`），②该层所有 rgba 停靠点 alpha 必须为 0（防白框回归），③`html.global-lookup body` 仍有 border-radius + border。断言前先剥 CSS 注释，避免注释里的字面量造成假阳/假阴。变异实测：改回 `background: transparent` → 红（用例①）；改成不透明渐变 → 红（用例②）；反向替换还原后复绿。

### 备注

修复后滚动条 gutter 依然存在（卡片右边距比左边多约 9 CSS px，thumb 落在卡片外的透明带里）。这是 `scrollbar-width: thin` 关掉 WebView2 Fluent overlay 滚动条的既有后果，属独立的观感问题，不影响本条的圆角正确性；若要卡片满宽，需另议 global-lookup 作用域的滚动条策略（改动面涉及主题化滚动条与滚动容器归属，本条不扩大范围）。

真机复验缺口：结论由「运行中窗口的 region dump + 用户截图逐像素 + 同引擎离屏三组对照」共同支撑，修复本身未在真机 Windows 构建上回看过。

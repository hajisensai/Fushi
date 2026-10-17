## BUG-3482 · iOS 滚动模式交叉轴能被拖动（竖排上下 / 横排左右）
- **报告**：2026-10-17（所有者真机录屏，iOS，小说阅读器滚动（continuous）模式，竖排日文，带有声书句高亮：手指上下拖动时整页内容跟着上下位移。要求「交叉轴要顶住，完全不能动」）
- **真实性**：✅ 真 bug。录屏 4.5 s 逐帧量化（588×1280，30 fps，与首帧做行剖面互相关）：正文在两个位置之间跳——0 与 13 px（≈9 pt），每次手指上下一甩就整页换到另一端，且停住不弹回（BUG-2615 已关了回弹，所以表现为「被拖开后停在那」）。
  根因：滚动模式的锁轴只有 `html { overflow-<交叉轴>: hidden }`（`fushi/lib/src/reader/reader_content_styles.dart:1491`，`_continuousLayoutCss`）。它只锁滚动条，锁不住 iOS 的手指：WKWebView 的 UIScrollView 内容尺寸取文档的**可滚动溢出**，正文里只要有 body 的后代沿交叉轴越出视口（有声书句高亮窄条 `fushi-hl-lanes`、注音、书自带的块等），WebKit 就允许手指沿交叉轴把整页拖开那段溢出，程序化的 `scrollBy` / `scrollIntoView` 也能把它推开（录屏起始帧就停在偏移 9 pt 处）。
  真 WebKit 实测（Mac，iPhone 17 Pro 模拟器 iOS 26.5，纯 WKWebView 配置对齐 flutter_inappwebview：bounces=false、contentInsetAdjustmentBehavior=never；页面用阅读器实际生成的连续模式 CSS + 一个沿交叉轴越界 16 px 的绝对定位块；XCUITest 真触摸上 / 下 / 左 / 右 / 斜各拖一次，读 UIScrollView 的 contentOffset / contentSize）：
  - 修复前：竖排 contentSize 402×**890**（视口 874），上下拖 contentOffset.y 在 0..16 间变化；横排 contentSize **418**×12877（视口宽 402），左右拖 contentOffset.x 在 0..16 间变化。没有越界块时两者都锁得住。
  - `position: fixed` 的越界元素（选区手柄那类）不计入内容尺寸，不是来源。
  - 只加 body 交叉轴 `clip` → 内容尺寸回到视口、交叉轴恒 0；只加 `touch-action` 主轴 → 内容尺寸仍 890 但手指拖不动交叉轴。
- **[x] ① 已修复** — `_continuousLayoutCss` 新增 `crossAxisLockRule`：`html, body { touch-action: pan-x | pan-y }`（只放行主轴平移）+ `body { overflow-<交叉轴>: clip }`（后代越界不再计入可滚动溢出，交叉轴可滚范围归零，程序化滚动也无处可去）。用 `clip` 不用 `hidden`：hidden 会让 body 另一轴变 auto、body 自成滚动容器（TODO-718 的坑）；clip 不建滚动容器，主轴仍由 html 滚。翻页 / VN 本来就是 html、body 两轴 hidden（body 自己裁掉后代），实测不受影响、也不改动。
- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/reader_continuous_cross_axis_lock_test.dart`：生成器层，钉住滚动模式两种书写方向的锁轴规则、body 不得用 hidden、翻页 / VN 不带此规则。
  - `fushi/integration_test/reader_cross_axis_lock_itest.dart`：真 app 6 种组合（竖 / 横 × 翻页 / 滚动 / VN），往 body 塞沿交叉轴越界 16 px 的块，断言根滚动器交叉轴无可滚范围、`scrollBy` 推不动交叉轴、滚动模式主轴照常滚。修复前 iOS 模拟器上滚动模式两条都红（竖排 890 > 874、横排 418 > 402），修复后全绿。
  - `fushi/integration_test/support/ios_webkit_pan_probe/`：真触摸那一层的实测装置（纯 WKWebView + XCUITest 拖动 + contentOffset 日志），实验页由上面的 itest 带 `--dart-define=FUSHI_XAXIS_DUMP=true` 从真 app 导出。Flutter 平台视图在模拟器上收不到 XCUITest 合成的触摸（框架侧手势竞技场已判给 WebView，WKWebView 一次 touchstart 都没收到），所以手指那层只能在纯 WKWebView 里测。
- **备注**：Android 一侧 BUG-2578 已关掉过滚，Chromium 本就尊重根元素的 hidden，不受此 bug 影响；新规则在 Chromium 上只是把交叉轴本来就不会发生的原生平移显式声明掉，长按 / 点击 / JS 触摸事件不变。所有者真机（带有声书）上的那段溢出具体来自哪个元素没有逐一定位——修法不依赖来源：凡 body 后代都被 clip 收住，手指层再由 touch-action 兜底。

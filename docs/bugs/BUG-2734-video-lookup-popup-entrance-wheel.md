## BUG-2734 · 视频查词框弹出动画跳变、滚轮手感与 galgame 查词框不一致
- **报告**：2026-09-27（用户：「查词弹出动画看着好难受，galgame 查词框和动画查词框的鼠标滚轮键滑动效果不一样，galgame 的好多了」，附 Windows 录屏）
- **真实性**：✅ 真 bug。录屏逐帧（24 fps）可见三种跳变，两个查词框跑同一份 `popup.js`，差异全在宿主层：
  1. **换词 / 分页追加词条时内容先放大一帧**：mixin 家族（视频 / 首页 / texthooker）的自适应高度（BUG-1651）把外壳收到内容高度，WebView 跟着改尺寸。Windows 上 WebView2 表面改尺寸要重建 WGC 帧池，新尺寸的帧晚于 Flutter 布局到达，那几帧旧的矮帧被 `Texture` 拉伸到新矩形里（录屏里「その代わり」一帧放大约 2 倍）。galgame 覆盖窗在 DOM 内改卡片高度，没有这一层。根因 `fushi/lib/src/pages/implementations/dictionary_page_mixin.dart` `buildNestedPopupLayer` 的 `onContentMetrics` → `entry.autoFitHeight` → `_calcMixinPopupPosition` 直接改 `Positioned` 高度。
  2. **弹出时先闪一个半透明空框**：顶层查词先画 Flutter 加载占位卡（`buildPopupLoadingPlaceholder`，无淡入），结果渲染完真弹窗接替时 `_PopupEntranceFade` 又从透明度 0 淡入（`dictionary_popup_layer.dart` `parkedPopupLayer`）——占位卡同帧撤掉、真弹窗还半透明，中间露出一段透底空框。galgame 覆盖窗只有「内容就绪 + 几何就绪」双闸门后的一次淡入。
  3. **滚轮一格一大跳、比 galgame 快得多**：fork `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp` `InAppWebView::sendScroll` 写死 `delta * 6 * dpr`，前提「Flutter 一档 delta≈20 逻辑像素」。现行引擎（3.44 `flutter_window.cc` `UpdateScrollOffsetMultiplier` + `WM_MOUSEWHEEL`）一档发 `行数×100/3` 物理像素（默认 100），框架再除以 dpr；于是一档到 WebView2 = 600 = 5 个 WHEEL_DELTA，而 galgame 覆盖窗（`global_lookup_window.cpp`）原样转发系统 120。`popup.js` 收到 5 倍 deltaY，被单步上限 `POPUP_WHEEL_MAX_VISUAL_STEP` 截成一格 120px 的硬跳。阅读器 / 漫画等其它 app 内 WebView 同受影响（一档 5 倍）。
- **[x] ① 已修复** —
  - ① WebView 按「外壳取用户最大高度」时的正文高度布局、顶端对齐、超出裁剪（`DictionaryPopupLayer.webViewOverflowHeight` / `popupWebViewOverflow`）；自适应高度只改裁剪框，原生表面尺寸不随内容变，JS 上报的视口对应 `fullPopupHeight`。
  - ② 控制器记录 `DictionaryPopupEntry.revealedOverSearchPlaceholder`（`revealRendered` / 兜底强制翻 / `show` 三条翻可见路径统一判定）；接替占位卡时 `parkedPopupLayer(fadeIn: false)` 直接满不透明，占位卡自身改为入场淡入（`popupEntranceFade`）。
  - ③ `sendScroll` 按引擎同一公式（`SPI_GETWHEELSCROLLLINES`、`行数*100.0/3.0`、int 截断）逆算回原生 WHEEL_DELTA；整页滚动 / 0 行回落默认倍率。
- **[x] ② 已加自动化测试** — `fushi/test/pages/dictionary_popup_entrance_and_overflow_test.dart`（占位卡标记四态、`fadeIn` 首帧不透明度、占位卡淡入、WebView 溢出布局与裁剪）；`fushi/test/build/popup_wheel_native_residual_guard_test.dart` 新增「按引擎倍率逆算」源码守卫组；`fushi/integration_test/webview_wheel_units_itest.dart`（Windows 真 WebView2：一档滚轮进 DOM 的 deltaY 与原生 WHEEL_DELTA 同量）。
- **备注**：触控板 pan-zoom 走同一入口，修正后为 1:1（此前同样 5 倍）；习惯了旧速度并调过「滚轮速度」偏好的用户会感到变慢，这是回到与原生窗口一致的尺度。

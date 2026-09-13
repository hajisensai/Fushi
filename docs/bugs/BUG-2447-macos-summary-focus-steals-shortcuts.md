## BUG-2447 · macOS 查词弹窗展开/折叠词典分组后全局快捷键失灵
- **报告**：2026-09-11（用户：查词后在查词弹框点击展开/关闭词条，之后快捷键就失灵）
- **真实性**：✅ 真 bug（沿真实代码路径定位；症状本身由用户在 macOS 真机观察到，本仓无 macOS 机器，未做真机复测——见「验证边界」）

  **根因链（每一环都有代码/引擎源码支撑）**

  1. `fushi/assets/popup/popup.js:4215` 词典分组的 `<summary class="dict-label">` 上只挂了长按选词典的监听，**不取消 mousedown 的默认动作**，于是鼠标点它 → 节点获得 DOM 焦点。
     `<summary>` 是弹窗里**唯一**「鼠标点一下就会获焦」的元素：按钮与链接在 macOS WebKit 下按平台惯例 `isMouseFocusable` 恒为 false，释义正文与留白根本不可聚焦。这正是「为什么偏偏是展开/折叠、点别处没事」。
  2. 节点一获焦，WebKit 就把承载它的 `WKWebView` 交成窗口 first responder，此后 `keyDown:` 全部进 WebKit，`FlutterViewController` 再也收不到按键。
  3. macOS 上**没有任何东西能把 first responder 还回来**：
     - Flutter 引擎平台视图层零 first-responder 代码——`engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterMutatorView.mm`（683 行）与 `FlutterPlatformViewController.mm` 里 `grep firstResponder` 零命中（本机 Flutter 3.44.0 SDK 自带 engine 源码）；
     - `fushi/lib/src/focus/page_focus_ownership.dart:89-103` `reclaim()` 只调 `node.requestFocus()`，**零 method channel / 零原生调用**，动的是 Flutter 自己的焦点树；
     - 全仓 `makeFirstResponder` / `becomeFirstResponder` / `resignFirstResponder` **0 命中**，`fushi/macos/Runner/` 下无任何键盘或 responder 代码；
     - Windows 那条兜底不是通道而是 fork：`packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart:515-524` 每次 `onPointerDown` 都 `_focusNode.requestFocus()` 并在 50ms 后补一次。它成立的前提是 WebView2 的**无窗口合成**（指针先到 Flutter），macOS 用的是上游 `flutter_inappwebview_macos` 的**真原生 `WKWebView` 子视图**（BUG-1692 已确认是真 `NSView` 层级），这条前提不存在。
  4. 于是弹窗持焦期间只剩弹窗内的 JS 桥一条路，而它**按构造**只转发宿主显式声明的动作：`dictionaryPopupInputSpecFor`（`fushi/lib/src/pages/implementations/dictionary_popup_input_bridge.dart:73-106`）从宿主的 `dictionaryPopupForwardedActions` 导出键表，阅读器只声明了 `globalBack` + `readerDismissDict`（`reader_fushi_page.dart:3990-3996`）。**其余全部快捷键无人接管**。
  5. 而「弹窗渲染那一刻抢一次焦点」这条旧兜底也够不着：`reader_fushi_page.dart:3974` 的 `popupRendered` 回收只在渲染时跑一次；`popup.js:6115` 的 `__fushiPopupClick` 对 `summary` 是**早退**（不发 `tapOutside`、不重查词、不重渲染），所以点展开/折叠连那一帧的 reclaim 都不会发生。点释义正文之所以没事，是因为它会触发选词→重新查词→`popupRendered`→reclaim。

  **家族关系**：BUG-136（手势后 WebView 抢走 OS 焦点无人归还）→ BUG-1071（弹窗渲染时抢回一次）→ BUG-1269（改用弹窗内 JS 桥，但只转发宿主声明的动作）→ BUG-1347（Windows 指针所有权分流）。本条是这条链在 **macOS + 可聚焦 DOM 节点** 上的未覆盖残余。

- **[x] ① 已修复** — `fushi/assets/popup/popup.js:4215`（三份镜像同步：`fushi/assets/browser_extension/vendor/popup.js`、`tools/browser-extension/vendor/popup.js`，byte-parity 守卫 `fushi/test/build/browser_extension_popup_parity_guard_test.dart`）：`<summary>` 的**主键** mousedown 取消默认动作，掐断「点击 → 节点获焦」这一步。
  - `<details>` 的开合是 `click` 的 **activation behavior**，与 mousedown 的默认动作无关 → 展开/折叠照常。
  - Tab 聚焦不受影响（只有**鼠标**聚焦是 mousedown 的默认动作），键盘可达性不变。
  - 只对主键生效：非主键本就不参与聚焦，中键/右键要原样留给弹窗输入桥的 `Mouse<n>` 转发判定。
  - 长按选词典（制卡用）、`mouseup` / `mouseleave` 撤销长按全部保留。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_summary_mouse_focus_test.dart` + 同名 `.js`（node 真执行 popup.js 里提取出的 `createGlossarySection`，拿它**实际挂上去的** mousedown 监听派发事件）：
  ① 主键 mousedown 必须 `defaultPrevented`；② 非主键必须不被拦；③ 长按仍能选中词典；④ `mouseup` 仍撤销长按。
  另有独立于被测源码的派生判据：popup.js 里 `summary` 的 mousedown 监听必须**有且只有一处**，抓错就不是自证。
  **变异实测**：删掉修复那一行后该测试红在断言 ①（`false !== true`），恢复后绿。
- **备注**：
  - **验证边界（不要写成「已验证」）**：本机无 macOS 设备，未在真机复测原始失败路径。「取消 mousedown 默认动作能阻止节点获焦」是 DOM 规范里 mousedown 的可取消默认动作，合成事件不是 trusted、默认动作本就不跑，**任何自动化层都测不到这一步**，只能靠真机手势验。上面第 1~5 环全部有代码/引擎源码支撑，但「WebKit 正是在节点获焦时移交 first responder」这一环取自 WebKit 的平台行为，本仓无法本地取证。
  - **残余（本条不处理，值得单开）**：① 弹窗里的**文本输入**（句子上下文编辑框）合法获焦，关掉之后 first responder 同样回不来——macOS 缺一条「把 first responder 还给 FlutterView」的原生通道，这是上面第 3 环的通用缺口；② `window.__fushiPopupModalDepth` 只在 `showMinedCardActionPanel` 的 `finish()` 里减（`popup.js:2173` / `:2177-2178`），而热槽 WebView 跨查词不重载、`renderPopup` 会把面板 DOM 连同 backdrop 一起抹掉 → `finish` 永不执行 → depth 永久 ≥1 → 整座 JS 桥（键盘 + 鼠标四个监听）永久让位。这是同一症状的第二条独立成因，与本条无关但同样会表现为「弹窗里快捷键全死」。
